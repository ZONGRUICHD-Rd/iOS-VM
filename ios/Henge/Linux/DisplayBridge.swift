// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CrateEngine
import Foundation

final class DisplayBridge: @unchecked Sendable {
    enum Viewer: Hashable {
        case app
        case external
    }

    private let lock = NSLock()
    private var machine: OpaquePointer?
    private let index: UInt32 = 0

    private var pixels: UnsafeMutableRawPointer?
    private var width = 0
    private var height = 0
    private var flushScheduled = false
    private var sinks: [Viewer: @MainActor (CGImage?) -> Void] = [:]
    private var wantsActive = false
    private var otherModes: [crate_display_mode] = []
    private var fitted: crate_display_mode?
    private var external: crate_display_mode?
    private var preferred: crate_display_mode? { external ?? fitted }
    private var offered: crate_display_mode?
    private var lastPointer = CGPoint(x: 0.5, y: 0.5)

    var callbacks: crate_display_callbacks {
        crate_display_callbacks(
            size: MemoryLayout<crate_display_callbacks>.size,
            context: Unmanaged.passUnretained(self).toOpaque(),
            frame: { context, _, frame in
                guard let context, let frame else { return }
                Unmanaged<DisplayBridge>.fromOpaque(context).takeUnretainedValue().take(frame.pointee)
            })
    }

    deinit {
        pixels?.deallocate()
    }

    func attach(machine: OpaquePointer) {
        let active = lock.withLock { () -> Bool in
            self.machine = machine
            return wantsActive
        }
        if active { crate_display_set_active(machine, index, true) }
        offerModes()
    }

    func modes(after others: [crate_display_mode]) -> [crate_display_mode] {
        lock.withLock {
            otherModes = others
            offered = preferred
            return list()
        }
    }

    @MainActor
    func fit(_ points: CGSize, window: CGSize?) {
        let mode: crate_display_mode
        if let window {
            let key = "linux.display.landscape.\(Int(max(window.width, window.height)))x\(Int(min(window.width, window.height)))"
            if points.width >= points.height {
                guard let fitted = Self.mode(fitting: points) else { return }
                UserDefaults.standard.set([Int(fitted.width), Int(fitted.height)], forKey: key)
                mode = fitted
            } else if let saved = UserDefaults.standard.array(forKey: key) as? [Int], saved.count == 2 {
                mode = crate_display_mode(width: UInt32(saved[0]), height: UInt32(saved[1]))
            } else {
                guard let swapped = Self.mode(fitting: points) else { return }
                mode = swapped
            }
        } else {
            guard let fitted = Self.mode(fitting: points) else { return }
            mode = fitted
        }
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let (changed, deferred) = lock.withLock { () -> (Bool, Bool) in
                guard self.fitted?.width != mode.width || self.fitted?.height != mode.height else { return (false, false) }
                self.fitted = mode
                return (true, self.external != nil)
            }
            guard changed else { return }
            HengeLog.log("linux", "display: \(mode.width)x\(mode.height) fits \(Int(points.width))x\(Int(points.height)) pt"
                         + (deferred ? ", offered once the external display goes" : ""))
            offerModes()
        }
        pendingFit = work
        let first = lock.withLock { fitted == nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.4), execute: work)
    }
    @MainActor private var pendingFit: DispatchWorkItem?

    @MainActor
    func fitExternal(_ pixels: CGSize?) {
        let mode = pixels.flatMap(Self.mode(forPixels:))
        let (changed, view) = lock.withLock { () -> (Bool, crate_display_mode?) in
            guard external?.width != mode?.width || external?.height != mode?.height else { return (false, nil) }
            external = mode
            return (true, fitted)
        }
        guard changed else { return }
        if let mode, let pixels {
            HengeLog.log("linux", "display: \(mode.width)x\(mode.height) fits external \(Int(pixels.width))x\(Int(pixels.height)) px")
        } else if let view {
            HengeLog.log("linux", "display: \(view.width)x\(view.height) fits the view again")
        }
        pendingExternal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.offerModes() }
        pendingExternal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    @MainActor private var pendingExternal: DispatchWorkItem?

    nonisolated static func mode(fitting points: CGSize) -> crate_display_mode? {
        let short = min(points.width, points.height), long = max(points.width, points.height)
        guard short >= 100 else { return nil }
        return landscape(long: long, short: short, scale: min(max(1, 600 / short), 2560 / long))
    }

    nonisolated static func mode(forPixels pixels: CGSize) -> crate_display_mode? {
        let short = min(pixels.width, pixels.height), long = max(pixels.width, pixels.height)
        guard short >= 100 else { return nil }
        return landscape(long: long, short: short, scale: min(1, 2560 / long))
    }

    private nonisolated static func landscape(long: CGFloat, short: CGFloat, scale: CGFloat) -> crate_display_mode {
        let round8 = { (v: CGFloat) in UInt32(max(8, (v * scale / 8).rounded() * 8)) }
        return crate_display_mode(width: round8(long), height: round8(short))
    }

    private func list() -> [crate_display_mode] {
        guard let preferred else { return otherModes }
        return [preferred] + otherModes.filter { $0.width != preferred.width || $0.height != preferred.height }
    }

    private func offerModes() {
        let offer = lock.withLock { () -> (OpaquePointer, [crate_display_mode])? in
            guard let machine, let preferred, !otherModes.isEmpty,
                  offered?.width != preferred.width || offered?.height != preferred.height else { return nil }
            offered = preferred
            return (machine, list())
        }
        if let (machine, modes) = offer {
            crate_display_set_modes(machine, index, modes, modes.count)
        }
    }

    @MainActor
    func detach() {
        lock.withLock { machine = nil }
        forgetScreen()
    }

    @MainActor
    func reset() {
        forgetScreen()
    }

    @MainActor
    private func forgetScreen() {
        let sinks = lock.withLock { () -> [@MainActor (CGImage?) -> Void] in
            pixels?.deallocate()
            pixels = nil
            width = 0
            height = 0
            return Array(self.sinks.values)
        }
        for sink in sinks { sink(nil) }
    }

    @MainActor
    func connect(_ viewer: Viewer, _ sink: @escaping @MainActor (CGImage?) -> Void) {
        let machine = lock.withLock { () -> OpaquePointer? in
            let first = sinks.isEmpty
            sinks[viewer] = sink
            wantsActive = true
            return first ? self.machine : nil
        }
        if let machine { crate_display_set_active(machine, index, true) }
        if let image = picture() { sink(image) }
        if viewer == .external { onExternalChange?(true) }
    }

    @MainActor
    func disconnect(_ viewer: Viewer) {
        let (removed, machine) = lock.withLock { () -> (Bool, OpaquePointer?) in
            guard sinks.removeValue(forKey: viewer) != nil else { return (false, nil) }
            guard sinks.isEmpty else { return (true, nil) }
            wantsActive = false
            return (true, self.machine)
        }
        if let machine { crate_display_set_active(machine, index, false) }
        if removed, viewer == .external { onExternalChange?(false) }
    }

    @MainActor
    var isShownExternally: Bool {
        lock.withLock { sinks[.external] != nil }
    }

    @MainActor var onExternalChange: ((Bool) -> Void)?

    var size: CGSize {
        lock.withLock { CGSize(width: width, height: height) }
    }

    func key(_ code: UInt16, down: Bool) {
        lock.withLock {
            guard let machine else { return }
            crate_input_key(machine, code, down)
        }
    }

    func pointer(x: Double, y: Double, buttons: UInt32) {
        let x = max(0, min(1, x)), y = max(0, min(1, y))
        let scale = 32767.0
        lock.withLock {
            lastPointer = CGPoint(x: x, y: y)
            guard let machine else { return }
            crate_input_pointer(machine, UInt32(x * scale), UInt32(y * scale), buttons)
        }
    }

    var pointerPosition: CGPoint {
        lock.withLock { lastPointer }
    }

    func scroll(dx: Int32, dy: Int32) {
        lock.withLock {
            guard let machine else { return }
            crate_input_scroll(machine, dx, dy)
        }
    }

    private func take(_ frame: crate_frame) {
        guard let source = frame.pixels else { return }
        lock.withLock {
            let w = Int(frame.width), h = Int(frame.height)
            var dirtyX = Int(frame.dirty_x), dirtyY = Int(frame.dirty_y)
            var dirtyW = Int(frame.dirty_width), dirtyH = Int(frame.dirty_height)
            if w != width || h != height || pixels == nil {
                pixels?.deallocate()
                pixels = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
                width = w
                height = h
                (dirtyX, dirtyY, dirtyW, dirtyH) = (0, 0, w, h)
                HengeLog.log("linux", "display: \(w)x\(h)")
            }
            guard let pixels, dirtyW > 0, dirtyH > 0 else { return }
            let stride = Int(frame.stride)
            for row in dirtyY..<min(dirtyY + dirtyH, h) {
                let from = source.advanced(by: row * stride + dirtyX * 4)
                let to = pixels.advanced(by: (row * w + dirtyX) * 4)
                to.copyMemory(from: from, byteCount: min(dirtyW, w - dirtyX) * 4)
            }
            guard !sinks.isEmpty, !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.async { self.flush() }
        }
    }

    @MainActor
    private func flush() {
        let sinks = lock.withLock { () -> [@MainActor (CGImage?) -> Void] in
            flushScheduled = false
            return Array(self.sinks.values)
        }
        guard !sinks.isEmpty, let image = picture() else { return }
        for sink in sinks { sink(image) }
    }

    func snapshot() -> CGImage? { picture() }

    private func picture() -> CGImage? {
        lock.withLock {
            guard let pixels, width > 0, height > 0 else { return nil }
            let data = Data(bytes: pixels, count: width * height * 4) as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
