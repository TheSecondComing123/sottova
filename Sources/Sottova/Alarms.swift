import SwiftUI
import SottovaCore

enum AlarmRequest: Identifiable {
    /// A new alarm, for this album or playlist, or for one picked in the sheet.
    case new(CoverTarget?)
    case edit(Alarm)

    var id: String {
        switch self {
        case .new(let target): "new \(String(describing: target))"
        case .edit(let alarm): alarm.id.uuidString
        }
    }
}

/// "Start at…": a time, once or on repeat, for an album or playlist to start by itself.
struct AlarmSheet: View {
    let request: AlarmRequest
    @Environment(Controller.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var source: String?
    @State private var time: Date
    @State private var repeats: Repeat
    @State private var shuffled: Bool
    @State private var volume: Double?

    enum Repeat: String, CaseIterable {
        case once = "Once", weekdays = "Weekdays", daily = "Every day"

        var days: Set<Int> {
            switch self {
            case .once: []
            case .weekdays: [2, 3, 4, 5, 6]
            case .daily: Set(1...7)
            }
        }
    }

    init(request: AlarmRequest) {
        self.request = request
        switch request {
        case .new(let target):
            switch target {
            case .album(let id), .playlist(let id): _source = State(initialValue: id)
            case nil: _source = State(initialValue: nil)
            }
            _time = State(initialValue: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now)!)
            _repeats = State(initialValue: .once)
            _shuffled = State(initialValue: false)
            // quiet by default: whatever the speaker is turned up to, this is what wakes you
            _volume = State(initialValue: 0.15)
        case .edit(let alarm):
            _source = State(initialValue: alarm.source)
            _time = State(initialValue: Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now)!)
            _repeats = State(initialValue: Repeat.allCases.first { $0.days == alarm.weekdays } ?? .weekdays)
            _shuffled = State(initialValue: alarm.shuffled)
            _volume = State(initialValue: alarm.volume)
        }
    }

    /// Whether this Mac's clock shows AM and PM.
    private static let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false

    /// "7", not "07": the AM or PM sits after the minutes.
    private var hourText: String {
        let hour = Calendar.current.component(.hour, from: time)
        return String(Self.twelveHour ? (hour + 11) % 12 + 1 : hour)
    }

    private var picking: Bool {
        if case .new(nil) = request { true } else { false }
    }

    private var editing: Bool {
        if case .edit = request { true } else { false }
    }

    private var name: String? {
        source.map { controller.alarmName(of: $0) }
    }

    /// The alarm as set so far, so the sheet can say exactly when it'll go off.
    private var alarm: Alarm? {
        guard let source, let name else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        var alarm = Alarm(source: source, name: name, hour: parts.hour ?? 7, minute: parts.minute ?? 0, weekdays: repeats.days, shuffled: shuffled)
        alarm.volume = volume
        if case .edit(let old) = request {
            alarm.id = old.id
            alarm.on = old.on
        }
        alarm.scheduleOnce()
        return alarm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(name.map { "Start \($0) at…" } ?? "New alarm")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            if picking {
                Menu {
                    if !controller.playlists.isEmpty {
                        Section("Playlists") {
                            ForEach(controller.playlists) { playlist in Button(playlist.name) { source = playlist.id } }
                        }
                    }
                    Section("Albums") {
                        ForEach(controller.catalog.albums) { album in Button(album.title) { source = album.id } }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(name ?? "Choose an album or playlist")
                            .foregroundStyle(name == nil ? Theme.muted : Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Ph.caretDown.icon(.bold, size: 12)
                            .foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.raised, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .contentShape(.rect)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
            // when: the time reads as a time, 7 : 00 AM, with what it repeats on and what that means right under it
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    TimeStep(text: hourText, help: "hour") { time = time.addingTimeInterval(Double($0) * 3600) }
                    Text(":")
                    TimeStep(text: time.formatted(.dateTime.minute(.twoDigits)), help: "minute") { time = time.addingTimeInterval(Double($0) * 60) }
                    if Self.twelveHour {
                        Text(Calendar.current.component(.hour, from: time) < 12 ? Calendar.current.amSymbol : Calendar.current.pmSymbol)
                            .padding(.leading, 4)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.muted)
                RepeatStrip(selection: $repeats)
                if let alarm {
                    Text(AlarmLine.describe(alarm) + (SystemWake.shared.missing(for: [alarm]).isEmpty ? "" : ". saving asks for your password once, so the mac can wake for it"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }
            }
            VStack(spacing: 8) {
                Toggle("Shuffled", isOn: $shuffled)
                Toggle("Set the volume", isOn: Binding(get: { volume != nil }, set: { volume = $0 ? 0.15 : nil }))
                if let level = volume {
                    HStack(spacing: 12) {
                        LineSlider(value: Binding(get: { level }, set: { volume = max($0, 0.02) }))
                        Text(level.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .transition(.opacity)
                }
            }
            .toggleStyle(KnobToggle())
            .animation(Theme.quick, value: volume == nil)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(QuietButton())
                Button(editing ? "Save" : "Set alarm") {
                    guard let alarm else { return }
                    if editing { controller.updateAlarm(alarm) } else { controller.addAlarm(alarm) }
                    dismiss()
                    SystemWake.shared.schedule(for: controller.alarms)
                }
                .buttonStyle(InvertedButton())
                .keyboardShortcut(.defaultAction)
                .disabled(alarm == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .presentationBackground(Theme.background)
    }
}

/// − value + in one bordered strip, like the gap steppers in Settings; a step past the end wraps around the clock.
private struct TimeStep: View {
    let text: String
    let help: String
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(.minus, -1)
            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 52)
                .contentTransition(.numericText())
            button(.plus, 1)
        }
        .frame(height: 36)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { $0 == .increment ? step(1) : step(-1) }
    }

    private func button(_ icon: Ph, _ delta: Int) -> some View {
        Button { withAnimation(Theme.quick) { step(delta) } } label: {
            icon.icon(.bold, size: 12)
                .foregroundStyle(Theme.muted)
                .frame(width: 32, height: 36)
                .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle())
        // held down it keeps going, so 7:30 isn't thirty clicks
        .buttonRepeatBehavior(.enabled)
        .help(delta < 0 ? "earlier" : "later")
    }
}

/// Once, Weekdays, Every day: the chosen one sits on a fill that slides between them, like the sidebar's.
private struct RepeatStrip: View {
    @Binding var selection: AlarmSheet.Repeat
    @Namespace private var fill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AlarmSheet.Repeat.allCases, id: \.self) { option in
                let chosen = option == selection
                Button { selection = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(chosen ? Theme.text : Theme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.hover)
                                    .matchedGeometryEffect(id: "fill", in: fill)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .animation(Theme.settle, value: selection)
    }
}

/// A label with the square switch at the far end, with no card around it.
private struct KnobToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 16)
                SwitchKnob(on: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The player bar's volume line, with the square knob from the gap range: no system accent in it.
private struct LineSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.hover).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Theme.text).frame(width: w * value, height: 4)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.text)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.background, lineWidth: 2))
                    .offset(x: w * value - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value = min(max($0.location.x / w, 0), 1) })
        }
        .frame(height: 20)
        .padding(.horizontal, 8)
        .accessibilityRepresentation { Slider(value: $value, in: 0...1) { Text("Volume") } }
    }
}

/// Every alarm in one place, soonest first; the ones turned off sit at the bottom.
struct AlarmsPage: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router

    var body: some View {
        let now = Date.now
        let alarms = controller.alarms.sorted { a, b in
            let (x, y) = (a.on ? a.next(after: now) : nil, b.on ? b.next(after: now) : nil)
            return (x ?? .distantFuture, a.hour * 60 + a.minute) < (y ?? .distantFuture, b.hour * 60 + b.minute)
        }
        PageScroll {
            PageHeader(title: "Alarms", detail: controller.nextAlarm().map { "next: \(AlarmLine.headline($0.alarm, at: $0.at))" }
                       ?? (alarms.isEmpty ? "an album or playlist that starts by itself" : "all off"), songs: [])
                .padding(.bottom, -8)
            WakeLine(alarms: alarms)
                .padding(.bottom, 16)
            // where Play sits on the other pages
            Button("New alarm") { router.alarm = .new(nil) }
                .buttonStyle(InvertedButton())
                .padding(.bottom, 24)
            if alarms.isEmpty {
                Text("set one here, or with Start at… on any album or playlist")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 2) {
                    ForEach(alarms) { AlarmRow(alarm: $0) }
                }
                .padding(.horizontal, -12)
                // a time a screen away from its name reads as a different row
                .frame(maxWidth: 720, alignment: .leading)
                .animation(Theme.quick, value: alarms.map(\.id))
            }
        }
    }
}

private struct AlarmRow: View {
    let alarm: Alarm
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Button { router.alarm = .edit(alarm) } label: {
                HStack(spacing: 16) {
                    Artwork(key: controller.alarmArtwork(of: alarm.source), size: 48, radius: 4, title: alarm.name)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alarm.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(AlarmLine.days(alarm) + (alarm.shuffled ? ", shuffled" : ""))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 16)
                    Text(AlarmLine.time(alarm))
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.4)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
                .opacity(alarm.on ? 1 : 0.4)
                .padding(.leading, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(scale: 0.99))
            .help("change the time or days")

            Button(action: toggle) {
                SwitchKnob(on: alarm.on)
            }
            .buttonStyle(PressStyle())
            .help(alarm.on ? "turn off" : "turn on")
            .accessibilityRepresentation {
                Toggle("on", isOn: Binding(get: { alarm.on }, set: { _ in toggle() }))
            }

            // only under the pointer: one click deletes, and it sat right beside the switch
            IconButton(icon: .x, weight: .bold, help: "delete") { controller.removeAlarm(alarm.id) }
                .padding(.trailing, 4)
                .opacity(hovering ? 1 : 0)
                .animation(Theme.quick, value: hovering)
        }
        .hoverable(radius: 8)
        .onHover { hovering = $0 }
        .sottovaMenu {
            [
                .item("Edit…") { router.alarm = .edit(alarm) },
                .item(alarm.on ? "Turn off" : "Turn on", action: toggle),
                .divider,
                .item("Delete") { controller.removeAlarm(alarm.id) },
            ]
        }
    }

    private func toggle() {
        var changed = alarm
        changed.on.toggle()
        // a one-off turned back on goes off at its next time, not on a day that's gone
        if changed.on { changed.scheduleOnce() }
        controller.updateAlarm(changed)
        if changed.on { SystemWake.shared.schedule(for: controller.alarms) }
    }
}

/// Whether the Mac wakes itself for the alarms, and a way to make it.
private struct WakeLine: View {
    let alarms: [Alarm]
    private var wake = SystemWake.shared

    init(alarms: [Alarm]) {
        self.alarms = alarms
    }

    var body: some View {
        Group {
            if let failure = wake.failure {
                Text(failure)
            } else if alarms.contains(where: \.on), !wake.missing(for: alarms).isEmpty {
                HStack(spacing: 8) {
                    Text("won't wake the mac from sleep, only play if it's awake")
                    LinkText(text: "wake it") { wake.schedule(for: alarms) }
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.muted)
        .onAppear { wake.refresh() }
    }
}

/// Under an album or playlist title: when it starts by itself, and a way to call that off.
struct AlarmLine: View {
    let source: String
    @Environment(Controller.self) private var controller

    var body: some View {
        let mine = controller.alarms.filter { $0.source == source && $0.on }
        if !mine.isEmpty {
            HStack(spacing: 8) {
                Ph.clock.icon(size: 14)
                    .foregroundStyle(Theme.accent(for: source))
                ForEach(mine) { alarm in
                    Text(Self.describe(alarm))
                        .foregroundStyle(Theme.muted)
                    LinkText(text: "cancel") { controller.removeAlarm(alarm.id) }
                        .foregroundStyle(Theme.text)
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    /// "Lauds at 7:02 tomorrow", by when it next goes off, so a repeating one names its day too.
    static func headline(_ alarm: Alarm, at: Date) -> String {
        "\(alarm.name) at \(time(alarm)) \(day(at))"
    }

    private static func day(_ at: Date) -> String {
        Calendar.current.isDateInToday(at) ? "today" : Calendar.current.isDateInTomorrow(at) ? "tomorrow" : at.formatted(.dateTime.weekday(.wide))
    }

    /// "starts at 7:02 tomorrow", "starts at 7:02 on weekdays".
    static func describe(_ alarm: Alarm) -> String {
        "starts at \(time(alarm)) \(days(alarm))"
    }

    static func time(_ alarm: Alarm) -> String {
        (Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now)
            .formatted(date: .omitted, time: .shortened)
    }

    /// "tomorrow", "every day", "on weekdays".
    static func days(_ alarm: Alarm) -> String {
        switch alarm.weekdays.count {
        case 7: return "every day"
        case 0:
            return alarm.next(after: .now).map(day) ?? "once"
        default: return alarm.weekdays == [2, 3, 4, 5, 6] ? "on weekdays" : "on some days"
        }
    }
}

extension Controller {
    /// What an alarm's album or playlist is called now; a rename since it was set shows.
    func alarmName(of source: String) -> String {
        playlists.first { $0.id == source }?.name ?? catalog.albumsByID[source]?.title ?? "this"
    }

    func alarmArtwork(of source: String) -> String? {
        if let playlist = playlists.first(where: { $0.id == source }) {
            return playlistCovers[source] ?? songs(of: playlist).first?.artwork
        }
        return catalog.albumsByID[source]?.artwork
    }
}

/// Wakes the Mac from sleep before each alarm, through pmset. Scheduling needs root, so it asks for the password;
/// reading what's scheduled doesn't, so the password is only asked for when a wake is missing.
@Observable @MainActor
final class SystemWake {
    static let shared = SystemWake()
    /// Enough before the alarm for the Mac to come up and the timer to fire on time.
    static let lead: TimeInterval = 2 * 60
    /// How far ahead wakes go in, so a repeating alarm doesn't ask for the password every morning.
    static let ahead: TimeInterval = 14 * 86_400

    /// The wakes pmset has, from any app.
    private(set) var scheduled: Set<Date> = []
    var failure: String?

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return f
    }()

    func refresh() {
        let pipe = Pipe()
        let pmset = Process()
        pmset.executableURL = URL(filePath: "/usr/bin/pmset")
        pmset.arguments = ["-g", "sched"]
        pmset.standardOutput = pipe
        guard (try? pmset.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pmset.waitUntilExit()
        scheduled = Set(output.matches(of: /wake(?:orpoweron)? at (\d\d\/\d\d\/\d{4} \d\d:\d\d:\d\d)/)
            .compactMap { Self.format.date(from: String($0.1)) })
    }

    /// The wakes the alarms that are on need in the next two weeks and don't have yet.
    func missing(for alarms: [Alarm], now: Date = .now) -> [Date] {
        alarms.filter(\.on)
            .flatMap { $0.times(after: now, until: now + Self.ahead) }
            .map { $0 - Self.lead }
            .filter { $0 > now + 60 && !scheduled.contains($0) }
            .sorted()
    }

    /// Asks for the password once and schedules every missing wake. A wake left from a deleted alarm stays: it
    /// only wakes the Mac, which goes back to sleep, and removing it would mean another password.
    func schedule(for alarms: [Alarm]) {
        refresh()
        let dates = missing(for: alarms)
        guard !dates.isEmpty else { return }
        let commands = dates.map { "/usr/bin/pmset schedule wakeorpoweron '\(Self.format.string(from: $0))'" }.joined(separator: "; ")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(commands)\" with administrator privileges")?.executeAndReturnError(&error)
        // -128 is Cancel in the password prompt: not a failure, the page still says the Mac won't wake
        if let error, error[NSAppleScript.errorNumber] as? Int != -128 {
            failure = "couldn't schedule the wake: \(error[NSAppleScript.errorMessage] as? String ?? "pmset failed")"
        } else {
            failure = nil
        }
        refresh()
    }
}
