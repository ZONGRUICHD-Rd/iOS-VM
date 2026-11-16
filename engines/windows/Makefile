CC = clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost -Idevices
OBJCFLAGS = -fobjc-arc -Wall -Wextra -O2 -g -Icore -Ihost -Idevices
B = build

# ---- iOS dynamic framework target: build/ios/WinVM.framework ----
IOS_SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
IOS_CC = env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=18.0 -isysroot $(IOS_SDK)
IOS_SLIRP_INC ?= ../../third_party/slirp_include
IOS_SLIRP_FW ?= ../../ios/Frameworks/Slirp.xcframework/ios-arm64
IOS_GLIB_FW ?= ../../ios/Frameworks/GLib.xcframework/ios-arm64
IOS_CFLAGS = -std=c11 -Wall -Wextra -O2 -g -fPIC -Icore -Ihost -Idevices -I$(IOS_SLIRP_INC)
IOS_OBJCFLAGS = -fobjc-arc -Wall -Wextra -O2 -g -fPIC -Icore -Ihost -Idevices -I.
IB = build/ios

IOS_C_SRC = $(wildcard core/*.c) \
            host/jit_region.c host/disk.c host/winvm.c host/net_slirp.c host/share.c \
            host/audio_mac.c host/hvsparse.c host/prof_ios.c \
            $(wildcard devices/*.c)
IOS_OBJ = $(patsubst %.c,$(IB)/%.o,$(IOS_C_SRC)) $(IB)/host/enter.o $(IB)/devices/fb_metal.o $(IB)/winios_bridge.o

WINVM_FW = $(IB)/WinVM.framework
WINVM_LIBS = -F$(IOS_SLIRP_FW) -F$(IOS_GLIB_FW) -framework slirp -framework glib \
             -framework Foundation -framework UIKit -framework CoreGraphics \
             -framework QuartzCore -framework Metal -framework AudioToolbox \
             -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers

$(IB)/core/mmu.o: core/mmu.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -mgeneral-regs-only -c $< -o $@
$(IB)/%.o: %.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -c $< -o $@
$(IB)/devices/fb_metal.o: devices/fb_metal.m devices/*.h core/*.h host/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_OBJCFLAGS) -c $< -o $@
$(IB)/winios_bridge.o: winios_bridge.m winios_bridge.h host/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_OBJCFLAGS) -c $< -o $@
$(IB)/host/enter.o: host/enter.S
	@mkdir -p $(dir $@)
	$(IOS_CC) -c $< -o $@

$(WINVM_FW)/WinVM: $(IOS_OBJ)
	@mkdir -p $(WINVM_FW)/Headers $(WINVM_FW)/Modules
	$(IOS_CC) -dynamiclib -install_name @rpath/WinVM.framework/WinVM \
		-Wl,-rpath,@executable_path/Frameworks -Wl,-rpath,@loader_path/Frameworks \
		$(IOS_OBJ) $(WINVM_LIBS) -o $@
	cp winios_bridge.h $(WINVM_FW)/Headers/winios_bridge.h
	printf 'framework module WinVM {\n    header "winios_bridge.h"\n    export *\n}\n' > $(WINVM_FW)/Modules/module.modulemap
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n  <key>CFBundleIdentifier</key><string>com.henge.app.WinVM</string>\n  <key>CFBundleExecutable</key><string>WinVM</string>\n  <key>CFBundleName</key><string>WinVM</string>\n  <key>CFBundlePackageType</key><string>FMWK</string>\n  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n  <key>CFBundleShortVersionString</key><string>1.0</string>\n  <key>CFBundleVersion</key><string>1</string>\n  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>\n  <key>MinimumOSVersion</key><string>18.0</string>\n</dict></plist>\n' > $(WINVM_FW)/Info.plist

ios-framework: $(WINVM_FW)/WinVM

clean:
	rm -rf $(B)

.PHONY: ios-framework clean
