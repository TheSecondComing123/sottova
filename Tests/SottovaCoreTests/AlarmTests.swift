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
        let alarm = Alarm(source: "a", name: "A", hour: LiveClock.farHour, minute: 2, weekdays: Set(1...7))
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

/// Clocks in New York go back on 2026-11-01 (1:59 EDT, then 1:00 EST) and forward on 2027-03-14 (1:59 EST, then 3:00 EDT).
struct DaylightSavingTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    // 2026-11-01 and 2027-03-14 are Sundays
    private let lauds = Alarm(source: "a", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))

    private func row(_ hour: Int, _ minute: Int, minutes: Int? = nil, weekdays: Set<Int> = Set(1...7)) -> Alarm {
        var alarm = Alarm(source: "a", name: "A", hour: hour, minute: minute, weekdays: weekdays)
        alarm.minutes = minutes
        alarm.whileHere = minutes != nil
        return alarm
    }

    @Test func aWakeTimeKeepsItsClockTimeOverBothChanges() {
        #expect(lauds.next(after: utc("2026-10-31T22:00:00Z"), calendar: calendar) == utc("2026-11-01T12:02:00Z"))
        #expect(lauds.next(after: utc("2026-11-01T12:02:00Z"), calendar: calendar) == utc("2026-11-02T12:02:00Z"))
        #expect(lauds.next(after: utc("2027-03-13T22:00:00Z"), calendar: calendar) == utc("2027-03-14T11:02:00Z"))
        #expect(lauds.next(after: utc("2027-03-14T11:02:00Z"), calendar: calendar) == utc("2027-03-15T11:02:00Z"))
    }

    @Test func timesListsEachDayOnceOverBothChanges() {
        #expect(lauds.times(after: utc("2026-10-31T00:00:00Z"), until: utc("2026-11-03T00:00:00Z"), calendar: calendar)
            == [utc("2026-10-31T11:02:00Z"), utc("2026-11-01T12:02:00Z"), utc("2026-11-02T12:02:00Z")])
        #expect(lauds.times(after: utc("2027-03-13T00:00:00Z"), until: utc("2027-03-16T00:00:00Z"), calendar: calendar)
            == [utc("2027-03-13T12:02:00Z"), utc("2027-03-14T11:02:00Z"), utc("2027-03-15T11:02:00Z")])
    }

    @Test func aTimeThatHappensTwiceGoesOffTheFirstTimeOnly() {
        let late = row(1, 30)
        let times = late.times(after: utc("2026-11-01T00:00:00Z"), until: utc("2026-11-02T00:00:00Z"), calendar: calendar)
        #expect(times == [utc("2026-11-01T05:30:00Z")])
        // between the two 1:30s, and past the second
        #expect(late.next(after: utc("2026-11-01T05:45:00Z"), calendar: calendar) == utc("2026-11-02T06:30:00Z"))
        #expect(late.next(after: utc("2026-11-01T06:45:00Z"), calendar: calendar) == utc("2026-11-02T06:30:00Z"))
    }

    @Test func aTimeThatDoesntHappenGoesOffAtThreeAndOnce() {
        let late = row(2, 30)
        let times = late.times(after: utc("2027-03-14T00:00:00Z"), until: utc("2027-03-15T12:00:00Z"), calendar: calendar)
        #expect(times == [utc("2027-03-14T07:00:00Z"), utc("2027-03-15T06:30:00Z")])
    }

    @Test func aWindowAcrossTwoIsItsMinutesLongInRealTime() {
        // 23:00 for four hours: back an hour on the way through, so it ends at 2:00 on the clock
        let back = row(23, 0, minutes: 240)
        let start = utc("2026-11-01T03:00:00Z")
        #expect(back.window(containing: utc("2026-11-01T05:30:00Z"), calendar: calendar)?.start == start)
        #expect(back.window(containing: utc("2026-11-01T06:30:00Z"), calendar: calendar)?.start == start)
        #expect(back.window(containing: utc("2026-11-01T06:59:00Z"), calendar: calendar)?.start == start)
        #expect(back.window(containing: utc("2026-11-01T07:00:00Z"), calendar: calendar) == nil)
        // forward an hour, so it ends at 4:00 on the clock
        let forward = row(23, 0, minutes: 240)
        let night = utc("2027-03-14T04:00:00Z")
        #expect(forward.window(containing: utc("2027-03-14T07:30:00Z"), calendar: calendar)?.start == night)
        #expect(forward.window(containing: utc("2027-03-14T08:00:00Z"), calendar: calendar) == nil)
    }

    @Test func aWindowStartingInTheHourThatHappensTwiceStartsTheFirstTime() {
        let late = row(1, 30, minutes: 60)
        let start = utc("2026-11-01T05:30:00Z")
        #expect(late.window(containing: utc("2026-11-01T05:29:00Z"), calendar: calendar) == nil)
        #expect(late.window(containing: utc("2026-11-01T05:45:00Z"), calendar: calendar)?.start == start)
        #expect(late.window(containing: utc("2026-11-01T06:29:00Z"), calendar: calendar)?.start == start)
        #expect(late.window(containing: utc("2026-11-01T06:30:00Z"), calendar: calendar) == nil)
    }

    @Test func theTestsThatStandAsideDoSoOnlyWhileTheHourRepeats() {
        let newYork = calendar.timeZone
        #expect(!LiveClock.repeatsAnHour(at: utc("2026-11-01T05:30:00Z"), in: newYork))
        #expect(LiveClock.repeatsAnHour(at: utc("2026-11-01T05:58:00Z"), in: newYork))
        #expect(LiveClock.repeatsAnHour(at: utc("2026-11-01T06:30:00Z"), in: newYork))
        #expect(!LiveClock.repeatsAnHour(at: utc("2026-11-01T07:01:00Z"), in: newYork))
        #expect(!LiveClock.repeatsAnHour(at: utc("2027-03-14T07:30:00Z"), in: newYork))
    }

    @Test func aWindowStartingInTheHourThatDoesntHappenStartsAtThree() {
        let late = row(2, 30, minutes: 60)
        #expect(late.window(containing: utc("2027-03-14T07:15:00Z"), calendar: calendar)?.start == utc("2027-03-14T07:00:00Z"))
        #expect(late.window(containing: utc("2027-03-14T08:00:00Z"), calendar: calendar) == nil)
    }

    @Test func theDayOfAWindowAcrossMidnightIsTheDayItStarted() {
        // Saturdays only: Saturday night into the Sunday the clocks change, and not the next night
        let saturday = row(23, 0, minutes: 240, weekdays: [7])
        #expect(saturday.window(containing: utc("2026-11-01T05:30:00Z"), calendar: calendar) != nil)
        #expect(saturday.window(containing: utc("2026-11-02T05:30:00Z"), calendar: calendar) == nil)
    }
}

struct AlarmOrderTests {
    private func song(_ path: String) -> Song {
        Song(id: path, title: path, work: path, detail: nil, artist: "", album: "Lauds", albumID: "Lauds", albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: path)
    }

    @Test func aShuffledAlarmNeverOpensWithYesterdaysFirstPiece() {
        let calendar = Calendar(identifier: .gregorian)
        let songs = (1...10).map { song("/Lauds/\($0).flac") }
        let alarm = Alarm(source: "Lauds", name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6])
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 7, minute: 2))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: due)!
        let history = [
            PlayRecord(file: "/Lauds/1.flac", startedAt: yesterday + 1, skipped: false, gapAfterSec: 200, heardSec: 453),
            // later that morning, not an opening
            PlayRecord(file: "/Lauds/2.flac", startedAt: yesterday + 757, skipped: true, gapAfterSec: 0, heardSec: 84),
        ]
        var rng = SplitMix64(seed: 7)
        var openers = Set<String>()
        for _ in 0..<500 {
            let order = Controller.alarmOrder(songs, at: alarm, due: due, history: history, calendar: calendar, using: &rng)
            #expect(Set(order) == Set(songs))
            openers.insert(order[0].id)
        }
        #expect(!openers.contains("/Lauds/1.flac"))
        // still a shuffle: every other piece gets to open
        #expect(openers.count == 9)
    }

    @Test func withNothingElseLeftItStillPlays() {
        let only = [song("/Lauds/1.flac")]
        let alarm = Alarm(source: "Lauds", name: "Lauds", hour: 7, minute: 2)
        let due = Date(timeIntervalSince1970: 1_793_000_000)
        let then = Calendar.current.date(bySettingHour: 7, minute: 2, second: 0, of: due - 86_400)!
        var rng = SplitMix64(seed: 1)
        let order = Controller.alarmOrder(only, at: alarm, due: due, history: [PlayRecord(file: "/Lauds/1.flac", startedAt: then,
                                                                                            skipped: false, gapAfterSec: 0)], using: &rng)
        #expect(order.map(\.id) == ["/Lauds/1.flac"])
    }

    /// Otherwise the next launch drops it for being past.
    @Test @MainActor func anEditedOneOffGetsATimeStillAhead() {
        let c = Controller(storage: nil)
        var once = Alarm(source: "a", name: "A", hour: 7, minute: 2, day: .now + 86_400)
        c.addAlarm(once)
        once.day = .now - 3 * 86_400
        c.changeAlarm(once.id) { $0 = once }
        #expect(c.alarms[0].next(after: .now) != nil)
    }

    @Test func anEditKeepsWhatTheAppKeepsAboutTheRow() {
        var row = Alarm(source: "a", name: "A", hour: 7, minute: 2, weekdays: [2])
        (row.lastFired, row.partSpent, row.nextPart) = (.now, .now, 2)
        var edited = Alarm(source: "b", name: "B", hour: 8, minute: 3, weekdays: [3])
        (edited.volume, edited.rotates, edited.on) = (0.2, true, false)
        let kept = (row.id, row.lastFired, row.partSpent, row.nextPart)
        row.setUserFields(from: edited)
        #expect((row.source, row.name, row.hour, row.minute, row.weekdays) == ("b", "B", 8, 3, [3]))
        #expect(row.volume == 0.2 && row.rotates && !row.on)
        #expect(row.id == kept.0 && row.lastFired == kept.1 && row.partSpent == kept.2 && row.nextPart == kept.3)
    }

    @Test func whatCountsAsMissedWhileGone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let at = { (day: Int, hour: Int, minute: Int) in calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
        let row = Alarm(source: "a", name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6])
        let missed = { (saved: Date, booted: Date, now: Date, row: Alarm) in
            row.missedWhileGone(lastSaved: saved, booted: booted, now: now, lateness: 600, calendar: calendar)
        }
        let due = at(2, 7, 2)
        #expect(missed(at(1, 20, 0), at(1, 8, 0), at(2, 8, 0), row) == Alarm.Missed(at: due, why: .notRunning))
        #expect(missed(at(1, 20, 0), at(2, 7, 30), at(2, 8, 0), row) == Alarm.Missed(at: due, why: .off))
        // set after its time this morning
        #expect(missed(at(2, 7, 30), at(1, 8, 0), at(2, 8, 0), row) == nil)
        // still in time to go off
        #expect(missed(at(1, 20, 0), at(1, 8, 0), at(2, 7, 5), row) == nil)
        // before it
        #expect(missed(at(1, 20, 0), at(1, 8, 0), at(2, 6, 0), row) == nil)
        // yesterday's isn't today's: Monday's, at Tuesday noon, was never on this row's today
        #expect(missed(at(2, 8, 0), at(1, 8, 0), at(3, 6, 0), row) == nil)
        var played = row
        played.lastFired = due
        #expect(missed(at(1, 20, 0), at(1, 8, 0), at(2, 8, 0), played) == nil)
        var off = row
        off.on = false
        #expect(missed(at(1, 20, 0), at(1, 8, 0), at(2, 8, 0), off) == nil)
        var here = row
        here.whileHere = true
        #expect(missed(at(1, 20, 0), at(1, 8, 0), at(2, 8, 0), here) == nil)
    }

    @Test func aMissSurvivesBeingSaved() throws {
        var row = Alarm(source: "a", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        row.missed = Alarm.Missed(at: Date(timeIntervalSince1970: 1_000), why: .off)
        let back = try JSONDecoder().decode(Alarm.self, from: JSONEncoder().encode(row))
        #expect(back.missed == row.missed)
        #expect(back.missed?.reason == "The Mac was off.")
    }
}
