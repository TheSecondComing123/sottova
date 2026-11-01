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
