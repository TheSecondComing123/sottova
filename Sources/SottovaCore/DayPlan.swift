import Foundation

/// What a day holds, for Your day, the sidebar and the line at the foot of Now. Wall-clock throughout, so a day the
/// clocks change on still draws to scale by what the clock says.
public struct DayPlan: Sendable {
    public struct Row: Identifiable, Sendable {
        public let alarm: Alarm
        public let start: Date
        /// Its window's end, or when its collection runs out; `start` if neither is known.
        public let end: Date
        /// The row this one overlaps, which waits: on the one that started later, which is the one that has the time.
        public let waits: String?
        /// Turned off, or off today: it plays nothing today and draws dimmed.
        public let off: Bool
        public var id: Alarm.ID { alarm.id }
    }

    /// What Now says when nothing's sounding.
    public struct Quiet: Equatable, Sendable {
        public let headline: String
        public let line: String
        /// A miss today, or that the Mac will wake.
        public let foot: String?
        /// What comes after an hour that's open, as the headline has that hour.
        public var next: String?
    }

    /// Today's rows by time, including those turned off and one still running from last night.
    public let rows: [Row]
    /// The rail runs from the hour of the first row to the end of the last. No rows, or `wholeDay`: 6 AM to 10 PM, or more if a row needs it.
    public let firstHour, lastHour: Int
    /// Stretches with no row in them drawn short, in hours from midnight. None on the whole day.
    public let breaks: [ClosedRange<Double>]
    private let alarms: [Alarm]
    fileprivate let now: Date
    fileprivate let calendar: Calendar
    fileprivate let twelveHour: Bool

    /// A break's drawn hours, and the gap it takes to make one.
    private static let breakHours = 2.0

    public init(alarms: [Alarm], now: Date = .now, lengths: [Alarm.ID: TimeInterval] = [:], calendar: Calendar = .current,
                twelveHour: Bool = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true, wholeDay: Bool = false) {
        (self.alarms, self.now, self.calendar, self.twelveHour) = (alarms, now, calendar, twelveHour)
        let spans: [(alarm: Alarm, start: Date, end: Date)] = alarms.compactMap { alarm in
            let weekday = calendar.component(.weekday, from: now)
            let today = alarm.weekdays.isEmpty ? alarm.day.map { calendar.isDate($0, inSameDayAs: now) } ?? false : alarm.weekdays.contains(weekday)
            guard let start = alarm.window(containing: now, calendar: calendar)?.start
                ?? (today ? calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: now) : nil) else { return nil }
            return (alarm, start, start + (alarm.minutes.map { Double($0) * 60 } ?? lengths[alarm.id] ?? 0))
        }.sorted { $0.start < $1.start }
        let resting = { (span: (alarm: Alarm, start: Date, end: Date)) in !span.alarm.on || span.alarm.isOff(span.start, calendar: calendar) }
        let on = spans.filter { !resting($0) }
        rows = spans.map { span in
            let earlier = on.prefix { $0.alarm.id != span.alarm.id }.last { span.start < $0.end }
            return Row(alarm: span.alarm, start: span.start, end: span.end,
                       waits: resting(span) ? nil : earlier?.alarm.name, off: resting(span))
        }
        let clock = { (date: Date) in calendar.dateComponents([.hour, .minute], from: date) }
        let midnight = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
        let whole = wholeDay || spans.isEmpty
        // one from last night is on the rail from midnight
        let first = spans.map { $0.start >= midnight ? clock($0.start).hour ?? 6 : 0 }.min() ?? 6
        let last = spans.map { span -> Int in
            if span.end >= tomorrow { return 24 }
            let end = clock(span.end)
            return (end.hour ?? 22) + ((end.minute ?? 0) > 0 ? 1 : 0)
        }.max() ?? 22
        firstHour = whole ? min(first, 6) : first
        lastHour = max(whole ? max(last, 22) : last, firstHour + 1)
        var gaps: [ClosedRange<Double>] = []
        if !whole {
            let hours = { (date: Date) in date < midnight ? 0 : date >= tomorrow ? 24 : Self.hours(date, calendar) }
            var reached = hours(spans[0].start)
            for span in spans {
                let start = hours(span.start)
                if start - reached > Self.breakHours { gaps.append(reached...start) }
                reached = max(reached, start, hours(span.end))
            }
        }
        breaks = gaps
    }

    private static func hours(_ date: Date, _ calendar: Calendar) -> Double {
        let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(clock.hour ?? 0) + Double(clock.minute ?? 0) / 60 + Double(clock.second ?? 0) / 3600
    }

    /// How far down the rail a time sits, 0 to 1.
    public func position(of date: Date) -> Double {
        let midnight = calendar.startOfDay(for: now)
        guard date >= midnight else { return 0 }
        guard date < calendar.date(byAdding: .day, value: 1, to: midnight) ?? date else { return 1 }
        return min(max(drawn(hour: Self.hours(date, calendar)) / span, 0), 1)
    }

    /// The rail's length in hours as drawn.
    public var span: Double {
        Double(lastHour - firstHour) - breaks.reduce(0) { $0 + ($1.upperBound - $1.lowerBound - Self.breakHours) }
    }

    /// Hours down the rail an hour of the day draws, with each break's gap squeezed evenly into its drawn length.
    public func drawn(hour: Double) -> Double {
        breaks.reduce(hour - Double(firstHour)) { drawn, gap in
            guard hour > gap.lowerBound else { return drawn }
            let length = gap.upperBound - gap.lowerBound
            return drawn - (min(hour, gap.upperBound) - gap.lowerBound) * (1 - Self.breakHours / length)
        }
    }

    /// The inverse of `drawn(hour:)`.
    public func hour(drawn: Double) -> Double {
        var hour = drawn + Double(firstHour)
        for gap in breaks where hour > gap.lowerBound {
            let length = gap.upperBound - gap.lowerBound
            hour += hour < gap.lowerBound + Self.breakHours ? (hour - gap.lowerBound) * (length / Self.breakHours - 1) : length - Self.breakHours
        }
        return hour
    }

    public func y(hour: Int, hourHeight: Double) -> Double { drawn(hour: Double(hour)) * hourHeight }

    /// "Compline at 8" under a row that's sounding: what comes after it. Nil if nothing does.
    public func next(sounding row: Alarm) -> String? {
        // a second back, so one starting as this ends counts
        following(after: (row.window(containing: now, calendar: calendar)?.end ?? now) - 1).map(nextLine)
    }

    /// "Compline at 8", "Lauds at 7:02 tomorrow"
    private func nextLine(_ next: (alarm: Alarm, at: Date)) -> String {
        "\(next.alarm.name) at \(time(next.at))\(calendar.isDate(next.at, inSameDayAs: now) ? "" : dayName(next.at))"
    }

    /// On its row: "Missed at 7:02. The Mac was off."
    public func missedToday(_ row: Alarm) -> String? {
        guard let missed = row.missed, calendar.isDate(missed.at, inSameDayAs: now) else { return nil }
        return "Missed at \(time(missed.at)). \(missed.reason)"
    }

    private var missedLine: String? {
        rows.compactMap { row in row.alarm.missed.flatMap { calendar.isDate($0.at, inSameDayAs: now) ? ($0, row.alarm.name) : nil } }
            .max { $0.0.at < $1.0.at }
            .map { "Missed \($0.1) at \(time($0.0.at)). \($0.0.reason)" }
    }

    /// Nothing sounding. `wakeScheduled` is whether the Mac will wake for the next one: only then can it say so. A miss
    /// today takes the foot, which is where you'd look for it.
    public func quiet(wakeScheduled: Bool = false) -> Quiet {
        let plan = quietPlan(wakeScheduled: wakeScheduled)
        return missedLine.map { Quiet(headline: plan.headline, line: plan.line, foot: $0, next: plan.next) } ?? plan
    }

    private func quietPlan(wakeScheduled: Bool) -> Quiet {
        let foot = { (next: (alarm: Alarm, at: Date)) in wakeScheduled && !next.alarm.whileHere ? "The Mac will wake for it." : nil }
        // the sidebar reads the same windows, so this can't say nothing's on while it says "till 9"
        if let open = alarms.filter(\.on).compactMap({ alarm in alarm.window(containing: now, calendar: calendar).map { (alarm.name, $0.end) } }).max(by: { $0.1 < $1.1 }) {
            let next = following(after: now)
            return Quiet(headline: open.0, line: "till \(fullTime(open.1)), not playing", foot: next.flatMap(foot), next: next.map(nextLine))
        }
        guard let next = following(after: now) else {
            return Quiet(headline: "Nothing on your day", line: "", foot: nil)
        }
        return Quiet(headline: next.alarm.name, line: when(next.at), foot: foot(next))
    }

    /// "3 PM today", "7:02 tomorrow", "7:02 Monday"
    private func when(_ date: Date) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        let bare = time(date)
        // as the sidebar has it: 7:02 alone reads as morning
        let halved = clock.minute == 0 && twelveHour ? "\(bare) \((clock.hour ?? 0) < 12 ? "AM" : "PM")" : bare
        return halved + (calendar.isDate(date, inSameDayAs: now) ? " today" : dayName(date))
    }

    /// The collection Now's words name when nothing's sounding, for its painting.
    public var quietSource: String? {
        alarms.filter(\.on).compactMap { alarm in alarm.window(containing: now, calendar: calendar).map { (alarm.source, $0.end) } }.max { $0.1 < $1.1 }?.0
            ?? following(after: now)?.alarm.source
    }

    /// Beside a collection in the sidebar: "till 7 PM" while it has the time, otherwise "7:02 AM" or "8 PM". Nil if it has no row on.
    public func label(of source: String) -> String? {
        let mine = alarms.filter { $0.on && $0.source == source }
        if let end = mine.compactMap({ $0.window(containing: now, calendar: calendar)?.end }).max() { return "till \(fullTime(end))" }
        guard let first = mine.min(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) }) else { return nil }
        let label = railTime(hour: first.hour, minute: first.minute, full: true)
        // its next time is a day off: the one it comes back on
        guard let next = first.next(after: now, calendar: calendar), next != first.withoutDaysOff.next(after: now, calendar: calendar) else { return label }
        let week = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
        return "\(label) \(next < week ? next.formatted(style.weekday(.abbreviated)) : shortDate(next))"
    }

    // MARK: Days off

    /// The day a row's next time falls on, days off or not, and what the menu item that takes it off says: "Off
    /// today", "Off tomorrow", "Off Monday". While its window is open, that's today.
    public func offChoice(_ alarm: Alarm) -> (day: String, title: String)? {
        let any = alarm.withoutDaysOff
        guard let at = any.window(containing: now, calendar: calendar)?.start ?? any.next(after: now, calendar: calendar) else { return nil }
        return (Alarm.day(at, calendar: calendar), "Off \(relativeDay(at))")
    }

    /// Each run of days off not yet over, with its days and what it says: "Off tomorrow", "Off Nov 27", "Off Dec 21 to
    /// Jan 4", or "Off till Jan 5" for one under way. Days it doesn't play don't break a run: a weekday row off for two
    /// weeks is one run.
    public func offRuns(_ alarm: Alarm) -> [(days: [String], text: String)] {
        let today = calendar.startOfDay(for: now)
        var runs: [[Date]] = []
        for run in alarm.offRuns(calendar: calendar) {
            if let last = runs.last?.last, let first = run.first, !alarm.weekdays.isEmpty,
               !days(from: last, to: first).dropFirst().dropLast().contains(where: { plays(alarm, $0) }) {
                runs[runs.count - 1] += run
            } else {
                runs.append(run)
            }
        }
        return runs.compactMap { run in
            guard let first = run.first, let last = run.last, last >= today else { return nil }
            let text: String
            if first <= today {
                text = calendar.isDate(last, inSameDayAs: today) ? "Off today"
                    : "Off till \(shortDate(back(alarm, after: last)))"
            } else if run.count == 1 {
                text = "Off \(relativeDay(first))"
            } else {
                text = "Off \(shortDate(first)) to \(shortDate(last))"
            }
            return (run.map { Alarm.day($0, calendar: calendar) }, text)
        }
    }

    /// The first day it plays after a run ending on `last`; a day off after that would have joined the run.
    private func back(_ alarm: Alarm, after last: Date) -> Date {
        let after = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return alarm.withoutDaysOff.next(after: after - 1, calendar: calendar).map(calendar.startOfDay) ?? after
    }

    /// The first `runs` runs on one line, for under the calendar: "Off Dec 21 to Jan 4", "Off tomorrow, Nov 20 to
    /// Nov 21", "Off today, Nov 19 to Nov 22, and 2 more".
    public func offLine(_ alarm: Alarm, runs count: Int = .max) -> String {
        let runs = offRuns(alarm).map(\.text)
        guard let first = runs.first else { return "No days off" }
        let shown = [first] + runs.dropFirst().prefix(max(count - 1, 0)).map { String($0.dropFirst(4)) }
        let more = runs.count - shown.count
        return (shown + (more > 0 ? ["and \(more) more"] : [])).joined(separator: ", ")
    }

    /// A month to point at days off in.
    public struct Month: Sendable {
        /// "November 2026"
        public let title: String
        /// Its 1st.
        public let first: Date
        /// Blank places before the 1st, so each day falls under its weekday.
        public let lead: Int
        public let days: [Day]

        public struct Day: Identifiable, Sendable {
            public let date: Date
            public let number: Int
            /// One of its weekdays.
            public let plays: Bool
            public let past: Bool
            public let today: Bool
            public let off: Bool
            /// A click takes it off or back.
            public var open: Bool { plays && !past }
            public var id: Date { date }
        }
    }

    /// "S", "M", … from the calendar's first weekday, over the month's columns.
    public var weekdayLetters: [String] {
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(letters[first...] + letters[..<first])
    }

    /// The month holding `date`, its days as `alarm` has them.
    public func month(_ alarm: Alarm, containing date: Date) -> Month {
        let first = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }.map { day in
            Month.Day(date: day, number: calendar.component(.day, from: day), plays: plays(alarm, day), past: day < today,
                      today: day == today, off: alarm.daysOff.contains(Alarm.day(day, calendar: calendar)))
        }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Month(title: first.formatted(style.month(.wide).year()), first: first, lead: lead, days: days)
    }

    /// Its days off with every day from one day to another, either way round, taken off or put back. Taking off only
    /// takes days it plays; days gone stay as they are.
    public func marking(_ alarm: Alarm, from: Date, to: Date, off: Bool) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        var daysOff = alarm.daysOff
        for day in days(from: min(from, to), to: max(from, to)) where day >= today {
            let key = Alarm.day(day, calendar: calendar)
            if !off {
                daysOff.remove(key)
            } else if plays(alarm, day) {
                daysOff.insert(key)
            }
        }
        return daysOff
    }

    private func plays(_ alarm: Alarm, _ day: Date) -> Bool {
        alarm.weekdays.contains(calendar.component(.weekday, from: day))
    }

    /// Each midnight from one day's to another's, both in.
    private func days(from: Date, to: Date) -> [Date] {
        var (day, days) = (calendar.startOfDay(for: from), [Date]())
        while day <= to, days.count < 800 {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? .distantFuture
        }
        return days
    }

    /// "today", "tomorrow", "Friday" within the week, then "Nov 27".
    private func relativeDay(_ date: Date) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(date, inSameDayAs: today) { return "today" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: today) ?? today) { return "tomorrow" }
        let week = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        return date < week ? date.formatted(style.weekday(.wide)) : shortDate(date)
    }

    /// "Nov 27"
    private func shortDate(_ date: Date) -> String {
        date.formatted(style.month(.abbreviated).day())
    }

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: calendar.timeZone)
    }

    /// Under a collection in the grid: "7:02 weekdays", "3 to 7 PM". Nil if it has no row on.
    public func shortHours(of source: String) -> String? {
        firstRow(of: source).map { row in
            // 7:02 alone reads as morning; anything else says which
            let noon = twelveHour && (row.hour >= 12 || row.minute == 0) ? row.hour < 12 ? " AM" : " PM" : ""
            return row.minutes == nil ? "\(clockTime(row))\(noon) \(days(row).lowercased())" : span(row)
        }
    }

    /// On a collection's page, before the row's words: "7:02 AM" or "8 to 9 PM".
    public func when(_ row: Alarm) -> String {
        row.minutes == nil ? "\(clockTime(row))\(twelveHour ? row.hour < 12 ? " AM" : " PM" : "")" : span(row)
    }

    /// The row a collection's page speaks for. Nil if it has no row on.
    public func firstRow(of source: String) -> Alarm? {
        alarms.filter { $0.on && $0.source == source }.min { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    private func clockTime(_ row: Alarm) -> String {
        Self.time(hour: row.hour, minute: row.minute, twelveHour: twelveHour)
    }

    /// "8 to 9 PM", "11 AM to 1 PM"; "15:00 to 19:00" on a 24-hour clock.
    private func span(_ row: Alarm) -> String {
        let end = (row.hour * 60 + row.minute + (row.minutes ?? 0)) % (24 * 60)
        let last = Self.time(hour: end / 60, minute: end % 60, twelveHour: twelveHour)
        guard twelveHour else { return "\(clockTime(row)) to \(last)" }
        let noon = { (hour: Int) in hour < 12 ? "AM" : "PM" }
        return noon(row.hour) == noon(end / 60) ? "\(clockTime(row)) to \(last) \(noon(end / 60))" : "\(clockTime(row)) \(noon(row.hour)) to \(last) \(noon(end / 60))"
    }

    fileprivate func days(_ row: Alarm) -> String {
        switch row.weekdays {
        case []: "Once"
        case Set(1...7): "Every day"
        case [2, 3, 4, 5, 6]: "Weekdays"
        case [1, 7]: "Weekends"
        default: "Some days"
        }
    }

    /// Collections with a row on, by the time of day it starts; the rest after, as they were.
    public func inDayOrder(_ sources: [String]) -> [String] {
        let start = { (source: String) in alarms.filter { $0.on && $0.source == source }.map { $0.hour * 60 + $0.minute }.min() ?? .max }
        return sources.enumerated().sorted { (start($0.element), $0.offset) < (start($1.element), $1.offset) }.map(\.element)
    }

    private func following(after date: Date) -> (alarm: Alarm, at: Date)? {
        alarms.filter(\.on).compactMap { alarm in alarm.next(after: date, calendar: calendar).map { (alarm, $0) } }.min { $0.1 < $1.1 }
    }

    private func dayName(_ date: Date) -> String {
        calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ? " tomorrow" : " " + date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: calendar.timeZone).weekday(.wide))
    }

    /// "7 PM", where `time` would say "7": alone on a line, a time says which half of the day.
    private func fullTime(_ date: Date) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        return railTime(hour: clock.hour ?? 0, minute: clock.minute ?? 0, full: true)
    }

    private func time(_ date: Date) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        return Self.time(hour: clock.hour ?? 0, minute: clock.minute ?? 0, twelveHour: twelveHour)
    }

    /// "3", "7:02"; "15:00" on a 24-hour clock.
    fileprivate static func time(hour: Int, minute: Int, twelveHour: Bool) -> String {
        let padded = minute < 10 ? "0\(minute)" : "\(minute)"
        guard twelveHour else { return "\(hour):\(padded)" }
        let shown = (hour + 11) % 12 + 1
        return minute == 0 ? "\(shown)" : "\(shown):\(padded)"
    }
}

/// A row's line on Your day, in pieces so each word can open its own menu.
extension DayPlan {
    public enum Word: Sendable { case days, daysOff, kind, order, volume, calendar, part, playNow, wake }

    public struct Piece: Equatable, Sendable {
        public let text: String
        public let word: Word?

        init(_ text: String, _ word: Word? = nil) {
            (self.text, self.word) = (text, word)
        }
    }

    /// Weekdays, shuffled, 25%, Strings next, as separate words. Whatever's happening to the row takes their place, and
    /// warnings stay sentences. `nextPart` is its part's name when it rotates.
    public func line(for row: Row, nextPart: String?, rising: Bool = false, waiting: Hold? = nil, cantWake: Bool = false) -> [Piece] {
        let alarm = row.alarm
        if rising {
            let level = alarm.volume.map { "Rising to \(Self.percent($0))" } ?? "Rising"
            return [Piece(level)] + sentence(alarm, nextPart: nextPart, volume: false)
        }
        if let waiting {
            let why = switch waiting {
            case .away: "you're away"
            case .call: "you're on a call"
            case .busy: "your calendar is busy"
            case .media: "something else is playing"
            }
            return [Piece("Waiting, \(why)")]
        }
        if let missed = missedToday(alarm) {
            let wake = cantWake ? [Piece("The Mac won't wake for the next one."), Piece("Wake it", .wake)] : []
            return [Piece(missed), Piece("Play it now", .playNow)] + wake
        }
        if cantWake { return wakeLine(alarm: alarm, nextPart: nextPart, cantWake: true) }
        guard let waits = row.waits else { return sentence(alarm, nextPart: nextPart) }
        return sentence(alarm, nextPart: nextPart) + [Piece("\(waits) waits")]
    }

    /// A row with no place on today's rail still says if the Mac can't wake for it.
    public func wakeLine(alarm: Alarm, nextPart: String?, cantWake: Bool) -> [Piece] {
        cantWake ? [Piece("The Mac won't wake for this."), Piece("Wake it", .wake)] : sentence(alarm, nextPart: nextPart)
    }

    /// Off today or any other day, it says the same. Every day goes without saying on a row for while you're at the Mac.
    public func sentence(_ alarm: Alarm, nextPart: String?, volume showsVolume: Bool = true) -> [Piece] {
        var pieces: [Piece] = []
        if !alarm.whileHere || alarm.weekdays != Set(1...7) { pieces.append(Piece(days(alarm), .days)) }
        if let off = offRuns(alarm).first { pieces.append(Piece(off.text, .daysOff)) }
        if alarm.whileHere { pieces.append(Piece("At the Mac", .kind)) }
        if alarm.shuffled {
            pieces.append(Piece("shuffled", .order))
        } else if !alarm.rotates {
            pieces.append(Piece("in order", .order))
        }
        if showsVolume, let volume = alarm.volume {
            pieces.append(Piece(Self.percent(volume) + " volume", .volume))
        }
        if alarm.heedsCalendar { pieces.append(Piece("unless busy", .calendar)) }
        if alarm.rotates, let nextPart {
            pieces.append(Piece(nextPart.prefix(1).uppercased() + nextPart.dropFirst() + " next", .part))
        }
        return pieces
    }

    /// After a row's words, while the Mac would still wake on a day off: the link asks once for the rule that cancels.
    public static let stillWakes = [Piece("The Mac still wakes for it."), Piece("Let it sleep", .wake)]

    private static func percent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    /// "7:02 AM" for a row with no place on today's rail.
    public static func startText(_ alarm: Alarm, twelveHour: Bool = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true) -> String {
        let bare = time(hour: alarm.hour, minute: alarm.minute, twelveHour: twelveHour)
        return twelveHour ? "\(bare) \(alarm.hour < 12 ? "AM" : "PM")" : bare
    }

    /// "7:02" in What played, where 3 alone would look like a count.
    public func clockText(_ date: Date) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        let hour = clock.hour ?? 0
        return String(format: "%d:%02d", twelveHour ? (hour + 11) % 12 + 1 : hour, clock.minute ?? 0)
    }

    /// The hour a point on the rail falls in, through any break, for a drop: a two-hour row has to fit, so never the last hour.
    public func hour(at y: Double, hourHeight: Double = Rail.hourHeight) -> Int {
        min(max(Int(hour(drawn: max(y, 0) / hourHeight)), firstHour), max(lastHour - 2, firstHour))
    }

    /// The time of day a point on the rail is at, in minutes from midnight to the nearest `snap`, through any break.
    /// Above and below the rail the scale goes on to the day's ends, so a row can be dragged past them.
    public func minute(at y: Double, hourHeight: Double = Rail.hourHeight, snap: Int = 5) -> Int {
        let minutes = hour(drawn: y / hourHeight) * 60
        return min(max(Int((minutes / Double(snap)).rounded()) * snap, 0), 24 * 60)
    }

    /// Where a start or end at `minute` goes when dragged `dy` points: on by whole five minutes, so 7:02 stays 7:02
    /// until the drag goes somewhere.
    public func minute(_ minute: Int, draggedBy dy: Double, hourHeight: Double = Rail.hourHeight) -> Int {
        let raw = hour(drawn: (y(minute: minute, hourHeight: hourHeight) + dy) / hourHeight) * 60
        return min(max(minute + Int(((raw - Double(minute)) / 5).rounded()) * 5, 0), 24 * 60)
    }

    public func y(minute: Int, hourHeight: Double) -> Double { drawn(hour: Double(minute) / 60) * hourHeight }

    /// "4 PM", "4:15 PM", "noon", as the rail says a row's start; not `full`, "4:15" as it says an end.
    public func timeText(minute: Int, full: Bool = true) -> String { railTime(hour: minute / 60, minute: minute % 60, full: full) }

    /// "10 AM to noon", as a dropped row would read.
    public func dropLabel(hour: Int) -> (start: String, span: String) {
        let start = railTime(hour: hour, minute: 0, full: true)
        return (start, "\(start) to \(railTime(hour: hour + 2, minute: 0, full: true))")
    }

    /// Your day to scale, in points from the rail's top. Rows keep their bars at their times; a row's words move down
    /// when the one above needs the room.
    public struct Rail: Sendable {
        public static let hourHeight = 24.0
        /// Above this a short day stops filling the page, as an hour can't usefully be taller than a painting.
        public static let maxHourHeight = 180.0
        /// A row's block: a name and its line, with room around them.
        public static let rowHeight = 56.0
        /// Each line of words past the first.
        public static let lineHeight = 18.0

        public struct Mark: Identifiable, Sendable {
            public let alarm: Alarm
            /// The top of its words.
            public let top: Double
            public let bar: ClosedRange<Double>
            /// Beside the line: it overlaps the row before.
            public let aside: Bool
            /// Turned off or off today.
            public let off: Bool
            /// The block behind its words, from its bar's end or its lines' room, stopping short of the next.
            public fileprivate(set) var block: ClosedRange<Double>
            let bottom: Double
            public var id: Alarm.ID { alarm.id }
        }

        /// A gap drawn short: where its mark goes, and how long it really is.
        public struct Break: Sendable {
            public let y: Double
            public let text: String
        }

        public enum Kind: Int, Sendable { case row, now, off, end, frame }

        public struct Label: Equatable, Sendable {
            public let text: String
            public let y: Double
            public let kind: Kind
            /// The row whose time this is, so it can be changed there.
            public let row: Alarm.ID?

            public init(text: String, y: Double, kind: Kind, row: Alarm.ID?) {
                (self.text, self.y, self.kind, self.row) = (text, y, kind, row)
            }
        }

        public let height: Double
        public let marks: [Mark]
        public let labels: [Label]
        public let now: Double?
        public let breaks: [Break]
    }

    public var rail: Rail { rail(hourHeight: Rail.hourHeight) }

    /// `hourHeight`: a page with room to spare spends it on the scale. `lines`: rows whose words take more than one line.
    public func rail(hourHeight: Double, lines: [Alarm.ID: Int] = [:]) -> Rail {
        let height = span * hourHeight
        let y = { (date: Date) in position(of: date) * height }
        var marks: [Rail.Mark] = []
        for row in rows {
            let room = Rail.rowHeight + Double((lines[row.id] ?? 1) - 1) * Rail.lineHeight
            let top = max(y(row.start) - 11, marks.last?.bottom ?? -.infinity)
            let bar = y(row.start)...max(y(row.end), y(row.start) + 3)
            marks.append(Rail.Mark(alarm: row.alarm, top: top, bar: bar, aside: row.waits != nil, off: row.off,
                                   block: top + 3...max(bar.upperBound, top + 3 + room - 4), bottom: top + room))
        }
        for index in marks.indices.dropLast() {
            let block = marks[index].block
            marks[index].block = block.lowerBound...max(block.lowerBound, min(block.upperBound, marks[index + 1].block.lowerBound - 4))
        }
        var wanted: [Rail.Label] = []
        for (mark, row) in zip(marks, rows) {
            let clock = calendar.dateComponents([.hour, .minute], from: row.start)
            wanted.append(Rail.Label(text: railTime(hour: clock.hour ?? 0, minute: clock.minute ?? 0, full: true), y: mark.top + 11,
                                     kind: row.off ? .off : .row, row: row.alarm.id))
            if row.end > row.start {
                let end = calendar.dateComponents([.hour, .minute], from: row.end)
                wanted.append(Rail.Label(text: railTime(hour: end.hour ?? 0, minute: end.minute ?? 0, full: end.minute == 0), y: mark.bar.upperBound,
                                         kind: .end, row: row.alarm.minutes == nil ? nil : row.alarm.id))
            }
        }
        let inDay = (firstHour..<lastHour).contains(calendar.component(.hour, from: now))
        if inDay { wanted.append(Rail.Label(text: clockText(now), y: y(now), kind: .now, row: nil)) }
        // with nothing on the rail the hours are all it has to say
        let bare = rows.isEmpty ? stride(from: firstHour + 3, to: lastHour, by: 3).map { $0 } : []
        for hour in [firstHour, lastHour] + (firstHour < 12 && lastHour > 12 && !breaks.contains { $0.contains(12) } ? [12] : []) + bare {
            let edge = hour == firstHour || hour == lastHour
            wanted.append(Rail.Label(text: railTime(hour: hour, minute: 0, full: edge), y: self.y(hour: hour, hourHeight: hourHeight), kind: .frame, row: nil))
        }
        var labels: [Rail.Label] = []
        for label in wanted.enumerated().sorted(by: { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }).map(\.element)
        where !labels.contains(where: { abs($0.y - label.y) < 15 }) {
            labels.append(label)
        }
        let foot = marks.last.map { max($0.bottom, $0.block.upperBound) } ?? Rail.rowHeight
        return Rail(height: max(height, foot), marks: marks, labels: labels.sorted { $0.y < $1.y }, now: inDay ? y(now) : nil,
                    breaks: breaks.map { gap in
                        let at = marks.firstIndex { drawn(hour: gap.upperBound) * hourHeight <= $0.bar.lowerBound + 0.001 } ?? 0
                        let above = at > 0 ? marks[at - 1].block.upperBound : 0
                        return Rail.Break(y: (above + (at < marks.count ? marks[at].block.lowerBound : height)) / 2, text: Self.length(gap.upperBound - gap.lowerBound))
                    })
    }

    /// "6 h 49 min", "7 h"
    private static func length(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "7:02 AM", "noon"; `full` says which half of the day, otherwise "8:11" or "3". A 24-hour clock has no halves.
    private func railTime(hour: Int, minute: Int, full: Bool) -> String {
        if twelveHour, minute == 0, hour % 24 == 12 { return "noon" }
        if twelveHour, minute == 0, hour % 24 == 0 { return "midnight" }
        let bare = Self.time(hour: hour % 24, minute: minute, twelveHour: twelveHour)
        return twelveHour && full ? "\(bare) \(hour % 24 < 12 ? "AM" : "PM")" : bare
    }
}

extension Controller {
    /// The day as of `now`; a row without an end is as long as its collection. `wholeDay`: something's being dropped on it.
    public func dayPlan(now: Date = .now, wholeDay: Bool = false) -> DayPlan {
        DayPlan(alarms: alarms, now: now, lengths: Dictionary(alarms.filter { $0.minutes == nil }.map { alarm in
            (alarm.id, rowSongs(alarm).reduce(0) { $0 + $1.duration })
        }, uniquingKeysWith: { first, _ in first }), wholeDay: wholeDay)
    }
}
