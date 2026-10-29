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

    @Test func anAlarmThatsOffNeverComesNext() {
        let c = Controller(storage: nil)
        var off = Alarm(source: "a", name: "A", hour: 7, minute: 2, weekdays: Set(1...7))
        off.on = false
        c.addAlarm(off)
        c.addAlarm(Alarm(source: "b", name: "B", hour: 8, minute: 0, weekdays: Set(1...7)))
        #expect(c.nextAlarm()?.alarm.name == "B")
    }

    @Test func savedAlarmsWithoutOnDecodeAsOn() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","source":"a","name":"A","hour":7,"minute":2,"weekdays":[],"shuffled":false}]"#
        let alarms = try JSONDecoder().decode([Alarm].self, from: Data(json.utf8))
        #expect(alarms.first?.on == true)
    }

    @Test func aOneOffIsScheduledTodayOrTomorrow() {
        var alarm = Alarm(source: "a", name: "A", hour: 7, minute: 2)
        alarm.scheduleOnce(after: date(2026, 10, 29, 6, 0), calendar: calendar)
        #expect(alarm.next(after: date(2026, 10, 29, 6, 0), calendar: calendar) == date(2026, 10, 29, 7, 2))
        alarm.scheduleOnce(after: date(2026, 10, 29, 7, 8), calendar: calendar)
        #expect(alarm.next(after: date(2026, 10, 29, 7, 8), calendar: calendar) == date(2026, 10, 30, 7, 2))
    }

    @Test func anAlarmMoreThanTenMinutesLateStaysQuiet() {
        let c = Controller(storage: nil)
        let alarm = Alarm(source: "a", name: "A", hour: 7, minute: 2, weekdays: Set(1...7))
        c.addAlarm(alarm)
        let due = Date.now.addingTimeInterval(-11 * 60)
        c.fire(alarm.id, due: due)
        #expect(c.problem?.hasPrefix("the A alarm didn't play") == true)
        #expect(c.status == .idle)
    }

    @Test func timesListsEveryWeekdayInTheWindow() {
        let alarm = Alarm(source: "a", name: "A", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6])
        // Thu 10/29 08:00 to Thu 11/5 08:00: Fri, Mon, Tue, Wed, Thu
        let times = alarm.times(after: date(2026, 10, 29, 8, 0), until: date(2026, 11, 5, 8, 0), calendar: calendar)
        #expect(times == [date(2026, 10, 30, 7, 2), date(2026, 11, 2, 7, 2), date(2026, 11, 3, 7, 2), date(2026, 11, 4, 7, 2), date(2026, 11, 5, 7, 2)])
    }
}
