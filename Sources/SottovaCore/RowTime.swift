import Foundation

/// What the row sheet's time fields store: only the clock, whatever day and seconds their dates carry.
public enum RowTime {
    public static func clock(_ date: Date, calendar: Calendar = .current) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 7, parts.minute ?? 0)
    }

    /// From the start to the end around the clock, so 10 PM to 1 AM is three hours; the same time both ways is a whole day.
    public static func span(from start: Date, until end: Date, calendar: Calendar = .current) -> Int {
        let minutes = { (date: Date) in
            let clock = clock(date, calendar: calendar)
            return clock.hour * 60 + clock.minute
        }
        let span = (minutes(end) - minutes(start) + 1440) % 1440
        return span == 0 ? 1440 : span
    }
}
