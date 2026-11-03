import Foundation
import Testing
@testable import SottovaCore

struct WakePlanTests {
    private let calendar = Calendar.current

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func readsEveryWakeInTheSchedule() {
        let output = """
        Scheduled power events:
         [0]  wakeorpoweron at 11/02/2026 07:00:00 by 'pmset'
         [1]  wake at 11/03/2026 19:58:00 by 'pmset'
         [2]  poweron at 11/04/2026 08:00:00 by 'pmset'
        """
        #expect(WakePlan.scheduled(in: output) == [date(2, 7, 0), date(3, 19, 58)])
    }

    @Test func wakesComeTwoMinutesEarlyForTwoWeeksAndOnlyForRowsThatStartByThemselves() {
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        var off = Alarm(source: "o", name: "Off", hour: 9, minute: 0, weekdays: Set(1...7))
        off.on = false
        var here = Alarm(source: "h", name: "Here", hour: 15, minute: 0, weekdays: Set(1...7))
        here.whileHere = true
        let needed = WakePlan.needed(for: [off, here, lauds], now: date(10, 12, 0))
        #expect(needed.count == 14)
        #expect(needed.first == date(11, 7, 0))
        #expect(needed == needed.sorted())
    }

    @Test func aWakeUnderAMinuteAwayIsLeftOut() {
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        #expect(WakePlan.needed(for: [lauds], now: date(10, 6, 59).addingTimeInterval(30)).first == date(11, 7, 0))
        #expect(WakePlan.needed(for: [lauds], now: date(10, 6, 58)).first == date(10, 7, 0))
    }

    @Test func aDayOffNeedsNoWake() {
        var lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        lauds.daysOff = [Alarm.day(date(11, 12, 0))]
        let needed = WakePlan.needed(for: [lauds], now: date(10, 12, 0))
        #expect(needed.count == 13)
        #expect(!needed.contains(date(11, 7, 0)))
    }

    @Test func onlyWakesSottovaAddedForADayOffOrARowTurnedOffAreCancelled() {
        let now = date(10, 12, 0)
        var lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        lauds.daysOff = Set([12, 13, 14, 30].map { Alarm.day(date($0, 12, 0)) })
        // Fridays at the same time: the 13th still needs its wake
        let twin = Alarm(source: "t", name: "Twin", hour: 7, minute: 2, weekdays: [6])
        var off = Alarm(source: "o", name: "Off", hour: 9, minute: 0, weekdays: Set(1...7))
        off.on = false
        let kept = date(11, 7, 0), dayOff = date(12, 7, 0), shared = date(13, 7, 0), foreign = date(14, 7, 0)
        let far = date(30, 7, 0), turnedOff = date(11, 8, 58), deleted = date(15, 10, 0)
        let scheduled: Set<Date> = [kept, dayOff, shared, foreign, far, turnedOff, deleted]
        let ours = scheduled.subtracting([foreign])
        #expect(WakePlan.cancels(for: [lauds, twin, off], scheduled: scheduled, ours: ours, now: now) == [turnedOff, dayOff])
        // not within the next minute, and nothing without rows to go by
        #expect(WakePlan.cancels(for: [lauds, twin, off], scheduled: scheduled, ours: ours, now: date(12, 6, 59) + 30).isEmpty)
        #expect(WakePlan.cancels(for: [], scheduled: scheduled, ours: ours, now: now).isEmpty)
    }

    @Test func theWakesToTrackAtFirstAreTheOnesARowNeeds() {
        var lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
        lauds.daysOff = [Alarm.day(date(12, 12, 0))]
        let scheduled: Set<Date> = [date(11, 7, 0), date(12, 7, 0), date(11, 6, 58), date(30, 7, 0)]
        #expect(WakePlan.wouldNeed(for: [lauds], now: date(10, 12, 0)).intersection(scheduled) == [date(11, 7, 0), date(12, 7, 0)])
    }

    @Test func theCancelIsTheOneTheRuleAllows() {
        #expect(WakePlan.cancelArguments(for: date(2, 7, 0)) == ["-n", "/usr/bin/pmset", "schedule", "cancel", "wakeorpoweron", "11/02/2026 07:00:00"])
    }

    @Test func theNewRuleIsCheckedAndInPlaceBeforeTheOldOnesGo() throws {
        let script = WakePlan.installScript(user: "me")
        #expect(WakePlan.rule == "/etc/sudoers.d/sottova-3")
        #expect(script.contains("NOPASSWD: /usr/bin/pmset schedule wakeorpoweron \(WakePlan.datePattern), /usr/bin/pmset schedule cancel wakeorpoweron \(WakePlan.datePattern)'"))
        let check = try #require(script.range(of: "visudo -cf"))
        let move = try #require(script.range(of: "mv /etc/sudoers.d/.sottova /etc/sudoers.d/sottova-3"))
        let remove = try #require(script.range(of: "rm -f /etc/sudoers.d/sottova "))
        #expect(check.lowerBound < move.lowerBound && move.lowerBound < remove.lowerBound)
        // an older build still adds its wakes through sottova-2
        #expect(!script.contains(WakePlan.addOnlyRule))
        // a failure takes away only the file it was writing
        #expect(script.contains("|| { rm -f /etc/sudoers.d/.sottova; exit 1; }"))
    }

    @Test func savingAsksOnlyWhenTheMacCantWakeOtherwiseAndAClickAsksForTheCancel() {
        let (newer, older, loose) = (WakePlan.rule, WakePlan.addOnlyRule, WakePlan.looseRule)
        // no rule yet: a wake to add asks
        #expect(WakePlan.asks(missing: true, forDaysOff: false, clicked: false, rules: []))
        #expect(!WakePlan.asks(missing: false, forDaysOff: true, clicked: false, rules: []))
        // the older rule adds wakes, so saving never asks for the one that cancels
        #expect(!WakePlan.asks(missing: true, forDaysOff: true, clicked: false, rules: [older]))
        #expect(WakePlan.asks(missing: false, forDaysOff: true, clicked: true, rules: [older]))
        #expect(!WakePlan.asks(missing: false, forDaysOff: false, clicked: true, rules: [older]))
        // the loose rule is swapped out at the next chance
        #expect(WakePlan.asks(missing: false, forDaysOff: false, clicked: false, rules: [loose]))
        // with the newer rule in, nothing asks
        #expect(!WakePlan.asks(missing: true, forDaysOff: true, clicked: true, rules: [newer, older, loose]))
    }

    @Test func theSudoCallIsTheOneTheRuleAllows() {
        let arguments = WakePlan.pmsetArguments(for: date(2, 7, 0))
        #expect(arguments == ["-n", "/usr/bin/pmset", "schedule", "wakeorpoweron", "11/02/2026 07:00:00"])
        let script = WakePlan.installScript(user: "me")
        #expect(script.hasPrefix("do shell script \"echo 'me ALL=(root) NOPASSWD: /usr/bin/pmset schedule wakeorpoweron [0-9]"))
        #expect(script.hasSuffix("exit 1; }\" with administrator privileges"))
    }

    @Test func cancelIsntAFailureAndAnythingElseSaysWhy() async throws {
        let canceled = try #require(await WakePlan.run("/usr/bin/osascript", ["-e", #"error "User canceled." number -128"#]))
        #expect(canceled.status != 0)
        #expect(WakePlan.installFailure(canceled.error) == nil)
        let denied = try #require(await WakePlan.run("/usr/bin/osascript", ["-e", #"error "The system said no." number -60007"#]))
        #expect(denied.status != 0)
        #expect(WakePlan.installFailure(denied.error) == "couldn't let sottova wake the mac: The system said no.")
        #expect(WakePlan.installFailure("something odd") == "couldn't let sottova wake the mac: the system said no")
    }

    @Test func aCommandReportsItsOutputAndStatusAndOneThatCantStartIsNil() async throws {
        let echo = try #require(await WakePlan.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(echo.status == 3 && echo.output == "out\n" && echo.error == "err\n")
        #expect(await WakePlan.run("/no/such/thing", []) == nil)
    }
}
