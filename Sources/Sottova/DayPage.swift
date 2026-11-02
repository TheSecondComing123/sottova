import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SottovaCore

/// Your day: the rows to scale down a rail, with what's not on it beside it, or around it when narrow.
struct DayPage: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var dropHour: Int?
    @State private var played: [Controller.Played] = []
    @State private var allPlayed = false
    @Environment(\.pageLayout) private var page
    private var wake = SystemWake.shared

    private var layout: DayLayout { page.day }

    private func now(_ date: Date) -> Date {
        #if SHOT
        controller.shotNow ?? date
        #else
        date
        #endif
    }

    var body: some View {
        // for the rail's now and rows passing; the words change by observing the rows
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = now(context.date)
            let plan = controller.dayPlan(now: now, wholeDay: droppingHere)
            PageScroll(insets: EdgeInsets(top: layout.insets.top, leading: layout.margin, bottom: layout.insets.bottom, trailing: layout.margin), maxWidth: .infinity) {
                if oneColumn(plan) {
                    newButton.frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 14)
                    day(plan)
                    others(plan, now: now)
                    playedList(plan)
                } else {
                    HStack(alignment: .top, spacing: DayLayout.gap) {
                        // the first block level with New
                        VStack(alignment: .leading, spacing: 0) { day(plan) }.padding(.top, 8)
                        VStack(alignment: .leading, spacing: 0) {
                            newButton.frame(maxWidth: .infinity, alignment: .trailing)
                            others(plan, now: now)
                            playedList(plan)
                        }
                        .frame(width: layout.right)
                    }
                }
            }
            .task(id: "\(controller.current?.id ?? "")\(controller.status)\(Calendar.current.component(.day, from: now))") {
                played = controller.playedToday(now: now)
            }
        }
        .onAppear { wake.refresh() }
    }

    private func rest(_ plan: DayPlan) -> [Alarm] {
        let today = Set(plan.rows.map(\.id))
        return controller.alarms.filter { !today.contains($0.id) }.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    private func oneColumn(_ plan: DayPlan) -> Bool {
        layout.oneColumn(others: rest(plan).count, played: played.count)
    }

    private func hourHeight(_ plan: DayPlan) -> Double {
        layout.hourHeight(span: plan.span, others: rest(plan).count, played: played.count)
    }

    private var newButton: some View {
        ThemeButton(title: "New…", icon: .plus, iconWeight: .line) { router.alarm = .new(nil) }
    }

    @ViewBuilder
    private func day(_ plan: DayPlan) -> some View {
        if let failure = wake.failure {
            Text(failure).role(.small).foregroundStyle(Theme.text).padding(.bottom, 16)
        }
        rail(plan)
    }

    /// Over the rail with a collection, every hour is a place to land.
    private var droppingHere: Bool {
        #if SHOT
        if router.shotDrop != nil { return true }
        #endif
        return dropHour != nil
    }

    /// The row the Mac can't wake for: only the very next one, as the days after are filled in as they come closer.
    private func cantWake(now: Date) -> Alarm.ID? {
        #if SHOT
        // the real schedule says nothing about the copy's rows
        guard UserDefaults.standard.bool(forKey: "shotCantWake") else { return nil }
        #else
        guard wake.nextMissing(for: controller.alarms, now: now) else { return nil }
        #endif
        return controller.alarms.filter { $0.on && !$0.whileHere }
            .compactMap { alarm in alarm.next(after: now).map { (alarm.id, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    private func rail(_ plan: DayPlan) -> some View {
        let scale = hourHeight(plan)
        let waiting = controller.status == .paused ? nil : controller.hold
        let sounding = controller.soundingRow?.id
        let unwoken = cantWake(now: nowDate)
        let pieces = Dictionary(plan.rows.map { row in
            let rising = sounding == row.id && controller.rising && controller.status != .paused
            return (row.id, plan.line(for: row, nextPart: nextPart(row.alarm), rising: rising, waiting: sounding == row.id ? waiting : nil, cantWake: unwoken == row.id))
        }, uniquingKeysWith: { first, _ in first })
        // room beside a painting at its usual size, and more than enough beside a larger one in a tall block
        let blockWidth = layout.blockWidth(oneColumn: oneColumn(plan))
        let room = blockWidth - 12 - 23 - 72 - 12 - 28
        let rail = plan.rail(hourHeight: scale, lines: pieces.mapValues { WordFlow.lines($0.map(\.text), width: room) })
        var drop = dropHour.map { ($0, controller.alarmName(of: router.draggingCollection ?? "")) }
        #if SHOT
        if let shot = router.shotDrop { drop = (shot.hour, shot.name) }
        #endif
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.hairline).frame(width: 1, height: rail.height).offset(x: 72)
            ForEach(rail.breaks, id: \.y) { gap in
                BreakMark(text: gap.text).offset(y: gap.y - 10)
            }
            ForEach(rail.marks) { mark in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.faint)
                    .frame(width: 3, height: mark.bar.upperBound - mark.bar.lowerBound)
                    .opacity(mark.alarm.on ? 1 : 0.35)
                    .offset(x: mark.aside ? 76 : 71, y: mark.bar.lowerBound)
            }
            if let y = rail.now {
                Circle().fill(Theme.primary).frame(width: 6, height: 6).offset(x: 69.5, y: y - 3)
            }
            // by what it's for, not its place: a popover open on a time must stay with that row as the now label comes and goes
            ForEach(rail.labels, id: \.key) { label in
                RailTime(label: label, alarm: controller.alarms.first { $0.id == label.row })
                    // an 18 pt line sits its small type higher than the mock's
                    .offset(y: label.y - 9 + (label.kind == .row || label.kind == .now ? 1 : 2))
            }
            if rail.marks.isEmpty {
                Group {
                    if controller.catalog.albums.isEmpty {
                        HStack(spacing: 4) {
                            Text("Nothing on your day.")
                            ThemeLink(text: "Add some music", underlined: true) { router.go(to: .home) }
                        }
                    } else {
                        Text("Drag a collection onto an hour")
                    }
                }
                .role(.body)
                .foregroundStyle(Theme.muted)
                .offset(x: DayLayout.blockLeft, y: rail.height / 2 - 9)
            }
            ForEach(rail.marks) { mark in
                let height = mark.block.upperBound - mark.block.lowerBound
                DayRow(alarm: mark.alarm, pieces: pieces[mark.id] ?? [], artwork: controller.alarmArtwork(of: mark.alarm.source),
                       painting: layout.painting(block: height, blockWidth: blockWidth), sounding: sounding == mark.id)
                    .frame(height: height)
                    .padding(.leading, DayLayout.blockLeft)
                    .offset(y: mark.block.lowerBound)
            }
            if let (hour, name) = drop {
                dropRow(plan: plan, hour: hour, name: name, scale: scale)
            }
        }
        // a day of one short row is still somewhere to drop
        .frame(maxWidth: .infinity, minHeight: max(rail.height, 96), alignment: .topLeading)
        .contentShape(.rect)
        .onDrop(of: [.plainText], delegate: HourDrop(now: nowDate, hour: $dropHour, router: router, controller: controller, scale: hourHeight))
    }

    private var nowDate: Date { now(.now) }

    private func dropRow(plan: DayPlan, hour: Int, name: String, scale: Double) -> some View {
        let label = plan.dropLabel(hour: hour)
        let top = plan.y(hour: hour, hourHeight: scale)
        return ZStack(alignment: .topLeading) {
            Text(label.start)
                .role(.body)
                .fontWeight(.medium)
                .foregroundStyle(Theme.primary)
                .frame(width: 60, alignment: .trailing)
                .offset(y: -8)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).role(.row).foregroundStyle(Theme.text)
                Text(label.span).role(.body).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 2 * scale, alignment: .topLeading)
            .background(Theme.primary.opacity(0.1), in: .rect(cornerRadius: Radius.small))
            .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.primary, lineWidth: 1) }
            .padding(.leading, DayLayout.blockLeft)
        }
        .offset(y: top)
        .allowsHitTesting(false)
    }

    private func nextPart(_ alarm: Alarm) -> String? {
        alarm.rotates ? controller.nextPartName(for: alarm) : nil
    }

    /// Rows not on today: they have no place on the rail, and would otherwise be out of reach for a day.
    @ViewBuilder
    private func others(_ plan: DayPlan, now: Date) -> some View {
        let rest = rest(plan)
        if !rest.isEmpty {
            heading("Other days").padding(.top, 24).padding(.bottom, 6)
            ForEach(rest) { alarm in
                OtherLine(alarm: alarm, pieces: plan.wakeLine(alarm: alarm, nextPart: nextPart(alarm), cantWake: cantWake(now: now) == alarm.id))
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).role(.body).fontWeight(.semibold).foregroundStyle(Theme.text)
    }

    /// Newest first. What doesn't fit is behind All, with the row each piece played for.
    @ViewBuilder
    private func playedList(_ plan: DayPlan) -> some View {
        if !played.isEmpty {
            let cap = layout.playedCap
            HStack(spacing: 6) {
                heading("What played")
                Text("\(played.count)").role(.body).monospacedDigit().foregroundStyle(Theme.muted)
                Spacer(minLength: 16)
                if played.count > cap {
                    ThemeLink(text: "All \(played.count)", underlined: true) { allPlayed = true }
                        .role(.body)
                        .popover(isPresented: $allPlayed, arrowEdge: .trailing) { allPlayedList(plan) }
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 6)
            ForEach(played.reversed().prefix(cap), id: \.at) { line in
                HStack(spacing: 8) {
                    Text(plan.clockText(line.at)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1).frame(width: 38, alignment: .trailing)
                    Artwork(key: line.artwork, size: 20, radius: 3)
                    Text(line.title).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(line.title)
                }
                .role(.body)
                .frame(height: 24)
            }
        }
    }

    private func allPlayedList(_ plan: DayPlan) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(played.reversed(), id: \.at) { line in
                    let words = [line.title, line.row].compactMap { $0 }.joined(separator: ", ")
                    HStack(spacing: 8) {
                        Text(plan.clockText(line.at)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1).frame(width: 38, alignment: .trailing)
                        Text(words).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(words)
                    }
                    .role(.body)
                    .frame(height: 24)
                }
            }
            .padding(12)
        }
        .frame(width: 380)
        .frame(maxHeight: 420)
    }
}

/// A long gap drawn short: the line broken, and how long it really is.
private struct BreakMark: View {
    let text: String

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.background).frame(width: 9, height: 12).offset(x: 68)
            Canvas { context, size in
                var slashes = Path()
                for x in [69.0, 73.0] {
                    slashes.move(to: CGPoint(x: x - 3, y: 13))
                    slashes.addLine(to: CGPoint(x: x + 3, y: 7))
                }
                context.stroke(slashes, with: .color(Theme.faint), lineWidth: 1)
            }
            .frame(width: 80, height: 20)
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .offset(x: DayLayout.blockLeft)
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("\(text) with nothing on")
    }
}

/// A time down the rail. A row's start, and an end it was given, are clickable: a native typed field in a popover,
/// applied when it closes so a half-typed time can't fire anything.
private extension DayPlan.Rail.Label {
    var key: String { row.map { "\($0) \(kind)" } ?? "\(kind) \(text) \(y)" }
}

private struct RailTime: View {
    let label: DayPlan.Rail.Label
    let alarm: Alarm?
    @Environment(Controller.self) private var controller
    @State private var open = false

    var body: some View {
        Group {
            if let alarm {
                Button { open = true } label: { text }
                    .buttonStyle(.plain)
                    .help(label.kind == .end ? "when it stops" : "when it starts")
                    .popover(isPresented: $open, arrowEdge: .trailing) { TimeField(alarm: alarm, end: label.kind == .end) }
            } else {
                text
            }
        }
        .frame(width: 60, alignment: .trailing)
        .accessibilityLabel(label.text)
    }

    private var text: some View {
        Text(label.text)
            .underline(alarm != nil, color: Theme.faint)
            .font(.system(size: strong ? 13 : 11, weight: strong ? .medium : .regular))
            .lineHeight(.exact(points: 18))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(label.kind == .now ? Theme.primary : label.kind == .row ? Theme.text : Theme.faint)
    }

    private var strong: Bool { label.kind == .row || label.kind == .now }
}

private struct TimeField: View {
    let alarm: Alarm
    let end: Bool
    @Environment(Controller.self) private var controller
    @State private var time: Date
    private let opened: Date

    init(alarm: Alarm, end: Bool) {
        (self.alarm, self.end) = (alarm, end)
        let start = Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now
        opened = end ? start + Double(alarm.minutes ?? 60) * 60 : start
        _time = State(initialValue: opened)
    }

    var body: some View {
        DatePicker(end ? "Until" : "At", selection: $time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
            .padding(12)
            .onDisappear(perform: apply)
    }

    private func apply() {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        let (hour, minute) = (clock.hour ?? alarm.hour, clock.minute ?? alarm.minute)
        guard time != opened else { return }
        controller.changeAlarm(alarm.id) { row in
            if end {
                let span = (hour * 60 + minute - row.hour * 60 - row.minute + 1440) % 1440
                row.minutes = span == 0 ? 1440 : span
            } else {
                (row.hour, row.minute) = (hour, minute)
            }
        }
        SystemWake.shared.renew(for: controller.alarms)
    }
}

/// A row's block: its tick, painting, name and words, with the rest of what it does behind the dots.
private struct DayRow: View {
    let alarm: Alarm
    let pieces: [DayPlan.Piece]
    let artwork: String?
    let painting: (width: Double, height: Double, under: Bool)
    let sounding: Bool
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RowTick(alarm: alarm).padding(.top, 4).frame(width: 23, alignment: .topLeading)
            let stack = painting.under ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            stack {
            Artwork(key: artwork, size: painting.height, width: painting.width, radius: 3, outlined: true)
                .opacity(alarm.on ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button { navigate(alarm.route(in: controller)) } label: {
                        Text(alarm.name).role(.row).foregroundStyle(alarm.on ? Theme.text : Theme.faint).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("open \(alarm.name)")
                    // so what's sounding doesn't rest on color alone
                    if sounding { Ph.speakerHigh.icon(size: 13).foregroundStyle(Theme.primary).accessibilityLabel("sounding") }
                }
                WordFlow {
                    ForEach(pieces, id: \.text) { RowWord(alarm: alarm, piece: $0) }
                }
                .foregroundStyle(alarm.on ? Theme.muted : Theme.faint)
            }
            }
            Spacer(minLength: 8)
            Menu { RowEntries(entries: entries) } label: {
                Ph.dotsThree.icon(size: 14)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .hoverable(radius: 4)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("more")
            .accessibilityLabel("more for \(alarm.name)")
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(sounding ? Theme.primary.opacity(0.1) : Theme.selection.opacity(alarm.on ? 1 : 0.4))
        }
        // on the whole block, so the painting counts; its words and tick keep their own clicks
        .contentShape(.rect)
        .onTapGesture(count: 2) { router.alarm = .edit(alarm) }
        .sottovaMenu { entries }
    }

    private var entries: [MenuEntry] { RowActions(alarm: alarm, controller: controller, router: router).entries }
}

/// A day that isn't today, on one line: the words it has room for, all of them behind the menu.
private struct OtherLine: View {
    let alarm: Alarm
    let pieces: [DayPlan.Piece]
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate

    private var warning: Bool { pieces.contains { $0.word == .wake } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RailTime(label: DayPlan.Rail.Label(text: DayPlan.startText(alarm), y: 0, kind: alarm.on ? .row : .off, row: alarm.id), alarm: alarm)
                RowTick(alarm: alarm)
                Button { navigate(alarm.route(in: controller)) } label: {
                    Text(alarm.name).role(.body).fontWeight(.medium).foregroundStyle(alarm.on ? Theme.text : Theme.faint).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("open \(alarm.name)")
                .layoutPriority(1)
                if !warning {
                    ViewThatFits(in: .horizontal) {
                        words(pieces)
                        words(Array(pieces.prefix(1)))
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            // a warning stays whole, under the line
            if warning {
                WordFlow { ForEach(pieces, id: \.text) { RowWord(alarm: alarm, piece: $0) } }
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 90)
            }
        }
        .contentShape(.rect)
        .sottovaMenu { RowActions(alarm: alarm, controller: controller, router: router).entries }
    }

    private func words(_ pieces: [DayPlan.Piece]) -> some View {
        HStack(spacing: 10) { ForEach(pieces, id: \.text) { RowWord(alarm: alarm, piece: $0) } }
            .fixedSize()
            .foregroundStyle(alarm.on ? Theme.muted : Theme.faint)
    }
}

private extension Alarm {
    @MainActor func route(in controller: Controller) -> Route {
        controller.playlists.contains { $0.id == source } ? .playlist(source) : .album(source)
    }
}

private struct RowTick: View {
    let alarm: Alarm
    @Environment(Controller.self) private var controller

    var body: some View {
        Toggle(alarm.on ? "Turn \(alarm.name) off" : "Turn \(alarm.name) on", isOn: Binding(get: { alarm.on }, set: { _ in
            let on = !alarm.on
            controller.changeAlarm(alarm.id) { $0.on = on }
            SystemWake.shared.renew(for: controller.alarms)
        }))
        .toggleStyle(Tick())
        .frame(width: 14, height: 14)
    }
}

/// One word of a row's line: most open a native menu that fits what they say.
private struct RowWord: View {
    let alarm: Alarm
    let piece: DayPlan.Piece
    @Environment(Controller.self) private var controller

    var body: some View {
        switch piece.word {
        case nil:
            Text(piece.text).role(.body)
        case .playNow:
            ThemeLink(text: piece.text, underlined: true) { controller.playNow(alarm) }.role(.body)
        case .wake:
            ThemeLink(text: piece.text, underlined: true) { SystemWake.shared.schedule(for: controller.alarms) }.role(.body)
        case .days?:
            WordMenu(text: piece.text, on: alarm.on) { DayWords(alarm: alarm, change: change) }
        case .kind?:
            WordMenu(text: piece.text, on: alarm.on) { KindWords(alarm: alarm, change: change) }
        case .order?:
            WordMenu(text: piece.text, on: alarm.on) { OrderWords(alarm: alarm, change: change) }
        case .volume?:
            WordMenu(text: piece.text, on: alarm.on) { VolumeWords(alarm: alarm, change: change) }
        case .calendar?:
            WordMenu(text: piece.text, on: alarm.on) {
                Toggle("Unless my calendar is busy", isOn: calendarBinding(true))
                Toggle("Whatever my calendar says", isOn: calendarBinding(false))
            }
        case .part?:
            WordMenu(text: piece.text, on: alarm.on) {
                let parts = controller.partChoices(for: alarm)
                ForEach(Array(parts.names.enumerated()), id: \.offset) { index, name in
                    Toggle(name.prefix(1).uppercased() + name.dropFirst(), isOn: Binding(get: { parts.next == index }, set: { _ in change { $0.nextPart = index } }))
                }
                Divider()
                OrderWords(alarm: alarm, change: change)
            }
        }
    }

    private func calendarBinding(_ heeds: Bool) -> Binding<Bool> {
        Binding(get: { alarm.heedsCalendar == heeds }, set: { _ in
            change { $0.heedsCalendar = heeds }
            if heeds { Task { await Presence.askForCalendars() } }
        })
    }

    /// No password from here: a Mac that can't wake says so on the row, with the link that asks.
    private func change(_ edit: (inout Alarm) -> Void) {
        controller.changeAlarm(alarm.id, edit)
        SystemWake.shared.renew(for: controller.alarms)
    }
}

/// What a row does, for its right click and its dots: an off attribute with no word of its own stays in reach here.
@MainActor
private struct RowActions {
    let alarm: Alarm
    let controller: Controller
    let router: Router
    private var preview: AlarmPreview { .shared }

    var entries: [MenuEntry] {
        [.item("Edit…") { router.alarm = .edit(alarm) }]
            + (alarm.whileHere ? [] : [.item(preview.playing == alarm.id ? "Stop" : "Hear it") { preview.toggle(alarm, controller: controller) }])
            + [
                .item(alarm.on ? "Turn off" : "Turn on") { change { $0.on = !alarm.on } },
                .divider,
                .item("Starts by itself", checked: !alarm.whileHere) { change { $0.whileHere = false } },
                .item("While you're at the Mac", checked: alarm.whileHere) { change(Self.whileHere) },
                .item("Unless my calendar is busy", checked: alarm.heedsCalendar) {
                    let on = !alarm.heedsCalendar
                    change { $0.heedsCalendar = on }
                    if on { Task { await Presence.askForCalendars() } }
                },
                .divider,
                .item("Delete") { controller.removeAlarm(alarm.id) },
            ]
    }

    /// A stretch of the day has to end.
    static func whileHere(_ row: inout Alarm) {
        row.whileHere = true
        row.minutes = row.minutes ?? 60
    }

    private func change(_ edit: (inout Alarm) -> Void) {
        controller.changeAlarm(alarm.id, edit)
        SystemWake.shared.renew(for: controller.alarms)
    }
}

/// The same entries as a SwiftUI menu, which opens on the press.
private struct RowEntries: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            switch entry.kind {
            case .divider:
                Divider()
            case .action(let action):
                if entry.checked {
                    Toggle(entry.title, isOn: Binding(get: { true }, set: { _ in action() }))
                } else {
                    Button(entry.title, action: action)
                }
            case .submenu:
                EmptyView()
            }
        }
    }
}

/// A check with no box while it's on; turned off, an empty box.
private struct Tick: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack {
                if configuration.isOn {
                    TickMark().stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 12, height: 12)
                } else {
                    RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.frame, lineWidth: 1)
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// From the mock, whose 12 pt check is lighter than any icon's.
private struct TickMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 2.5, y: 6.4))
            path.addLine(to: CGPoint(x: 5, y: 8.8))
            path.addLine(to: CGPoint(x: 9.6, y: 3.2))
        }
    }
}

/// One clickable word of a row's line, opening a native menu.
private struct WordMenu<Content: View>: View {
    let text: String
    let on: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            Text(text)
                .underline(color: Theme.faint)
                .role(.body)
                // a Menu's label doesn't inherit the row's foreground
                .foregroundStyle(hovering ? Theme.text : on ? Theme.muted : Theme.faint)
                .background { RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.selection : .clear).padding(EdgeInsets(top: -1, leading: -4, bottom: -1, trailing: -4)) }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

private struct OrderWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void

    var body: some View {
        Toggle("In order", isOn: Binding(get: { !alarm.shuffled }, set: { _ in change { $0.shuffled = false } }))
        Toggle("Shuffled", isOn: Binding(get: { alarm.shuffled }, set: { _ in change { $0.shuffled = true } }))
        Divider()
        Toggle("One part at a time", isOn: Binding(get: { alarm.rotates }, set: { on in change { $0.rotates = on } }))
    }
}

private struct DayWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void
    private let choices: [(String, Set<Int>)] = [("Once", []), ("Weekdays", [2, 3, 4, 5, 6]), ("Weekends", [1, 7]), ("Every day", Set(1...7))]

    var body: some View {
        ForEach(choices, id: \.0) { name, days in
            Toggle(name, isOn: Binding(get: { alarm.weekdays == days }, set: { _ in change { $0.weekdays = days } }))
        }
    }
}

private struct KindWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void

    var body: some View {
        Toggle("Starts by itself", isOn: Binding(get: { !alarm.whileHere }, set: { _ in change { $0.whileHere = false } }))
        Toggle("While you're at the Mac", isOn: Binding(get: { alarm.whileHere }, set: { _ in change(RowActions.whileHere) }))
    }
}

private struct VolumeWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void
    private let levels = [0.1, 0.15, 0.25, 0.5, 0.75, 1]

    var body: some View {
        Toggle("The speaker's volume", isOn: Binding(get: { alarm.volume == nil }, set: { _ in change { $0.volume = nil } }))
        Divider()
        ForEach(levels.contains(alarm.volume ?? 0.1) ? levels : (levels + [alarm.volume ?? 0.1]).sorted(), id: \.self) { level in
            Toggle("\(Int((level * 100).rounded()))%", isOn: Binding(get: { alarm.volume == level }, set: { _ in change { $0.volume = level } }))
        }
    }
}

/// Words left to right, spaced, wrapping between them; one too long for a line wraps inside itself.
private struct WordFlow: Layout {
    private static let spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let placed = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: placed.map { $0.x + $0.size.width }.max() ?? 0, height: placed.map { $0.y + $0.size.height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, spot) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y), proposal: ProposedViewSize(spot.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [(x: CGFloat, y: CGFloat, size: CGSize)] {
        var (x, y, tallest): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { (x, y, tallest) = (0, y + tallest, 0) }
            defer {
                x += size.width + Self.spacing
                tallest = max(tallest, size.height)
            }
            return (x, y, size)
        }
    }

    /// How many lines these words take at `width`, for a row to leave them room before it's laid out.
    static func lines(_ words: [String], width: Double) -> Int {
        let font = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: Role.body.size)]
        var (x, lines) = (0.0, 1)
        for word in words {
            let size = Double(ceil((word as NSString).size(withAttributes: font).width))
            if x > 0, x + size > width { (x, lines) = (0, lines + 1) }
            lines += max(0, Int(size / width))
            x += size.truncatingRemainder(dividingBy: width) + Double(spacing)
        }
        return lines
    }
}

/// A collection dropped on the rail takes the hour under the pointer, two hours of it, while you're at the Mac, so it
/// can't wake anyone until you say so in its words.
private struct HourDrop: DropDelegate {
    let now: Date
    @Binding var hour: Int?
    let router: Router
    let controller: Controller
    let scale: (DayPlan) -> Double

    func validateDrop(info: DropInfo) -> Bool {
        router.draggingCollection != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // the whole day's scale from the first sample, as that's what the rail opens to under the pointer
        let day = controller.dayPlan(now: now, wholeDay: true)
        hour = day.hour(at: Double(info.location.y), hourHeight: scale(day))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { hour = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            hour = nil
            router.draggingCollection = nil
        }
        guard let source = router.draggingCollection, let hour else { return false }
        var row = Alarm(source: source, name: controller.alarmName(of: source), hour: hour, minute: 0, weekdays: Set(1...7), shuffled: true)
        (row.whileHere, row.minutes) = (true, 120)
        controller.addAlarm(row)
        return true
    }
}
