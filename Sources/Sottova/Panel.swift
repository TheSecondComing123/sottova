import AppKit
import SwiftUI
import SottovaCore

struct Panel: View {
    @Bindable var controller: Controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showsGap = false

    var body: some View {
        let color = Mocha.accent(for: controller.title)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.headline)
                    .font(.custom("Comic Mono", size: 17).bold())
                    .foregroundStyle(controller.status == .playing ? color : Mocha.text)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(controller.subline(at: context.date))
                        .font(.callout)
                        .foregroundStyle(Mocha.subtext0)
                }
            }

            Timeline(controller: controller)
                .frame(height: 44)
                .padding(12)
                .glassEffect(.regular.tint(color.opacity(0.14)), in: .rect(cornerRadius: 14))

            if let problem = controller.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Color(hex: 0xF38BA8))
            }

            HStack {
                if controller.tracks.isEmpty {
                    Button("add a music folder…", action: addFolders)
                        .buttonStyle(.glassProminent)
                } else {
                    Controls(controller: controller)
                }
                Spacer()
                Menu {
                    Button("open window") { openWindow(id: "now") }
                    Divider()
                    Button("add folder…", action: addFolders)
                    if !controller.folders.isEmpty {
                        Menu("remove folder") {
                            ForEach(controller.folders, id: \.self) { folder in
                                Button(folder.lastPathComponent) { controller.removeFolder(folder) }
                            }
                        }
                    }
                    Divider()
                    Button("settings…") { openSettings() }
                    Button("quit sottova") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(.circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }

            gapSection

            Text(controller.libraryLine)
                .font(.caption)
                .foregroundStyle(Mocha.overlay0)
        }
        .padding(16)
        .frame(width: 320)
        .tint(color)
        .preferredColorScheme(.dark)
    }

    private var gapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { showsGap.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(controller.settings.name).foregroundStyle(Mocha.subtext0)
                    Text(controller.settings.crossfade
                        ? "crossfade \(Int(controller.settings.crossfadeSec)) s"
                        : "\(duration(controller.settings.gapRange.lowerBound)) – \(duration(controller.settings.gapRange.upperBound))")
                        .monospacedDigit()
                        .foregroundStyle(Mocha.text)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Mocha.overlay0)
                        .rotationEffect(.degrees(showsGap ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showsGap {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("preset")
                        PresetPicker(controller: controller)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("shortest")
                        Slider(value: $controller.settings.gapMin, in: 0...1200, step: 30)
                    }
                    GridRow {
                        Text("longest")
                        Slider(value: $controller.settings.gapMax, in: 0...1200, step: 30)
                    }
                    GridRow {
                        Text("fade")
                        Picker("fade", selection: $controller.settings.curve) {
                            Text("quartic").tag(FadeCurve.quartic)
                            Text("dB-linear").tag(FadeCurve.dbLinear)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .font(.callout)
                .foregroundStyle(Mocha.subtext0)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        // an accessory app's open panel otherwise lands behind the frontmost app
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        controller.addFolders(panel.urls)
    }
}
