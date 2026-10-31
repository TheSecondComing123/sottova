import Foundation

/// For tests that set rows on the live clock.
enum LiveClock {
    /// An hour that isn't soon and didn't just pass, for a row fired by hand: one whose time passed in the last ten
    /// minutes also counts as due by itself.
    static var farHour: Int {
        Calendar.current.component(.hour, from: .now + 6 * 3600)
    }

    /// In the hour the clocks go back, and just before, a row set for a time near now means the first time that hour
    /// happened, an hour off, so a window can't be opened around now. DaylightSavingTests covers that hour on fixed dates.
    static func repeatsAnHour(at date: Date = .now, in zone: TimeZone = .current) -> Bool {
        guard let change = zone.nextDaylightSavingTimeTransition(after: date - 3600), change <= date + 300 else { return false }
        return zone.secondsFromGMT(for: change) < zone.secondsFromGMT(for: change - 1)
    }
}
