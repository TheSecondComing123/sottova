import Foundation
import Testing
@testable import SottovaCore

struct DayPlanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// November 2026: the 2nd is a Monday. The clocks go back on the 1st.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private var lauds: Alarm {
        var row = Alarm(source: "lauds", name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6])
        row.volume = 0.25
        return row
    }

    private var overworld: Alarm {
        var row = Alarm(source: "overworld", name: "Overworld", hour: 15, minute: 0, weekdays: Set(1...7))
        (row.whileHere, row.minutes) = (true, 240)
        return row
    }

    private var compline: Alarm {
        var row = Alarm(source: "compline", name: "Compline", hour: 20, minute: 0, weekdays: Set(1...7))
        row.minutes = 60
        return row
    }

    /// The facts a line carries, so a change of wording doesn't break what it's checking.
    private func says(_ line: String?, _ facts: String...) -> Bool { facts.allSatisfy { line?.contains($0) == true } }

    private func plan(_ alarms: [Alarm], _ now: Date, lengths: [Alarm.ID: TimeInterval] = [:], twelveHour: Bool = true, wholeDay: Bool = false) -> DayPlan {
        DayPlan(alarms: alarms, now: now, lengths: lengths, calendar: calendar, twelveHour: twelveHour, wholeDay: wholeDay)
    }

    @Test func todaysRowsComeInOrderAndOnlyToday() {
        let monday = plan([compline, lauds, overworld], date(2, 12))
        #expect(monday.rows.map(\.alarm.name) == ["Lauds", "Overworld", "Compline"])
        #expect(monday.rows[1].start == date(2, 15) && monday.rows[1].end == date(2, 19))
        let sunday = plan([compline, lauds, overworld], date(8, 12))
        #expect(sunday.rows.map(\.alarm.name) == ["Overworld", "Compline"])
    }

    @Test func aRowTurnedOffStaysOnTheDayButIsNoNextOne() {
        var off = overworld
        off.on = false
        let day = plan([off, compline], date(2, 12))
        #expect(day.rows.map(\.alarm.name) == ["Overworld", "Compline"])
        #expect(day.quiet().line == "Compline at 8.")
    }

    @Test func aRowWithNoEndIsAsLongAsItsCollection() {
        let row = lauds
        let day = plan([row], date(2, 12), lengths: [row.id: 69 * 60])
        #expect(day.rows[0].end == date(2, 8, 11))
        #expect(plan([row], date(2, 12)).rows[0].end == date(2, 7, 2))
    }

    @Test func aOneOffIsOnlyOnItsDay() {
        let once = Alarm(source: "x", name: "Once", hour: 9, minute: 0, day: date(3, 0))
        #expect(plan([once], date(2, 8)).rows.isEmpty)
        #expect(plan([once], date(3, 8)).rows.map(\.alarm.name) == ["Once"])
    }

    @Test func oneRunningFromLastNightIsOnTodayAndThePlanReachesMidnight() {
        var late = Alarm(source: "x", name: "Late", hour: 23, minute: 0, weekdays: [2])
        late.minutes = 180
        let night = plan([late], date(3, 0, 30))
        #expect(night.rows.map(\.alarm.name) == ["Late"])
        #expect(night.position(of: night.rows[0].start) == 0)
        let evening = plan([late], date(2, 12))
        #expect(evening.lastHour == 24)
        #expect(evening.position(of: evening.rows[0].end) == 1)
    }

    @Test func theRailRunsFromTheFirstRowToTheLast() {
        let day = plan([overworld], date(2, 12))
        #expect((day.firstHour, day.lastHour) == (15, 19))
        #expect(day.position(of: date(2, 15)) == 0)
        #expect(day.position(of: date(2, 17)) == 0.5)
        #expect(day.position(of: date(2, 19)) == 1)
        #expect(day.position(of: date(2, 23)) == 1)
        let row = lauds
        let full = plan([row, overworld, compline], date(2, 12), lengths: [row.id: 69 * 60])
        #expect((full.firstHour, full.lastHour) == (7, 21))
    }

    @Test func aPartHourRoundsOutward() {
        var row = Alarm(source: "x", name: "Row", hour: 4, minute: 30, weekdays: Set(1...7))
        row.minutes = 15
        #expect({ let day = plan([row], date(2, 12)); return (day.firstHour, day.lastHour) }() == (4, 5))
    }

    @Test func aRowWithNoLengthStillHasAnHour() {
        let row = Alarm(source: "x", name: "Row", hour: 9, minute: 0, weekdays: Set(1...7))
        let day = plan([row], date(2, 12))
        #expect((day.firstHour, day.lastHour) == (9, 10))
        #expect(day.position(of: date(2, 9)) == 0)
    }

    @Test func oneFromLastNightStartsTheRailAtMidnight() {
        var late = Alarm(source: "x", name: "Late", hour: 23, minute: 0, weekdays: [2])
        late.minutes = 180
        let day = plan([late, overworld], date(3, 0, 30))
        #expect((day.firstHour, day.lastHour) == (0, 19))
        #expect(abs(day.rail.marks[0].bar.upperBound - 2 * DayPlan.Rail.hourHeight) < 0.01)
    }

    @Test func anEmptyDayAndADragGetTheWholeDay() {
        let empty = plan([], date(2, 12))
        #expect((empty.firstHour, empty.lastHour) == (6, 22))
        let dragging = plan([overworld], date(2, 12), wholeDay: true)
        #expect((dragging.firstHour, dragging.lastHour) == (6, 22))
        var early = Alarm(source: "x", name: "Early", hour: 4, minute: 30, weekdays: Set(1...7))
        early.minutes = 15
        var late = Alarm(source: "y", name: "Late", hour: 22, minute: 30, weekdays: Set(1...7))
        late.minutes = 15
        let wider = plan([early, late], date(2, 12), wholeDay: true)
        #expect((wider.firstHour, wider.lastHour) == (4, 23))
    }

    @Test func theNowDotIsOnlyOnTheRail() {
        #expect(plan([overworld], date(2, 16)).rail.now != nil)
        #expect(plan([overworld], date(2, 12)).rail.now == nil)
        #expect(plan([overworld], date(2, 19, 30)).rail.now == nil)
    }

    @Test func theRailReadsTheClockOnTheDayItChanges() {
        let day = plan([], date(1, 12))
        #expect(day.position(of: date(1, 14)) == 0.5)
    }

    @Test func theLaterOfTwoOverlappingRowsSaysItHasTheTime() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
        (chopin.whileHere, chopin.minutes) = (true, 60)
        let day = plan([overworld, chopin, compline], date(2, 12))
        #expect(day.rows[0].overlapNote == nil)
        #expect(day.rows[1].overlapNote == "Overlaps Overworld. This one plays, Overworld waits.")
        #expect(day.rows[2].overlapNote == nil)
        var off = overworld
        off.on = false
        #expect(plan([off, chopin], date(2, 12)).rows[1].overlapNote == nil)
    }

    @Test func whatSoundingLeadsTo() {
        #expect(plan([lauds, overworld, compline], date(2, 15, 40)).foot(sounding: overworld) == "Overworld until 7, then Compline at 8.")
        #expect(says(plan([lauds, overworld, compline], date(2, 20, 5)).foot(sounding: compline), "Compline", "until 9", "Lauds", "7:02"))
        #expect(says(plan([lauds, overworld, compline], date(2, 7, 5)).foot(sounding: lauds), "Lauds", "7:02", "until 3"))
        #expect(says(plan([overworld], date(2, 15, 40)).foot(sounding: overworld), "Overworld", "until 7", "at 3"))
        let once = Alarm(source: "x", name: "Once", hour: 9, minute: 5, day: date(2, 0))
        #expect(plan([once], date(2, 9, 6)).foot(sounding: once) == "Once at 9:05.")
    }

    @Test func aFarDayIsNamed() {
        #expect(says(plan([lauds, compline], date(6, 20, 5)).foot(sounding: compline), "until 9", "Compline at 8"))
        #expect(says(plan([lauds], date(6, 7, 5)).foot(sounding: lauds), "Lauds", "7:02", "Monday"))
    }

    @Test func whatNowSaysInSilenceOfTheDay() {
        #expect(plan([], date(2, 12)).quiet() == .init(headline: "Nothing on your day", line: "Press play.", foot: nil))
        #expect(plan([lauds, overworld, compline], date(2, 12)).quiet() == .init(headline: "Nothing on yet", line: "Overworld at 3.", foot: nil))
        #expect(plan([lauds, overworld, compline], date(2, 22)).quiet(wakeScheduled: true) == .init(headline: "The day is done", line: "Lauds at 7:02 tomorrow.", foot: "The Mac will wake for it."))
        #expect(plan([lauds], date(2, 22)).quiet().foot == nil)
        #expect(plan([overworld], date(2, 22)).quiet(wakeScheduled: true).foot == nil)
        #expect(plan([lauds], date(8, 12)).quiet(wakeScheduled: true) == .init(headline: "Nothing on today", line: "Lauds at 7:02 tomorrow.", foot: "The Mac will wake for it."))
        #expect(plan([lauds], date(7, 12)).quiet().line == "Lauds at 7:02 Monday.")
    }

    @Test func sidebarLabels() {
        let day = plan([lauds, overworld, compline], date(2, 15, 40))
        #expect(day.label(of: "lauds") == "7:02")
        #expect(day.label(of: "overworld") == "till 7")
        #expect(day.label(of: "compline") == "8 PM")
        #expect(day.label(of: "other") == nil)
        #expect(plan([overworld], date(2, 12)).label(of: "overworld") == "3 PM")
        #expect(plan([overworld], date(2, 12), twelveHour: false).label(of: "overworld") == "15:00")
        var off = compline
        off.on = false
        #expect(day.label(of: "x") == nil && plan([off], date(2, 12)).label(of: "compline") == nil)
    }

    @Test func theSidebarGoesInDayOrder() {
        let day = plan([compline, lauds, overworld], date(2, 12))
        #expect(day.inDayOrder(["shellac", "compline", "counterpoint", "overworld", "lauds"]) == ["lauds", "overworld", "compline", "shellac", "counterpoint"])
    }

    @Test func aMissTodayIsSaidAndYesterdaysIsnt() {
        var row = lauds
        row.missed = Alarm.Missed(at: date(2, 7, 2), why: .off)
        let today = plan([row, overworld], date(2, 12))
        #expect(today.missedToday(row) == "Missed at 7:02. The Mac was off.")
        #expect(today.quiet().foot == "Missed Lauds at 7:02. The Mac was off.")
        #expect(today.quiet().line == "Overworld at 3.")
        let tomorrow = plan([row, overworld], date(3, 12))
        #expect(tomorrow.missedToday(row) == nil)
        #expect(tomorrow.quiet().foot == nil)
    }

    @Test func backToBackRowsFollowEachOther() {
        var next = compline
        next.hour = 19
        #expect(says(plan([overworld, next], date(2, 15, 40)).foot(sounding: overworld), "until 7", "Compline at 7"))
    }

    @Test func twoRowsStartingTogetherDontBothClaimTheTime() {
        var twin = overworld
        twin.name = "Twin"
        let notes = plan([overworld, twin], date(2, 12)).rows.map(\.overlapNote)
        #expect(notes.compactMap { $0 }.count == 1)
    }

    private func plan(_ rows: [Alarm]) -> DayPlan {
        DayPlan(alarms: rows, now: date(2, 9), calendar: calendar, twelveHour: true)
    }

    @Test func hoursInTheGridAndOnThePage() {
        var compline = Alarm(source: "compline", name: "Compline", hour: 20, minute: 0, weekdays: Set(1...7))
        (compline.volume, compline.minutes) = (0.15, 60)
        var noon = Alarm(source: "noon", name: "Noon", hour: 11, minute: 30, weekdays: [1, 7])
        noon.minutes = 90
        var off = Alarm(source: "off", name: "Off", hour: 9, minute: 0, weekdays: Set(1...7))
        off.on = false
        let day = plan([lauds, overworld, compline, noon, off])
        #expect(day.shortHours(of: "lauds") == "7:02 weekdays")
        #expect(says(day.shortHours(of: "overworld"), "3", "7 PM"))
        #expect(day.hours(of: "compline") == "Every day, 8 to 9 PM, at 15%")
        #expect(says(day.hours(of: "lauds"), "Weekdays", "7:02", "25%"))
        #expect(says(day.hours(of: "noon"), "Weekends", "11:30", "1 PM"))
        let eight = Alarm(source: "eight", name: "Eight", hour: 20, minute: 0, weekdays: Set(1...7))
        #expect(says(plan([eight]).shortHours(of: "eight"), "8 PM", "every day"))
        #expect(day.hours(of: "off") == nil)
        #expect(day.shortHours(of: "nothing") == nil)
    }

    private func text(_ pieces: [DayPlan.Piece]) -> String { pieces.map(\.text).joined() }

    @Test func rowsSayTheirWords() {
        var morning = lauds
        morning.shuffled = true
        morning.rotates = true
        let day = plan([morning, overworld, compline], date(2, 12))
        #expect(text(day.sentence(morning, nextPart: "Strings")) == "Weekdays, shuffled, at 25%. Strings next.")
        var here = overworld
        (here.shuffled, here.heedsCalendar) = (true, true)
        #expect(says(text(day.sentence(here, nextPart: nil)), "at the Mac", "shuffled", "busy"))
        var evening = compline
        (evening.volume, evening.rotates) = (0.15, true)
        #expect(says(text(day.sentence(evening, nextPart: "part 2")), "Every day", "15%", "Part 2"))
        var plain = compline
        plain.volume = nil
        #expect(says(text(day.sentence(plain, nextPart: nil)), "Every day", "in order"))
        var some = overworld
        some.weekdays = [2, 3, 4, 5, 6]
        #expect(says(text(day.sentence(some, nextPart: nil)), "Weekdays", "at the Mac", "in order"))
        #expect(day.sentence(here, nextPart: nil).compactMap(\.word) == [.days, .order, .calendar])
    }

    @Test func whatsHappeningTakesTheLine() {
        var morning = lauds
        morning.shuffled = true
        morning.missed = Alarm.Missed(at: date(2, 7, 2), why: .off)
        let day = plan([morning, overworld], date(2, 12))
        let row = day.rows[0]
        #expect(text(day.line(for: row, nextPart: nil)) == "Missed at 7:02. The Mac was off. Play it now")
        #expect(day.line(for: row, nextPart: nil).last?.word == .playNow)
        #expect(says(text(day.line(for: row, nextPart: nil, rising: true)), "Rising", "25%", "shuffled"))
        #expect(says(text(day.line(for: day.rows[1], nextPart: nil, waiting: .call)), "Waiting", "call"))
        #expect(text(day.line(for: day.rows[1], nextPart: nil, cantWake: true)) == "The Mac won't wake for this. Wake it")
        // a miss today mustn't hide that the next one can't wake either
        #expect(text(day.line(for: row, nextPart: nil, cantWake: true)) == "Missed at 7:02. The Mac was off. Play it now. The Mac won't wake for the next one. Wake it")
        #expect(text(day.wakeLine(alarm: overworld, nextPart: nil, cantWake: true)) == "The Mac won't wake for this. Wake it")
        #expect(says(text(day.wakeLine(alarm: overworld, nextPart: nil, cantWake: false)), "at the Mac", "in order"))
    }

    @Test func anOverlapIsAddedToTheRowsWords() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
        (chopin.whileHere, chopin.minutes, chopin.shuffled) = (true, 60, true)
        let day = plan([overworld, chopin], date(2, 12))
        let line = day.line(for: day.rows[1], nextPart: nil)
        #expect(says(text(line), "at the Mac", "shuffled", "Overworld"))
        #expect(line.compactMap(\.word) == [.days, .order])
    }

    @Test func anOverlapWrapsWordByWordAndTheNextRowLeavesRoom() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
        (chopin.whileHere, chopin.minutes) = (true, 60)
        var soon = compline
        soon.hour = 18
        let day = plan([overworld, chopin, soon], date(2, 12))
        #expect(day.line(for: day.rows[1], nextPart: nil).filter { $0.text.contains("Overlaps") }.map(\.text) == ["Overlaps "])
        let marks = day.rail.marks
        #expect(marks[2].top >= marks[1].bottom)
        #expect(day.rail.height >= marks[2].top + DayPlan.Rail.rowHeight)
    }

    @Test func aLastRowWithAnOverlapKeepsItsSecondLineOnTheRail() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 18, minute: 0, weekdays: Set(1...7))
        chopin.minutes = 30
        let rail = plan([overworld, chopin], date(2, 12)).rail
        #expect(rail.height >= rail.marks[1].bottom)
    }

    @Test func theRailIsToScale() {
        let morning = lauds
        let rail = plan([morning, overworld, compline], date(2, 15, 40), lengths: [morning.id: 69 * 60]).rail
        let scale = DayPlan.Rail.hourHeight
        #expect(rail.height >= rail.marks[2].bottom)
        // the rail starts at 7: Lauds runs 7:02 to 8:11, Overworld 3 to 7, and it's 3:40
        #expect(abs(rail.marks[0].bar.lowerBound - 2.0 / 60 * scale) < 0.01)
        #expect(abs(rail.marks[0].bar.upperBound - 71.0 / 60 * scale) < 0.01)
        #expect(rail.marks[1].bar == 8 * scale...12 * scale)
        #expect(rail.marks[2].top >= rail.marks[1].bottom)
        #expect(abs(rail.now! - 26.0 / 3 * scale) < 0.01)
        #expect(rail.labels.map(\.text) == ["7:02 AM", "8:11", "noon", "3 PM", "3:40", "7 PM", "8 PM", "9 PM"])
    }

    @Test func wordsMakeRoomButBarsDont() {
        var soon = lauds
        (soon.hour, soon.minute, soon.id) = (7, 30, UUID())
        let rail = plan([lauds, soon], date(2, 12)).rail
        #expect(rail.marks[1].top >= rail.marks[0].bottom)
        #expect(rail.marks[1].bar.lowerBound == 12)
        // a time's label goes where its words went
        #expect(rail.labels.contains { $0.text == "7:30 AM" && abs($0.y - rail.marks[1].top - 11) < 0.01 })
    }

    @Test func aRowsTimeBeatsTheFrameAndTheNow() {
        let rail = plan([lauds, overworld], date(2, 7, 3)).rail
        #expect(rail.now != nil)
        #expect(!rail.labels.contains { $0.text == "7:03" })
        #expect(rail.labels.contains { $0.text == "7:02 AM" })
    }

    @Test func anEmptyDayShowsItsHours() {
        let rail = plan([], date(2, 15, 40)).rail
        #expect(rail.labels.map(\.text) == ["6 AM", "9", "noon", "3", "3:40", "6", "9", "10 PM"])
    }

    @Test func aDropLandsOnAnHourThatFitsTwo() {
        let day = plan([lauds], date(2, 12), wholeDay: true)
        #expect(day.hour(at: 100) == 10)
        #expect(day.hour(at: -5) == 6)
        #expect(day.hour(at: 9999) == 20)
        #expect(day.dropLabel(hour: 10).span == "10 AM to noon")
    }

    @Test func aTwentyFourHourClockHasNoHalves() {
        let rail = plan([overworld], date(2, 15, 40), twelveHour: false).rail
        #expect(rail.labels.map(\.text) == ["15:00", "15:40", "19:00"])
    }
}
