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
    /// A folder about to be removed, asked about first: its songs go with it.
    @State private var removing: URL?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var activeState

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
                    if let problem = controller.problem {
                        ProblemNotice(message: problem) { controller.problem = nil }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.raised, in: .rect(cornerRadius: Radius.small))
                            .padding(.bottom, 12)
                    }
                    music
                    section("Your day") {
                        // says itself while off: after a restart, alarms wouldn't play
                        Toggle(isOn: $opensAtLogin) { label("Open at login", detail: loginProblem ?? (opensAtLogin ? nil : "Your day needs Sottova running.")) }
                            .toggleStyle(ThemeCheckbox())
                            .modifier(SettingsRow())
                            .onChange(of: opensAtLogin) { _, on in setOpensAtLogin(on) }
                        CalendarRow()
                    }
                    playing
                    look
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .overlayScrollers()
        }
        .overlay(alignment: .bottom) { Toast().environment(controller).padding(.bottom, 16).padding(.horizontal, 16) }
        .frame(width: 620)
        // with the title bar this stretches up under; every row one line, more folders scroll
        .frame(minHeight: 460, idealHeight: 460, maxHeight: .infinity)
        .background(Theme.background)
        .ignoresSafeArea()
        .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
        // changes made here undo here, with ⌘Z and the toast
        .onChange(of: activeState, initial: true) { if activeState == .key { controller.undo = undoManager } }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).role(.body).fontWeight(.semibold).foregroundStyle(Theme.text).padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(Theme.sidebar, in: .rect(cornerRadius: Radius.medium))
                .overlay { RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Theme.stroke, lineWidth: 0.5) }
        }
        .padding(.bottom, 10)
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
                let path = shortPath(folder)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.lastPathComponent)
                            .role(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.text)
                        Text(path)
                            .role(.small)
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                    Spacer(minLength: 0)
                    Text(Format.count(songCount(in: folder), "song")).role(.body).monospacedDigit().foregroundStyle(Theme.muted).fixedSize()
                    ThemeButton(title: "Remove") { removing = folder }
                        .help("stop watching this folder; the files stay where they are")
                }
                .modifier(SettingsRow())
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ThemeButton(title: "Rescan", action: controller.rescan)
                ThemeButton(title: "Add folder…", action: controller.chooseFolders)
            }
            .modifier(SettingsRow())
            if !controller.skippedFiles.isEmpty { skipped }
        }
        .confirmationDialog(removing.map { "Remove \(shortPath($0))?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { folder in
            Button("Remove", role: .destructive) { controller.removeFolder(folder) }
        } message: { folder in
            let count = songCount(in: folder)
            Text("Its \(Format.count(count, "song")) \(count == 1 ? "leaves" : "leave") your library. The files stay where they are.")
        }
    }

    private func shortPath(_ folder: URL) -> String {
        folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~").trimmingSuffix("/")
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
                label("Loudness", detail: "Levels song volume")
                Spacer(minLength: 0)
                ThemePopup(title: Self.levels.first { $0.lufs == controller.settings.targetLufs }?.name ?? "\(Int(controller.settings.targetLufs)) LUFS") {
                    ForEach(Self.levels, id: \.lufs) { level in
                        Toggle("\(level.name), \(level.detail)", isOn: Binding(get: { controller.settings.targetLufs == level.lufs },
                                                                              set: { _ in controller.settings.targetLufs = level.lufs }))
                    }
                }
            }
            .modifier(SettingsRow())
            HStack(spacing: 16) {
                label("Don't repeat any of the last")
                Spacer(minLength: 0)
                ValueStepper(value: Binding(get: { Double(controller.settings.avoidLastN) }, set: { controller.settings.avoidLastN = Int($0) }),
                             range: 0...50, unit: "songs")
            }
            .modifier(SettingsRow())
            Toggle(isOn: $controller.keepsMacAwake) { label("Keep the Mac awake during silence") }
                .toggleStyle(ThemeCheckbox())
                .modifier(SettingsRow())
            Toggle(isOn: $controller.acceptsURLs) { label("Accept sottova:// links", detail: "For hotkeys and other apps") }
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
            loginProblem = "Couldn't change login items. Try System Settings, General, Login Items."
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
            .padding(.vertical, 2)
    }
}

/// None counted, a row minding its calendar has nothing to wait for: there's nothing else to store.
private struct CalendarRow: View {
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
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calendars that count as busy").role(.body).foregroundStyle(Theme.text)
                        Text("Music can wait while your calendar is busy.").role(.small).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    ThemePopup(title: "\(calendars.count(where: counts)) of \(calendars.count)") {
                        Button("All") { calendars.forEach { set(true, $0) } }
                        Button("None") { calendars.forEach { set(false, $0) } }
                        Divider()
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(calendar.title, isOn: Binding(get: { counts(calendar) }, set: { set($0, calendar) }))
                        }
                    }
                }
                .modifier(SettingsRow())
            case .notDetermined:
                ask("Calendars that count as busy", help: "Music can wait while your calendar is busy.", button: "Allow") {
                    Task {
                        await Presence.askForCalendars()
                        refresh()
                    }
                }
            default:
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Sottova can't read your calendars").role(.body).foregroundStyle(Theme.text)
                        Text("Rows can't wait for a busy calendar until you allow it.").role(.small).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    ThemeButton(title: "Open Privacy settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
                .modifier(SettingsRow())
            }
        }
        .onAppear(perform: refresh)
    }

    private func ask(_ title: String, help: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).role(.body).foregroundStyle(Theme.text)
                Text(help).role(.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ThemeButton(title: button, action: action).help(help)
        }
        .modifier(SettingsRow())
    }

    private func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        // reading calendars from the copy would ask for access
        #if SHOT
        if UserDefaults.standard.bool(forKey: "shotCalendars") {
            let store = EKEventStore()
            status = .fullAccess
            calendars = ["Home", "Work", "School", "Piano", "US Holidays"].map {
                let calendar = EKCalendar(for: .event, eventStore: store)
                calendar.title = $0
                return calendar
            }
        }
        #else
        calendars = Presence.calendars
        #endif
    }
}
