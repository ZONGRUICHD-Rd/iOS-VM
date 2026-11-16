import Foundation
import UIKit

enum VMKind: String, Codable, Hashable {
    case macOS
    case windows
    case linux

    var label: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }

    var symbol: String {
        switch self {
        case .macOS: return "macwindow.on.rectangle"
        case .windows: return "pc"
        case .linux: return "terminal"
        }
    }
}

/// A virtual machine (macOS, Windows 11 ARM64, or Linux ARM64).
struct VirtualMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: VMKind?
    var name: String
    var ecid: UInt64
    var seed: UInt64
    var ramMB: Int
    var diskBytes: Int64
    var added = Date()
    var osName: String?
    var lastUsed: Date?
    /// The size macOS is told its screen is. Macs made before this was a choice have none: 16:9.
    var screenWidth: Int?
    var screenHeight: Int?
    /// m4 fork: the iPad's own panel at Retina density. On by default on iPad, for Macs that never chose.
    var retina: Bool?
    /// About This Mac reports the device Henge runs on (its name and chip) instead of the
    /// virtual Mac. nil/false: the vmapple identity. Applied at the next boot.
    var reportHostIdentity: Bool?
    /// With reportHostIdentity: also report the device's model identifier (hw.model).
    /// Experimental — it may bring the device's icon, and may confuse macOS.
    var reportHostModelID: Bool?

    // Linux (CrateEngine) metadata
    var linuxDistributionID: String?
    var linuxVersion: String?
    var linuxDesktop: String?
    var linuxImageID: String?
    var linuxCmdline: String?
    var linuxDisplay: String?
    var linuxFullWidth: Bool?

    // Windows (WinVM) metadata
    var windowsUseSafariOAuth: Bool?

    var vmKind: VMKind { kind ?? .macOS }
    var isRetina: Bool { vmKind == .macOS && Device.isPad && (retina ?? false) }
    var screen: (width: Int, height: Int) {
        if vmKind == .macOS {
            return isRetina ? Device.retinaScreen : (screenWidth ?? 1920, screenHeight ?? 1080)
        }
        return (screenWidth ?? 1280, screenHeight ?? 800)
    }
    var aspect: CGFloat { CGFloat(screen.width) / CGFloat(screen.height) }

    var directory: URL { Machines.directory(for: id) }
    var rom: URL { directory.appendingPathComponent("AVPBooter.vmapple2.bin") }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var aux: URL { directory.appendingPathComponent("auxiliary.bin") }

    var primaryDiskURL: URL {
        switch vmKind {
        case .macOS, .linux:
            return disk
        case .windows:
            let raw = directory.appendingPathComponent("windows11.img")
            if FileManager.default.fileExists(atPath: raw.path) { return raw }
            return directory.appendingPathComponent("windows11.hvsparse")
        }
    }

    var hasRequiredFiles: Bool {
        let fm = FileManager.default
        switch vmKind {
        case .macOS:
            return fm.fileExists(atPath: disk.path)
        case .linux:
            return fm.fileExists(atPath: directory.appendingPathComponent("vmlinuz").path)
                && fm.fileExists(atPath: directory.appendingPathComponent("initrd.img").path)
                && fm.fileExists(atPath: disk.path)
        case .windows:
            return fm.fileExists(atPath: directory.appendingPathComponent("code.fd").path)
                && fm.fileExists(atPath: directory.appendingPathComponent("vars.fd").path)
                && (fm.fileExists(atPath: directory.appendingPathComponent("windows11.img").path)
                    || fm.fileExists(atPath: directory.appendingPathComponent("windows11.hvsparse").path))
        }
    }
}

/// How much RAM a Mac gets. The engine first asks the kernel to leave it out of Henge's footprint,
/// which is allowed once a debugger has attached (how JIT is turned on). If that is refused it uses
/// a file beside the disk: iOS's memory limit does not count a mapped file's pages either.
enum GuestMemory {
    /// Points the engine at the file (it is unlinked as soon as it is open) and returns the size that fits.
    static func prepare(_ mac: VirtualMac) -> UInt64 {
        let file = mac.directory.appendingPathComponent("ram.tmp")
        setenv("HV_RAM_FILE", file.path, 1)
        let free = (try? mac.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let room = free > 0 ? UInt64(max(free - (2 << 30), 0)) >> 20 : UInt64.max
        let reach = henge_largest_mapping_mb()
        let ram = min(UInt64(mac.ramMB), room, reach > 512 ? reach - 512 : 0) / 512 * 512
        HengeLog.log("session", "guest RAM \(ram) MB (asked \(mac.ramMB), disk room \(room), largest mapping \(reach))")
        return ram
    }
}

/// machine.json in an exported folder (tools/export_ios.sh writes it).
private struct MachineFile: Codable {
    var name: String?
    var ecid: UInt64
    var seed: UInt64?
    var ramMB: Int?
}

@MainActor
final class Machines: ObservableObject {
    static let shared = Machines()

    @Published private(set) var all: [VirtualMac] = []
    @Published private(set) var importing: String?
    @Published var lastError: String?

    /// The files an exported machine folder holds; its disk is disk.img, or disk.img.hvsparse (tools/export_ios.sh packs it).
    static let required = ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json"]
    static let packedDisk = "disk.img.hvsparse"

    nonisolated static func hasDisk(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path)
            || fm.fileExists(atPath: folder.appendingPathComponent(packedDisk).path)
    }

    nonisolated static func isWindowsFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("code.fd").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("vars.fd").path)
            && (fm.fileExists(atPath: folder.appendingPathComponent("windows11.img").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("windows11.hvsparse").path))
    }

    nonisolated static func isLinuxFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("vmlinuz").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("initrd.img").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path)
    }

    @Published private(set) var unpacked: Double = 0
    /// While a Mac is being exported: its name and how far along.
    @Published private(set) var exporting: String?
    @Published private(set) var exported: Double = 0
    /// The last finished export, ready to be moved out of Henge.
    @Published var lastExport: URL?

    private init() {
        load()
        removeLeftovers()
    }

    /// The file the installer puts in a machine's folder once macOS is on its disk (it holds the release's name).
    nonisolated static let installedMarker = "installed"

    private func removeOldTemporaryDownloads() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private func removeLeftovers() {
        removeOldTemporaryDownloads()
        if listUnreadable {
            HengeLog.log("machines", "the list of VMs could not be read: no machine folder is removed")
            return
        }
        let known = Set(all.map(\.id))
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            guard let id = UUID(uuidString: item.lastPathComponent), !known.contains(id) else { continue }
            let marker = item.appendingPathComponent(Self.installedMarker)
            if fm.fileExists(atPath: marker.path), let data = try? Data(contentsOf: item.appendingPathComponent("machine.json")),
               let info = try? JSONDecoder().decode(MachineFile.self, from: data),
               fm.fileExists(atPath: item.appendingPathComponent("disk.img").path) {
                var mac = VirtualMac(id: id, name: info.name ?? "Mac", ecid: info.ecid, seed: info.seed ?? 0,
                                     ramMB: info.ramMB ?? Device.suggestedRAMGB * 1024, diskBytes: 64 << 30)
                let os = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                mac.osName = os.isEmpty ? nil : os
                (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                all.append(mac)
                save()
                try? fm.removeItem(at: item.appendingPathComponent("restore"))
                HengeLog.log("machines", "\(mac.name) finished installing but was not listed: listed again")
                continue
            }
            HengeLog.log("machines", "removing the unfinished machine \(id)")
            try? fm.removeItem(at: item)
        }
    }

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Machines", isDirectory: true)
    }
    nonisolated static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// Where Finder file sharing puts what the user drops on Henge.
    nonisolated static var inbox: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Folders dropped into Henge's Documents over Finder (or the Files app) are moved in.
    func collectImports() {
        Task { await collect() }
    }

    private func collect() async {
        guard importing == nil else { return }
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil) {
            for folder in items {
                if Self.hasDisk(folder) && Self.required.allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
                    await adopt(folder, move: true)
                } else if Self.isWindowsFolder(folder) {
                    await adoptWindows(folder, name: folder.lastPathComponent, ramMB: Device.suggestedRAMGB * 1024, move: true)
                } else if Self.isLinuxFolder(folder) {
                    await adoptLinux(folder, name: folder.lastPathComponent, ramMB: Device.suggestedRAMGB * 1024, move: true)
                }
            }
        }
        let winInbox = Self.inbox.appendingPathComponent("Machines/Win11", isDirectory: true)
        if Self.isWindowsFolder(winInbox) {
            await adoptWindows(winInbox, name: "Windows 11", ramMB: Device.suggestedRAMGB * 1024, move: true)
        }
        if Self.isWindowsFolder(Self.inbox) {
            await adoptWindows(Self.inbox, name: "Windows 11", ramMB: Device.suggestedRAMGB * 1024, move: true)
        }
    }

    /// A macOS folder chosen in the Files picker: copied.
    func importFolder(_ folder: URL) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await adopt(folder, move: false)
        }
    }

    /// A Windows 11 ARM64 folder (code.fd, vars.fd, windows11.img / windows11.hvsparse) chosen in Files.
    func importWindowsFolder(_ folder: URL, name: String = "Windows 11", ramMB: Int = Device.suggestedRAMGB * 1024) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await adoptWindows(folder, name: name, ramMB: ramMB, move: false)
        }
    }

    /// A Linux folder (vmlinuz, initrd.img, disk.img) chosen in Files.
    func importLinuxFolder(_ folder: URL, name: String? = nil, ramMB: Int = Device.suggestedRAMGB * 1024) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await adoptLinux(folder, name: name ?? folder.lastPathComponent, ramMB: ramMB, move: false)
        }
    }

    private func adoptWindows(_ folder: URL, name: String, ramMB: Int, move: Bool) async {
        do {
            guard Self.isWindowsFolder(folder) else {
                throw message("The folder needs code.fd, vars.fd, and windows11.img or windows11.hvsparse.")
            }
            var vm = VirtualMac(
                kind: .windows,
                name: name.isEmpty ? "Windows 11" : name,
                ecid: 0,
                seed: 0,
                ramMB: ramMB,
                diskBytes: 0,
                osName: "Windows 11 ARM64"
            )
            vm.screenWidth = 1280
            vm.screenHeight = 800
            importing = vm.name
            unpacked = 0
            let dest = vm.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            excludeFromBackup()

            for file in ["code.fd", "vars.fd", "windows11.img"] {
                let from = folder.appendingPathComponent(file)
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = dest.appendingPathComponent(file)
                if move { try fm.moveItem(at: from, to: to) } else { try fm.copyItem(at: from, to: to) }
            }
            let sparse = folder.appendingPathComponent("windows11.hvsparse")
            let rawDst = dest.appendingPathComponent("windows11.img")
            if !fm.fileExists(atPath: rawDst.path) && fm.fileExists(atPath: sparse.path) {
                let target = rawDst.path, source = sparse.path
                let ok = await Task.detached { () -> Bool in
                    hv_sparse_unpack(source, target, { done, total, _ in
                        let fraction = Double(done) / Double(max(total, 1))
                        Task { @MainActor in Machines.shared.unpacked = fraction }
                    }, nil) == 0
                }.value
                guard ok else {
                    try? fm.removeItem(at: dest)
                    throw message("Could not unpack windows11.hvsparse (not enough space?).")
                }
                if move { try? fm.removeItem(at: sparse) }
            }
            if move && folder != Self.inbox { try? fm.removeItem(at: folder) }
            vm.diskBytes = (try? fm.attributesOfItem(atPath: vm.primaryDiskURL.path)[.size] as? Int64) ?? 0
            all.append(vm)
            save()
            HengeLog.log("machines", "imported Windows VM \(vm.name) (\(vm.diskBytes >> 30) GB disk)")
        } catch {
            lastError = error.localizedDescription
            HengeLog.log("machines", "Windows import failed: \(error.localizedDescription)")
        }
        importing = nil
    }

    private func adoptLinux(_ folder: URL, name: String, ramMB: Int, move: Bool) async {
        do {
            guard Self.isLinuxFolder(folder) else {
                throw message("The folder needs vmlinuz, initrd.img, and disk.img.")
            }
            var vm = VirtualMac(
                kind: .linux,
                name: name.isEmpty ? "Linux" : name,
                ecid: 0,
                seed: 0,
                ramMB: ramMB,
                diskBytes: 0,
                osName: "Linux ARM64"
            )
            vm.screenWidth = 1280
            vm.screenHeight = 800
            vm.linuxDisplay = "1280 × 800"
            importing = vm.name
            unpacked = 0
            let dest = vm.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            excludeFromBackup()

            for file in ["vmlinuz", "initrd.img", "disk.img", "seed.img"] {
                let from = folder.appendingPathComponent(file)
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = dest.appendingPathComponent(file)
                if move { try fm.moveItem(at: from, to: to) } else { try fm.copyItem(at: from, to: to) }
            }
            if move { try? fm.removeItem(at: folder) }
            vm.diskBytes = (try? fm.attributesOfItem(atPath: vm.disk.path)[.size] as? Int64) ?? 0
            all.append(vm)
            save()
            HengeLog.log("machines", "imported Linux VM \(vm.name) (\(vm.diskBytes >> 30) GB disk)")
        } catch {
            lastError = error.localizedDescription
            HengeLog.log("machines", "Linux import failed: \(error.localizedDescription)")
        }
        importing = nil
    }

    private func adopt(_ folder: URL, move: Bool) async {
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("machine.json"))
            let info = try JSONDecoder().decode(MachineFile.self, from: data)
            let missing = Self.required.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            guard missing.isEmpty, Self.hasDisk(folder) else { throw message("The folder is missing \((missing + (Self.hasDisk(folder) ? [] : ["disk.img"])).joined(separator: ", ")).") }
            var mac = VirtualMac(name: info.name ?? folder.lastPathComponent, ecid: info.ecid, seed: info.seed ?? 0,
                                 ramMB: info.ramMB ?? 2048, diskBytes: 0)
            importing = mac.name
            unpacked = 0
            let dest = mac.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            excludeFromBackup()
            for name in ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json", "disk.img"] {
                let from = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if move { try fm.moveItem(at: from, to: dest.appendingPathComponent(name)) }
                else { try fm.copyItem(at: from, to: dest.appendingPathComponent(name)) }
            }
            let packed = folder.appendingPathComponent(Self.packedDisk)
            if fm.fileExists(atPath: packed.path) {
                let target = mac.disk.path, source = packed.path
                let ok = await Task.detached { () -> Bool in
                    hv_sparse_unpack(source, target, { done, total, _ in
                        let fraction = Double(done) / Double(max(total, 1))
                        Task { @MainActor in Machines.shared.unpacked = fraction }
                    }, nil) == 0
                }.value
                guard ok else { try? fm.removeItem(at: dest); throw message("The packed disk could not be unpacked (not enough space?).") }
                if move { try? fm.removeItem(at: packed) }
            }
            if move { try? fm.removeItem(at: folder) }
            mac.diskBytes = (try? fm.attributesOfItem(atPath: mac.disk.path)[.size] as? Int64) ?? 0
            all.append(mac)
            save()
            HengeLog.log("machines", "imported \(mac.name) (ECID \(mac.ecid), \(mac.diskBytes >> 30) GB disk)")
        } catch {
            lastError = error.localizedDescription
            HengeLog.log("machines", "import of \(folder.lastPathComponent) failed: \(error.localizedDescription)")
        }
        importing = nil
    }

    func export(_ mac: VirtualMac) {
        guard mac.vmKind == .macOS else { return }
        guard exporting == nil, importing == nil else { return }
        exporting = mac.name
        exported = 0
        lastExport = nil
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer {
                exporting = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do { lastExport = try await writeExport(mac) } catch {
                lastError = error.localizedDescription
                HengeLog.log("machines", "export of \(mac.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ mac: VirtualMac) async throws -> URL {
        let fm = FileManager.default
        let exports = Self.inbox.appendingPathComponent("Exports", isDirectory: true)
        let safeName = mac.name.replacingOccurrences(of: "/", with: "-")
        let final = exports.appendingPathComponent(safeName, isDirectory: true)
        let partial = exports.appendingPathComponent(safeName + ".partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: final)
        let used = (try? mac.disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
        let free = (try? Self.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Int64(used) + (256 << 20)
        if free > 0 && free < needed {
            throw message("Exporting \(mac.name) needs about \(ByteText.string(UInt64(needed))) free; this \(Device.name) has \(ByteText.string(UInt64(free))). Deleting a downloaded macOS installer (Install macOS, swipe it) frees about 16 GB.")
        }
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: mac.rom, to: partial.appendingPathComponent("AVPBooter.vmapple2.bin"))
            try fm.copyItem(at: mac.aux, to: partial.appendingPathComponent("auxiliary.bin"))
            let info: [String: Any] = ["name": mac.name, "ecid": mac.ecid, "seed": mac.seed, "ramMB": mac.ramMB]
            try JSONSerialization.data(withJSONObject: info).write(to: partial.appendingPathComponent("machine.json"))
            let source = mac.disk.path, target = partial.appendingPathComponent(Self.packedDisk).path
            let ok = await Task.detached { () -> Bool in
                hv_sparse_pack_progress(source, target, { done, total, _ in
                    let fraction = Double(done) / Double(max(total, 1))
                    Task { @MainActor in Machines.shared.exported = fraction }
                }, nil) == 0
            }.value
            guard ok else { throw message("The disk could not be written (not enough space?).") }
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        HengeLog.log("machines", "exported \(mac.name) to \(final.path)")
        return final
    }

    func add(_ mac: VirtualMac) {
        all.removeAll { $0.id == mac.id }
        all.append(mac)
        save()
    }

    func update(_ mac: VirtualMac) {
        guard let i = all.firstIndex(where: { $0.id == mac.id }) else { return }
        all[i] = mac
        save()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        all.removeAll { $0.id == id }
        save()
    }

    private var listURL: URL { Self.root.appendingPathComponent("machines.json") }

    private func excludeFromBackup() { Self.excludeFromBackup(Self.root) }

    nonisolated static func excludeFromBackup(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private var listUnreadable = false

    private func load() {
        guard let data = try? Data(contentsOf: listURL) else { return }
        guard let list = try? JSONDecoder().decode([VirtualMac].self, from: data) else {
            listUnreadable = true
            HengeLog.log("machines", "machines.json (\(data.count) bytes) could not be read")
            return
        }
        all = list.filter { $0.hasRequiredFiles }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        excludeFromBackup()
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: listURL, options: .atomic) }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
