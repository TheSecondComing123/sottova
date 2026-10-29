import AppKit
import SwiftUI
import SottovaCore

struct Panel: View {
    @Bindable var controller: Controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showsGap = false
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.headline)
                    .font(.custom("Comic Mono", size: 17).bold())
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.subline(at: context.date))
                        if let next = controller.nextAlarm(after: context.date) {
                            Label { Text(AlarmLine.headline(next.alarm, at: next.at)) } icon: { Ph.alarm.icon(size: 13) }
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                }
            }

            Timeline(controller: controller, visible: visible)
                .frame(height: 44)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

            if let problem = controller.problem {
                Text(problem)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }

            HStack {
                if controller.tracks.isEmpty {
                    Button("Add a music folder", action: controller.chooseFolders)
                        .buttonStyle(.glassProminent)
                } else {
                    Controls(controller: controller)
                }
                Spacer()
                SleepButton()
                Menu {
                    Button("Open Sottova") { openWindow(id: "main"); NSApp.activate() }
                    Divider()
                    Button("Add folder…", action: controller.chooseFolders)
                    if !controller.folders.isEmpty {
                        Menu("Remove folder") {
                            ForEach(controller.folders, id: \.self) { folder in
                                Button(folder.lastPathComponent) { controller.removeFolder(folder) }
                            }
                        }
                    }
                    Divider()
                    Button("Settings…") { openSettings() }
                    Button("Quit Sottova") { NSApplication.shared.terminate(nil) }
                } label: {
                    Ph.dotsThree.icon(.bold, size: 16)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .hoverable(radius: 8)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }

            gapSection

            Text(controller.libraryLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.faint)
        }
        .padding(16)
        .frame(width: 320)
        .tint(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private var gapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.settle) { showsGap.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(controller.settings.name).foregroundStyle(Theme.muted)
                    Text(controller.settings.crossfade
                        ? "crossfade \(Int(controller.settings.crossfadeSec)) s"
                        : Format.range(controller.settings))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Ph.caretDown.icon(.bold, size: 12)
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(showsGap ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showsGap {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Preset")
                        PresetPicker(controller: controller)
                            .labelsHidden()
                    }
                    // the log-scale range from Settings: on a linear slider 30 s sat 2.5% along
                    GridRow {
                        GapRange(low: $controller.settings.gapMin, high: $controller.settings.gapMax)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        Text("Fade")
                        Picker("fade", selection: $controller.settings.curve) {
                            Text("Quartic").tag(FadeCurve.quartic)
                            Text("Even").tag(FadeCurve.dbLinear)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .transition(.opacity)
            }
        }
    }
}
