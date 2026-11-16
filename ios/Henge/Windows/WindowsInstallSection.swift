import SwiftUI
import UniformTypeIdentifiers

struct WindowsInstallSection: View {
    @ObservedObject private var machines = Machines.shared
    @State private var name = "Windows 11"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var pickingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            DeskHeading("Windows 11 ARM64")
            VStack(alignment: .leading, spacing: 10) {
                Text("WindowsiOS runs retail Windows 11 24H2 ARM64 using a 4 KB software MMU, UEFI + ACPI 6.3, NVMe, USB 3.0 xHCI, Intel HD Audio, and VirtIO-Net.")
                    .font(.system(size: 14))
                    .foregroundStyle(Desk.dim)
                Text("Required files in the imported folder:")
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("• code.fd (64 MB EDK2 ArmVirtQemu UEFI firmware)")
                    Text("• vars.fd (64 MB persistent UEFI NVRAM store)")
                    Text("• windows11.img or windows11.hvsparse")
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Desk.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17)
            .deskCard()

            DeskHeading("New Windows VM")
            VStack(spacing: 0) {
                TextField("Name", text: $name)
                    .font(.system(size: 16))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
                Stepper(value: $ramGB, in: Device.memoryChoices) {
                    HStack {
                        Text("Memory").font(.system(size: 16))
                        Spacer()
                        Text("\(ramGB) GB").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
            }
            .deskCard()

            Button("Import Windows 11 Folder…") {
                pickingFolder = true
            }
            .buttonStyle(DeskButtonStyle(enabled: machines.importing == nil))
            .disabled(machines.importing != nil)
            .padding(.top, 20)

            Text("You can also drop the folder into Files › Henge (or Files › Henge › Machines/Win11) and Henge will adopt it automatically.")
                .font(.system(size: 13))
                .foregroundStyle(Desk.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                machines.importWindowsFolder(url, name: name, ramMB: ramGB * 1024)
            }
        }
    }
}
