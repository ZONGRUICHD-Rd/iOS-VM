import SwiftUI

struct LinuxInstallSection: View {
    @ObservedObject private var installer = LinuxInstaller.shared
    @State private var catalog: [CatalogImage] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var selected: CatalogImage?
    @State private var name = ""
    @State private var username = "user"
    @State private var password = ""
    @State private var hostname = "linux-vm"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var diskGB = 32

    private var canInstall: Bool {
        selected != nil && SeedDisk.isValid(user: username) && !password.isEmpty && SeedDisk.isValid(hostname: hostname)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch installer.phase {
            case .idle:
                chooser
            case .downloading(let done, let total):
                progressCard(
                    title: "Downloading \(installer.image?.name ?? "Linux")…",
                    fraction: total > 0 ? Double(done) / Double(total) : 0,
                    subtitle: "\(ByteText.string(done)) of \(ByteText.string(total))"
                )
            case .unpacking(let done, let total):
                progressCard(
                    title: "Unpacking disk image…",
                    fraction: total > 0 ? Double(done) / Double(total) : 0,
                    subtitle: "\(ByteText.string(done)) of \(ByteText.string(total))"
                )
            case .finishing:
                progressCard(title: "Writing configuration…", fraction: 1, subtitle: "Almost ready")
            case .done(let text):
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
                    Text("Installed").font(.system(size: 24, weight: .bold))
                    Text(text).font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
                    Button("Done") { installer.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .deskCard(radius: 30)
                .padding(.top, 8)
            case .failed(let text):
                VStack(alignment: .leading, spacing: 10) {
                    Text("It did not work").font(.system(size: 22, weight: .bold))
                    Text(text).font(.system(size: 15))
                    Button("Back") { installer.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
                }
                .padding(18)
                .deskCard(radius: 30)
                .padding(.top, 8)
            }
        }
        .task {
            if catalog.isEmpty && !loading {
                await fetchCatalog()
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        DeskHeading("Distribution")
        if loading {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading Linux catalog…").font(.system(size: 15)).foregroundStyle(Desk.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17)
            .deskCard()
        } else if let loadError {
            VStack(alignment: .leading, spacing: 10) {
                Text(loadError).font(.system(size: 14)).foregroundStyle(Desk.bad)
                Button("Retry") { Task { await fetchCatalog() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Desk.accentLight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17)
            .deskCard()
        } else {
            VStack(spacing: 0) {
                ForEach(catalog) { item in
                    Button { selected = item } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.name) \(item.version) · \(item.desktop)")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Desk.text)
                                Text("\(ByteText.string(item.downloadBytes)) download · \(ByteText.string(item.installedBytes)) unpacked")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Desk.dim)
                            }
                            Spacer()
                            if selected?.id == item.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Desk.accentLight)
                            }
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if item.id != catalog.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }

        DeskHeading("New Linux VM")
        VStack(spacing: 0) {
            TextField("Name (optional)", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            SecureField("Password", text: $password)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            TextField("Hostname", text: $hostname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
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
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Stepper(value: $diskGB, in: 16...128, step: 8) {
                HStack {
                    Text("Disk size").font(.system(size: 16))
                    Spacer()
                    Text("\(diskGB) GB").font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
        }
        .deskCard()

        Button("Download and Install") {
            guard let selected else { return }
            let seed = SeedDisk(
                user: username,
                password: password,
                hostname: hostname,
                timeZone: TimeZone.current.identifier,
                vendorData: selected.vendorData
            )
            installer.install(selected, name: name, memoryGB: ramGB, diskGB: diskGB, owner: seed)
        }
        .buttonStyle(DeskButtonStyle(enabled: canInstall))
        .disabled(!canInstall)
        .padding(.top, 20)

        Text("Images come from oneamendez/arm64-desktop-images. Enter a valid lowercase username, password, and hostname.")
            .font(.system(size: 13))
            .foregroundStyle(Desk.dim)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
    }

    private func progressCard(title: String, fraction: Double, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 56, weight: .bold))
                .monospacedDigit()
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Desk.dim)
            DeskBar(fraction: fraction, height: 11)
            Button("Cancel", role: .destructive) { installer.cancel() }
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskCard(radius: 30)
        .padding(.top, 10)
    }

    private func fetchCatalog() async {
        loading = true
        loadError = nil
        do {
            let result = try await LinuxCatalog.fetch()
            catalog = result.images
            if selected == nil { selected = catalog.first }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}
