import Testing
@testable import SottovaCore

struct TrackVisualTests {
    /// Sparse: 6 in, 8 out, in a 200 s piece.
    private var sparse: Track { Track(duration: 200, fadeIn: 6, outStart: 192, outLength: 8) }
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    @Test func sparseFallsIn4Point5AndRisesIn4() {
        #expect(near(sparse.fallLength, 4.5))
        #expect(near(sparse.riseLength, 4))
    }

    @Test func holdIsFullAndStill() {
        let v = sparse.visual(at: 100)
        #expect(v == Track.Visual(cover: 1, under: 0, scale: 1, text: 1, hairline: 1, silent: false))
        #expect(near(sparse.stillFor(at: 100), 92))
    }

    @Test func riseStartsWithTheOldCoverAtItsAfterimageAndNothingElse() {
        let v = sparse.visual(at: 0)
        #expect(v.cover == 0)
        #expect(near(v.under, 0.25))
        #expect(near(v.scale, 0.985))
        #expect(v.text == 0)
    }

    @Test func riseMatchesThePrototypeHalfway() {
        let v = sparse.visual(at: 2) // p .5, ease .5; over at ease(.575)
        #expect(near(v.under, 0.125))
        #expect(near(v.scale, 0.9925))
        #expect(near(v.text, 4.0 / 6))
        #expect(near(v.cover, 0.575 * 0.575 * (3 - 2 * 0.575)))
    }

    @Test func riseEndsExactlyFull() {
        #expect(sparse.visual(at: 4) == sparse.visual(at: 100))
        #expect(sparse.stillFor(at: 3.9) == 0)
    }

    @Test func aCrossfadedPieceTakesTheOldCoverDownFromFull() {
        var t = sparse
        t.equalPowerIn = true
        #expect(t.visual(at: 0).under == 1)
    }

    @Test func fallIsQuadraticToTheAfterimage() {
        let v = sparse.visual(at: 192 + 2.25) // p .5, g .25
        #expect(near(v.cover, 0.25 + 0.75 * 0.25))
        #expect(near(v.text, 0.4))
        #expect(v.hairline == 1)
        #expect(!v.silent)
    }

    @Test func hairlineGoesInTheFallsLastFifth() {
        #expect(near(sparse.visual(at: 192 + 4.5 * 0.9).hairline, 0.5))
        #expect(sparse.visual(at: 192 + 4.5 * 0.8).hairline == 1)
    }

    @Test func silenceComesAtFallEndAndFadesInOver1Point5() {
        let v = sparse.visual(at: 196.5)
        #expect(v.silent)
        #expect(near(v.cover, 0.25))
        #expect(v.text == 0)
        #expect(v.hairline == 0)
        #expect(near(sparse.visual(at: 197.25).text, 0.5))
        #expect(sparse.visual(at: 198).text == 1)
    }

    @Test func silenceHoldsStillForever() {
        #expect(sparse.stillFor(at: 197) == 0)
        #expect(sparse.stillFor(at: 198) == .infinity)
        #expect(sparse.visual(at: 500) == sparse.visual(at: 198))
    }

    @Test func aSeekDoesntDim() {
        var t = sparse
        t.seekedAt = 1
        t.elapsed = 1
        #expect(t.visual(at: 1.2) == sparse.visual(at: 100))
        #expect(t.stillFor(at: 1.2) > 0)
    }

    @Test func aSeekIntoTheFallLandsOnThatLevel() {
        var t = sparse
        t.seekedAt = 193
        #expect(t.visual(at: 193) == sparse.visual(at: 193))
    }

    @Test func aSkipFromFullFallsOverItsOwnShortLength() {
        var m = Machine(settings: Settings(), seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: 200))
        for _ in 0..<2000 { _ = m.handle(.tick(0.01)) }
        _ = m.handle(.skip)
        guard case .track(let t) = m.phase else { Issue.record("no track"); return }
        #expect(near(t.fallLength, 0.5625))
        #expect(near(t.visual(at: t.outStart).cover, 1))
        #expect(t.visual(at: t.outStart + 1).silent)
    }

    @Test func aSkipMidFallCarriesOnFromWhereTheCoverIs() {
        var settings = Settings()
        (settings.fadeIn, settings.fadeOut) = (6, 8)
        var m = Machine(settings: settings, seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: 100))
        for _ in 0..<9400 { _ = m.handle(.tick(0.01)) } // two seconds into the fall
        guard case .track(let before) = m.phase else { Issue.record("no track"); return }
        let level = before.visual(at: before.elapsed)
        _ = m.handle(.skip)
        guard case .track(let t) = m.phase else { Issue.record("no track"); return }
        #expect(near(t.visual(at: t.outStart).cover, level.cover))
        #expect(near(t.visual(at: t.outStart).text, level.text))
    }

    @Test func aSkipMidRiseDoesntJumpUp() {
        var settings = Settings()
        (settings.fadeIn, settings.fadeOut) = (6, 8)
        var m = Machine(settings: settings, seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: 100))
        for _ in 0..<40 { _ = m.handle(.tick(0.01)) }
        guard case .track(let before) = m.phase else { Issue.record("no track"); return }
        let level = before.visual(at: before.elapsed)
        _ = m.handle(.skip)
        guard case .track(let t) = m.phase else { Issue.record("no track"); return }
        let start = t.visual(at: t.outStart)
        #expect(near(start.cover, level.cover))
        #expect(near(start.text, level.text))
        #expect(t.visual(at: t.outStart + 1).cover <= level.cover + 0.0001)
    }

    @Test func noFadesAtAllDoesntDivideByZero() {
        let t = Track(duration: 10, fadeIn: 0, outStart: 10, outLength: 0)
        #expect(t.visual(at: 0).cover == 1)
        #expect(t.visual(at: 10).silent)
        #expect(t.visual(at: 10).cover.isFinite)
    }

    @Test func multiplyStrengthMatchesThePrototype() {
        #expect(near(Track.multiplied(0.25), 0.4))
        #expect(Track.multiplied(1) == 1)
        #expect(Track.multiplied(0) == 0)
    }
}
