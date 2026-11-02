import Foundation
import Testing
@testable import SottovaCore

struct RowTimeTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func at(_ hour: Int, _ minute: Int, second: Int = 0, day: Int = 2) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func storesTheClockOnly() {
        #expect(RowTime.clock(at(7, 2), calendar: calendar) == (7, 2))
        #expect(RowTime.clock(at(23, 59, second: 59, day: 9), calendar: calendar) == (23, 59))
    }

    @Test func spanGoesRoundTheClock() {
        #expect(RowTime.span(from: at(15, 0), until: at(19, 0), calendar: calendar) == 240)
        #expect(RowTime.span(from: at(22, 0), until: at(1, 0), calendar: calendar) == 180)
        #expect(RowTime.span(from: at(7, 2), until: at(7, 2), calendar: calendar) == 1440)
        // an end carried onto the next day by a start plus its length
        #expect(RowTime.span(from: at(23, 30), until: at(0, 30, day: 3), calendar: calendar) == 60)
    }
}
