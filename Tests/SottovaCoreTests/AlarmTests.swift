import Foundation
import Testing
@testable import SottovaCore

@MainActor
struct AlarmTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func aOneOffGoesOffOnItsDayThenNever() {
        let alarm = Alarm(source: "lauds", name: "Lauds", hour: 7, minute: 2, day: date(2026, 10, 29, 0, 0))
        #expect(alarm.next(after: date(2026, 10, 28, 21, 55), calendar: calendar) == date(2026, 10, 29, 7, 2))
        #expect(alarm.next(after: date(2026, 10, 29, 7, 3), calendar: calendar) == nil)
    }

    @Test func weekdaysSkipToTheNextChosenDay() {
        // Mon–Fri; 2026-10-30 is a Friday
        let alarm = Alarm(source: "lauds", name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6])
        #expect(alarm.next(after: date(2026, 10, 30, 6, 0), calendar: calendar) == date(2026, 10, 30, 7, 2))
        #expect(alarm.next(after: date(2026, 10, 30, 8, 0), calendar: calendar) == date(2026, 11, 2, 7, 2))
    }

    @Test func alarmsAreSavedAndPastOneOffsDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-alarms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: dir)
        c.addAlarm(Alarm(source: "a", name: "A", hour: 7, minute: 2, day: .now.addingTimeInterval(86_400)))
        c.addAlarm(Alarm(source: "b", name: "B", hour: 7, minute: 2, day: .now.addingTimeInterval(-3 * 86_400)))
        let reopened = Controller(storage: dir)
        reopened.run()
        #expect(reopened.alarms.map(\.name) == ["A"])
    }
}
