// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A Linux system image from the arm64-desktop-images catalog.
struct CatalogImage: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let version: String
    let desktop: String
    let cmdline: String
    let kernel: File
    let initrd: File
    let disk: Disk
    let vendorData: String?

    struct File: Hashable, Decodable {
        let url: URL
        let size: Int64
        let sha256: String
    }

    struct Disk: Hashable, Decodable {
        let size: Int64
        let sha256: String
        let compression: String
        let parts: [File]
    }

    var distributionID: String {
        String(id.prefix { $0 != "-" })
    }

    var distribution: LinuxDistribution { .named(distributionID) }

    var downloadBytes: Int64 {
        kernel.size + initrd.size + disk.parts.reduce(0) { $0 + $1.size }
    }

    var installedBytes: Int64 {
        disk.size + kernel.size + initrd.size
    }

    func machine(name: String, memoryGB: Int, diskGB: Int) -> VirtualMac {
        var vm = VirtualMac(
            kind: .linux,
            name: name.isEmpty ? "\(self.name) \(desktop)" : name,
            ecid: 0,
            seed: 0,
            ramMB: memoryGB * 1024,
            diskBytes: Int64(diskGB) << 30
        )
        vm.osName = "\(self.name) \(version) · \(desktop)"
        vm.screenWidth = 1280
        vm.screenHeight = 800
        vm.linuxDistributionID = distributionID
        vm.linuxVersion = version
        vm.linuxDesktop = desktop
        vm.linuxImageID = id
        vm.linuxCmdline = cmdline
        vm.linuxDisplay = "1280 × 800"
        return vm
    }
}

struct LinuxCatalog: Decodable {
    let release: String
    let images: [CatalogImage]

    static let url = URL(string: "https://github.com/oneamendez/arm64-desktop-images/releases/latest/download/catalog.json")!

    static func fetch() async throws -> LinuxCatalog {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CatalogError.unavailable(http.statusCode)
        }
        return try JSONDecoder().decode(LinuxCatalog.self, from: data)
    }
}

enum CatalogError: LocalizedError {
    case unavailable(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let status): "The list of Linux VMs isn't available right now (HTTP \(status))."
        }
    }
}
