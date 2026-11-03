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
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your day").role(.title).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        newButton
                    }
                    .padding(.bottom, 14)
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

    /// A day off the Mac still wakes for, until the rule that cancels is in.
    private func stillWakes(_ row: Alarm) -> [DayPlan.Piece] {
        wake.stillWakes(row, among: controller.alarms, now: nowDate) ? DayPlan.stillWakes : []
    }

    private func rail(_ plan: DayPlan) -> some View {
        let scale = hourHeight(plan)
        let waiting = controller.status == .paused ? nil : controller.hold
        let sounding = controller.soundingRow?.id
        let unwoken = cantWake(now: nowDate)
        let pieces = Dictionary(plan.rows.map { row in
            let rising = sounding == row.id && controller.rising && controller.status != .paused
            let line = plan.line(for: row, nextPart: nextPart(row.alarm), rising: rising, waiting: sounding == row.id ? waiting : nil, cantWake: unwoken == row.id)
            return (row.id, line + stillWakes(row.alarm))
        }, uniquingKeysWith: { first, _ in first })
        // room beside a painting at its usual size, and more than enough under one
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
                    .opacity(mark.off ? 0.35 : 1)
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
                DayRow(alarm: mark.alarm, off: mark.off, pieces: pieces[mark.id] ?? [], artwork: controller.alarmArtwork(of: mark.alarm.source),
                       painting: layout.painting(block: height, blockWidth: blockWidth, lines: WordFlow.lines((pieces[mark.id] ?? []).map(\.text), width: blockWidth - 67)), sounding: sounding == mark.id)
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
                OtherLine(alarm: alarm, pieces: plan.wakeLine(alarm: alarm, nextPart: nextPart(alarm), cantWake: cantWake(now: now) == alarm.id) + stillWakes(alarm))
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
            .padding(.leading, oneColumn(plan) ? DayLayout.blockLeft : 0)
            ForEach(played.reversed().prefix(cap), id: \.at) { line in
                HStack(spacing: 8) {
                    // one column: the time in the rail's gutter, the art at the blocks' edge
                    Text(plan.clockText(line.at)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1).frame(width: oneColumn(plan) ? DayLayout.blockLeft - 30 : 38, alignment: .trailing)
                        .padding(.trailing, oneColumn(plan) ? 22 : 0)
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
/// applied when it closes so a half-typed time can't fire anything. Return and a click away apply, Esc doesn't.
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
                Button { open = true } label: { text.padding(.horizontal, 3).hoverable(radius: 3).padding(.horizontal, -3) }
                    .buttonStyle(.plain)
                    .help(label.kind == .end ? "when it stops" : "when it starts")
                    .popover(isPresented: $open, arrowEdge: .trailing) { TimeField(alarm: alarm, end: label.kind == .end, open: $open) }
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
    @Binding var open: Bool
    @Environment(Controller.self) private var controller
    @State private var time: Date
    @State private var keys: Any?
    @State private var cancelled = false
    @FocusState private var typing: Bool
    private let opened: Date

    init(alarm: Alarm, end: Bool, open: Binding<Bool>) {
        (self.alarm, self.end, _open) = (alarm, end, open)
        let start = Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now
        opened = end ? start + Double(alarm.minutes ?? 60) * 60 : start
        _time = State(initialValue: opened)
    }

    var body: some View {
        DatePicker(end ? "Until" : "At", selection: $time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
            .focused($typing)
            .defaultFocus($typing, true)
            .padding(12)
            .onAppear {
                keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    switch event.keyCode {
                    case 36, 76: open = false
                    case 53: (cancelled, open) = (true, false)
                    default: return event
                    }
                    return nil
                }
            }
            .onDisappear {
                keys.map(NSEvent.removeMonitor)
                if !cancelled { apply() }
            }
    }

    private func apply() {
        NSDatePicker.commitTyping()
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

extension Controller {
    /// Now, or the picture's now in a shot.
    var wallNow: Date {
        #if SHOT
        shotNow ?? .now
        #else
        .now
        #endif
    }
}

extension View {
    /// Days off… on this row: a popover from its words, below them or above, whichever the window has room for.
    func daysOffPopover(_ alarm: Alarm) -> some View {
        modifier(DaysOffPopover(alarm: alarm))
    }
}

private struct DaysOffPopover: ViewModifier {
    let alarm: Alarm
    @Environment(Router.self) private var router
    @Environment(\.colorScheme) private var scheme
    @State private var frame: CGRect = .zero
    /// The row's "Off…" word, in this view's space.
    @State private var word: CGRect?

    func body(content: Content) -> some View {
        let window = NSApp.windows.first { $0.isVisible && $0.isMainWindow }?.contentView?.bounds.height ?? .infinity
        let at = router.daysOffFromWord ? word : nil
        let bottom = frame.minY + (at?.maxY ?? frame.height)
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .backgroundPreferenceValue(OffWord.self) { anchor in
                GeometryReader { proxy in
                    let rect = anchor.map { proxy[$0] }
                    Color.clear.onChange(of: rect, initial: true) { word = rect }
                }
            }
            .popover(isPresented: Binding(get: { router.daysOff == alarm.id }, set: { if !$0, router.daysOff == alarm.id { router.daysOff = nil } }),
                     attachmentAnchor: at.map { .rect(.rect($0)) } ?? .rect(.bounds),
                     arrowEdge: window - bottom > DaysOffField.height + 24 ? .bottom : .top) {
                // glass lets a painting under it wash out the faint days; dark's popover color is a row card's, so
                // it takes the page's there
                DaysOffField(id: alarm.id).presentationBackground(scheme == .dark ? Theme.background : Theme.popover)
            }
    }
}

/// A month to point at days off in. A click takes a day off or puts it back, ⇧-click does the run from the last day
/// clicked, a drag paints a run. Each change applies on release and undoes as one.
private struct DaysOffField: View {
    let id: Alarm.ID
    @Environment(Controller.self) private var controller
    @State private var shown: Date?
    /// While the pointer is down: the days off it would leave.
    @State private var draft: Set<String>?
    @State private var stroke: (from: Date, off: Bool)?
    /// The last day clicked and which way it went, for ⇧-click.
    @State private var last: (date: Date, off: Bool)?
    @State private var hovered: Date?

    private static let cell = CGSize(width: 30, height: 26)
    static let height: CGFloat = 12 + 22 + 8 + 16 + 4 + cell.height * 6 + 10 + 18 + 12

    private var plan: DayPlan { DayPlan(alarms: [], now: controller.wallNow) }
    private var alarm: Alarm? { controller.alarms.first { $0.id == id } }
    private var drawn: Alarm? {
        alarm.map { alarm in
            var drawn = alarm
            drawn.daysOff = draft ?? alarm.daysOff
            return drawn
        }
    }

    var body: some View {
        if let drawn {
            let month = plan.month(drawn, containing: shown ?? opening(drawn))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    Text(month.title).role(.body).fontWeight(.medium).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    turn(month, by: -1)
                    turn(month, by: 1)
                }
                .frame(height: 22)
                .padding(.leading, 7)
                HStack(spacing: 0) {
                    ForEach(Array(plan.weekdayLetters.enumerated()), id: \.offset) { _, letter in
                        Text(letter).role(.small).foregroundStyle(Theme.faint).frame(width: Self.cell.width)
                    }
                }
                .frame(height: 16)
                .padding(.top, 8)
                .accessibilityHidden(true)
                grid(month).padding(.top, 4)
                ViewThatFits(in: .horizontal) {
                    ForEach([Int.max, 2, 1], id: \.self) { runs in
                        Text(plan.offLine(drawn, runs: runs)).lineLimit(1)
                    }
                }
                    .role(.body)
                    .foregroundStyle(Theme.muted)
                    .help(plan.offLine(drawn))
                    .padding(.leading, 7)
                    .padding(.top, 10)
            }
            .padding(12)
            .frame(width: Self.cell.width * 7 + 24, alignment: .top)
        }
    }

    /// The month of the next day it plays, which is the one "Off tomorrow" names.
    private func opening(_ alarm: Alarm) -> Date {
        let calendar = Calendar.current
        let next = alarm.withoutDaysOff.next(after: controller.wallNow) ?? controller.wallNow
        return calendar.isDate(next, equalTo: controller.wallNow, toGranularity: .month) ? controller.wallNow : next
    }

    private func turn(_ month: DayPlan.Month, by step: Int) -> some View {
        let calendar = Calendar.current
        let earliest = !calendar.isDate(month.first, equalTo: controller.wallNow, toGranularity: .month) || step > 0
        return Button { shown = calendar.date(byAdding: .month, value: step, to: month.first) } label: {
            (step < 0 ? Ph.caretLeft : Ph.caretRight).icon(.bold, size: 11)
                .foregroundStyle(Theme.muted)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
                .hoverable(radius: 4)
        }
        .buttonStyle(.plain)
        .disabled(!earliest)
        .opacity(earliest ? 1 : 0.35)
        .help(step < 0 ? "previous month" : "next month")
        .accessibilityLabel(step < 0 ? "previous month" : "next month")
    }

    private func grid(_ month: DayPlan.Month) -> some View {
        let places: [DayPlan.Month.Day?] = Array(repeating: nil, count: month.lead) + month.days
        return VStack(spacing: 0) {
            ForEach(0..<(places.count + 6) / 7, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = week * 7 + column
                        if index < places.count, let day = places[index] {
                            cell(day)
                        } else {
                            Color.clear.frame(width: Self.cell.width, height: Self.cell.height)
                        }
                    }
                }
            }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active(let point) = phase { hovered = day(at: point, in: places)?.date } else { hovered = nil }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in press(day(at: drag.location, in: places)) }
            .onEnded { _ in release() })
    }

    private func cell(_ day: DayPlan.Month.Day) -> some View {
        let off = day.off && !day.past
        let plate = RoundedRectangle(cornerRadius: 4).inset(by: 1)
        return Text("\(day.number)")
            .role(.body)
            .monospacedDigit()
            .foregroundStyle(off ? Theme.primary : day.open ? Theme.text : Theme.faint)
            // so a day gone doesn't pass for one to click
            .opacity(day.past ? 0.6 : 1)
            .frame(width: Self.cell.width, height: Self.cell.height)
            .background {
                if off {
                    plate.fill(Theme.primary.opacity(day.open && hovered == day.date ? 0.28 : 0.16))
                } else if day.open, hovered == day.date {
                    plate.fill(Theme.selection)
                }
            }
            .overlay { if day.today { plate.strokeBorder(off ? Theme.primary : Theme.muted, lineWidth: 1) } }
            .accessibilityElement()
            .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()) + (day.past ? ", past" : day.plays ? "" : ", doesn't play"))
            .accessibilityAddTraits(day.open ? .isButton : [])
            .accessibilityAddTraits(off ? .isSelected : [])
            .accessibilityAction {
                guard day.open, let alarm else { return }
                apply(plan.marking(alarm, from: day.date, to: day.date, off: !day.off))
                last = (day.date, !day.off)
            }
    }

    private func day(at point: CGPoint, in places: [DayPlan.Month.Day?]) -> DayPlan.Month.Day? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let (column, week) = (Int(point.x / Self.cell.width), Int(point.y / Self.cell.height))
        guard column < 7, week < 6, week * 7 + column < places.count else { return nil }
        return places[week * 7 + column]
    }

    private func press(_ day: DayPlan.Month.Day?) {
        guard let alarm, let day else { return }
        if stroke == nil {
            guard day.open else { return }
            if NSEvent.modifierFlags.contains(.shift), let last {
                stroke = (last.date, last.off)
            } else {
                stroke = (day.date, !day.off)
            }
        }
        guard let stroke else { return }
        draft = plan.marking(alarm, from: stroke.from, to: day.date, off: stroke.off)
        if day.open { last = (day.date, stroke.off) }
    }

    private func release() {
        if let draft { apply(draft) }
        (draft, stroke) = (nil, nil)
    }

    private func apply(_ daysOff: Set<String>) {
        guard let alarm, daysOff != alarm.daysOff else { return }
        controller.changeAlarm(id, action: "Days Off") { $0.daysOff = daysOff }
        SystemWake.shared.renew(for: controller.alarms)
    }
}

/// A row's block: its tick, painting, name and words, with the rest of what it does behind the dots.
private struct DayRow: View {
    let alarm: Alarm
    /// Turned off or off today.
    let off: Bool
    let pieces: [DayPlan.Piece]
    let artwork: String?
    let painting: (width: Double, height: Double, under: Bool)
    let sounding: Bool
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate

    var body: some View {
        Group {
            if painting.under {
                VStack(alignment: .leading, spacing: 8) {
                    art
                    HStack(alignment: .top, spacing: 0) { tick; words; Spacer(minLength: 8); dots }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    tick
                    HStack(alignment: .top, spacing: 12) { art; words }
                    Spacer(minLength: 8)
                    dots
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(sounding ? Theme.primary.opacity(0.1) : Theme.selection.opacity(off ? 0.4 : 1))
        }
        // on the whole block, so the painting counts; its words and tick keep their own clicks
        .contentShape(.rect)
        .onTapGesture(count: 2) { router.alarm = .edit(alarm) }
        .sottovaMenu { entries }
    }

    private var tick: some View {
        RowTick(alarm: alarm).padding(.top, 4).frame(width: 23, alignment: .topLeading)
    }

    private var art: some View {
        Artwork(key: artwork, size: painting.height, width: painting.width, radius: 3, outlined: true)
            .opacity(off ? 0.4 : 1)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button { navigate(alarm.route(in: controller)) } label: {
                    Text(alarm.name).role(.row).foregroundStyle(off ? Theme.faint : Theme.text).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("open \(alarm.name)")
                // so what's sounding doesn't rest on color alone
                if sounding { Ph.speakerHigh.icon(size: 13).foregroundStyle(Theme.primary).accessibilityLabel("sounding") }
            }
            WordFlow {
                ForEach(pieces, id: \.text) { RowWord(alarm: alarm, piece: $0, off: off) }
            }
            .foregroundStyle(off ? Theme.faint : Theme.muted)
        }
        .daysOffPopover(alarm)
    }

    private var dots: some View {
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
            .daysOffPopover(alarm)
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
            ]
            + daysOff
            + [
                .divider,
                .item("Starts by itself", checked: !alarm.whileHere) { change { $0.whileHere = false } },
                .item("While you're at the Mac", checked: alarm.whileHere) { change(KindWords.whileHere) },
                .item("Unless my calendar is busy", checked: alarm.heedsCalendar) {
                    let on = !alarm.heedsCalendar
                    change { $0.heedsCalendar = on }
                    if on { Task { await Presence.askForCalendars() } }
                },
                .divider,
                .item("Delete") { controller.removeAlarm(alarm.id) },
            ]
    }

    /// "Off tomorrow", named for the day its next time falls on, and the popover for a run of days. Not on a row that
    /// plays once; dimmed on one turned off.
    private var daysOff: [MenuEntry] {
        guard !alarm.weekdays.isEmpty, let next = DayPlan(alarms: [], now: controller.wallNow).offChoice(alarm) else { return [] }
        let off = alarm.daysOff.contains(next.day)
        return [
            .item(next.title, checked: off, enabled: alarm.on) { change { if off { $0.daysOff.remove(next.day) } else { $0.daysOff.insert(next.day) } } },
            .item("Days off…", enabled: alarm.on) {
                router.daysOffFromWord = false
                router.daysOff = alarm.id
            },
        ]
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
                Group {
                    if entry.checked {
                        Toggle(entry.title, isOn: Binding(get: { true }, set: { _ in action() }))
                    } else {
                        Button(entry.title, action: action)
                    }
                }
                .disabled(!entry.enabled)
            case .submenu(let entries):
                Menu(entry.title) { RowEntries(entries: entries) }
                    .disabled(!entry.enabled)
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
