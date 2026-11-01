import Testing
@testable import SottovaCore

struct TypedDurationTests {
    @Test(arguments: [
        ("5 min", 60, 300), ("5", 60, 300), ("5", 1, 5), ("5m", 1, 300), ("12 minutes", 1, 720),
        ("6 s", 60, 6), ("90s", 60, 90), ("90 sec", 60, 90), ("1:30", 1, 90), ("1.5 min", 1, 90),
        ("1 min 30 s", 1, 90), ("1 h", 1, 3600), ("  7 MIN ", 1, 420), ("0", 60, 0), ("0 s", 1, 0),
    ] as [(String, Double, Double)])
    func reads(text: String, unit: Double, seconds: Double) {
        #expect(TypedDuration.parse(text, unit: unit) == seconds)
    }

    @Test(arguments: ["", "  ", "soon", "5 parsecs", "-5", "5 s 2 min", "1:75", "min", "nan", "inf", "1000000000000000000000", "25 h"])
    func refuses(text: String) {
        #expect(TypedDuration.parse(text, unit: 60) == nil)
    }

    @Test(arguments: [(6.0, "6 s"), (0, "0 s"), (300, "5 min"), (90, "1 min 30 s"), (720, "12 min"), (1.5, "1.5 s")])
    func showsAndReadsBack(seconds: Double, text: String) {
        #expect(TypedDuration.format(seconds) == text)
        #expect(TypedDuration.parse(text, unit: 1) == seconds)
    }
}
