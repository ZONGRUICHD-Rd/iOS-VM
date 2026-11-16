// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import SafariServices
import SwiftUI
import UIKit
import WinVM

struct WindowsSessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @AppStorage("henge.cpus") private var cpus = 4
    @StateObject private var controller = WindowsSessionController()
    @State private var trackpadMode = false
    @State private var rightClickArmed = false
    @State private var showKeyboard = false
    @State private var showDetails = false
    @State private var confirmStop = false
    @State private var controlsHidden = false
    @State private var stoppedReason: String?

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height

            ZStack {
                (landscape ? Color.black : Desk.page)

                VStack(spacing: 0) {
                    if !landscape {
                        Spacer().frame(height: max(insets.top + 8, 16))
                    }

                    ZStack {
                        WinMetalCanvasView(
                            trackpadMode: $trackpadMode,
                            rightClickArmed: $rightClickArmed,
                            showKeyboard: $showKeyboard
                        )
                        .clipShape(RoundedRectangle(cornerRadius: landscape ? 0 : 15, style: .continuous))
                        .overlay {
                            if !landscape {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                            }
                        }

                        if controller.isUnpacking {
                            VStack(spacing: 12) {
                                ProgressView(value: controller.unpackProgress)
                                    .tint(Desk.accent)
                                    .frame(maxWidth: 240)
                                Text(controller.statusText)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .padding(20)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else if !controller.isRunning && stoppedReason == nil && controller.errorMessage == nil {
                            VStack(spacing: 10) {
                                ProgressView().tint(.white)
                                Text(controller.statusText)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(20)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }

                        if let err = controller.errorMessage {
                            VStack(spacing: 12) {
                                Text(err)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                Button("Close") { close() }
                                    .buttonStyle(DeskButtonStyle())
                                    .frame(maxWidth: 200)
                            }
                            .padding(22)
                            .frame(maxWidth: 340)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : full.width * 0.68)
                    .padding(.horizontal, landscape ? 0 : 8)

                    if !landscape {
                        Spacer(minLength: 8)
                        if let reason = stoppedReason {
                            StoppedMacView(outcome: 0, reason: reason, start: {
                                stoppedReason = nil
                                controller.start(mac: mac, cpus: cpus)
                            }, close: close)
                            .frame(maxWidth: 360)
                            .padding(.bottom, max(insets.bottom, 20))
                        } else {
                            uprightControls
                                .padding(.horizontal, 16)
                                .padding(.bottom, max(insets.bottom + 8, 20))
                        }
                    }
                }

                if landscape && !controlsHidden && stoppedReason == nil {
                    VStack {
                        floatingPill
                            .padding(.top, max(insets.top + 8, 14))
                        Spacer()
                    }
                } else if landscape && stoppedReason != nil {
                    StoppedMacView(outcome: 0, reason: stoppedReason ?? "Stopped", start: {
                        stoppedReason = nil
                        controller.start(mac: mac, cpus: cpus)
                    }, close: close)
                    .frame(maxWidth: 360)
                }
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showDetails) { detailsSheet }
        .sheet(item: $controller.activeSafariURL) { item in
            WinSafariSheet(url: item.url)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Send Power Button") { WinIOSBridge.shared.pressPowerButton() }
            Button("Force Stop", role: .destructive) {
                controller.savePreview(for: mac)
                WinIOSBridge.shared.stopVM()
                close()
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            var updated = mac
            updated.lastUsed = Date()
            Machines.shared.update(updated)
            controller.onStopped = { reason in
                controller.savePreview(for: mac)
                stoppedReason = reason
            }
            controller.start(mac: mac, cpus: cpus)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.savePreview(for: mac)
        }
    }

    private var uprightControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                controlChip(title: trackpadMode ? "Trackpad" : "Touch", icon: trackpadMode ? "rectangle.and.hand.point.up.left" : "hand.tap") {
                    trackpadMode.toggle()
                }
                controlChip(title: "Keyboard", icon: "keyboard", active: showKeyboard) {
                    showKeyboard.toggle()
                }
                controlChip(title: "Right Click", icon: "computermouse", active: rightClickArmed) {
                    rightClickArmed.toggle()
                }
            }
            HStack(spacing: 10) {
                controlChip(title: "Win", icon: "square.grid.2x2") {
                    WinIOSBridge.shared.sendWindowsKey()
                }
                controlChip(title: "Ctrl+Alt+Del", icon: "lock.shield") {
                    WinIOSBridge.shared.sendCtrlAltDel()
                }
                controlChip(title: "Info", icon: "info.circle") {
                    showDetails = true
                }
                controlChip(title: "Stop", icon: "power", tint: Desk.bad) {
                    confirmStop = true
                }
            }
        }
    }

    private var floatingPill: some View {
        HStack(spacing: 12) {
            Button { confirmStop = true } label: {
                Image(systemName: "power").foregroundStyle(Desk.bad)
            }
            Button { showKeyboard.toggle() } label: {
                Image(systemName: "keyboard").foregroundStyle(showKeyboard ? Desk.accentLight : .white)
            }
            Button { trackpadMode.toggle() } label: {
                Image(systemName: trackpadMode ? "rectangle.and.hand.point.up.left" : "hand.tap")
                    .foregroundStyle(.white)
            }
            Button { WinIOSBridge.shared.sendWindowsKey() } label: {
                Image(systemName: "square.grid.2x2").foregroundStyle(.white)
            }
            Button { showDetails = true } label: {
                Image(systemName: "info.circle").foregroundStyle(.white)
            }
            Button { controlsHidden = true } label: {
                Image(systemName: "eye.slash").foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .deskGlass(in: Capsule())
    }

    private func controlChip(title: String, icon: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Desk.accentLight : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 10)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(active ? Desk.accentLight : Desk.hairline, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private var detailsSheet: some View {
        NavigationStack {
            List {
                Section("Windows 11 ARM64") {
                    LabeledContent("Status", value: controller.statusText)
                    LabeledContent("Display", value: "\(controller.fbWidth) × \(controller.fbHeight)")
                    LabeledContent("Frames", value: "\(controller.frames)")
                    LabeledContent("USB Keyboard", value: controller.kbdReady ? "Ready" : "Waiting")
                    LabeledContent("USB Tablet", value: controller.tabReady ? "Ready" : "Waiting")
                }
                Section("OAuth & Keys") {
                    Toggle("Open OAuth Links in iOS Safari", isOn: Binding(
                        get: { controller.useSafariOAuth },
                        set: { controller.setUseSafariOAuth($0) }
                    ))
                    Button("Send Windows Key") { WinIOSBridge.shared.sendWindowsKey(); showDetails = false }
                    Button("Send Alt + Tab") { WinIOSBridge.shared.sendAltTab(); showDetails = false }
                    Button("Send Ctrl + Alt + Del") { WinIOSBridge.shared.sendCtrlAltDel(); showDetails = false }
                }
                Section {
                    Button("ACPI Power Button") { WinIOSBridge.shared.pressPowerButton(); showDetails = false }
                    Button("Force Stop", role: .destructive) {
                        showDetails = false
                        WinIOSBridge.shared.stopVM()
                        close()
                    }
                }
            }
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDetails = false }
                }
            }
        }
    }
}

@MainActor
private final class WindowsSessionController: ObservableObject {
    struct IdentifiableURL: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published var isRunning = false
    @Published var isUnpacking = false
    @Published var unpackProgress: Double = 0
    @Published var statusText = "Starting Windows 11…"
    @Published var errorMessage: String?
    @Published var fbWidth: UInt32 = 0
    @Published var fbHeight: UInt32 = 0
    @Published var frames: UInt64 = 0
    @Published var kbdReady = false
    @Published var tabReady = false
    @Published var activeSafariURL: IdentifiableURL?
    @Published var useSafariOAuth = WinIOSBridge.shared.useSafariForGuestLinks

    var onStopped: ((String) -> Void)?
    private var pollTimer: Timer?

    init() {
        let b = WinIOSBridge.shared
        b.onStateChanged = { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        b.onVMStopped = { [weak self] reason in
            Task { @MainActor in self?.onStopped?(reason) }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    func start(mac: VirtualMac, cpus: Int) {
        guard let mapping = henge_ios_jit_get_mapping()?.pointee,
              let rx = mapping.rx_addr,
              let rw = mapping.rw_addr,
              mapping.size > 0 else {
            errorMessage = "JIT region is not ready. Turn on JIT first."
            return
        }
        let b = WinIOSBridge.shared
        b.prepareAndStart(
            inDirectory: mac.directory.path,
            jitRx: rx,
            jitRw: rw,
            jitBytes: mapping.size,
            ramMB: UInt64(mac.ramMB),
            cpus: Int32(cpus),
            layer: nil
        )
        sync()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let b = WinIOSBridge.shared
                if b.takeGuestOAuthDone(), self.activeSafariURL != nil {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.activeSafariURL = nil
                }
                if let raw = b.takeGuestOpenURL(), let u = URL(string: raw) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self.activeSafariURL = IdentifiableURL(url: u)
                }
                self.sync()
            }
        }
    }

    func setUseSafariOAuth(_ on: Bool) {
        WinIOSBridge.shared.useSafariForGuestLinks = on
        useSafariOAuth = on
    }

    func savePreview(for mac: VirtualMac) {
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("win_preview_\(mac.id.uuidString).png")
        guard WinIOSBridge.shared.saveScreenshot(toPath: pngURL.path),
              let img = UIImage(contentsOfFile: pngURL.path),
              let jpg = img.jpegData(compressionQuality: 0.8) else { return }
        try? FileManager.default.removeItem(at: pngURL)
        try? jpg.write(to: MacPreview.file(for: mac), options: .atomic)
    }

    private func sync() {
        let b = WinIOSBridge.shared
        isRunning = b.isVMRunning
        isUnpacking = b.isUnpacking
        unpackProgress = b.unpackProgress
        statusText = b.vmStatusText
        fbWidth = b.framebufferWidth
        fbHeight = b.framebufferHeight
        frames = b.presentedFrames
        kbdReady = b.usbKeyboardReady
        tabReady = b.usbTabletReady
        if statusText.hasPrefix("Error:") || statusText.hasPrefix("VM create failed:") {
            errorMessage = statusText
        }
    }
}

private struct WinSafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        return vc
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct WinMetalCanvasView: UIViewRepresentable {
    @Binding var trackpadMode: Bool
    @Binding var rightClickArmed: Bool
    @Binding var showKeyboard: Bool

    func makeUIView(context: Context) -> WinCanvasUIView {
        let v = WinCanvasUIView(frame: .zero)
        v.onRightClickConsumed = { DispatchQueue.main.async { rightClickArmed = false } }
        v.onKeyboardDismissed = { DispatchQueue.main.async { showKeyboard = false } }
        return v
    }

    func updateUIView(_ uiView: WinCanvasUIView, context: Context) {
        uiView.trackpadMode = trackpadMode
        uiView.rightClickArmed = rightClickArmed
        if showKeyboard && !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !showKeyboard && uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }
}

private final class WinCanvasUIView: UIView, UIKeyInput {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var trackpadMode = false
    var rightClickArmed = false
    var onRightClickConsumed: (() -> Void)?
    var onKeyboardDismissed: (() -> Void)?

    private var cursorX = 0.5
    private var cursorY = 0.5
    private var panLast: CGPoint = .zero
    private var activeDragButtons: UInt8 = 0
    private var scrollAccum: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        if #available(iOS 13.4, *) { scroll.allowedScrollTypesMask = .all }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.45

        for gr in [tap, twoTap, pan, scroll, hold] { addGestureRecognizer(gr) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableScale()
        if window != nil { WinIOSBridge.shared.bindMetalLayer(metalLayer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableScale()
    }

    private func updateDrawableScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    private func norm(_ pt: CGPoint) -> (Double, Double) {
        let bw = max(1.0, bounds.width), bh = max(1.0, bounds.height)
        let fw = Double(WinIOSBridge.shared.framebufferWidth), fh = Double(WinIOSBridge.shared.framebufferHeight)
        var rect = bounds
        if fw > 0 && fh > 0 {
            let va = Double(bw / bh), fa = fw / fh
            if va > fa {
                let w = CGFloat(Double(bh) * fa)
                rect = CGRect(x: (bw - w) * 0.5, y: 0, width: w, height: bh)
            } else {
                let h = CGFloat(Double(bw) / fa)
                rect = CGRect(x: 0, y: (bh - h) * 0.5, width: bw, height: h)
            }
        }
        return (min(1, max(0, Double((pt.x - rect.minX) / max(1, rect.width)))),
                min(1, max(0, Double((pt.y - rect.minY) / max(1, rect.height)))))
    }

    private func click(x: Double, y: Double, mask: UInt8) {
        cursorX = x; cursorY = y
        WinIOSBridge.shared.sendTabletNormalizedX(x, y: y, buttons: 0, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.014) {
            WinIOSBridge.shared.sendTabletNormalizedX(x, y: y, buttons: mask, wheel: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
                WinIOSBridge.shared.sendTabletNormalizedX(x, y: y, buttons: 0, wheel: 0)
            }
        }
    }

    @objc private func onTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        let mask: UInt8 = rightClickArmed ? 2 : 1
        if rightClickArmed { rightClickArmed = false; onRightClickConsumed?() }
        if trackpadMode {
            click(x: cursorX, y: cursorY, mask: mask)
        } else {
            let (nx, ny) = norm(gr.location(in: self))
            click(x: nx, y: ny, mask: mask)
        }
    }

    @objc private func onTwoTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        click(x: cursorX, y: cursorY, mask: 2)
    }

    @objc private func onHold(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        if trackpadMode {
            click(x: cursorX, y: cursorY, mask: 2)
        } else {
            let (nx, ny) = norm(gr.location(in: self))
            click(x: nx, y: ny, mask: 2)
        }
    }

    @objc private func onPan(_ gr: UIPanGestureRecognizer) {
        let loc = gr.location(in: self)
        switch gr.state {
        case .began:
            panLast = loc
            if !trackpadMode {
                let (nx, ny) = norm(loc)
                cursorX = nx; cursorY = ny
                activeDragButtons = rightClickArmed ? 2 : 1
                if rightClickArmed { rightClickArmed = false; onRightClickConsumed?() }
                WinIOSBridge.shared.sendTabletNormalizedX(nx, y: ny, buttons: activeDragButtons, wheel: 0)
            }
        case .changed:
            if trackpadMode {
                let dx = Double(loc.x - panLast.x) / Double(max(220, bounds.width)) * 1.4
                let dy = Double(loc.y - panLast.y) / Double(max(130, bounds.height)) * 1.4
                panLast = loc
                cursorX = min(1, max(0, cursorX + dx))
                cursorY = min(1, max(0, cursorY + dy))
                WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: activeDragButtons, wheel: 0)
            } else {
                let (nx, ny) = norm(loc)
                cursorX = nx; cursorY = ny
                WinIOSBridge.shared.sendTabletNormalizedX(nx, y: ny, buttons: activeDragButtons, wheel: 0)
            }
        case .ended, .cancelled, .failed:
            if activeDragButtons != 0 {
                activeDragButtons = 0
                WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: 0, wheel: 0)
            }
        default: break
        }
    }

    @objc private func onScroll(_ gr: UIPanGestureRecognizer) {
        let trans = gr.translation(in: self)
        if gr.state == .began { scrollAccum = 0 }
        else if gr.state == .changed {
            let delta = trans.y - scrollAccum
            if abs(delta) >= 12 {
                let steps = Int(delta / 12)
                scrollAccum += CGFloat(steps) * 12
                WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: 0, wheel: Int8(clamping: max(-8, min(8, steps))))
            }
        }
    }

    // MARK: Keyboard (Linux keycodes -> WinVM hv_winvm_key_linux / HID)
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no

    func insertText(_ text: String) {
        for ch in text {
            guard let stroke = LinuxKeys.stroke(for: ch) else { continue }
            if stroke.shift { WinIOSBridge.shared.sendKeyLinux(LinuxKeys.leftShift, down: true) }
            WinIOSBridge.shared.sendKeyLinux(stroke.code, down: true)
            WinIOSBridge.shared.sendKeyLinux(stroke.code, down: false)
            if stroke.shift { WinIOSBridge.shared.sendKeyLinux(LinuxKeys.leftShift, down: false) }
        }
    }

    func deleteBackward() {
        WinIOSBridge.shared.tapKeyHid(0x2a)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onKeyboardDismissed?() }
        return ok
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let k = p.key, k.keyCode.rawValue <= 0xff {
                WinIOSBridge.shared.sendKeyHid(UInt8(k.keyCode.rawValue), down: true)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let k = p.key, k.keyCode.rawValue <= 0xff {
                WinIOSBridge.shared.sendKeyHid(UInt8(k.keyCode.rawValue), down: false)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }
}
