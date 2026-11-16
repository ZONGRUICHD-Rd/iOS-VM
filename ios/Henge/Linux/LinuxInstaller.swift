// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import UIKit

@MainActor
final class LinuxInstaller: ObservableObject {
    static let shared = LinuxInstaller()

    enum Phase: Equatable, Sendable {
        case idle
        case downloading(done: Int64, total: Int64)
        case unpacking(done: Int64, total: Int64)
        case finishing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var image: CatalogImage?
    private var task: Task<Void, Never>?

    var busy: Bool {
        switch phase {
        case .downloading, .unpacking, .finishing: true
        default: false
        }
    }

    func install(_ image: CatalogImage, name: String, memoryGB: Int, diskGB: Int, owner: SeedDisk) {
        guard !busy else { return }
        self.image = image
        let vm = image.machine(name: name, memoryGB: memoryGB, diskGB: diskGB)
        let dir = vm.directory
        phase = .downloading(done: 0, total: image.downloadBytes)
        HengeLog.log("linux-install", "\(image.id) \(image.version) as \(vm.id)")
        let reporter = Reporter { [weak self] phase in self?.phase = phase }
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await Self.run(image, directory: dir, diskBytes: Int64(diskGB) << 30, owner: owner,
                                   instance: vm.id, reporter: reporter)
                Machines.shared.add(vm)
                HengeLog.log("linux-install", "\(image.id) done")
                phase = .done("\(vm.name) is ready on Home.")
            } catch {
                try? FileManager.default.removeItem(at: dir)
                if Task.isCancelled {
                    HengeLog.log("linux-install", "\(image.id) cancelled")
                    phase = .idle
                } else {
                    HengeLog.log("linux-install", "\(image.id) failed: \(error)")
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        guard !busy else { return }
        phase = .idle
    }

    private nonisolated static func run(_ image: CatalogImage, directory: URL, diskBytes: Int64,
                                        owner: SeedDisk, instance: UUID, reporter: Reporter) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloader = LinuxDownloader()
        let total = image.downloadBytes
        var downloaded: Int64 = 0
        func fetch(_ file: CatalogImage.File, to url: URL) async throws {
            let before = downloaded
            try await downloader.download(file, to: url) { bytes in
                reporter.send(.downloading(done: before + bytes, total: total))
            }
            downloaded += file.size
        }

        try await fetch(image.kernel, to: directory.appendingPathComponent("vmlinuz"))
        try await fetch(image.initrd, to: directory.appendingPathComponent("initrd.img"))

        guard image.disk.compression == "xz" else { throw LinuxInstallError.unsupported(image.disk.compression) }
        let unpacker = try DiskUnpacker(to: directory.appendingPathComponent("disk.img")) { written in
            reporter.send(.unpacking(done: written, total: image.disk.size))
        }
        let temporary = directory.appendingPathComponent("part.download")
        for part in image.disk.parts {
            try await fetch(part, to: temporary)
            try unpacker.unpack(part: temporary)
            try FileManager.default.removeItem(at: temporary)
        }
        reporter.send(.finishing, now: true)
        let (written, digest) = try unpacker.finish()
        guard written == image.disk.size, digest == image.disk.sha256 else {
            throw LinuxInstallError.corrupt("the disk")
        }
        try unpacker.extend(to: diskBytes)
        try owner.write(to: directory.appendingPathComponent("seed.img"), instance: instance)
    }
}

private enum LinuxInstallError: LocalizedError {
    case download(Int)
    case corrupt(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .download(let status): "The download stopped (HTTP \(status)). Try again."
        case .corrupt(let what): "\(what) didn't download correctly. Try again."
        case .unsupported(let kind): "This image is packed in a way Henge can't unpack (\(kind))."
        }
    }
}

private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let report: @MainActor (LinuxInstaller.Phase) -> Void

    init(report: @escaping @MainActor (LinuxInstaller.Phase) -> Void) {
        self.report = report
    }

    func send(_ phase: LinuxInstaller.Phase, now: Bool = false) {
        let due = lock.withLock { () -> Bool in
            guard now || Date().timeIntervalSince(last) > 0.25 else { return false }
            last = Date()
            return true
        }
        if due { Task { @MainActor in report(phase) } }
    }
}

private final class LinuxDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<Void, Error>
        let progress: (Int64) -> Void
        let destination: URL
        var moved: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    deinit {
        session.invalidateAndCancel()
    }

    func download(_ file: CatalogImage.File, to url: URL, progress: @escaping (Int64) -> Void) async throws {
        let task = session.downloadTask(with: file.url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(continuation: continuation, progress: progress, destination: url)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        guard try Self.sha256(of: url) == file.sha256 else {
            throw LinuxInstallError.corrupt(file.url.lastPathComponent)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        progress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination = lock.withLock({ pending[downloadTask.taskIdentifier]?.destination }) else { return }
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = LinuxInstallError.download(http.statusCode)
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.withLock { pending[downloadTask.taskIdentifier]?.moved = failure }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let done = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = error ?? done.moved {
            done.continuation.resume(throwing: failure)
        } else {
            done.continuation.resume()
        }
    }

    private static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
