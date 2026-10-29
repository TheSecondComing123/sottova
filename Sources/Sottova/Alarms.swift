import SwiftUI
import SottovaCore

/// "Start at…": a time, once or on repeat, for an album or playlist to start by itself.
struct AlarmSheet: View {
    let target: CoverTarget
    @Environment(Controller.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now)!
    @State private var repeats = Repeat.once
    @State private var shuffled = false

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

    private var source: String {
        switch target {
        case .album(let id), .playlist(let id): id
        }
    }

    private var name: String {
        controller.playlists.first { $0.id == source }?.name ?? controller.catalog.albumsByID[source]?.title ?? "this"
    }

    /// The alarm as set so far, so the sheet can say exactly when it'll go off.
    private var alarm: Alarm {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        var alarm = Alarm(source: source, name: name, hour: parts.hour ?? 7, minute: parts.minute ?? 0, weekdays: repeats.days, shuffled: shuffled)
        if repeats == .once {
            // today if that time is still ahead, otherwise tomorrow
            alarm.day = .now
            if alarm.next(after: .now) == nil { alarm.day = Calendar.current.date(byAdding: .day, value: 1, to: .now) }
        }
        return alarm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Start \(name) at…")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
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
            Text(AlarmLine.describe(alarm) + ". the mac has to be awake, and sottova running in the menu bar")
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
                Button("Set alarm") {
                    controller.addAlarm(alarm)
                    dismiss()
                }
                .buttonStyle(InvertedButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .presentationBackground(Theme.background)
    }
}

/// Under an album or playlist title: when it starts by itself, and a way to call that off.
struct AlarmLine: View {
    let source: String
    @Environment(Controller.self) private var controller

    var body: some View {
        let mine = controller.alarms.filter { $0.source == source }
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

    /// "starts at 7:02 tomorrow", "starts at 7:02 on weekdays".
    static func describe(_ alarm: Alarm) -> String {
        let time = (Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now)
            .formatted(date: .omitted, time: .shortened)
        switch alarm.weekdays.count {
        case 7: return "starts at \(time) every day"
        case 0:
            guard let at = alarm.next(after: .now) else { return "starts at \(time)" }
            return "starts at \(time) " + (Calendar.current.isDateInToday(at) ? "today" : Calendar.current.isDateInTomorrow(at) ? "tomorrow" : at.formatted(.dateTime.weekday(.wide)))
        default: return alarm.weekdays == [2, 3, 4, 5, 6] ? "starts at \(time) on weekdays" : "starts at \(time) on some days"
        }
    }
}
