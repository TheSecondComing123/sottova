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
        case .edit(let alarm):
            _source = State(initialValue: alarm.source)
            _time = State(initialValue: Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now)!)
            _repeats = State(initialValue: Repeat.allCases.first { $0.days == alarm.weekdays } ?? .weekdays)
            _shuffled = State(initialValue: alarm.shuffled)
        }
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
                Picker("Plays", selection: $source) {
                    Text("Choose an album or playlist").tag(String?.none)
                    if !controller.playlists.isEmpty {
                        Section("Playlists") {
                            ForEach(controller.playlists) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    }
                    Section("Albums") {
                        ForEach(controller.catalog.albums) { Text($0.title).tag(String?.some($0.id)) }
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            }
            HStack(spacing: 16) {
                DatePicker("time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .font(.system(size: 22, weight: .semibold))
                Picker("repeat", selection: $repeats) {
                    ForEach(Repeat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Shuffled", isOn: $shuffled)
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text((alarm.map(AlarmLine.describe) ?? "pick what it plays") + ". the mac has to be awake, and sottova running in the menu bar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.faint)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12)
                Button(editing ? "Save" : "Set alarm") {
                    guard let alarm else { return }
                    if editing { controller.updateAlarm(alarm) } else { controller.addAlarm(alarm) }
                    dismiss()
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

            IconButton(icon: .x, weight: .bold, help: "delete") { controller.removeAlarm(alarm.id) }
                .padding(.trailing, 4)
        }
        .hoverable(radius: 8)
        .contextMenu {
            Button("Edit…") { router.alarm = .edit(alarm) }
            Button(alarm.on ? "Turn off" : "Turn on", action: toggle)
            Divider()
            Button("Delete") { controller.removeAlarm(alarm.id) }
        }
    }

    private func toggle() {
        var changed = alarm
        changed.on.toggle()
        // a one-off turned back on goes off at its next time, not on a day that's gone
        if changed.on { changed.scheduleOnce() }
        controller.updateAlarm(changed)
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
