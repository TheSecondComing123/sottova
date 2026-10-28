import ServiceManagement
import SwiftUI
import SottovaCore

struct SettingsView: View {
    @Bindable var controller: Controller

    var body: some View {
        TabView {
            Tab("Library", systemImage: "folder") { LibraryTab(controller: controller) }
            Tab("Playback", systemImage: "waveform") { PlaybackTab(controller: controller) }
            Tab("General", systemImage: "gearshape") { GeneralTab(controller: controller) }
        }
        .frame(width: 480, height: 400)
        .tint(Mocha.accent(for: controller.title))
        .onAppear { Dock.windowOpened(identifier: "Settings") }
        .onDisappear { Dock.windowClosed() }
    }
}

private struct LibraryTab: View {
    let controller: Controller

    var body: some View {
        Form {
            Section {
                ForEach(controller.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(folder.lastPathComponent)
                        Text(folder.deletingLastPathComponent().path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("remove", systemImage: "minus.circle") { controller.removeFolder(folder) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("add folder…") { addFolders() }
                    Button("rescan") { controller.rescan() }
                }
            } header: {
                Text("watched folders")
            } footer: {
                Text(controller.libraryLine).foregroundStyle(.secondary)
            }

            if !controller.skippedFiles.isEmpty {
                Section("skipped, format not supported") {
                    ForEach(controller.skippedFiles, id: \.self) { file in
                        Text(file.lastPathComponent).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.addFolders(panel.urls)
    }
}

private struct PlaybackTab: View {
    @Bindable var controller: Controller

    var body: some View {
        Form {
            Section {
                PresetPicker(controller: controller)
            }
            Section("gap between tracks") {
                LabeledContent("shortest") {
                    Slider(value: $controller.settings.gapMin, in: 0...1200, step: 30)
                    Text(duration(controller.settings.gapMin)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                LabeledContent("longest") {
                    Slider(value: $controller.settings.gapMax, in: 0...1200, step: 30)
                    Text(duration(controller.settings.gapMax)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
            Section("fades") {
                LabeledContent("fade in") {
                    Slider(value: $controller.settings.fadeIn, in: 0...20, step: 1)
                    Text("\(Int(controller.settings.fadeIn)) s").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                LabeledContent("fade out") {
                    Slider(value: $controller.settings.fadeOut, in: 0...20, step: 1)
                    Text("\(Int(controller.settings.fadeOut)) s").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                Picker("curve", selection: $controller.settings.curve) {
                    Text("quartic").tag(FadeCurve.quartic)
                    Text("dB-linear").tag(FadeCurve.dbLinear)
                }
                Toggle("crossfade instead of resting", isOn: $controller.settings.crossfade)
                if controller.settings.crossfade {
                    LabeledContent("crossfade") {
                        Slider(value: $controller.settings.crossfadeSec, in: 1...10, step: 1)
                        Text("\(Int(controller.settings.crossfadeSec)) s").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section("shuffle") {
                Stepper("don't repeat the last \(controller.settings.avoidLastN) tracks", value: $controller.settings.avoidLastN, in: 0...50)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @Bindable var controller: Controller
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                Toggle("open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in setOpensAtLogin(on) }
                if let loginProblem {
                    Text(loginProblem).font(.caption).foregroundStyle(.red)
                }
                Toggle("keep the Mac awake during gaps", isOn: $controller.keepsMacAwake)
            } footer: {
                Text("the engine pauses between tracks, so without this the Mac can idle-sleep in the middle of a gap").foregroundStyle(.secondary)
            }
            Section {
                Toggle("accept sottova:// links", isOn: $controller.acceptsURLs)
            } footer: {
                Text("sottova://play, pause, toggle, skip and preset/minecraft. status.json in ~/Library/Application Support/Sottova updates on every change.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginProblem = nil
        } catch {
            loginProblem = "couldn't change login items: \(error.localizedDescription)"
        }
        // the user can also change this in System Settings, so read back what actually happened
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct PresetPicker: View {
    let controller: Controller

    var body: some View {
        Picker("preset", selection: Binding(
            get: { controller.settings.name },
            set: { name in
                if let preset = Settings.presets.first(where: { $0.name == name }) {
                    controller.apply(preset)
                }
            }
        )) {
            ForEach(Settings.presets, id: \.name) { preset in
                Text(preset.name).tag(preset.name)
            }
            if controller.settings.name == "Custom" {
                Text("Custom").tag("Custom")
            }
        }
    }
}

func duration(_ seconds: Double) -> String {
    seconds < 60 ? "\(Int(seconds)) s" : String(format: "%g min", seconds / 60)
}
