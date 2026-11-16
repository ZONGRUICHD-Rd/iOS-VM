// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CrateEngine
import Foundation
import UIKit

@MainActor
final class LinuxMachineRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopped(String)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var machineID: UUID?
    let console = ConsoleBridge()
    let display = DisplayBridge()
    private var machine: OpaquePointer?

    init() {
        crate_set_log_callback({ _, level, message in
            guard let message else { return }
            let tag = level == CRATE_LOG_ERROR ? "error: " : level == CRATE_LOG_WARN ? "warning: " : ""
            HengeLog.log("crate", tag + String(cString: message))
        }, nil, CRATE_LOG_INFO)
    }

    var isRunning: Bool {
        phase == .starting || phase == .running
    }

    func start(_ vm: VirtualMac, cpus: Int) {
        guard !isRunning else { return }
        if let old = machine {
            crate_machine_free(old)
            machine = nil
        }

        guard let mapping = henge_ios_jit_get_mapping()?.pointee,
              let rx = mapping.rx_addr,
              let rw = mapping.rw_addr,
              mapping.size > 0 else {
            phase = .failed("JIT region is not available. Turn on JIT first.")
            return
        }

        let dir = vm.directory
        let kernel = dir.appendingPathComponent("vmlinuz")
        let initrd = dir.appendingPathComponent("initrd.img")
        let disk = dir.appendingPathComponent("disk.img")
        let seed = dir.appendingPathComponent("seed.img")

        let fm = FileManager.default
        let missing = [kernel, initrd, disk].filter { !fm.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
        if !missing.isEmpty {
            phase = .failed("\(vm.name)'s files aren't on this \(Device.name) yet (\(missing.joined(separator: ", "))).")
            return
        }
        if !fm.isWritableFile(atPath: disk.path) {
            phase = .failed("Henge can't write to \(vm.name)'s disk.")
            HengeLog.log("linux", "\(disk.path) isn't writable")
            return
        }

        phase = .starting
        machineID = vm.id
        console.reset()
        display.reset()

        let settings = Settings(
            vm: vm,
            requestedCPUs: cpus,
            kernel: kernel.path,
            initrd: initrd.path,
            disk: disk.path,
            seed: fm.fileExists(atPath: seed.path) ? seed.path : nil,
            display: display
        )
        HengeLog.log("linux", "starting \(vm.name): \(settings.cpus) CPUs, \(settings.memoryMiB) MiB, code \(mapping.size >> 20) MiB")

        let console = self.console
        let display = self.display
        let rxAddr = UInt(bitPattern: rx)
        let rwAddr = UInt(bitPattern: rw)
        let jitSize = mapping.size
        let context = Unmanaged.passUnretained(self).toOpaque()

        Task.detached(priority: .userInitiated) {
            let started = Date()
            let result = Self.create(
                settings,
                rx: UnsafeMutableRawPointer(bitPattern: rxAddr)!,
                rw: UnsafeMutableRawPointer(bitPattern: rwAddr)!,
                size: jitSize,
                console: console,
                display: display,
                context: context
            )
            await MainActor.run {
                switch result {
                case .success(let made):
                    self.machine = made
                    console.attach(machine: made)
                    display.attach(machine: made)
                    if crate_machine_start(made) == CRATE_OK {
                        HengeLog.log("linux", String(format: "running, created in %.2f s", Date().timeIntervalSince(started)))
                        self.phase = .running
                    } else {
                        self.phase = .failed("crate couldn't start the VM: \(String(cString: crate_last_error())).")
                    }
                case .failure(let message):
                    HengeLog.log("linux", message)
                    self.phase = .failed(message)
                }
            }
        }
    }

    func stop() {
        guard let machine, isRunning else { return }
        crate_machine_kill(machine)
    }

    func savePreview(for vm: VirtualMac) {
        guard let cg = display.snapshot(),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: MacPreview.file(for: vm), options: .atomic)
    }

    nonisolated private struct Settings: Sendable {
        let cpus: Int
        let memoryMiB: Int
        let kernel: String
        let initrd: String
        let disk: String
        let seed: String?
        let commandLine: String
        let displayModes: [crate_display_mode]

        init(vm: VirtualMac, requestedCPUs: Int, kernel: String, initrd: String, disk: String, seed: String?, display: DisplayBridge) {
            cpus = max(1, min(requestedCPUs, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
            memoryMiB = Self.memory(askedMB: vm.ramMB)
            self.kernel = kernel
            self.initrd = initrd
            self.disk = disk
            self.seed = seed
            commandLine = vm.linuxCmdline ?? Self.defaultCommandLine
            displayModes = display.modes(after: Self.modes(preferring: vm.linuxDisplay ?? "1280 × 800"))
        }

        static func modes(preferring display: String) -> [crate_display_mode] {
            let numbers = display.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            var sizes = [(1280, 800), (1024, 768), (1920, 1200)]
            if numbers.count == 2 {
                let preferred = (numbers[0], numbers[1])
                sizes.removeAll { $0 == preferred }
                sizes.insert(preferred, at: 0)
            }
            return sizes.map { crate_display_mode(width: UInt32($0.0), height: UInt32($0.1)) }
        }

        static func memory(askedMB: Int) -> Int {
            let available = Int(os_proc_available_memory() >> 20)
            guard available > 0 else { return askedMB }
            let headroom = 768
            let fits = max(1024, (available - headroom) / 2 * 2)
            return min(askedMB, fits)
        }

        static let defaultCommandLine = ([
            "console=ttyAMA0", "root=/dev/vda", "rw", "net.ifnames=0",
            "vt.global_cursor_default=0", "systemd.unit=multi-user.target",
            "systemd.wants=aterm-desktop.service",
        ] + [
            "systemd-timesyncd.service", "e2scrub_reap.service", "apt-daily.timer",
            "apt-daily-upgrade.timer", "man-db.timer",
            "getty@tty1.service", "getty@tty2.service", "getty@tty3.service",
            "getty@tty4.service", "getty@tty5.service", "getty@tty6.service",
        ].map { "systemd.mask=\($0)" }).joined(separator: " ")

        #if targetEnvironment(simulator)
        static let gpu = CRATE_GPU_2D
        #else
        static let gpu = CRATE_GPU_VIRGL
        #endif
    }

    private enum Created {
        case success(OpaquePointer)
        case failure(String)
    }

    nonisolated private static func create(_ settings: Settings,
                                           rx: UnsafeMutableRawPointer,
                                           rw: UnsafeMutableRawPointer,
                                           size: Int,
                                           console: ConsoleBridge,
                                           display: DisplayBridge,
                                           context: UnsafeMutableRawPointer) -> Created {
        guard let config = crate_config_new("virt") else { return .failure("crate doesn't know the virt board.") }
        defer { crate_config_free(config) }

        func check(_ status: crate_status, _ what: String) -> String? {
            status == CRATE_OK ? nil : "crate refused \(what): \(String(cString: crate_last_error()))."
        }

        let steps: [() -> String?] = [
            { check(crate_config_set_cpu_backend(config, CRATE_CPU_JIT), "the CPU backend") },
            { check(crate_config_set_cpus(config, UInt32(settings.cpus)), "\(settings.cpus) CPUs") },
            { check(crate_config_set_memory(config, UInt64(settings.memoryMiB) << 20), "\(settings.memoryMiB) MiB of memory") },
            { check(crate_config_set_jit_region(config, rx, rw, size), "the code region") },
            { check(crate_config_set_kernel(config, settings.kernel), "the kernel") },
            { check(crate_config_set_initrd(config, settings.initrd), "the initrd") },
            { check(crate_config_set_cmdline(config, settings.commandLine), "the kernel command line") },
            { check(crate_config_add_disk(config, settings.disk, 0), "the disk") },
            {
                guard let seed = settings.seed else { return nil }
                return check(crate_config_add_disk(config, seed, CRATE_DISK_READ_ONLY), "the first-boot settings")
            },
            {
                var network: UInt32 = 0
                return check(crate_config_add_network(config, &network), "the network")
            },
            {
                var callbacks = console.callbacks
                var index: UInt32 = 0
                return check(crate_config_add_console(config, CRATE_CONSOLE_SERIAL, &callbacks, &index), "the console")
            },
            {
                var callbacks = display.callbacks
                var index: UInt32 = 0
                if let failure = check(crate_config_add_display(config, Settings.gpu, &callbacks, &index), "the display") {
                    return failure
                }
                let modes = settings.displayModes
                return check(crate_config_set_display_modes(config, index, modes, modes.count), "the display's sizes")
            },
            { check(crate_config_add_input(config, CRATE_INPUT_KEYBOARD | CRATE_INPUT_TABLET), "the keyboard and tablet") },
            {
                check(crate_config_set_state_callback(config, { context, state, reason in
                    guard let context, state == CRATE_STATE_STOPPED else { return }
                    let runner = Unmanaged<LinuxMachineRunner>.fromOpaque(context).takeUnretainedValue()
                    let error = reason == CRATE_STOP_ERROR ? String(cString: crate_last_error()) : nil
                    Task { @MainActor in runner.stopped(reason, error: error) }
                }, context), "the state callback")
            },
        ]

        for step in steps {
            if let failure = step() { return .failure(failure) }
        }
        var made: OpaquePointer?
        if let failure = check(crate_machine_create(config, &made), "to create the VM") { return .failure(failure) }
        guard let made else { return .failure("crate made no VM.") }
        return .success(made)
    }

    private func stopped(_ reason: crate_stop_reason, error: String?) {
        let text: String
        switch reason {
        case CRATE_STOP_POWER_OFF: text = "The VM shut down."
        case CRATE_STOP_RESET: text = "The VM asked to restart."
        case CRATE_STOP_KILLED: text = "The VM was stopped."
        default: text = "The VM stopped: \(error ?? "crate gave no reason")."
        }
        HengeLog.log("linux", text)
        console.detach()
        display.detach()
        if let machine {
            crate_machine_free(machine)
            self.machine = nil
        }
        phase = reason == CRATE_STOP_ERROR ? .failed(text) : .stopped(text)
    }
}
