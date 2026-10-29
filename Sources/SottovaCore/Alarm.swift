import Foundation

/// Starts an album or playlist at a time of day: once on a given day, or on chosen weekdays.
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
        case id, source, name, hour, minute, weekdays, day, shuffled, on
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
    }

    /// A one-off goes off at its time today if that's still ahead, otherwise tomorrow.
    public mutating func scheduleOnce(after now: Date = .now, calendar: Calendar = .current) {
        guard weekdays.isEmpty else { return }
        day = now
        if next(after: now, calendar: calendar) == nil { day = calendar.date(byAdding: .day, value: 1, to: now) }
    }

    /// The next time it goes off after `now`, or nil for a one-off that's past.
    public func next(after now: Date, calendar: Calendar = .current) -> Date? {
        if weekdays.isEmpty {
            guard let day, let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), date > now else { return nil }
            return date
        }
        // the next 8 days always hold one of the chosen weekdays
        for offset in 0..<8 {
            guard let base = calendar.date(byAdding: .day, value: offset, to: now),
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { continue }
            if date > now, weekdays.contains(calendar.component(.weekday, from: date)) { return date }
        }
        return nil
    }
}
