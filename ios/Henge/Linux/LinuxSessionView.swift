// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct LinuxSessionView: View {
    enum Mode: Hashable {
        case display
        case console
    }

    let mac: VirtualMac
    let close: () -> Void

    @AppStorage("henge.cpus") private var cpus = 4
    @StateObject private var runner = LinuxMachineRunner()
    @State private var mode: Mode = .display
    @State private var showsKeyboard = false
    @State private var hasPicture = false
    @State private var consoleKeyboardRequests = 0
    @State private var confirmStop = false
    @State private var showDetails = false

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets

            ZStack {
                Color.black.ignoresSafeArea()

                switch runner.phase {
                case .idle, .starting, .running:
                    ZStack {
                        DisplayView(
                            bridge: runner.display,
                            showsKeyboard: Binding(
                                get: { mode == .display && showsKeyboard },
                                set: { showsKeyboard = $0 }
                            ),
                            hasPicture: $hasPicture
                        )
                        .opacity(mode == .display ? 1 : 0)
                        .allowsHitTesting(mode == .display)

                        if mode == .console {
                            ConsoleView(bridge: runner.console, keyboardRequests: consoleKeyboardRequests)
                                .padding(.top, max(insets.top + 54, 62))
                        }

                        if mode == .display && !hasPicture {
                            VStack(spacing: 12) {
                                ProgressView().tint(.white)
                                Text("Starting \(mac.name)…")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                Button("Open Serial Console") { mode = .console }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Desk.accentLight)
                            }
                            .padding(22)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }

                case .stopped(let text), .failed(let text):
                    StoppedMacView(
                        outcome: 0,
                        reason: text,
                        start: { runner.start(mac, cpus: cpus) },
                        close: close
                    )
                    .frame(maxWidth: 360)
                }

                if runner.isRunning || runner.phase == .starting {
                    VStack {
                        topBar
                            .padding(.top, max(insets.top + 6, 12))
                            .padding(.horizontal, 14)
                        Spacer()
                    }
                }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showDetails) { detailsSheet }
        .confirmationDialog("Stop \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop VM", role: .destructive) {
                runner.savePreview(for: mac)
                runner.stop()
            }
        } message: {
            Text("Stops the Linux machine immediately.")
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            var updated = mac
            updated.lastUsed = Date()
            Machines.shared.update(updated)
            LinuxExternalDisplay.shared.show(runner.display)
            runner.start(mac, cpus: cpus)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            runner.savePreview(for: mac)
            LinuxExternalDisplay.shared.show(nil)
            if runner.isRunning { runner.stop() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { confirmStop = true } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Desk.bad)
                    .frame(width: 34, height: 34)
                    .deskGlass(in: Circle())
            }

            Picker("View", selection: $mode) {
                Text("Display").tag(Mode.display)
                Text("Console").tag(Mode.console)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)

            Button {
                if mode == .display {
                    showsKeyboard.toggle()
                } else {
                    consoleKeyboardRequests += 1
                }
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(showsKeyboard && mode == .display ? Desk.accentLight : .white)
                    .frame(width: 34, height: 34)
                    .deskGlass(in: Circle())
            }

            Button { showDetails = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .deskGlass(in: Circle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .deskGlass(in: Capsule())
    }

    private var detailsSheet: some View {
        NavigationStack {
            List {
                Section("Linux VM") {
                    LabeledContent("Name", value: mac.name)
                    if let os = mac.osName { LabeledContent("System", value: os) }
                    LabeledContent("Memory", value: "\(mac.ramMB / 1024) GB")
                    LabeledContent("CPUs", value: "\(cpus)")
                    let sz = runner.display.size
                    if sz.width > 0 { LabeledContent("Display", value: "\(Int(sz.width)) × \(Int(sz.height))") }
                }
                Section {
                    Button("Stop VM", role: .destructive) {
                        showDetails = false
                        runner.savePreview(for: mac)
                        runner.stop()
                    }
                    Button("Close Session") {
                        showDetails = false
                        runner.savePreview(for: mac)
                        runner.stop()
                        close()
                    }
                }
            }
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDetails = false }
                }
            }
        }
    }
}
