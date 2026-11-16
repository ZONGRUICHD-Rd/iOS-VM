// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CrateEngine
import Foundation

final class ConsoleBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var machine: OpaquePointer?
    private let index: UInt32 = 0

    private var shown: [UInt8] = []
    private var unsent: [UInt8] = []
    private var flushScheduled = false
    private var typed: [UInt8] = []
    private var sink: (@MainActor ([UInt8]) -> Void)?

    private static let keep = 1 << 20
    static let logURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("linux-console.log")
    private let logQueue = DispatchQueue(label: "com.henge.linux.console-log", qos: .utility)
    private var logPending: [UInt8] = []
    private var logScheduled = false
    private var logged = 0

    var callbacks: crate_console_callbacks {
        crate_console_callbacks(
            size: MemoryLayout<crate_console_callbacks>.size,
            context: Unmanaged.passUnretained(self).toOpaque(),
            output: { context, _, bytes, length in
                guard let context, let bytes else { return }
                Unmanaged<ConsoleBridge>.fromOpaque(context).takeUnretainedValue()
                    .output(UnsafeBufferPointer(start: bytes, count: length))
            },
            input_ready: { context, _ in
                guard let context else { return }
                Unmanaged<ConsoleBridge>.fromOpaque(context).takeUnretainedValue().inputReady()
            })
    }

    func reset() {
        lock.withLock {
            shown.removeAll()
            unsent.removeAll()
            typed.removeAll()
            logPending.removeAll()
            logged = 0
        }
        logQueue.async { try? Data().write(to: Self.logURL) }
    }

    func attach(machine: OpaquePointer) {
        lock.withLock { self.machine = machine }
    }

    func detach() {
        lock.withLock {
            machine = nil
            typed.removeAll()
        }
    }

    @MainActor
    func connect(_ sink: @escaping @MainActor ([UInt8]) -> Void) {
        let replay = lock.withLock { () -> [UInt8] in
            self.sink = sink
            unsent.removeAll()
            return shown
        }
        if !replay.isEmpty { sink(replay) }
    }

    @MainActor
    func disconnect() {
        lock.withLock { sink = nil }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        lock.withLock {
            typed.append(contentsOf: bytes)
            writeTyped()
        }
    }

    private func output(_ bytes: UnsafeBufferPointer<UInt8>) {
        lock.withLock {
            shown.append(contentsOf: bytes)
            if shown.count > Self.keep { shown.removeFirst(shown.count - Self.keep) }
            if logged < Self.keep {
                logPending.append(contentsOf: bytes)
                logged += bytes.count
                if !logScheduled {
                    logScheduled = true
                    logQueue.asyncAfter(deadline: .now() + 0.25) { self.writeLog() }
                }
            }
            guard sink != nil else { return }
            unsent.append(contentsOf: bytes)
            if !flushScheduled {
                flushScheduled = true
                DispatchQueue.main.async { self.flush() }
            }
        }
    }

    private func inputReady() {
        lock.withLock { writeTyped() }
    }

    private func writeTyped() {
        guard let machine, !typed.isEmpty else { return }
        let taken = typed.withUnsafeBufferPointer { crate_console_write(machine, index, $0.baseAddress, $0.count) }
        typed.removeFirst(taken)
    }

    private func writeLog() {
        let bytes = lock.withLock { () -> [UInt8] in
            defer {
                logPending.removeAll(keepingCapacity: true)
                logScheduled = false
            }
            return logPending
        }
        guard !bytes.isEmpty, let handle = try? FileHandle(forWritingTo: Self.logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(bytes))
    }

    @MainActor
    private func flush() {
        let (bytes, sink) = lock.withLock { () -> ([UInt8], (@MainActor ([UInt8]) -> Void)?) in
            defer {
                unsent.removeAll(keepingCapacity: true)
                flushScheduled = false
            }
            return (unsent, self.sink)
        }
        if !bytes.isEmpty { sink?(bytes) }
    }
}
