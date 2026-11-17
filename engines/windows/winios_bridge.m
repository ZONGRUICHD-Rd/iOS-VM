/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "winios_bridge.h"

#include "hvsparse.h"
#include "share.h"
#include "winvm.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/proc.h>
#include <sys/mman.h>
#include <sys/stat.h>

static WinIOSBridge *s_shared_bridge = nil;

@interface WinIOSBridge () {
    BOOL _vmRunning;
    BOOL _unpacking;
    double _unpackProgress;
    NSString *_vmStatus;
    dispatch_queue_t _diagQueue;
    dispatch_source_t _diagTimer;
    CFAbsoluteTime _bootStartTime;
    uint64_t _configuredRamMB;
    int _configuredCPUs;
    CAMetalLayer *__weak _pendingLayer;
    uint64_t _diagTickCount;
    uint64_t _lastMachTicks;
    uint64_t _lastWfiTicks;
    double _lastWfiIdlePct;

    os_unfair_lock _metricsLock;
    CGSize _screenSizePts;
    CGFloat _screenScale;
    NSInteger _hingeStatus;
    double _hingeAngleDegrees;
}
- (void)handleVMExitWithReason:(NSString *)reason;
- (void)updateUnpackProgress:(double)frac;
- (void)startDiagTimer;
- (void)stopDiagTimer;
@end

static void vm_exit_trampoline(int reason) {
    NSString *r = [NSString stringWithUTF8String:hv_winvm_reason_name(reason)];
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_shared_bridge handleVMExitWithReason:r];
    });
}

typedef struct UnpackCtx {
    __unsafe_unretained WinIOSBridge *bridge;
    CFAbsoluteTime lastUpdate;
} UnpackCtx;

static void unpack_progress_cb(uint64_t done, uint64_t total, void *opaque) {
    UnpackCtx *ctx = (UnpackCtx *)opaque;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (done < total && now - ctx->lastUpdate < 0.2) return;
    ctx->lastUpdate = now;
    double frac = total ? (double)done / (double)total : 0.0;
    WinIOSBridge *b = ctx->bridge;
    dispatch_async(dispatch_get_main_queue(), ^{
        [b updateUnpackProgress:frac];
    });
}

@implementation WinIOSBridge

+ (WinIOSBridge *)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_shared_bridge = [[WinIOSBridge alloc] init];
    });
    return s_shared_bridge;
}

- (instancetype)init {
    if ((self = [super init])) {
        _vmStatus = @"Idle";
        _metricsLock = OS_UNFAIR_LOCK_INIT;
        _screenSizePts = CGSizeZero;
        _screenScale = 3.0;
        _hingeStatus = 0;
        _hingeAngleDegrees = -1.0;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        BOOL safariDefault = ([ud objectForKey:@"winios.safariOAuthV2"] == nil) ? YES : [ud boolForKey:@"winios.safariOAuthV2"];
        hv_share_set_url_handler_enabled(safariDefault ? 1 : 0);
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _diagQueue = dispatch_queue_create("com.henge.winvm.diag", attr);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationWillTerminateNotification object:nil];
        [nc addObserver:self selector:@selector(onAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }
    return self;
}

- (void)configureAudioSessionAndMicPermission {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions opts = AVAudioSessionCategoryOptionDefaultToSpeaker |
                                         AVAudioSessionCategoryOptionAllowBluetooth |
                                         AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                         AVAudioSessionCategoryOptionMixWithOthers;
    NSError *err = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:&err]) {
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    }
    [session setPreferredSampleRate:48000.0 error:nil];
    [session setPreferredIOBufferDuration:0.010 error:nil];
    [session setActive:YES error:nil];

    if (@available(iOS 17.0, *)) {
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            if (granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    AVAudioSession *s = [AVAudioSession sharedInstance];
                    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:nil];
                    [s setActive:YES error:nil];
                });
            }
        }];
    }
}

- (void)onAudioInterruption:(NSNotification *)note {
    NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (typeNum && typeNum.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    }
}

- (void)onAppBackgroundOrTerminate:(NSNotification *)note {
    (void)note;
    if (_vmRunning) {
        dispatch_async(_diagQueue, ^{
            hv_winvm_flush_disks();
        });
    }
}

- (void)notifyChanged {
    if ([NSThread isMainThread]) {
        if (self.onStateChanged) self.onStateChanged();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onStateChanged) self.onStateChanged();
        });
    }
}

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale {
    os_unfair_lock_lock(&_metricsLock);
    _screenSizePts = size;
    if (scale > 0.0) _screenScale = scale;
    os_unfair_lock_unlock(&_metricsLock);
}

- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees {
    os_unfair_lock_lock(&_metricsLock);
    _hingeStatus = status;
    _hingeAngleDegrees = angleDegrees;
    os_unfair_lock_unlock(&_metricsLock);
}

- (BOOL)isVMRunning { return _vmRunning; }
- (BOOL)isUnpacking { return _unpacking; }
- (double)unpackProgress { return _unpackProgress; }
- (NSString *)vmStatusText { return _vmStatus; }

- (uint32_t)framebufferWidth {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return w;
    return 0;
}

- (uint32_t)framebufferHeight {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return h;
    return 0;
}

- (uint64_t)presentedFrames {
    return _vmRunning ? hv_winvm_display_frames() : 0;
}

- (uint64_t)availableMemoryMB {
    return (uint64_t)(os_proc_available_memory() >> 20);
}

- (BOOL)usbKeyboardReady {
    if (!_vmRunning) return NO;
    int kr = 0;
    hv_winvm_usb_stats(&kr, NULL, NULL);
    return kr != 0;
}

- (BOOL)usbTabletReady {
    if (!_vmRunning) return NO;
    int tr = 0;
    hv_winvm_usb_stats(NULL, &tr, NULL);
    return tr != 0;
}

- (uint64_t)usbEventsDelivered {
    if (!_vmRunning) return 0;
    uint64_t d = 0;
    hv_winvm_usb_stats(NULL, NULL, &d);
    return d;
}

- (uint64_t)jitUsedBytes {
    if (!_vmRunning) return 0;
    uint64_t used = 0;
    hv_winvm_engine_stats(&used, NULL, NULL, NULL);
    return used;
}

- (uint64_t)jitCapBytes {
    if (!_vmRunning) return 0;
    uint64_t cap = 0;
    hv_winvm_engine_stats(NULL, &cap, NULL, NULL);
    return cap;
}

- (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
}

- (BOOL)hasRawDiskImageAt:(NSString *)dir {
    NSString *raw = [dir stringByAppendingPathComponent:@"windows11.img"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:raw error:nil];
    return attrs && [attrs fileSize] >= (64ull << 20);
}

- (BOOL)needsSparseUnpackAtDirectory:(NSString *)dir {
    NSString *sparse = [dir stringByAppendingPathComponent:@"windows11.hvsparse"];
    return [[NSFileManager defaultManager] fileExistsAtPath:sparse];
}

- (BOOL)hasProvisionedMachineAtDirectory:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"code.fd"]]) return NO;
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"vars.fd"]]) return NO;
    return [self hasRawDiskImageAt:dir] || [self needsSparseUnpackAtDirectory:dir];
}

- (void)updateUnpackProgress:(double)frac {
    _unpackProgress = frac;
    _vmStatus = [NSString stringWithFormat:@"Unpacking Windows 11 NVMe image (%.0f%%)...", frac * 100.0];
    [self notifyChanged];
}

- (void)bindMetalLayer:(nullable CAMetalLayer *)layer {
    _pendingLayer = layer;
    if (_vmRunning) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }
}

- (void)prepareAndStartInDirectory:(NSString *)dir
                             jitRx:(void *)jitRx
                             jitRw:(void *)jitRw
                          jitBytes:(size_t)jitBytes
                             ramMB:(uint64_t)ramMB
                              cpus:(int)cpus
                             layer:(nullable CAMetalLayer *)layer {
    if (layer) _pendingLayer = layer;
    if (_vmRunning || _unpacking) return;

    if (!jitRx || !jitRw || jitBytes == 0) {
        _vmStatus = @"Error: JIT region missing";
        [self notifyChanged];
        return;
    }

    if (![self hasProvisionedMachineAtDirectory:dir]) {
        _vmStatus = @"Missing code.fd, vars.fd, or windows11.img/.hvsparse";
        [self notifyChanged];
        return;
    }

    if ([self needsSparseUnpackAtDirectory:dir] && ![self hasRawDiskImageAt:dir]) {
        _unpacking = YES;
        _unpackProgress = 0.0;
        _vmStatus = @"Unpacking Windows 11 NVMe image (0%)...";
        [self notifyChanged];

        NSString *src = [dir stringByAppendingPathComponent:@"windows11.hvsparse"];
        NSString *dst = [dir stringByAppendingPathComponent:@"windows11.img"];
        NSString *tmpDst = [dir stringByAppendingPathComponent:@"windows11.img.unpacking"];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            unlink(tmpDst.fileSystemRepresentation);
            unlink(dst.fileSystemRepresentation);
            UnpackCtx ctx = {.bridge = self, .lastUpdate = 0};
            int rc = hv_sparse_unpack(src.fileSystemRepresentation, tmpDst.fileSystemRepresentation, unpack_progress_cb, &ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_unpacking = NO;
                if (rc == 0) {
                    unlink(dst.fileSystemRepresentation);
                    rename(tmpDst.fileSystemRepresentation, dst.fileSystemRepresentation);
                    unlink(src.fileSystemRepresentation);
                    self->_unpackProgress = 1.0;
                    [self startConfiguredVMInDirectory:dir jitRx:jitRx jitRw:jitRw jitBytes:jitBytes ramMB:ramMB cpus:cpus];
                } else {
                    unlink(tmpDst.fileSystemRepresentation);
                    self->_vmStatus = @"Error: failed to unpack windows11.hvsparse";
                    [self notifyChanged];
                }
            });
        });
        return;
    }

    [self startConfiguredVMInDirectory:dir jitRx:jitRx jitRw:jitRw jitBytes:jitBytes ramMB:ramMB cpus:cpus];
}

- (void)startConfiguredVMInDirectory:(NSString *)dir
                               jitRx:(void *)jitRx
                               jitRw:(void *)jitRw
                            jitBytes:(size_t)jitBytes
                               ramMB:(uint64_t)reqRamMB
                                cpus:(int)reqCpus {
    if (_vmRunning) return;
    [self configureAudioSessionAndMicPermission];

    NSString *ramBacking = [dir stringByAppendingPathComponent:@"ram.tmp"];
    setenv("HV_RAM_FILE", ramBacking.fileSystemRepresentation, 1);

    uint64_t ramMB = reqRamMB >= 1024 ? reqRamMB : 3072;
    /* Probe contiguous virtual address space (ramMB + 256 MB headroom for pflash/DTB) and step down if needed. */
    while (ramMB > 1024) {
        size_t probe = (size_t)((ramMB + 256ULL) << 20);
        void *p = mmap(NULL, probe, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
            munmap(p, probe);
            break;
        }
        ramMB = (ramMB > 1536) ? (ramMB - 512) : 1024;
    }

    NSString *sharedDir = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sharedDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *rawTmp = [NSTemporaryDirectory() stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
    NSString *shareSock = [rawTmp stringByAppendingPathComponent:@"w"];
    unlink(shareSock.fileSystemRepresentation);

    NSString *codePath = [dir stringByAppendingPathComponent:@"code.fd"];
    NSString *varsPath = [dir stringByAppendingPathComponent:@"vars.fd"];
    NSString *diskPath = [dir stringByAppendingPathComponent:@"windows11.img"];

    _configuredRamMB = ramMB;
    _configuredCPUs = reqCpus >= 1 ? reqCpus : 4;

    HvWinVmConfig cfg = {
        .code_fd = codePath.fileSystemRepresentation,
        .vars_fd = varsPath.fileSystemRepresentation,
        .disk0 = diskPath.fileSystemRepresentation,
        .disk1 = NULL,
        .share_dir = sharedDir.fileSystemRepresentation,
        .share_sock = shareSock.fileSystemRepresentation,
        .ncpus = _configuredCPUs,
        .ram_mb = _configuredRamMB,
        .jit_bytes = jitBytes,
        .jit_rx = jitRx,
        .jit_rw = jitRw,
        .prealloc_ram = NULL,
        .no_net = 0,
        .enable_sound = 1,
        .log = 0,
        .stats_interval = 0,
    };

    char err[256] = {0};
    if (hv_winvm_create(&cfg, err, sizeof err) != 0) {
        _vmStatus = [NSString stringWithFormat:@"VM create failed: %s", err];
        [self notifyChanged];
        return;
    }

    CAMetalLayer *layer = _pendingLayer;
    if (layer) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }

    _vmRunning = YES;
    _bootStartTime = CFAbsoluteTimeGetCurrent();
    _diagTickCount = 0;
    _lastMachTicks = mach_absolute_time();
    _lastWfiTicks = 0;
    _lastWfiIdlePct = 0.0;
    _vmStatus = [NSString stringWithFormat:@"Running Windows 11 ARM64 (%d vCPUs, %llu MB RAM)", _configuredCPUs, _configuredRamMB];
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

    hv_winvm_start(1, vm_exit_trampoline);

    [self startDiagTimer];
    [self notifyChanged];
}

- (void)startDiagTimer {
    [self stopDiagTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _diagQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                              8ull * NSEC_PER_SEC,
                              1ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onDiagTickBackground];
    });
    _diagTimer = timer;
    dispatch_resume(timer);
}

- (void)stopDiagTimer {
    if (_diagTimer) {
        dispatch_source_cancel(_diagTimer);
        _diagTimer = nil;
    }
}

- (void)onDiagTickBackground {
    _diagTickCount++;
    if (_vmRunning && (_diagTickCount % 4u) == 0u) {
        hv_winvm_flush_disks();
    }
    [self notifyChanged];
}

- (void)handleVMExitWithReason:(NSString *)reason {
    _vmRunning = NO;
    [self stopDiagTimer];
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    _vmStatus = [NSString stringWithFormat:@"Stopped (%@)", reason];
    [self notifyChanged];
    if (self.onVMStopped) self.onVMStopped(reason);
}

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel {
    if (!_vmRunning) return;
    hv_winvm_tablet(x, y, buttons, wheel);
}

- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, down ? 1 : 0);
}

- (void)sendKeyLinux:(uint16_t)code down:(BOOL)down {
    if (!_vmRunning) return;
    hv_winvm_key_linux(code, down ? 1 : 0);
}

- (void)tapKeyHid:(uint8_t)usage {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        hv_winvm_key_hid(usage, 0);
    });
}

- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage {
    if (!_vmRunning) return;
    for (NSNumber *m in modifiers) {
        hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 1);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (usage != 0) hv_winvm_key_hid(usage, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(38 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (usage != 0) hv_winvm_key_hid(usage, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                for (NSNumber *m in [modifiers reverseObjectEnumerator]) {
                    hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 0);
                }
            });
        });
    });
}

- (void)sendWindowsKey { [self tapKeyHid:0xe3]; }
- (void)sendEscape { [self tapKeyHid:0x29]; }
- (void)sendAltTab { [self sendKeyComboWithModifiers:@[@(0xe2)] key:0x2b]; }
- (void)sendCtrlAltDel { if (_vmRunning) hv_winvm_send_ctrl_alt_del(); }
- (void)pressPowerButton { if (_vmRunning) hv_winvm_power_button(); }
- (void)flushDisks { if (_vmRunning) hv_winvm_flush_disks(); }
- (void)stopVM { if (_vmRunning) hv_winvm_stop(); }

- (BOOL)saveScreenshotToPath:(NSString *)path {
    if (!_vmRunning) return NO;
    return hv_winvm_save_png(path.fileSystemRepresentation) == 0;
}

- (BOOL)useSafariForGuestLinks {
    return hv_share_url_handler_enabled() != 0;
}

- (void)setUseSafariForGuestLinks:(BOOL)useSafariForGuestLinks {
    hv_share_set_url_handler_enabled(useSafariForGuestLinks ? 1 : 0);
    [[NSUserDefaults standardUserDefaults] setBool:useSafariForGuestLinks forKey:@"winios.safariOAuthV2"];
}

- (nullable NSString *)takeGuestOpenURL {
    char *raw = hv_share_take_open_url();
    if (!raw) return nil;
    NSString *s = [NSString stringWithUTF8String:raw];
    free(raw);
    return s;
}

- (BOOL)takeGuestOAuthDone {
    return hv_share_take_oauth_done() != 0;
}

@end
