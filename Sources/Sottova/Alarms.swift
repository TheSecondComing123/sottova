import AVFoundation
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

/// "Start at…": a time, once or on repeat, for a collection to start by itself; or a stretch of the day when it plays
/// now and then while you're at the Mac.
struct AlarmSheet: View {
    let request: AlarmRequest
    @Environment(Controller.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var source: String?
    @State private var kind: Kind
    @State private var time: Date
    /// Where it ends: always for one that plays while you're here, and when `stops` for one that starts by itself.
    @State private var until: Date
    @State private var stops: Bool
    @State private var repeats: Repeat
    @State private var shuffled: Bool
    @State private var volume: Double?
    @State private var heedsCalendar: Bool
    @State private var rotates: Bool
    @State private var partCount: Int
    private let preview = AlarmPreview.shared

    enum Kind: String, CaseIterable {
        case byItself = "Starts by itself", whileHere = "Plays while you're here"
    }

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
            _kind = State(initialValue: .byItself)
            _time = State(initialValue: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now)!)
            _until = State(initialValue: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!)
            _repeats = State(initialValue: .once)
            _shuffled = State(initialValue: false)
            _heedsCalendar = State(initialValue: false)
            _rotates = State(initialValue: false)
            _partCount = State(initialValue: 4)
            _stops = State(initialValue: false)
            // quiet by default: whatever the speaker is turned up to, this is what wakes you
            _volume = State(initialValue: 0.15)
        case .edit(let alarm):
            _source = State(initialValue: alarm.source)
            _kind = State(initialValue: alarm.whileHere ? .whileHere : .byItself)
            let start = Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now)!
            _time = State(initialValue: start)
            _until = State(initialValue: start + Double(alarm.minutes ?? 60) * 60)
            _stops = State(initialValue: alarm.minutes != nil)
            _repeats = State(initialValue: Repeat.allCases.first { $0.days == alarm.weekdays } ?? .weekdays)
            _shuffled = State(initialValue: alarm.shuffled)
            _heedsCalendar = State(initialValue: alarm.heedsCalendar)
            _rotates = State(initialValue: alarm.rotates)
            _partCount = State(initialValue: alarm.parts)
            _volume = State(initialValue: alarm.volume)
        }
    }

    /// What a new one starts from: 7 AM, once, quiet; or the afternoon at the desk, every day, shuffled, at whatever
    /// the speaker is at.
    private static func defaults(_ kind: Kind) -> (start: Int, end: Int, repeats: Repeat, shuffled: Bool, volume: Double?, calendar: Bool) {
        kind == .whileHere ? (15, 19, .daily, true, nil, true) : (7, 8, .once, false, 0.15, false)
    }

    /// Whether this Mac's clock shows AM and PM.
    private static let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false

    /// "7", not "07": the AM or PM sits after the minutes.
    private func hourText(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return String(Self.twelveHour ? (hour + 11) % 12 + 1 : hour)
    }

    /// From the start to `until` around the clock, so 10 PM to 1 AM is three hours.
    private var span: Int {
        let minutes = { (date: Date) in Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date) }
        let span = (minutes(until) - minutes(time) + 1440) % 1440
        return span == 0 ? 1440 : span
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
        alarm.heedsCalendar = heedsCalendar
        alarm.rotates = rotates
        alarm.parts = partCount
        alarm.whileHere = kind == .whileHere
        alarm.minutes = alarm.whileHere || stops ? span : nil
        if case .edit(let old) = request {
            alarm.id = old.id
            alarm.on = old.on
            alarm.nextPart = old.nextPart
            alarm.lastFired = old.lastFired
            alarm.partSpent = old.partSpent
        }
        alarm.scheduleOnce()
        return alarm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            let unnamed = "New row"
            Text(kind == .whileHere ? name.map { "Play \($0) while you're here" } ?? "Music while you're here"
                                    : name.map { "Start \($0) at…" } ?? unnamed)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            if picking {
                Menu {
                    // one list, yours first
                    ForEach(controller.playlists) { playlist in Button(playlist.name) { source = playlist.id } }
                    if !controller.playlists.isEmpty {
                        Divider()
                    }
                    ForEach(controller.shownAlbums) { album in Button(album.title) { source = album.id } }
                } label: {
                    HStack(spacing: 8) {
                        Text(name ?? "Choose a collection")
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
            Strip(selection: $kind)
            // when: the time reads as a time, 7 : 00 AM, with what it repeats on and what that means right under it
            VStack(alignment: .leading, spacing: 12) {
                // the same two rows in both, so switching doesn't move anything under the pointer; one that starts by
                // itself may play on, so its end has a switch
                clock($time, label: kind == .whileHere ? "From" : "At")
                clock($until, label: "Until", on: kind == .whileHere ? nil : Binding(get: { stops }, set: { on in
                    if on, !stops { until = time + 3600 }
                    stops = on
                }))
                Strip(selection: $repeats)
                if let alarm {
                    Text(alarm.whileHere ? "plays now and then, \(AlarmLine.time(alarm)) to \(AlarmLine.end(of: alarm, minutes: span)) \(AlarmLine.days(alarm)). waits while you're away, on a call\(heedsCalendar ? ", playing something else or busy on your calendar" : " or playing something else")"
                        : AlarmLine.describe(alarm) + (heedsCalendar ? ", not on days your calendar has something on then" : "") + (SystemWake.shared.trusted || SystemWake.shared.missing(for: [alarm]).isEmpty ? "" : ". saving asks for your password once, so the mac can wake for alarms from then on"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            settings
            HStack(spacing: 12) {
                if let alarm {
                    Button(preview.playing == alarm.id ? "Stop" : "Hear it") { preview.toggle(alarm, controller: controller) }
                        .buttonStyle(QuietButton())
                        .help(alarm.whileHere ? "a few seconds at its volume" : "a few seconds at the volume it rises to")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(QuietButton())
                let setting = "Set"
                Button(editing ? "Save" : kind == .whileHere ? "Set hours" : setting) {
                    guard let alarm else { return }
                    if editing { controller.changeAlarm(alarm.id) { $0.setUserFields(from: alarm) } } else { controller.addAlarm(alarm) }
                    dismiss()
                    if alarm.heedsCalendar {
                        Task { await Presence.askForCalendars() }
                    }
                    if !alarm.whileHere {
                        SystemWake.shared.schedule(for: controller.alarms)
                    }
                }
                .buttonStyle(InvertedButton())
                .keyboardShortcut(.defaultAction)
                .disabled(alarm == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.sidebar)
        .presentationBackground(Theme.sidebar)
        .animation(Theme.quick, value: kind)
        .onChange(of: kind) { old, new in
            // a new one moves to what suits the other kind, except where you've already changed something
            guard !editing else { return }
            let (was, next) = (Self.defaults(old), Self.defaults(new))
            let at = { (hour: Int) in Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)! }
            if time == at(was.start) { time = at(next.start) }
            if until == at(was.end) { until = at(next.end) }
            if repeats == was.repeats { repeats = next.repeats }
            if shuffled == was.shuffled { shuffled = next.shuffled }
            if volume == was.volume { volume = next.volume }
            if heedsCalendar == was.calendar { heedsCalendar = next.calendar }
        }
        .onDisappear { preview.stop() }
    }

    /// "At 7 : 00 AM" as two steppers; with `on`, a switch at the end, and the steppers stand down while it's off.
    private func clock(_ date: Binding<Date>, label: String, on: Binding<Bool>? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 48, alignment: .leading)
            HStack(spacing: 4) {
                TimeStep(text: hourText(date.wrappedValue), help: "hour") { date.wrappedValue = date.wrappedValue.addingTimeInterval(Double($0) * 3600) }
                Text(":")
                TimeStep(text: date.wrappedValue.formatted(.dateTime.minute(.twoDigits)), help: "minute") {
                    date.wrappedValue = date.wrappedValue.addingTimeInterval(Double($0) * 60)
                }
                if Self.twelveHour {
                    Text(Calendar.current.component(.hour, from: date.wrappedValue) < 12 ? Calendar.current.amSymbol : Calendar.current.pmSymbol)
                        .padding(.leading, 4)
                }
            }
            .opacity(on?.wrappedValue == false ? 0.35 : 1)
            .disabled(on?.wrappedValue == false)
            Spacer(minLength: 0)
            if let on {
                Button { on.wrappedValue.toggle() } label: { SwitchKnob(on: on.wrappedValue) }
                    .buttonStyle(PressStyle())
                    .help(on.wrappedValue ? "play on instead" : "stop at a set time, easing down over the last three minutes")
                    .accessibilityRepresentation { Toggle("Stops", isOn: on) }
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Theme.muted)
    }

    /// "its own 3 parts, part 2 next", or "about 30 min each, part 1 next".
    private var partsLine: String? {
        guard let alarm, rotates else { return nil }
        let cut = controller.parts(for: alarm)
        guard !cut.isEmpty else { return nil }
        let next = controller.nextPartName(for: alarm) + " next"
        if controller.playlists.first(where: { $0.id == alarm.source })?.breaks.isEmpty == false {
            return "its own \(cut.count) parts, \(next)"
        }
        let total: Double = cut.joined().reduce(0) { $0 + $1.duration }
        let minutes = Int((total / Double(cut.count) / 60).rounded())
        return "about \(minutes) min each, \(next)"
    }

    /// The order, the calendar, the parts, and the volume it plays at.
    @ViewBuilder private var settings: some View {
        VStack(spacing: 8) {
            Toggle("Shuffled", isOn: $shuffled)
            Toggle("Not while my calendar is busy", isOn: $heedsCalendar)
            Toggle("One part each time", isOn: $rotates)
            if rotates {
                HStack(spacing: 12) {
                    // a collection with parts of its own uses those
                    if controller.playlists.first(where: { $0.id == source })?.breaks.isEmpty != false {
                        ValueStepper(value: Binding(get: { Double(partCount) }, set: { partCount = Int($0) }), range: 2...12, unit: "parts")
                    }
                    if let partsLine {
                        Text(partsLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
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
                // the machine's rise, Machine.riseLength
                Text(kind == .whileHere ? "set as it begins, whatever the speaker was left at" : "starts silent and rises to this over a minute and a half")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .toggleStyle(KnobToggle())
        .animation(Theme.quick, value: volume == nil)
        .animation(Theme.quick, value: rotates)
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
private struct Strip<Option: CaseIterable & Hashable & RawRepresentable>: View where Option.AllCases: RandomAccessCollection, Option.RawValue == String {
    @Binding var selection: Option
    @Namespace private var fill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Option.allCases), id: \.self) { option in
                let chosen = option == selection
                Button { selection = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Theme.text : Theme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            // the fill alone is barely lighter than the strip in monochrome; the edge says which
                            if chosen {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.hover)
                                    .strokeBorder(Theme.faint, lineWidth: 1)
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

/// A volume line with a square knob: no system accent in it.
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

/// How a row reads in words.
enum AlarmLine {
    private static func day(_ at: Date) -> String {
        Calendar.current.isDateInToday(at) ? "today" : Calendar.current.isDateInTomorrow(at) ? "tomorrow" : at.formatted(.dateTime.weekday(.wide))
    }

    /// "starts at 7:02 tomorrow", "starts at 7:02 on weekdays", "plays 3:00 PM to 7:00 PM every day, while you're at the mac".
    static func describe(_ alarm: Alarm) -> String {
        if alarm.whileHere { return "plays \(time(alarm)) to \(end(of: alarm, minutes: alarm.minutes ?? 0)) \(days(alarm)), while you're at the mac" }
        return "starts at \(time(alarm)) \(days(alarm))" + (alarm.minutes.map { ", stops at \(end(of: alarm, minutes: $0))" } ?? "")
    }

    /// When an alarm that stops after `minutes` goes quiet: "9:00 PM".
    static func end(of alarm: Alarm, minutes: Int) -> String {
        ((Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now) + Double(minutes) * 60)
            .formatted(date: .omitted, time: .shortened)
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
    /// The alarms that would go with this collection to the Trash; one made from an album gives its alarms back instead.
    func alarmsLost(trashing playlist: Playlist) -> [Alarm] {
        playlist.fromAlbum == nil ? alarms.filter { $0.source == playlist.id } : []
    }

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
/// reading what's scheduled doesn't. The commands run off the main actor, so a password prompt or a slow pmset can't
/// hold up the audio ticks; they run one at a time, in the order they were asked for.
@Observable @MainActor
final class SystemWake {
    static let shared = SystemWake()

    /// The wakes pmset has, from any app.
    private(set) var scheduled: Set<Date> = []
    var failure: String?
    @ObservationIgnored private var last: Task<Void, Never>?

    private func inTurn(_ work: @escaping @MainActor () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await work()
        }
    }

    func refresh() {
        inTurn { await self.read() }
    }

    private func read() async {
        guard let pmset = await WakePlan.run("/usr/bin/pmset", ["-g", "sched"]) else { return }
        scheduled = WakePlan.scheduled(in: pmset.output)
    }

    var trusted: Bool { FileManager.default.fileExists(atPath: WakePlan.rule) }

    func missing(for alarms: [Alarm], now: Date = .now) -> [Date] {
        WakePlan.needed(for: alarms, now: now).filter { !scheduled.contains($0) }
    }

    /// Whether the very next alarm can't wake the Mac; the days after it are filled in as they come closer.
    func nextMissing(for alarms: [Alarm], now: Date = .now) -> Bool {
        WakePlan.needed(for: alarms, now: now).first.map { !scheduled.contains($0) } ?? false
    }

    /// Fills in the wakes without asking, once the rule is in. Runs at launch, on every wake from sleep, and every six hours.
    func renew(for alarms: [Alarm]) {
        if trusted || FileManager.default.fileExists(atPath: WakePlan.looseRule) { schedule(for: alarms, asking: false) }
    }

    /// Schedules every missing wake, asking for the password first if the rule isn't in yet. A wake left from a
    /// deleted alarm stays: it only wakes the Mac, which goes back to sleep.
    func schedule(for alarms: [Alarm], asking: Bool = true) {
        inTurn { await self.fill(alarms, asking: asking) }
    }

    private func fill(_ alarms: [Alarm], asking: Bool) async {
        await read()
        let dates = missing(for: alarms)
        // the loose rule keeps wakes topped up, so nothing may be missing; saving an alarm still swaps it out
        let loose = !trusted && FileManager.default.fileExists(atPath: WakePlan.looseRule)
        guard !dates.isEmpty || (loose && asking) else { return }
        if !trusted, asking {
            let install = await WakePlan.run("/usr/bin/osascript", ["-e", WakePlan.installScript(user: NSUserName())])
            if install?.status != 0 {
                failure = WakePlan.installFailure(install?.error ?? "")
                return
            }
        }
        var failed = 0
        for date in dates where await WakePlan.run("/usr/bin/sudo", WakePlan.pmsetArguments(for: date))?.status != 0 {
            failed += 1
        }
        failure = failed == 0 ? nil : "couldn't schedule \(failed) of the wakes: the system said no"
        await read()
    }
}

/// A few seconds of how an alarm starts: its first piece (any piece, if it's shuffled) from the trim, faded in the way
/// it will be, at the alarm's volume and the piece's leveling. On a player of its own, with the queue paused.
@Observable @MainActor
final class AlarmPreview {
    static let shared = AlarmPreview()
    private(set) var playing: Alarm.ID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ending: Task<Void, Never>?
    /// The player whose music this paused, to pick it back up once the preview is over.
    @ObservationIgnored private weak var paused: Controller?

    func toggle(_ alarm: Alarm, controller: Controller) {
        if playing == alarm.id { stop() } else { play(alarm, controller: controller) }
    }

    private func play(_ alarm: Alarm, controller: Controller) {
        #if !SHOT
        halt()
        let songs = controller.playlists.first { $0.id == alarm.source }.map(controller.songs(of:)) ?? controller.catalog.albumsByID[alarm.source]?.songs ?? []
        guard let song = alarm.shuffled ? songs.randomElement() : songs.first,
              let player = try? AVAudioPlayer(contentsOf: URL(filePath: song.id)) else { return }
        if controller.status == .playing {
            controller.toggle()
            paused = controller
        }
        let own = controller.albumSettings[alarm.source] ?? controller.playlists.first { $0.id == alarm.source }?.gaps
        let fadeIn = (own?.gaps(over: controller.yourSettings) ?? controller.yourSettings).fadeIn
        player.currentTime = controller.trims[song.id]?.start ?? 0
        player.volume = 0
        player.play()
        player.setVolume(Float(min((alarm.volume ?? controller.volume) * controller.gain(of: song.id), 1)), fadeDuration: fadeIn)
        self.player = player
        playing = alarm.id
        ending = Task {
            try? await Task.sleep(for: .seconds(fadeIn + 6))
            guard !Task.isCancelled else { return }
            player.setVolume(0, fadeDuration: 1.5)
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            stop()
        }
        #endif
    }

    func stop() {
        halt()
        paused?.play()
        paused = nil
    }

    private func halt() {
        ending?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}
