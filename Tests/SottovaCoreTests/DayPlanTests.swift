import Foundation
import Testing
@testable import SottovaCore

struct DayPlanTests {
    @Test func aMovedWindowEndDoesNotCollideWithTheNextRowsStart() {
        let day = ownersDay
        let rail = day.rail(hourHeight: 34)
        let window = day.rows.first { $0.alarm.name == "Overworld" }!
        let evening = day.rows.first { $0.alarm.name == "Compline" }!
        let target = rail.marks.first { $0.id == evening.id }!.bar.lowerBound
        let moving = DayPlan.Rail.Label(text: "4 PM", y: rail.position(day.y(minute: 16 * 60, hourHeight: 34)), kind: .row, row: window.id)
        let labels = rail.drawingLabels(adjustedBy: { label in
            label.row == window.id && label.kind == .end ? DayPlan.Rail.Label(text: "8 PM", y: target, kind: .end, row: window.id) : nil
        }, moving: moving)
        let atEight = labels.filter { abs($0.y - target) < 15 }
        #expect(atEight.count == 1)
        #expect(atEight.first?.row == evening.id)
        #expect(atEight.first?.kind == .row)
        let resized = rail.drawingLabels(adjustedBy: { _ in nil }, moving: DayPlan.Rail.Label(text: "8 PM", y: target, kind: .end, row: window.id))
        let atResizedEnd = resized.filter { abs($0.y - target) < 15 }
        #expect(atResizedEnd.count == 1)
        #expect(atResizedEnd.first?.row == evening.id)
        #expect(atResizedEnd.first?.kind == .row)
    }

    @Test func rowsStartingTogetherShareTheirRealClockPoint() {
        var first = lauds
        first.minute = 0
        var second = first
        second.id = UUID()
        let day = plan([first, second], date(2, 8))
        let rail = day.rail(hourHeight: 34)
        let starts = rail.labels.filter { $0.kind == .row || $0.kind == .off }
        #expect(starts.count == 1)
        for label in starts {
            #expect(day.minute(at: rail.time(at: label.y), hourHeight: 34, snap: 1) == 7 * 60)
        }
        for mark in rail.marks {
            #expect(day.hour(at: rail.dropTime(at: (mark.block.lowerBound + mark.block.upperBound) / 2), hourHeight: 34) == 7)
        }
    }

    @Test func windowsFromLastNightShareMidnightOnTheRail() {
        var first = Alarm(source: "a", name: "First", hour: 22, minute: 0, weekdays: [2])
        first.minutes = 240
        var second = Alarm(source: "b", name: "Second", hour: 23, minute: 0, weekdays: [2])
        second.minutes = 180
        let day = plan([first, second], date(3, 0, 30))
        let rail = day.rail(hourHeight: 34)
        let starts = rail.labels.filter { $0.kind == .row || $0.kind == .off }
        #expect(starts.count == 1)
        for label in starts {
            #expect(label.text == "midnight")
            #expect(label.row == nil)
            #expect(day.minute(at: rail.time(at: label.y), hourHeight: 34, snap: 1) == 0)
        }
        for mark in rail.marks {
            #expect(day.hour(at: rail.dropTime(at: (mark.block.lowerBound + mark.block.upperBound) / 2), hourHeight: 34) == 0)
        }
    }

    @Test func aLongWindowHasACompactContentRow() {
        let rail = plan([overworld], date(2, 16)).rail(hourHeight: 34)
        let mark = rail.marks[0]
        #expect(mark.block.upperBound - mark.block.lowerBound <= 112)
        #expect(abs(mark.bar.upperBound - mark.bar.lowerBound - 4 * 34) < 0.01)
    }

    @Test func contentRowsLeaveAQuietGapEvenWhenTimesAreClose() {
        var later = compline
        later.hour = 15
        later.minute = 10
        let rail = plan([overworld, later], date(2, 16)).rail(hourHeight: 34)
        #expect(rail.marks[1].block.lowerBound - rail.marks[0].block.upperBound >= 28)
    }

    @Test func compactRailMappingKeepsStartsEndsAndDropsOnTheirTimes() {
        let day = ownersDay
        for scale in [24.0, 34, 50] {
            let rail = day.rail(hourHeight: scale)
            for minute in stride(from: 0, through: 24 * 60, by: 5) {
                let before = day.y(minute: minute, hourHeight: scale)
                #expect(abs(rail.time(at: rail.position(before)) - before) < 0.0001)
            }
            for start in [7 * 60 + 2, 15 * 60, 19 * 60, 20 * 60, 21 * 60] {
                let before = day.y(minute: start, hourHeight: scale)
                let target = rail.position(day.y(minute: start + 5, hourHeight: scale))
                let distance = rail.time(at: target) - before
                #expect(day.minute(start, draggedBy: distance, hourHeight: scale) == start + 5)
                #expect(day.minute(at: rail.time(at: rail.position(before)), hourHeight: scale, snap: 1) == start)
            }
        }
    }

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
        #expect(day.quiet().headline == "Compline")
        #expect(day.quiet().line == "8 PM today")
    }

    @Test func anOpenWindowIsntADayThatsDone() {
        // 8:30 on Compline's own hour, nothing playing: the sidebar says till 9, so Now names that hour
        let quiet = plan([lauds, compline], date(2, 20, 30)).quiet()
        #expect(quiet.headline == "Compline")
        #expect(says(quiet.line, "till 9 PM", "not playing"))
        // what comes after it still shows, and whether the Mac will wake for that
        let after = plan([lauds, compline], date(2, 20, 30)).quiet(wakeScheduled: true)
        #expect(after.next == "Lauds at 7:02 AM tomorrow")
        #expect(after.foot == "The Mac will wake for it.")
        // a row starting inside the open hour comes before one after it
        #expect(plan([overworld, compline, lauds], date(2, 15, 30)).quiet().next == "Compline at 8 PM")
        var inside = compline
        inside.hour = 17
        #expect(plan([overworld, inside], date(2, 15, 30)).quiet().next == "Compline at 5 PM")
        // an hour that's off is no window, and past it the next row has the page
        var off = compline
        off.on = false
        #expect(plan([lauds, off], date(2, 20, 30)).quiet().headline == "Lauds")
        #expect(plan([lauds, compline], date(2, 21, 30)).quiet().headline == "Lauds")
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
        // midnight to 2, then a break to 3 PM drawn as two hours
        #expect(day.breaks == [2...15])
        #expect(abs(day.rail.time(at: day.rail.marks[0].bar.upperBound) - 2 * DayPlan.Rail.hourHeight) < 0.01)
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
        #expect(day.rows[0].waits == nil)
        #expect(day.rows[1].waits == "Overworld")
        #expect(day.rows[2].waits == nil)
        var off = overworld
        off.on = false
        #expect(plan([off, chopin], date(2, 12)).rows[1].waits == nil)
    }

    @Test func whatSoundingLeadsTo() {
        #expect(plan([lauds, overworld, compline], date(2, 15, 40)).next(sounding: overworld) == "Compline at 8 PM")
        #expect(plan([lauds, overworld, compline], date(2, 20, 5)).next(sounding: compline) == "Lauds at 7:02 AM tomorrow")
        #expect(plan([lauds, overworld, compline], date(2, 7, 5)).next(sounding: lauds) == "Overworld at 3 PM")
        #expect(plan([overworld], date(2, 15, 40)).next(sounding: overworld) == "Overworld at 3 PM tomorrow")
        let once = Alarm(source: "x", name: "Once", hour: 9, minute: 5, day: date(2, 0))
        #expect(plan([once], date(2, 9, 6)).next(sounding: once) == nil)
    }

    @Test func aFarDayIsNamed() {
        #expect(plan([lauds, compline], date(6, 20, 5)).next(sounding: compline) == "Compline at 8 PM tomorrow")
        #expect(plan([lauds], date(6, 7, 5)).next(sounding: lauds) == "Lauds at 7:02 AM Monday")
    }

    @Test func aTimeAloneSaysItsHalfAndNoonIsNoon() {
        var midday = overworld
        midday.hour = 12
        let day = plan([midday], date(2, 9))
        #expect(day.quiet().line == "noon today")
        #expect(day.shortHours(of: "overworld") == "noon to 4 PM")
        #expect(day.firstRow(of: "overworld").map(day.when) == "noon to 4 PM")
        var once = lauds
        (once.hour, once.minute) = (12, 0)
        let single = plan([once], date(2, 9))
        #expect(single.shortHours(of: "lauds") == "noon weekdays")
        #expect(single.firstRow(of: "lauds").map(single.when) == "noon")
        #expect(DayPlan.startText(once, twelveHour: true) == "noon")
        #expect(DayPlan.startText(lauds, twelveHour: false) == "7:02")
        var late = compline
        (late.hour, late.minutes) = (22, 120)
        let night = plan([late], date(2, 9))
        #expect(night.firstRow(of: "compline").map(night.when) == "10 PM to midnight")
        let evening = date(2, 20, 40)
        #expect(DayPlan.fullTime(evening, calendar: calendar, twelveHour: true) == "8:40 PM")
        #expect(DayPlan.fullTime(evening, calendar: calendar, twelveHour: false) == "20:40")
        #expect(plan([lauds, compline], date(2, 20, 5), twelveHour: false).next(sounding: compline) == "Lauds at 7:02 tomorrow")
    }

    @Test func lengthsHaveOneShape() {
        #expect(DayPlan.length(minutes: 45) == "45 min")
        #expect(DayPlan.length(minutes: 60) == "1 h")
        #expect(DayPlan.length(minutes: 90) == "1 h 30 min")
        #expect(DayPlan.length(minutes: 0) == "0 min")
    }

    @Test func whatNowSaysInSilenceOfTheDay() {
        #expect(plan([], date(2, 12)).quiet() == .init(headline: "Nothing on your day", line: "", foot: nil))
        #expect(plan([lauds, overworld, compline], date(2, 12)).quiet() == .init(headline: "Overworld", line: "3 PM today", foot: nil))
        #expect(plan([lauds, overworld, compline], date(2, 22)).quiet(wakeScheduled: true) == .init(headline: "Lauds", line: "7:02 AM tomorrow", foot: "The Mac will wake for it."))
        #expect(plan([lauds], date(2, 22)).quiet().foot == nil)
        #expect(plan([overworld], date(2, 22)).quiet(wakeScheduled: true).foot == nil)
        #expect(plan([lauds], date(8, 12)).quiet(wakeScheduled: true) == .init(headline: "Lauds", line: "7:02 AM tomorrow", foot: "The Mac will wake for it."))
        #expect(plan([lauds], date(7, 12)).quiet().line == "7:02 AM Monday")
    }

    @Test func nothingSoundingHasThePaintingOfTheRowItNames() {
        #expect(plan([lauds, compline], date(2, 20, 30)).quietSource == compline.source)
        #expect(plan([lauds, compline], date(2, 22)).quietSource == lauds.source)
        #expect(plan([], date(2, 22)).quietSource == nil)
    }

    @Test func sidebarLabels() {
        let day = plan([lauds, overworld, compline], date(2, 15, 40))
        #expect(day.label(of: "lauds") == "7:02 AM")
        #expect(day.label(of: "overworld") == "till 7 PM")
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
        #expect(today.missedToday(row) == "Missed at 7:02 AM. The Mac was off.")
        #expect(today.quiet().foot == "Missed Lauds at 7:02 AM. The Mac was off.")
        #expect(today.quiet().line == "3 PM today")
        let tomorrow = plan([row, overworld], date(3, 12))
        #expect(tomorrow.missedToday(row) == nil)
        #expect(tomorrow.quiet().foot == nil)
    }

    @Test func backToBackRowsFollowEachOther() {
        var next = compline
        next.hour = 19
        #expect(plan([overworld, next], date(2, 15, 40)).next(sounding: overworld) == "Compline at 7 PM")
    }

    @Test func twoRowsStartingTogetherDontBothClaimTheTime() {
        var twin = overworld
        twin.name = "Twin"
        let notes = plan([overworld, twin], date(2, 12)).rows.map(\.waits)
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
        #expect(day.shortHours(of: "lauds") == "7:02 AM weekdays")
        #expect(says(day.shortHours(of: "overworld"), "3", "7 PM"))
        #expect(day.firstRow(of: "compline").map(day.when) == "8 to 9 PM")
        #expect(says(day.firstRow(of: "lauds").map(day.when), "7:02"))
        #expect(says(day.firstRow(of: "noon").map(day.when), "11:30", "1 PM"))
        let eight = Alarm(source: "eight", name: "Eight", hour: 20, minute: 0, weekdays: Set(1...7))
        #expect(says(plan([eight]).shortHours(of: "eight"), "8 PM", "every day"))
        #expect(day.firstRow(of: "off") == nil)
        #expect(day.shortHours(of: "nothing") == nil)
    }

    private func text(_ pieces: [DayPlan.Piece]) -> String { pieces.map(\.text).joined(separator: " · ") }

    @Test func rowsSayTheirWords() {
        var morning = lauds
        morning.shuffled = true
        morning.rotates = true
        let day = plan([morning, overworld, compline], date(2, 12))
        #expect(text(day.sentence(morning, nextPart: "Strings")) == "Weekdays · shuffled · 25% volume · Strings next")
        var here = overworld
        (here.shuffled, here.heedsCalendar) = (true, true)
        #expect(text(day.sentence(here, nextPart: nil)) == "While you're at the Mac · shuffled · unless busy")
        var evening = compline
        (evening.volume, evening.rotates) = (0.15, true)
        #expect(says(text(day.sentence(evening, nextPart: "part 2")), "Every day", "15%", "Part 2"))
        var plain = compline
        plain.volume = nil
        #expect(text(day.sentence(plain, nextPart: nil)) == "Every day · in order")
        var some = overworld
        some.weekdays = [2, 3, 4, 5, 6]
        #expect(text(day.sentence(some, nextPart: nil)) == "Weekdays · while you're at the Mac · in order")
        #expect(day.sentence(here, nextPart: nil).compactMap(\.word) == [.kind, .order, .calendar])
        // one sentence on a collection's page, its time first
        #expect(day.summary(plain) == "8 to 9 PM, every day, in order")
        #expect(day.summary(some) == "3 to 7 PM, weekdays, while you're at the Mac, in order")
    }

    // MARK: Days off

    private func off(_ row: Alarm, _ days: [String]) -> Alarm {
        var row = row
        row.daysOff = Set(days)
        return row
    }

    @Test func aDayOffSaysWhenRightAfterTheDays() {
        let monday = plan([], date(2, 12))
        let token = { (row: Alarm) in monday.sentence(row, nextPart: nil).first { $0.word == .daysOff }?.text }
        #expect(monday.sentence(off(lauds, ["2026-11-03"]), nextPart: nil).prefix(2).map(\.text) == ["Weekdays", "off tomorrow"])
        #expect(token(off(lauds, ["2026-11-02"])) == "off today")
        #expect(token(off(lauds, ["2026-11-06"])) == "off Friday")
        #expect(token(off(lauds, ["2026-11-27"])) == "off Nov 27")
        #expect(token(off(lauds, (21...31).map { "2026-12-\($0)" } + (1...4).map { "2027-01-0\($0)" })) == "off Dec 21 to Jan 4")
        #expect(token(off(lauds, ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"])) == "off till Nov 5")
        // the weekend isn't when it's back: Monday is
        #expect(token(off(lauds, (2...6).map { "2026-11-0\($0)" })) == "off till Nov 9")
        // yesterday's is kept but over
        #expect(token(off(lauds, ["2026-11-01"])) == nil)
        #expect(token(lauds) == nil)
        // with no days word, it leads
        #expect(monday.sentence(off(overworld, ["2026-11-03"]), nextPart: nil).first?.text == "Off tomorrow")
        let runs = monday.offRuns(off(lauds, ["2026-11-03", "2026-11-20", "2026-11-21"]))
        #expect(runs.map(\.text) == ["Off tomorrow", "Off Nov 20 to Nov 21"])
        #expect(runs.map(\.days) == [["2026-11-03"], ["2026-11-20", "2026-11-21"]])
    }

    @Test func theMenuNamesTheDayItsNextTimeIsOn() {
        #expect(plan([], date(2, 12)).offChoice(lauds)?.title == "Off tomorrow")
        #expect(plan([], date(2, 12)).offChoice(lauds)?.day == "2026-11-03")
        // named for the day whether or not it's off already
        #expect(plan([], date(2, 12)).offChoice(off(lauds, ["2026-11-03"]))?.title == "Off tomorrow")
        #expect(plan([], date(2, 6)).offChoice(lauds)?.title == "Off today")
        #expect(plan([], date(6, 12)).offChoice(lauds)?.title == "Off Monday")
        #expect(plan([], date(2, 16)).offChoice(off(overworld, ["2026-11-02"]))?.title == "Off today")
    }

    @Test func theCalendarLaysOutTheMonthAsTheRowHasIt() {
        let monday = plan([], date(2, 12))
        let november = monday.month(off(lauds, ["2026-11-04"]), containing: date(17, 9))
        #expect(november.title == "November 2026")
        // the 1st is a Sunday, under S
        #expect(november.lead == 0)
        #expect(monday.weekdayLetters == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(november.days.count == 30)
        let day = { (number: Int) in november.days[number - 1] }
        #expect(day(1).past && !day(1).open)
        #expect(day(2).today && day(2).open)
        #expect(day(4).off && day(4).open)
        // a Saturday it doesn't play
        #expect(!day(7).plays && !day(7).open)
        #expect(monday.month(lauds, containing: date(2, 12) + 40 * 86400).lead == 2)
        #expect(monday.month(lauds, containing: date(2, 12) + 40 * 86400).title == "December 2026")
    }

    @Test func aRunTakesOffTheDaysItPlaysAndReadsAsOne() {
        let monday = plan([], date(2, 12))
        let at = { (month: Int, day: Int) in self.calendar.date(from: DateComponents(year: month == 1 ? 2027 : 2026, month: month, day: day))! }
        #expect(monday.offLine(lauds) == "No days off")
        var row = lauds
        // either way round
        row.daysOff = monday.marking(row, from: at(1, 4), to: at(12, 21), off: true)
        #expect(!row.daysOff.contains("2026-12-26"))
        #expect(row.daysOff.count == 11)
        #expect(monday.offLine(row) == "Off Dec 21 to Jan 4")
        #expect(monday.offRuns(row).count == 1)
        row.daysOff = monday.marking(row, from: at(12, 28), to: at(12, 31), off: false)
        #expect(monday.offLine(row) == "Off Dec 21 to Dec 25, Jan 1 to Jan 4")
        // one day, back and forth
        row.daysOff = monday.marking(row, from: at(11, 3), to: at(11, 3), off: true)
        #expect(monday.offLine(row) == "Off tomorrow, Dec 21 to Dec 25, Jan 1 to Jan 4")
        #expect(monday.offLine(row, runs: 2) == "Off tomorrow, Dec 21 to Dec 25, and 1 more")
        row.daysOff = monday.marking(row, from: at(11, 3), to: at(11, 3), off: false)
        #expect(monday.offLine(row).hasPrefix("Off Dec 21"))
        // days gone stay; putting back clears days it doesn't play too
        row.daysOff = ["2026-11-01", "2026-11-07"]
        row.daysOff = monday.marking(row, from: at(10, 30), to: at(11, 8), off: false)
        #expect(row.daysOff == ["2026-11-01"])
        row.daysOff = monday.marking(row, from: at(10, 30), to: at(11, 3), off: true)
        #expect(row.daysOff == ["2026-11-01", "2026-11-02", "2026-11-03"])
    }

    @Test func aRowOffTodayDrawsLikeOneTurnedOffAndNobodyWaitsForIt() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
        (chopin.whileHere, chopin.minutes) = (true, 60)
        let day = plan([off(overworld, ["2026-11-02"]), chopin], date(2, 16))
        #expect(day.rows.map(\.alarm.name) == ["Overworld", "Perfect Chopin"])
        #expect(day.rows.map(\.off) == [true, false])
        #expect(day.rows[1].waits == nil)
        #expect(day.rail.marks.map(\.off) == [true, false])
        #expect(day.rail.labels.first { $0.row == day.rows[0].id && $0.kind != .end }?.kind == .off)
        #expect(day.label(of: "overworld") == "3 PM")
    }

    @Test func whileTheNextTimeIsOffTheSidebarNamesTheNextOne() {
        #expect(plan([off(lauds, ["2026-11-03"])], date(2, 12)).label(of: "lauds") == "7:02 AM Wed")
        #expect(plan([off(lauds, (3...30).map { "2026-11-\(String(format: "%02d", $0))" })], date(2, 12)).label(of: "lauds") == "7:02 AM Dec 1")
        #expect(plan([off(lauds, ["2026-11-04"])], date(2, 12)).label(of: "lauds") == "7:02 AM")
        #expect(plan([off(lauds, ["2026-11-03"])], date(2, 22)).quiet().line == "7:02 AM Wednesday")
    }

    @Test func whatsHappeningTakesTheLine() {
        var morning = lauds
        morning.shuffled = true
        morning.missed = Alarm.Missed(at: date(2, 7, 2), why: .off)
        let day = plan([morning, overworld], date(2, 12))
        let row = day.rows[0]
        #expect(text(day.line(for: row, nextPart: nil)) == "Missed at 7:02 AM. The Mac was off. · Play it now")
        #expect(day.line(for: row, nextPart: nil).last?.word == .playNow)
        #expect(text(day.line(for: row, nextPart: nil, rising: true)) == "Rising to 25% · weekdays · shuffled")
        #expect(says(text(day.line(for: day.rows[1], nextPart: nil, waiting: .call)), "Waiting", "call"))
        #expect(text(day.line(for: day.rows[1], nextPart: nil, cantWake: true)) == "The Mac won't wake for this. · Wake it")
        // a miss today mustn't hide that the next one can't wake either
        #expect(text(day.line(for: row, nextPart: nil, cantWake: true)) == "Missed at 7:02 AM. The Mac was off. · Play it now · The Mac won't wake for the next one. · Wake it")
        #expect(text(day.wakeLine(alarm: overworld, nextPart: nil, cantWake: true)) == "The Mac won't wake for this. · Wake it")
        #expect(says(text(day.wakeLine(alarm: overworld, nextPart: nil, cantWake: false)), "While you're at the Mac", "in order"))
    }

    @Test func anOverlapIsAddedToTheRowsWords() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
        (chopin.whileHere, chopin.minutes, chopin.shuffled) = (true, 60, true)
        let day = plan([overworld, chopin], date(2, 12))
        let line = day.line(for: day.rows[1], nextPart: nil)
        #expect(text(line) == "While you're at the Mac · shuffled · Overworld waits")
        #expect(line.compactMap(\.word) == [.kind, .order])
    }

    @Test func theNextRowLeavesRoomForALongerLine() {
        var chopin = Alarm(source: "c", name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
        (chopin.whileHere, chopin.minutes) = (true, 60)
        var soon = compline
        soon.hour = 18
        let day = plan([overworld, chopin, soon], date(2, 12))
        let rail = day.rail(hourHeight: DayPlan.Rail.hourHeight, lines: [chopin.id: 2])
        #expect(rail.marks[2].top >= rail.marks[1].bottom)
        #expect(rail.height >= rail.marks[2].block.upperBound)
        #expect(rail.marks[1].aside)
    }

    @Test func theRailIsToScale() {
        let morning = lauds
        let day = plan([morning, overworld, compline], date(2, 15, 40), lengths: [morning.id: 69 * 60])
        let rail = day.rail
        let scale = DayPlan.Rail.hourHeight
        #expect(rail.height >= rail.marks[2].bottom)
        // the rail starts at 7: Lauds runs 7:02 to 8:11, the long gap draws two hours, Overworld 3 to 7, and it's 3:40
        #expect(abs(rail.time(at: rail.marks[0].bar.lowerBound) - 2.0 / 60 * scale) < 0.01)
        #expect(abs(rail.time(at: rail.marks[0].bar.upperBound) - 71.0 / 60 * scale) < 0.01)
        let three = (71.0 / 60 + 2) * scale
        #expect(abs(rail.time(at: rail.marks[1].bar.lowerBound) - three) < 0.01 && abs(rail.time(at: rail.marks[1].bar.upperBound) - (three + 4 * scale)) < 0.01)
        #expect(rail.marks[2].top >= rail.marks[1].bottom)
        #expect(abs(rail.time(at: rail.now!) - (three + 40.0 / 60 * scale)) < 0.01)
        #expect(rail.labels.map(\.text).contains("7:02 AM") && rail.labels.map(\.text).contains("3 PM") && rail.labels.map(\.text).contains("3:40"))
    }

    @Test func wordsLeaveEachClockPointFindable() {
        var soon = lauds
        (soon.hour, soon.minute, soon.id) = (7, 30, UUID())
        let rail = plan([lauds, soon], date(2, 12)).rail
        #expect(rail.marks[1].top >= rail.marks[0].bottom)
        #expect(abs(rail.time(at: rail.marks[1].bar.lowerBound) - 12) < 0.001)
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

    // MARK: long gaps

    /// 7:02 to 8:11, a long gap, 3 to 7, an hour, 8 to 9.
    private var ownersDay: DayPlan {
        let row = lauds
        return plan([row, overworld, compline], date(2, 12), lengths: [row.id: 69 * 60])
    }

    @Test func aGapOverTwoHoursBreaksAndAShorterOneDoesnt() {
        let day = ownersDay
        #expect(day.breaks.count == 1)
        #expect(abs(day.breaks[0].lowerBound - (8 + 11.0 / 60)) < 0.001 && day.breaks[0].upperBound == 15)
        #expect(abs(day.span - (14 - (15 - 8 - 11.0 / 60) + 2)) < 0.001)
        // exactly two hours is still to scale
        var two = compline
        two.hour = 21
        #expect(plan([overworld, two], date(2, 12)).breaks.isEmpty)
        two.minute = 1
        #expect(plan([overworld, two], date(2, 12)).breaks.count == 1)
    }

    @Test func aRowTurnedOffStillHoldsItsPlaceInAGap() {
        var off = Alarm(source: "x", name: "Off", hour: 11, minute: 0, weekdays: Set(1...7))
        (off.on, off.minutes) = (false, 60)
        let row = lauds
        #expect(plan([row, off, overworld], date(2, 12), lengths: [row.id: 69 * 60]).breaks.count == 2)
    }

    @Test func overlappingRowsDontMakeAGap() {
        var chopin = Alarm(source: "c", name: "Chopin", hour: 16, minute: 0, weekdays: Set(1...7))
        chopin.minutes = 30
        // Chopin ends at 4:30 inside Overworld, so Compline's gap counts from 7
        var late = compline
        late.hour = 22
        #expect(plan([overworld, chopin, late], date(2, 12)).breaks == [19...22])
    }

    @Test func theWholeDayAndAnEmptyDayHaveNoBreaks() {
        let row = lauds
        #expect(plan([row, overworld, compline], date(2, 12), lengths: [row.id: 69 * 60], wholeDay: true).breaks.isEmpty)
        #expect(plan([], date(2, 12)).breaks.isEmpty)
    }

    @Test func aRowIsNeverCompressedAndABreakDrawsTwoHours() {
        for scale in [24.0, 50, 76, 120] {
            let rail = ownersDay.rail(hourHeight: scale)
            let marks = rail.marks
            #expect(abs(rail.time(at: marks[0].bar.upperBound) - rail.time(at: marks[0].bar.lowerBound) - 69.0 / 60 * scale) < 0.001)
            #expect(abs(rail.time(at: marks[1].bar.upperBound) - rail.time(at: marks[1].bar.lowerBound) - 4 * scale) < 0.001)
            #expect(abs(marks[2].bar.upperBound - marks[2].bar.lowerBound - scale) < 0.001)
            #expect(abs(rail.time(at: marks[1].bar.lowerBound) - rail.time(at: marks[0].bar.upperBound) - 2 * scale) < 0.001)
            #expect(abs(rail.time(at: marks[2].bar.lowerBound) - rail.time(at: marks[1].bar.upperBound) - scale) < 0.001)
            #expect(abs(rail.height - ownersDay.span * scale) < 0.001 || rail.height > ownersDay.span * scale)
        }
    }

    @Test func theMapAndItsInverseAgreeEverywhere() {
        let day = ownersDay
        var last = -1.0
        for quarter in 28...84 {
            let hour = Double(quarter) / 4
            let drawn = day.drawn(hour: hour)
            #expect(drawn > last)
            last = drawn
            #expect(abs(day.hour(drawn: drawn) - hour) < 0.0001)
        }
        #expect(day.drawn(hour: 7) == 0)
        #expect(abs(day.drawn(hour: 21) - day.span) < 0.001)
        #expect(day.position(of: date(2, 21)) == 1)
    }

    @Test func aDropInABreakLandsByTheInverseSnappedToItsHour() {
        let day = ownersDay
        let scale = 50.0
        // halfway down the break is halfway through the gap
        let middle = day.drawn(hour: (8 + 11.0 / 60 + 15) / 2) * scale
        #expect(day.hour(at: middle, hourHeight: scale) == 11)
        #expect(day.hour(at: 0, hourHeight: scale) == 7)
        #expect(day.hour(at: -5, hourHeight: scale) == 7)
        #expect(day.hour(at: 99999, hourHeight: scale) == 19)
        // what it lands on draws where it says
        #expect(abs(day.y(hour: 15, hourHeight: scale) - day.rail(hourHeight: scale).time(at: day.rail(hourHeight: scale).marks[1].bar.lowerBound)) < 0.001)
        for y in stride(from: 0.0, through: day.span * scale, by: 7) {
            let hour = day.hour(at: y, hourHeight: scale)
            #expect(hour >= 7 && hour <= 19)
        }
    }

    @Test func theNowDotInABreakIsBetweenWhatsEitherSide() {
        let row = lauds
        let day = plan([row, overworld, compline], date(2, 11, 30), lengths: [row.id: 69 * 60])
        let rail = day.rail(hourHeight: 50)
        #expect(rail.now! > rail.marks[0].bar.upperBound && rail.now! < rail.marks[1].bar.lowerBound)
        #expect(rail.labels.contains { $0.text == "11:30" && $0.kind == .now })
    }

    @Test func timesEitherSideOfABreakStayAndHoursInsideItDont() {
        let rail = ownersDay.rail(hourHeight: 50)
        let texts = rail.labels.map(\.text)
        #expect(texts.contains("8:11") && texts.contains("3 PM"))
        #expect(!texts.contains("noon"))
        #expect(rail.breaks.map(\.text) == ["6 h 49 min"])
        #expect(rail.breaks[0].y > rail.marks[0].bar.upperBound && rail.breaks[0].y < rail.marks[1].bar.lowerBound)
    }

    @Test func aBlockFitsItsLinesAndNeverRunsIntoTheNext() {
        var soon = lauds
        (soon.hour, soon.minute, soon.id) = (7, 30, UUID())
        let first = lauds
        for scale in [24.0, 50, 120] {
            let rail = plan([first, soon, overworld], date(2, 12), lengths: [first.id: 3600]).rail(hourHeight: scale, lines: [soon.id: 3])
            for (mark, next) in zip(rail.marks, rail.marks.dropFirst()) {
                #expect(mark.block.upperBound <= next.block.lowerBound)
                #expect(mark.block.upperBound - mark.block.lowerBound >= DayPlan.Rail.rowHeight - 4)
            }
            #expect(rail.marks[1].block.upperBound - rail.marks[1].block.lowerBound >= DayPlan.Rail.rowHeight - 4 + 2 * DayPlan.Rail.lineHeight)
            #expect(rail.height >= rail.marks.last!.block.upperBound)
        }
    }

    @Test func aDragMovesATimeByWholeFiveMinutes() {
        let day = ownersDay
        let scale = 50.0
        let lauds = 7 * 60 + 2
        // a drag that comes back leaves 7:02 where it was
        #expect(day.minute(lauds, draggedBy: 0, hourHeight: scale) == lauds)
        #expect(day.minute(lauds, draggedBy: scale / 60, hourHeight: scale) == lauds)
        #expect(day.minute(lauds, draggedBy: scale / 12, hourHeight: scale) == lauds + 5)
        #expect(day.minute(lauds, draggedBy: -scale / 2, hourHeight: scale) == lauds - 30)
        #expect(day.minute(lauds, draggedBy: -99999, hourHeight: scale) == 0)
        #expect(day.minute(lauds, draggedBy: 99999, hourHeight: scale) == 24 * 60)
    }

    @Test func aPointOnTheRailIsATimeSnappedThroughBreaks() {
        let day = ownersDay
        let scale = 50.0
        for minute in stride(from: day.firstHour * 60, through: day.lastHour * 60, by: 5) {
            #expect(day.minute(at: day.y(minute: minute, hourHeight: scale), hourHeight: scale) == minute)
        }
        // 7:02 snaps to 7:00, 7:03 to 7:05; by fifteen, 7:08 to 7:15
        #expect(day.minute(at: day.y(minute: 7 * 60 + 2, hourHeight: scale), hourHeight: scale) == 7 * 60)
        #expect(day.minute(at: day.y(minute: 7 * 60 + 3, hourHeight: scale), hourHeight: scale) == 7 * 60 + 5)
        #expect(day.minute(at: day.y(minute: 7 * 60 + 8, hourHeight: scale), hourHeight: scale, snap: 15) == 7 * 60 + 15)
        // past the rail's ends, on to the day's
        #expect(day.minute(at: -scale / 2, hourHeight: scale) == day.firstHour * 60 - 30)
        #expect(day.minute(at: day.span * scale + scale, hourHeight: scale) == day.lastHour * 60 + 60)
        #expect(day.minute(at: -99999, hourHeight: scale) == 0)
        #expect(day.minute(at: 99999, hourHeight: scale) == 24 * 60)
        #expect(day.timeText(minute: 16 * 60) == "4 PM")
        #expect(day.timeText(minute: 16 * 60 + 15) == "4:15 PM")
        #expect(day.timeText(minute: 12 * 60) == "noon")
    }

    @Test func theVolumeWordSaysWhatItIs() {
        let pieces = plan([lauds], date(2, 12)).sentence(lauds, nextPart: nil)
        #expect(pieces.contains(DayPlan.Piece("25% volume", .volume)))
    }
}
