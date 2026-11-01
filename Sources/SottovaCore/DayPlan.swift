import Foundation

/// What a day holds, for Your day, the sidebar and the line at the foot of Now. Wall-clock throughout, so a day the
/// clocks change on still draws to scale by what the clock says.
public struct DayPlan: Sendable {
    public struct Row: Identifiable, Sendable {
        public let alarm: Alarm
        public let start: Date
        /// Its window's end, or when its collection runs out; `start` if neither is known.
        public let end: Date
        /// "Overlaps Overworld. This one plays, Overworld waits.", on the one that started later, which is the one that has the time.
        public let overlapNote: String?
        public var id: Alarm.ID { alarm.id }
    }

    public struct Gap: Equatable, Sendable {
        public let from, to: Date
        /// "Nothing from 8 to 3."
        public let text: String
    }

    /// What Now says when nothing's sounding.
    public struct Quiet: Equatable, Sendable {
        public let headline: String
        public let line: String
        public let foot: String?
    }

    /// Today's rows by time, including those turned off and one still running from last night.
    public let rows: [Row]
    /// The rail runs 6 AM to 10 PM unless a row needs more.
    public let firstHour, lastHour: Int
    public let gaps: [Gap]
    private let alarms: [Alarm]
    private let now: Date
    private let calendar: Calendar
    private let twelveHour: Bool

    /// A stretch this long between rows gets said out loud, and the next row stops being "then".
    private static let longGap: TimeInterval = 2 * 3600

    public init(alarms: [Alarm], now: Date = .now, lengths: [Alarm.ID: TimeInterval] = [:], calendar: Calendar = .current,
                twelveHour: Bool = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true) {
        (self.alarms, self.now, self.calendar, self.twelveHour) = (alarms, now, calendar, twelveHour)
        let spans: [(alarm: Alarm, start: Date, end: Date)] = alarms.compactMap { alarm in
            let weekday = calendar.component(.weekday, from: now)
            let today = alarm.weekdays.isEmpty ? alarm.day.map { calendar.isDate($0, inSameDayAs: now) } ?? false : alarm.weekdays.contains(weekday)
            guard let start = alarm.window(containing: now, calendar: calendar)?.start
                ?? (today ? calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: now) : nil) else { return nil }
            return (alarm, start, start + (alarm.minutes.map { Double($0) * 60 } ?? lengths[alarm.id] ?? 0))
        }.sorted { $0.start < $1.start }
        let on = spans.filter(\.alarm.on)
        rows = spans.map { span in
            let earlier = on.last { $0.alarm.id != span.alarm.id && $0.start <= span.start && span.start < $0.end }
            return Row(alarm: span.alarm, start: span.start, end: span.end,
                       overlapNote: span.alarm.on ? earlier.map { "Overlaps \($0.alarm.name). This one plays, \($0.alarm.name) waits." } : nil)
        }
        let clock = { (date: Date) in calendar.dateComponents([.hour, .minute], from: date) }
        let midnight = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
        firstHour = spans.filter { $0.start >= midnight }.map { clock($0.start).hour ?? 6 }.reduce(6, min)
        lastHour = spans.map { span -> Int in
            if span.end >= tomorrow { return 24 }
            let end = clock(span.end)
            return (end.hour ?? 22) + ((end.minute ?? 0) > 0 ? 1 : 0)
        }.reduce(22, max)
        var gaps: [Gap] = []
        var reached = on.first?.end
        for span in on.dropFirst() {
            if let from = reached, span.start.timeIntervalSince(from) >= Self.longGap {
                let hour = Self.time(hour: clock(from).hour ?? 0, minute: 0, twelveHour: twelveHour)
                let to = Self.time(hour: clock(span.start).hour ?? 0, minute: clock(span.start).minute ?? 0, twelveHour: twelveHour)
                gaps.append(Gap(from: from, to: span.start, text: "Nothing from \(hour) to \(to)."))
            }
            reached = max(reached ?? span.end, span.end)
        }
        self.gaps = gaps
    }

    /// How far down the rail a time sits, 0 to 1.
    public func position(of date: Date) -> Double {
        let midnight = calendar.startOfDay(for: now)
        guard date >= midnight else { return 0 }
        guard date < calendar.date(byAdding: .day, value: 1, to: midnight) ?? date else { return 1 }
        let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(clock.hour ?? 0) + Double(clock.minute ?? 0) / 60 + Double(clock.second ?? 0) / 3600
        return min(max((hours - Double(firstHour)) / Double(lastHour - firstHour), 0), 1)
    }

    /// "Overworld until 7, then Compline at 8." under a row that's sounding.
    public func foot(sounding row: Alarm) -> String {
        let end = row.window(containing: now, calendar: calendar)?.end
        let head = end.map { "\(row.name) until \(time($0))" } ?? "\(row.name) at \(Self.time(hour: row.hour, minute: row.minute, twelveHour: twelveHour))"
        let after = end ?? now
        guard let next = following(after: after) else { return head + "." }
        if !calendar.isDate(next.at, inSameDayAs: after) {
            return "\(head). Then nothing until \(next.alarm.name) at \(time(next.at))\(dayWord(next.at))."
        }
        return next.at.timeIntervalSince(after) < Self.longGap ? "\(head), then \(next.alarm.name) at \(time(next.at))."
                                                                : "\(head). Then nothing until \(time(next.at))."
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
        return missedLine.map { Quiet(headline: plan.headline, line: plan.line, foot: $0) } ?? plan
    }

    private func quietPlan(wakeScheduled: Bool) -> Quiet {
        guard let next = following(after: now) else {
            return Quiet(headline: "Nothing on your day", line: "Press play, or give a collection some hours.", foot: nil)
        }
        if calendar.isDate(next.at, inSameDayAs: now) {
            let then = following(after: next.at).flatMap { calendar.isDate($0.at, inSameDayAs: now) ? "Then \($0.alarm.name) at \(time($0.at))." : nil }
            return Quiet(headline: "Nothing on yet", line: "\(next.alarm.name) at \(time(next.at)).", foot: then)
        }
        let word = dayWord(next.at).isEmpty ? " tomorrow" : dayWord(next.at)
        return Quiet(headline: rows.contains(where: \.alarm.on) ? "The day is done" : "Nothing on today", line: "\(next.alarm.name) at \(time(next.at))\(word).",
                     foot: wakeScheduled && !next.alarm.whileHere ? "The Mac will wake for it." : nil)
    }

    /// Beside a collection in the sidebar: "till 7" while it has the time, otherwise "7:02" or "8 PM". Nil if it has no row on.
    public func label(of source: String) -> String? {
        let mine = alarms.filter { $0.on && $0.source == source }
        if let end = mine.compactMap({ $0.window(containing: now, calendar: calendar)?.end }).max() { return "till \(time(end))" }
        guard let first = mine.min(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) }) else { return nil }
        let bare = Self.time(hour: first.hour, minute: first.minute, twelveHour: twelveHour)
        return first.minute == 0 && twelveHour ? "\(bare) \(first.hour < 12 ? "AM" : "PM")" : bare
    }

    /// Collections with a row on, by the time of day it starts; the rest after, as they were.
    public func inDayOrder(_ sources: [String]) -> [String] {
        let start = { (source: String) in alarms.filter { $0.on && $0.source == source }.map { $0.hour * 60 + $0.minute }.min() ?? .max }
        return sources.enumerated().sorted { (start($0.element), $0.offset) < (start($1.element), $1.offset) }.map(\.element)
    }

    private func following(after date: Date) -> (alarm: Alarm, at: Date)? {
        alarms.filter(\.on).compactMap { alarm in alarm.next(after: date, calendar: calendar).map { (alarm, $0) } }.min { $0.1 < $1.1 }
    }

    private func dayWord(_ date: Date) -> String {
        calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ? "" : " " + date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: calendar.timeZone).weekday(.wide))
    }

    private func time(_ date: Date) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        return Self.time(hour: clock.hour ?? 0, minute: clock.minute ?? 0, twelveHour: twelveHour)
    }

    /// "3", "7:02"; "15:00" on a 24-hour clock.
    private static func time(hour: Int, minute: Int, twelveHour: Bool) -> String {
        let padded = minute < 10 ? "0\(minute)" : "\(minute)"
        guard twelveHour else { return "\(hour):\(padded)" }
        let shown = (hour + 11) % 12 + 1
        return minute == 0 ? "\(shown)" : "\(shown):\(padded)"
    }
}

extension Controller {
    /// The day as of `now`; a row without an end is as long as its collection.
    public func dayPlan(now: Date = .now) -> DayPlan {
        DayPlan(alarms: alarms, now: now, lengths: Dictionary(uniqueKeysWithValues: alarms.filter { $0.minutes == nil }.map { alarm in
            (alarm.id, rowSongs(alarm).reduce(0) { $0 + $1.duration })
        }))
    }
}
