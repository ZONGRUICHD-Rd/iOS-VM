// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

@MainActor
final class LinuxExternalDisplay {
    static let shared = LinuxExternalDisplay()

    private var bridge: DisplayBridge?
    private var scene: UIWindowScene?
    private var window: UIWindow?

    var hasActiveSession: Bool { bridge != nil }

    func show(_ bridge: DisplayBridge?) {
        guard bridge !== self.bridge else { return }
        takeWindowOff()
        self.bridge = bridge
        putWindowOn()
    }

    func connected(_ scene: UIWindowScene) {
        takeWindowOff()
        self.scene = scene
        putWindowOn()
    }

    func disconnected(_ scene: UIWindowScene) {
        guard scene === self.scene else { return }
        takeWindowOff()
        self.scene = nil
    }

    private func putWindowOn() {
        guard let scene, let bridge, window == nil else { return }
        let screen = LinuxExternalScreenController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = screen
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        self.window = window
        bridge.connect(.external) { [weak screen] image in screen?.show(image) }
        bridge.fitExternal(Self.pixels(of: scene.screen))
    }

    private func takeWindowOff() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        bridge?.disconnect(.external)
        bridge?.fitExternal(nil)
    }

    private static func pixels(of screen: UIScreen) -> CGSize {
        screen.currentMode?.size ?? screen.nativeBounds.size
    }
}

final class LinuxExternalScreenController: UIViewController {
    private let picture = CALayer()

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        picture.contentsGravity = .resizeAspect
        picture.magnificationFilter = .linear
        view.layer.addSublayer(picture)
        self.view = view
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = view.bounds
        CATransaction.commit()
    }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }
}
