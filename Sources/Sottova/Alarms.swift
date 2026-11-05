import AVFoundation
import SwiftUI
import SottovaCore

enum AlarmRequest: Identifiable {
    /// A new alarm, for this album or playlist, or for one picked in the sheet.
    case new(CoverTarget?)
    /// A new one at this minute of the day, from a click on the rail, its collection picked in the sheet.
    case newAt(Int)
    case edit(Alarm)

    var id: String {
        switch self {
        case .new(let target): "new \(String(describing: target))"
        case .newAt(let minute): "new at \(minute)"
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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// A new one's id while the sheet is open: Hear it knows its preview by it.
    @State private var draft = UUID()
    private let preview = AlarmPreview.shared

    enum Kind: String, CaseIterable {
        case byItself = "Starts by itself", whileHere = "Plays while you're here"
    }

    enum Repeat: String, CaseIterable {
        case once = "Once", weekdays = "Weekdays", weekends = "Weekends", daily = "Every day"

        var days: Set<Int> {
            switch self {
            case .once: []
            case .weekdays: [2, 3, 4, 5, 6]
            case .weekends: [1, 7]
            case .daily: Set(1...7)
            }
        }
    }

    init(request: AlarmRequest) {
        self.request = request
        switch request {
        case .new, .newAt:
            let target: CoverTarget? = if case .new(let target) = request { target } else { nil }
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
            if case .newAt(let minute) = request {
                let start = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now)!
                (_time, _until) = (State(initialValue: start), State(initialValue: start + 3600))
            }
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

    /// From the start to `until` around the clock, so 10 PM to 1 AM is three hours.
    private var span: Int { RowTime.span(from: time, until: until) }

    private var picking: Bool {
        switch request {
        case .new(nil), .newAt: true
        default: false
        }
    }

    /// Its time came from where it was clicked on the rail, so the other kind's hours don't replace it.
    private var placed: Bool {
        if case .newAt = request { true } else { false }
    }

    private var editing: Bool {
        if case .edit = request { true } else { false }
    }

    private var name: String? {
        source.map { controller.alarmName(of: $0) }
    }

    /// The alarm as set so far.
    private var alarm: Alarm? {
        guard let source, let name else { return nil }
        let clock = RowTime.clock(time)
        var alarm = Alarm(source: source, name: name, hour: clock.hour, minute: clock.minute, weekdays: repeats.days, shuffled: shuffled)
        alarm.id = draft
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
            alarm.daysOff = old.daysOff
        }
        alarm.scheduleOnce()
        return alarm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let unnamed = "Schedule music"
            Text(kind == .whileHere ? name.map { "Play \($0) while you're here" } ?? "Music while you're here"
                                    : name.map { "Start \($0)" } ?? unnamed)
                .role(.sheet)
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
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Theme.raised, in: .rect(cornerRadius: Radius.small))
                    .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.border))
                    .contentShape(.rect)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Strip(selection: $kind)
                Text(kind == .whileHere ? "Waits while you're away." : "Starts at its time.")
                    .role(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            when
            Strip(selection: $repeats)
            settings
            if let alarm, !alarm.whileHere, !SystemWake.shared.canAdd, !SystemWake.shared.missing(for: [alarm]).isEmpty {
                Text("Saving asks for your password once.")
                    .role(.small)
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 12) {
                if case .edit(let old) = request {
                    Button("Delete", role: .destructive) {
                        controller.removeAlarm(old.id)
                        dismiss()
                    }
                    .buttonStyle(SecondaryStyle())
                    .help("⌘Z brings it back")
                }
                if let alarm {
                    Button(preview.playing == alarm.id ? "Stop" : "Hear it") { preview.toggle(alarm, controller: controller) }
                        .buttonStyle(SecondaryStyle())
                        .help(alarm.whileHere ? "a few seconds at its volume" : "a few seconds at the volume it rises to")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryStyle())
                Button(editing ? "Save" : "Schedule", action: save)
                .buttonStyle(PrimaryStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(alarm == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.sidebar)
        .presentationBackground(Theme.sidebar)
        .animation(reduceMotion ? nil : Theme.quick, value: kind)
        .onChange(of: kind) { old, new in
            // a new one moves to what suits the other kind, except where you've already changed something
            guard !editing else { return }
            let (was, next) = (Self.defaults(old), Self.defaults(new))
            let at = { (hour: Int) in Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)! }
            if !placed, time == at(was.start) { time = at(next.start) }
            if !placed, until == at(was.end) { until = at(next.end) }
            if repeats == was.repeats { repeats = next.repeats }
            if shuffled == was.shuffled { shuffled = next.shuffled }
            if volume == was.volume { volume = next.volume }
            if heedsCalendar == was.calendar { heedsCalendar = next.calendar }
        }
        .onDisappear { preview.stop() }
    }

    private func save() {
        NSDatePicker.commitTyping()
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

    /// One line: its start and its end. One that starts by itself may play on, so its end has a box, the word Until in its click.
    private var when: some View {
        HStack(spacing: 8) {
            Text(kind == .whileHere ? "From" : "At").role(.body).foregroundStyle(Theme.text)
            timeField($time, label: kind == .whileHere ? "From" : "At")
            Spacer(minLength: 16)
            if kind == .whileHere {
                Text("Until").role(.body).foregroundStyle(Theme.text)
            } else {
                Toggle("Until", isOn: Binding(get: { stops }, set: { on in
                    if on, !stops { until = time + 3600 }
                    stops = on
                }))
                .help(stops ? "play on instead" : "stop at a set time, easing down over the last three minutes")
            }
            timeField($until, label: "Until")
                .opacity(kind == .whileHere || stops ? 1 : 0.35)
                .disabled(kind != .whileHere && !stops)
        }
        .toggleStyle(BoxFirst())
    }

    private func timeField(_ date: Binding<Date>, label: String) -> some View {
        DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
            .labelsHidden()
            .fixedSize()
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
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Toggle("Shuffled", isOn: $shuffled)
                    Toggle("Unless my calendar is busy", isOn: $heedsCalendar)
                }
                GridRow {
                    Toggle("One part at a time", isOn: $rotates)
                    Toggle("Set the volume", isOn: Binding(get: { volume != nil }, set: { volume = $0 ? 0.15 : nil }))
                }
            }
            if heedsCalendar {
                HStack(spacing: 8) {
                    Text(kind == .whileHere ? "Waits during events." : "Doesn't start during events.")
                        .foregroundStyle(Theme.muted)
                    ThemeLink(text: "Calendars…") { openSettings() }
                }
                .role(.small)
            }
            if rotates {
                HStack(spacing: 12) {
                    // a collection with parts of its own uses those
                    if controller.playlists.first(where: { $0.id == source })?.breaks.isEmpty != false {
                        ValueStepper(value: Binding(get: { Double(partCount) }, set: { partCount = Int($0) }), range: 2...12, unit: "parts")
                    }
                    if let partsLine {
                        Text(partsLine)
                            .font(Role.column.font)
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
            if rotates {
                Text(kind == .whileHere ? "This part fills these hours." : "Stops after this part.")
                    .role(.small).foregroundStyle(Theme.muted)
            }
            if let level = volume {
                HStack(spacing: 12) {
                    LineSlider(value: Binding(get: { level }, set: { volume = max($0, 0.02) }))
                    Text(level.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .frame(width: 40, alignment: .trailing)
                }
                // the machine's rise, Machine.riseLength
                .help(kind == .whileHere ? "set as it begins" : "rises to this over 90 seconds")
                .transition(.opacity)
            }
        }
        .toggleStyle(BoxFirst())
        .animation(Theme.quick, value: volume == nil)
        .animation(Theme.quick, value: rotates)
    }
}

/// Once, Weekdays, Every day: the chosen one sits on a fill that slides between them, like the sidebar's.
private struct Strip<Option: CaseIterable & Hashable & RawRepresentable>: View where Option.AllCases: RandomAccessCollection, Option.RawValue == String {
    @Binding var selection: Option
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .frame(height: 22)
                        .background {
                            // the fill alone is barely lighter than the strip in monochrome; the edge says which
                            if chosen {
                                RoundedRectangle(cornerRadius: Radius.small - 1)
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
        .padding(1)
        .background(Theme.raised, in: .rect(cornerRadius: Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.border))
        .animation(reduceMotion ? nil : Theme.settle, value: selection)
    }
}

/// The square box, then its label, both in the click: the two columns would pair a box at the far end with the wrong word.
private struct BoxFirst: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                CheckBox(on: configuration.isOn)
                configuration.label
                    .role(.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
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

/// Wakes the Mac from sleep before each alarm, through pmset, and takes back the ones it added for a day off or a row
/// turned off. Scheduling needs root, so it asks for the password; reading what's scheduled doesn't. The commands run
/// off the main actor, so a password prompt or a slow pmset can't hold up the audio ticks; they run one at a time, in
/// the order they were asked for.
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
        ours = ours.intersection(scheduled)
    }

    /// The wakes this app added and pmset still has: the only ones it ever cancels, as the schedule doesn't say who
    /// asked for each.
    private var ours: Set<Date> {
        get { Set((UserDefaults.standard.array(forKey: "addedWakes") as? [Double] ?? []).map(Date.init(timeIntervalSince1970:))) }
        set { UserDefaults.standard.set(newValue.map(\.timeIntervalSince1970).sorted(), forKey: "addedWakes") }
    }

    /// Wakes added before the app kept track: once, the scheduled ones within two weeks that a row needs.
    private func adoptOnce(_ alarms: [Alarm]) {
        guard !alarms.isEmpty, !UserDefaults.standard.bool(forKey: "addedWakesAdopted") else { return }
        ours.formUnion(WakePlan.wouldNeed(for: alarms, now: .now).intersection(scheduled))
        UserDefaults.standard.set(true, forKey: "addedWakesAdopted")
    }

    /// The rule that adds and cancels is in.
    var trusted: Bool { FileManager.default.fileExists(atPath: WakePlan.rule) }

    /// Some rule is in, so a wake can be added without asking.
    var canAdd: Bool { trusted || addsOnly }

    /// An older rule that only adds.
    private var addsOnly: Bool {
        !trusted && [WakePlan.addOnlyRule, WakePlan.looseRule].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether the Mac still wakes for a day off on this row, as only the newer rule can take a wake back.
    func stillWakes(_ row: Alarm, among alarms: [Alarm], now: Date = .now) -> Bool {
        #if SHOT
        // the real schedule says nothing about the copy's rows
        return !row.daysOff.isEmpty && UserDefaults.standard.bool(forKey: "shotStillWakes")
        #else
        guard !trusted, !row.daysOff.isEmpty else { return false }
        let mine = Set(WakePlan.needed(for: [row.withoutDaysOff], now: now))
        // whoever added it, a wake still listed wakes the Mac
        return !mine.isDisjoint(with: WakePlan.cancels(for: alarms, scheduled: scheduled, ours: scheduled, now: now))
        #endif
    }

    func missing(for alarms: [Alarm], now: Date = .now) -> [Date] {
        WakePlan.needed(for: alarms, now: now).filter { !scheduled.contains($0) }
    }

    /// Whether the very next alarm can't wake the Mac; the days after it are filled in as they come closer.
    func nextMissing(for alarms: [Alarm], now: Date = .now) -> Bool {
        WakePlan.needed(for: alarms, now: now).first.map { !scheduled.contains($0) } ?? false
    }

    /// Fills in the wakes without asking, once a rule is in. Runs at launch, on every wake from sleep, and every six hours.
    func renew(for alarms: [Alarm]) {
        if trusted || addsOnly { schedule(for: alarms, asking: false) }
    }

    /// Schedules every missing wake and cancels the ones a day off or a row turned off no longer needs, asking for the
    /// password first if no rule can add them yet. Only a click on Let it sleep or Wake it (`clicked`) asks for the
    /// rule that cancels. A wake left from a deleted alarm stays: it only wakes the Mac, which goes back to sleep.
    func schedule(for alarms: [Alarm], asking: Bool = true, clicked: Bool = false) {
        inTurn { await self.fill(alarms, asking: asking, clicked: clicked) }
    }

    private func fill(_ alarms: [Alarm], asking: Bool, clicked: Bool) async {
        await read()
        adoptOnce(alarms)
        let dates = missing(for: alarms)
        let cancels = WakePlan.cancels(for: alarms, scheduled: scheduled, ours: ours, now: .now)
        let forDaysOff = !WakePlan.cancels(for: alarms.filter(\.on), scheduled: scheduled, ours: ours, now: .now).isEmpty
        let rules = Set([WakePlan.rule, WakePlan.addOnlyRule, WakePlan.looseRule].filter { FileManager.default.fileExists(atPath: $0) })
        let asks = asking && WakePlan.asks(missing: !dates.isEmpty, forDaysOff: forDaysOff, clicked: clicked, rules: rules)
        guard !dates.isEmpty || !cancels.isEmpty && trusted || asks else { return }
        var said: String?
        if asks {
            let install = await WakePlan.run("/usr/bin/osascript", ["-e", WakePlan.installScript(user: NSUserName())])
            if install?.status != 0 {
                said = WakePlan.installFailure(install?.error ?? "")
                // an older rule still adds the wakes a new or moved row needs
                guard addsOnly else {
                    failure = said
                    return
                }
            }
        }
        var added: [Date] = []
        for date in dates where await WakePlan.run("/usr/bin/sudo", WakePlan.pmsetArguments(for: date))?.status == 0 {
            added.append(date)
        }
        if trusted {
            for date in cancels { _ = await WakePlan.run("/usr/bin/sudo", WakePlan.cancelArguments(for: date)) }
        }
        await read()
        ours.formUnion(scheduled.intersection(added))
        // a cancel that's still listed didn't take, whatever sudo said
        let failed = dates.count - added.count + (trusted ? cancels.filter(scheduled.contains).count : 0)
        failure = failed == 0 ? said : "couldn't change \(failed) of the wakes: the system said no"
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
        if controller.holdForPreview() {
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
        paused?.endPreview()
        paused = nil
    }

    private func halt() {
        ending?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

extension NSDatePicker {
    /// A digit that could still be the first of two shows but isn't the picker's value until it loses focus, and a
    /// click on Save doesn't take focus: without this, typing 3 in the minutes saves the old minutes under a 3.
    @MainActor static func commitTyping() {
        for window in NSApp.windows where window.firstResponder is NSDatePicker { window.makeFirstResponder(nil) }
    }
}
