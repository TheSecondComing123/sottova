#if NEWLOOK
import EventKit
import ServiceManagement
import SwiftUI
import SottovaCore

/// One pane: what's left of Settings now that silence lives in its sheet and the rest on Your day.
struct SettingsView: View {
    @Bindable var controller: Controller
    let themeChanged: () -> Void
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?
    @State private var showsSkipped = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .role(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    look
                    section("Starting") {
                        Toggle(isOn: $opensAtLogin) { label("Open at login", detail: loginProblem ?? "Your day needs Sottova running.") }
                            .toggleStyle(ThemeCheckbox())
                            .modifier(SettingsRow())
                            .onChange(of: opensAtLogin) { _, on in setOpensAtLogin(on) }
                    }
                    section("Calendars") { CalendarRows() }
                    music
                    playing
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .overlayScrollers()
        }
        .frame(width: 620)
        // 560 with the title bar this stretches up under
        .frame(minHeight: 528, idealHeight: 528, maxHeight: .infinity)
        .background(Theme.background)
        .ignoresSafeArea()
        .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).role(.body).fontWeight(.semibold).foregroundStyle(Theme.text).padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(Theme.sidebar, in: .rect(cornerRadius: Radius.medium))
                .overlay { RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Theme.stroke, lineWidth: 0.5) }
        }
        .padding(.bottom, 16)
    }

    private func label(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).role(.body).foregroundStyle(Theme.text)
            if let detail { Text(detail).role(.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var look: some View {
        section("Look") {
            themeRow("Dark theme", side: .dark, key: "themeDark", current: Theme.slotNames.dark)
            themeRow("Light theme", side: .light, key: "themeLight", current: Theme.slotNames.light)
            ForEach(Theme.themes.rejected, id: \.file) { rejected in
                Text("\(rejected.file) was skipped: \(rejected.why).").role(.small).foregroundStyle(Theme.muted).modifier(SettingsRow())
            }
        }
    }

    private func themeRow(_ title: String, side: ThemeFile.Side, key: String, current: String) -> some View {
        HStack(spacing: 16) {
            label(title)
            Spacer(minLength: 0)
            ThemePopup(title: current) {
                ForEach(Theme.themes.themes.filter { $0.side == side }.sorted { $0.name < $1.name }, id: \.name) { theme in
                    Toggle(theme.name, isOn: Binding(get: { theme.name == current }, set: { _ in
                        UserDefaults.standard.set(theme.name, forKey: key)
                        if Theme.reloadThemes() { themeChanged() }
                    }))
                }
            }
        }
        .modifier(SettingsRow())
    }

    private var music: some View {
        section("Music") {
            ForEach(controller.folders, id: \.self) { folder in
                HStack(spacing: 16) {
                    label(folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~").trimmingSuffix("/"),
                          detail: Format.count(songCount(in: folder), "song"))
                    Spacer(minLength: 0)
                    ThemeButton(title: "Remove") { controller.removeFolder(folder) }
                        .help("stop watching this folder; the files stay where they are")
                }
                .modifier(SettingsRow())
            }
            HStack(spacing: 16) {
                label("Add a folder…")
                Spacer(minLength: 0)
                ThemeButton(title: "Choose", action: controller.chooseFolders)
            }
            .modifier(SettingsRow())
            HStack(spacing: 16) {
                label("Look through them again")
                Spacer(minLength: 0)
                ThemeButton(title: "Rescan", action: controller.rescan)
            }
            .modifier(SettingsRow())
            if !controller.skippedFiles.isEmpty { skipped }
        }
    }

    private var skipped: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                label("\(Format.count(controller.skippedFiles.count, "file")) can't be played")
                Spacer(minLength: 0)
                if controller.skippedFiles.count > 5 {
                    ThemeButton(title: showsSkipped ? "Fewer" : "All") { showsSkipped.toggle() }
                }
            }
            ForEach(controller.skippedFiles.prefix(showsSkipped ? .max : 5), id: \.self) { file in
                Text(file.lastPathComponent).role(.small).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .modifier(SettingsRow())
    }

    private var playing: some View {
        section("Playing") {
            HStack(spacing: 16) {
                label("Loudness", detail: "Starts with the next song.")
                Spacer(minLength: 0)
                ThemePopup(title: Self.levels.first { $0.lufs == controller.settings.targetLufs }?.name ?? "\(Int(controller.settings.targetLufs)) LUFS") {
                    ForEach(Self.levels, id: \.lufs) { level in
                        Toggle("\(level.name), \(level.detail)", isOn: Binding(get: { controller.settings.targetLufs == level.lufs },
                                                                              set: { _ in controller.settings.targetLufs = level.lufs }))
                    }
                }
            }
            .modifier(SettingsRow())
            Toggle(isOn: $controller.keepsMacAwake) {
                label("Keep the Mac awake during silence", detail: "Sound stops between songs, so otherwise the Mac can sleep in the middle of one.")
            }
            .toggleStyle(ThemeCheckbox())
            .modifier(SettingsRow())
            Toggle(isOn: $controller.acceptsURLs) {
                label("Accept sottova:// links", detail: "Play, pause, toggle, skip and preset/minecraft, from Raycast, Shortcuts or a script. status.json in Application Support/Sottova follows every change.")
            }
            .toggleStyle(ThemeCheckbox())
            .modifier(SettingsRow())
        }
    }

    private static let levels: [(lufs: Double, name: String, detail: String)] = [
        (-14, "Loud", "like streaming apps"), (-18, "Medium", "the default"), (-23, "Quiet", "like broadcast TV"),
    ]

    private func songCount(in folder: URL) -> Int {
        let prefix = folder.path(percentEncoded: false)
        return controller.tracks.count { $0.path(percentEncoded: false).hasPrefix(prefix) }
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
            loginProblem = "Couldn't change login items: \(error.localizedDescription)"
        }
        // the user can also change this in System Settings, so read back what actually happened
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self }
}

private struct SettingsRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}

/// Off, no calendar counts, which is what a row minding them reads: there's nothing else to store.
private struct CalendarRows: View {
    @State private var status = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [EKCalendar] = []
    @State private var counted: [String: Bool] = [:]

    private func counts(_ calendar: EKCalendar) -> Bool {
        counted[calendar.calendarIdentifier] ?? Presence.counts(calendar)
    }

    private func set(_ on: Bool, _ calendar: EKCalendar) {
        Presence.setCounts(on, for: calendar)
        counted[calendar.calendarIdentifier] = on
    }

    var body: some View {
        Group {
            switch status {
            case .fullAccess:
                Toggle(isOn: Binding(get: { calendars.contains(where: counts) }, set: { on in calendars.forEach { set(on, $0) } })) {
                    Text("Wait while my calendar is busy").role(.body).foregroundStyle(Theme.text)
                }
                .toggleStyle(ThemeCheckbox())
                .modifier(SettingsRow())
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    Toggle(isOn: Binding(get: { counts(calendar) }, set: { set($0, calendar) })) {
                        Text(calendar.title).role(.body).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(ThemeCheckbox())
                    .modifier(SettingsRow())
                }
            case .notDetermined:
                ask("Sottova hasn't asked for your calendars", detail: "Rows can wait for meetings once you allow it.", button: "Allow") {
                    Task {
                        await Presence.askForCalendars()
                        refresh()
                    }
                }
            default:
                ask("Sottova can't read your calendars", detail: "Rows can't wait for meetings until you allow it.", button: "Open Privacy settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func ask(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).role(.body).foregroundStyle(Theme.text)
                Text(detail).role(.small).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            ThemeButton(title: button, action: action)
        }
        .modifier(SettingsRow())
    }

    private func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        // reading calendars from the copy would ask for access
        #if !SHOT
        calendars = Presence.calendars
        #endif
    }
}
#endif
