// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct LinuxDistribution: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color

    static let debian = LinuxDistribution(id: "debian", name: "Debian", color: .pink)
    static let ubuntu = LinuxDistribution(id: "ubuntu", name: "Ubuntu", color: .orange)
    static let arch = LinuxDistribution(id: "arch", name: "Arch Linux", color: .indigo)
    static let omarchy = LinuxDistribution(id: "omarchy", name: "Omarchy", color: .teal)

    static let all: [LinuxDistribution] = [.debian, .ubuntu, .arch, .omarchy]

    static func named(_ id: String) -> LinuxDistribution {
        all.first { $0.id == id } ?? .debian
    }
}
