import AppKit
import SwiftUI
import SottovaCore

/// One word of a row's line: most open a native menu that fits what they say.
struct RowWord: View {
    let alarm: Alarm
    let piece: DayPlan.Piece
    /// Off today: its words dim like a row turned off.
    var off = false
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router

    var body: some View {
        switch piece.word {
        case nil:
            Text(piece.text).role(.body).padding(.trailing, WordMenu<EmptyView>.caret)
        case .playNow:
            ThemeLink(text: piece.text) { controller.playNow(alarm) }.role(.body).padding(.trailing, WordMenu<EmptyView>.caret)
        case .wake:
            ThemeLink(text: piece.text) { SystemWake.shared.schedule(for: controller.alarms, clicked: true) }.role(.body).padding(.trailing, WordMenu<EmptyView>.caret)
        case .days?:
            WordMenu(text: piece.text, on: alarm.on && !off) { DayWords(alarm: alarm, change: change) }
                .anchorPreference(key: DaysWord.self, value: .bounds) { $0 }
        case .daysOff?:
            WordMenu(text: piece.text, on: alarm.on && !off) {
                ForEach(DayPlan(alarms: [], now: controller.wallNow).offRuns(alarm), id: \.text) { run in
                    Toggle(run.text, isOn: Binding(get: { true }, set: { _ in change { $0.daysOff.subtract(run.days) } }))
                }
                Divider()
                Button("Days off…") {
                    router.daysOffFromWord = true
                    router.daysOff = alarm.id
                }
            }
            .anchorPreference(key: OffWord.self, value: .bounds) { $0 }
        case .kind?:
            WordMenu(text: piece.text, on: alarm.on && !off) { KindWords(alarm: alarm, change: change) }
        case .order?:
            WordMenu(text: piece.text, on: alarm.on && !off) { OrderWords(alarm: alarm, change: change) }
        case .volume?:
            WordMenu(text: piece.text, on: alarm.on && !off) { VolumeWords(alarm: alarm, change: change) }
        case .calendar?:
            WordMenu(text: piece.text, on: alarm.on && !off) {
                Toggle("Unless my calendar is busy", isOn: calendarBinding(true))
                Toggle("Whatever my calendar says", isOn: calendarBinding(false))
            }
        case .part?:
            WordMenu(text: piece.text, on: alarm.on && !off) {
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

/// Where a row's "Off…" word is, for the calendar it opens to point at.
struct OffWord: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Where its days word is, for the calendar opened from the menus.
struct DaysWord: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// One clickable word of a row's line, opening a native menu. No underline: under the pointer a plate and a caret say
/// it's a menu.
struct WordMenu<Content: View>: View {
    let text: String
    let on: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    /// The caret's room after every word, held at rest too, so the gaps stay even and showing it moves nothing.
    static var caret: CGFloat { 10 }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 2) {
                Text(text)
                Ph.caretDown.icon(.bold, size: 8).opacity(hovering ? 1 : 0).animation(Theme.quick, value: hovering)
            }
                .role(.body)
                // a Menu's label doesn't inherit the row's foreground
                .foregroundStyle(hovering ? Theme.text : on ? Theme.muted : Theme.faint)
                .background {
                    // ends at the caret, so the next word keeps its air; a block's fill is Theme.hover, so not that
                    RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.selection : .clear)
                        .padding(EdgeInsets(top: -1, leading: -4, bottom: -1, trailing: 0))
                }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        #if SHOT
        .onAppear { hovering = UserDefaults.standard.string(forKey: "shotHoverWord") == text }
        #endif
    }
}

struct OrderWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void

    var body: some View {
        Toggle("In order", isOn: Binding(get: { !alarm.shuffled }, set: { _ in change { $0.shuffled = false } }))
        Toggle("Shuffled", isOn: Binding(get: { alarm.shuffled }, set: { _ in change { $0.shuffled = true } }))
        Divider()
        Toggle("One part at a time", isOn: Binding(get: { alarm.rotates }, set: { on in change { $0.rotates = on } }))
    }
}

struct DayWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void
    private let choices: [(String, Set<Int>)] = [("Once", []), ("Weekdays", [2, 3, 4, 5, 6]), ("Weekends", [1, 7]), ("Every day", Set(1...7))]

    var body: some View {
        ForEach(choices, id: \.0) { name, days in
            Toggle(name, isOn: Binding(get: { alarm.weekdays == days }, set: { _ in change { $0.weekdays = days } }))
        }
    }
}

struct KindWords: View {
    let alarm: Alarm
    let change: ((inout Alarm) -> Void) -> Void

    /// A stretch of the day has to end.
    static func whileHere(_ row: inout Alarm) {
        row.whileHere = true
        row.minutes = row.minutes ?? 60
    }

    var body: some View {
        Toggle("Starts by itself", isOn: Binding(get: { !alarm.whileHere }, set: { _ in change { $0.whileHere = false } }))
        Toggle("While you're at the Mac", isOn: Binding(get: { alarm.whileHere }, set: { _ in change(KindWords.whileHere) }))
    }
}

struct VolumeWords: View {
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
struct WordFlow: Layout {
    // each word holds its caret's room as well
    private static let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let placed = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: placed.map { $0.x + $0.size.width }.max() ?? 0, height: placed.map { $0.y + $0.size.height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, spot) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y), proposal: ProposedViewSize(spot.size))
        }
    }

    /// The first line's, so the words sit on a name's baseline beside them.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
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
    static func lines(_ pieces: [DayPlan.Piece], width: Double) -> Int {
        let font = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: Role.body.size)]
        var (x, lines) = (0.0, 1)
        for piece in pieces {
            let size = Double(ceil((piece.text as NSString).size(withAttributes: font).width) + WordMenu<EmptyView>.caret)
            if x > 0, x + size > width { (x, lines) = (0, lines + 1) }
            lines += max(0, Int(size / width))
            x += size.truncatingRemainder(dividingBy: width) + Double(spacing)
        }
        return lines
    }
}
