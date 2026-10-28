import Testing
@testable import SottovaCore

struct FadeTests {
    @Test(arguments: FadeCurve.allCases)
    func endpointsAreExact(curve: FadeCurve) {
        #expect(curve.fadeIn(0) == 0)
        #expect(curve.fadeIn(1) == 1)
        #expect(curve.fadeOut(0) == 1)
        #expect(curve.fadeOut(1) == 0)
    }

    @Test(arguments: FadeCurve.allCases)
    func fadeInNeverDecreases(curve: FadeCurve) {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<10_000 {
            let a = Double.random(in: 0...1, using: &rng)
            let b = Double.random(in: 0...1, using: &rng)
            #expect(curve.fadeIn(min(a, b)) <= curve.fadeIn(max(a, b)))
        }
    }

    @Test func splitMixMatchesReference() {
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
    }
}
