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

    public init(source: String, name: String, hour: Int, minute: Int, weekdays: Set<Int> = [], day: Date? = nil, shuffled: Bool = false) {
        self.source = source
        self.name = name
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.day = day
        self.shuffled = shuffled
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
