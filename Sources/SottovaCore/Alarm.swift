import Foundation

/// Starts an album or playlist at a time of day: once on a given day, or on chosen weekdays. Or, `whileHere`, plays it
/// from that time for `minutes` only while you're at the Mac.
public struct Alarm: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// An album id or a playlist's file path.
    public var source: String
    /// What it plays, as shown in lists.
    public var name: String
    public var hour: Int
    public var minute: Int
    /// Calendar weekdays (1 is Sunday); empty means once, on `day`.
    public var weekdays: Set<Int> = []
    /// The day a one-off alarm fires on.
    public var day: Date?
    public var shuffled = false
    /// Off keeps it in the list without it going off.
    public var on = true
    /// What the volume is set to as it starts, so a speaker left loud isn't a jolt; nil leaves it.
    public var volume: Double?
    /// How long it plays before easing down to a stop, through the sleep timer; nil plays on.
    public var minutes: Int?
    /// Plays a piece now and then from its time for `minutes`, while you're at the Mac, instead of starting by itself.
    public var whileHere = false
    /// While your calendar has something on, one that plays while you're here waits and one that starts by itself
    /// skips the day.
    public var heedsCalendar = false
    /// Plays one part of its collection each time, in turn: the collection's own parts, or `parts` cut by length.
    public var rotates = false
    public var parts = 4
    /// The part that plays next time, from 0.
    public var nextPart = 0
    /// The time it last went off for, or an hour's window it last started in, so a relaunch or a clock set back
    /// doesn't play it again.
    public var lastFired: Date?
    /// The `lastFired` that used up a part, so one window doesn't use up two.
    public var partSpent: Date?
    /// The last time it didn't go off and why, shown on its row that day.
    public var missed: Missed?
    /// Days it stays quiet, "2026-11-03" on the wall calendar, then comes back by itself. A time or window counts by
    /// the day it starts.
    public var daysOff: Set<String> = []

    public struct Missed: Codable, Equatable, Sendable {
        public enum Why: String, Codable, Sendable { case asleep, off, notRunning }
        public let at: Date
        public let why: Why

        /// "The Mac was off."
        public var reason: String {
            switch why {
            case .asleep: "The Mac was asleep."
            case .off: "The Mac was off."
            case .notRunning: "Sottova wasn't running."
            }
        }
    }

    public init(source: String, name: String, hour: Int, minute: Int, weekdays: Set<Int> = [], day: Date? = nil, shuffled: Bool = false) {
        self.source = source
        self.name = name
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.day = day
        self.shuffled = shuffled
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, name, hour, minute, weekdays, day, shuffled, on, volume, minutes, whileHere, heedsCalendar, rotates, parts, nextPart, lastFired, partSpent, missed, daysOff
    }

    // alarms.json from before alarms could be turned off has no `on`
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        name = try c.decode(String.self, forKey: .name)
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        weekdays = try c.decode(Set<Int>.self, forKey: .weekdays)
        day = try c.decodeIfPresent(Date.self, forKey: .day)
        shuffled = try c.decode(Bool.self, forKey: .shuffled)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        whileHere = try c.decodeIfPresent(Bool.self, forKey: .whileHere) ?? false
        // saved before it was a choice: those that play while you're here already waited for the calendar
        heedsCalendar = try c.decodeIfPresent(Bool.self, forKey: .heedsCalendar) ?? whileHere
        rotates = try c.decodeIfPresent(Bool.self, forKey: .rotates) ?? false
        parts = try c.decodeIfPresent(Int.self, forKey: .parts) ?? 4
        nextPart = try c.decodeIfPresent(Int.self, forKey: .nextPart) ?? 0
        lastFired = try c.decodeIfPresent(Date.self, forKey: .lastFired)
        partSpent = try c.decodeIfPresent(Date.self, forKey: .partSpent)
        missed = try c.decodeIfPresent(Missed.self, forKey: .missed)
        daysOff = try c.decodeIfPresent(Set<String>.self, forKey: .daysOff) ?? []
    }

    /// What you can set yourself, from `other`. Its id and what the app keeps about when it last went off stay.
    public mutating func setUserFields(from other: Alarm) {
        (source, name, hour, minute, weekdays, day) = (other.source, other.name, other.hour, other.minute, other.weekdays, other.day)
        (shuffled, on, volume, minutes, whileHere, heedsCalendar, rotates, parts) = (other.shuffled, other.on, other.volume, other.minutes, other.whileHere, other.heedsCalendar, other.rotates, other.parts)
        daysOff = other.daysOff
    }

    /// "2026-11-03": the key `daysOff` keeps a day under.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether the time or window starting at `start` falls on a day off.
    public func isOff(_ start: Date, calendar: Calendar = .current) -> Bool {
        !daysOff.isEmpty && daysOff.contains(Self.day(start, calendar: calendar))
    }

    /// Forgets days off that are over. Yesterday stays: a window from last night or a late alarm still belongs to it.
    public mutating func prune(now: Date = .now, calendar: Calendar = .current) {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return }
        let first = Self.day(yesterday, calendar: calendar)
        daysOff = daysOff.filter { $0 >= first }
    }

    /// The days off as runs of days in a row, soonest first, each day as its midnight.
    public func offRuns(calendar: Calendar = .current) -> [[Date]] {
        let days = daysOff.sorted().compactMap { key -> Date? in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        var runs: [[Date]] = []
        for day in days {
            if let last = runs.last?.last, let next = calendar.date(byAdding: .day, value: 1, to: last), calendar.isDate(next, inSameDayAs: day) {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        return runs
    }

    /// As if it had no days off: what a day off is named after, and the wakes it would need.
    public var withoutDaysOff: Alarm {
        var row = self
        row.daysOff = []
        return row
    }

    /// A one-off goes off at its time today if that's still ahead, otherwise tomorrow. It has no days off: one kept
    /// from when it repeated could fall on that day, and it would never play.
    public mutating func scheduleOnce(after now: Date = .now, calendar: Calendar = .current) {
        guard weekdays.isEmpty else { return }
        daysOff = []
        day = now
        // one that plays while you're there and is already under way is for now
        if next(after: now, calendar: calendar) == nil, !(whileHere && window(containing: now, calendar: calendar) != nil) {
            day = calendar.date(byAdding: .day, value: 1, to: now)
        }
    }

    /// Its time today, if that passed unheard with the app gone. `lastSaved` is when alarms.json last changed: nothing
    /// before it counts, or a row set at noon for 7:02 would be missed that morning. One only just passed isn't missed,
    /// it still goes off. A Mac that started after the time was off; one that didn't just didn't have the app open.
    public func missedWhileGone(lastSaved: Date, booted: Date, now: Date, lateness: TimeInterval, calendar: Calendar = .current) -> Missed? {
        guard on, !whileHere else { return nil }
        guard let at = times(after: max(lastSaved, calendar.startOfDay(for: now)), until: now - lateness + 1, calendar: calendar).last,
              at != lastFired, at != missed?.at else { return nil }
        return Missed(at: at, why: booted > at ? .off : .notRunning)
    }

    /// Every time it goes off after `now` and before `end`, soonest first.
    public func times(after now: Date, until end: Date, calendar: Calendar = .current) -> [Date] {
        var times: [Date] = []
        var from = now
        while let at = next(after: from, calendar: calendar), at < end {
            times.append(at)
            from = at
        }
        return times
    }

    /// The stretch that `now` falls in, from its time for its minutes, on a day it's set for; one that began
    /// yesterday evening can still be running.
    public func window(containing now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard let minutes else { return nil }
        for back in 0...1 {
            guard let base = calendar.date(byAdding: .day, value: -back, to: now),
                  let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { continue }
            let setFor = weekdays.isEmpty ? day.map { calendar.isDate($0, inSameDayAs: start) } ?? false
                                          : weekdays.contains(calendar.component(.weekday, from: start))
            if setFor, start <= now, now < start + Double(minutes) * 60, !isOff(start, calendar: calendar) {
                return DateInterval(start: start, duration: Double(minutes) * 60)
            }
        }
        return nil
    }

    /// The next time it goes off after `now`, or nil for a one-off that's past.
    public func next(after now: Date, calendar: Calendar = .current) -> Date? {
        if weekdays.isEmpty {
            guard let day, let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), date > now,
                  !isOff(date, calendar: calendar) else { return nil }
            return date
        }
        // the next 8 days always hold one of the chosen weekdays, and each day off can push it a week further
        for offset in 0..<(8 + 7 * daysOff.count) {
            guard let base = calendar.date(byAdding: .day, value: offset, to: now),
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { continue }
            if date > now, weekdays.contains(calendar.component(.weekday, from: date)), !isOff(date, calendar: calendar) { return date }
        }
        return nil
    }
}
