import Testing
@testable import SottovaCore

struct SleepTests {
    private static let settings: Settings = {
        var s = Settings()
        s.gapMin = 30
        s.gapMax = 120
        s.fadeIn = 4
        s.fadeOut = 6
        return s
    }()

    private func playing(_ settings: Settings = Self.settings, duration: Double = 900) -> Machine {
        var m = Machine(settings: settings, seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: duration))
        return m
    }

    /// Ticks in 10 ms steps and returns every effect.
    private func tick(_ m: inout Machine, seconds: Double) -> [Machine.Effect] {
        (0..<Int((seconds * 100).rounded())).flatMap { _ in m.handle(.tick(0.01)) }
    }

    private func gains(_ effects: [Machine.Effect]) -> [Double] {
        effects.compactMap { if case .setGain(let g) = $0 { g } else { nil } }
    }

    @Test func easesDownOverTheLastThreeMinutesThenStops() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        _ = m.handle(.sleep(after: 300))
        #expect(gains(tick(&m, seconds: 119)).allSatisfy { $0 == 1 })
        let easing = tick(&m, seconds: 150)
        let g = gains(easing)
        #expect(zip(g, g.dropFirst()).allSatisfy { $0 >= $1 })
        // 30 s left of 180: dB-linear from 0 to −60 dB puts it at −50 dB
        #expect(abs(g.last! - FadeCurve.dbLinear.fadeIn(30.0 / 180)) < 0.001)
        let end = tick(&m, seconds: 32)
        #expect(end.suffix(2) == [.setGain(0), .stopTrack(skipped: false)])
        #expect(m.status == .idle)
        #expect(m.sleep == nil)
    }

    @Test func aGapInTheLastMinutesEndsInsteadOfStartingAPiece() {
        var m = playing(duration: 10)
        _ = tick(&m, seconds: 10.5)
        #expect(m.status == .resting)
        // the ease-down starts 20 s from now, before the shortest gap (30 s) is over
        _ = m.handle(.sleep(after: 200))
        let effects = tick(&m, seconds: 25)
        #expect(!effects.contains(.startNextTrack))
        #expect(m.status == .idle)
    }

    @Test func afterThisPieceStopsWhereItWouldRest() {
        var m = playing(duration: 20)
        _ = m.handle(.sleepAfterCurrent)
        let effects = tick(&m, seconds: 21)
        #expect(effects.suffix(2) == [.setGain(0), .stopTrack(skipped: false)])
        #expect(!effects.contains(.startNextTrack))
        #expect(m.status == .idle)
    }

    @Test func afterThisPieceInAGapMeansTheNextOne() {
        var m = playing(duration: 10)
        _ = tick(&m, seconds: 10.5)
        _ = m.handle(.sleepAfterCurrent)
        _ = tick(&m, seconds: 121)
        #expect(m.status == .playing)
        _ = m.handle(.trackStarted(duration: 10))
        _ = tick(&m, seconds: 10.5)
        #expect(m.status == .idle)
    }

    @Test func afterThisPieceDoesNotCrossfadeIntoTheNext() {
        var m = playing(Settings.presets.first { $0.name == "Continuous" }!, duration: 20)
        _ = m.handle(.sleepAfterCurrent)
        let effects = tick(&m, seconds: 21)
        #expect(!effects.contains(.handOff))
        #expect(!effects.contains(.startNextTrack))
        #expect(m.status == .idle)
    }

    @Test func pauseFreezesTheCountdown() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        _ = m.handle(.sleep(after: 300))
        _ = m.handle(.pause)
        _ = tick(&m, seconds: 1000)
        #expect(m.sleep == .timer(left: 300, fade: 180))
        _ = m.handle(.resume)
        #expect(gains(tick(&m, seconds: 100)).allSatisfy { $0 == 1 })
    }

    @Test func cancellingMidEaseBringsTheVolumeBack() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        _ = m.handle(.sleep(after: 200))
        _ = tick(&m, seconds: 100)
        #expect(m.sleepGain < 0.1)
        #expect(m.handle(.cancelSleep) == [.setGain(1)])
        #expect(gains(tick(&m, seconds: 200)).allSatisfy { $0 == 1 })
    }

    @Test func aShortTimerEasesDownOverItsWholeLength() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        _ = m.handle(.sleep(after: 60))
        #expect(m.sleep == .timer(left: 60, fade: 60))
        #expect(m.sleepGain == 1)
        _ = tick(&m, seconds: 30)
        #expect(m.sleepGain < 1)
    }

    @Test func idleIgnoresTheTimer() {
        var m = Machine(settings: Self.settings, seed: 1)
        _ = m.handle(.sleep(after: 600))
        _ = m.handle(.sleepAfterCurrent)
        #expect(m.sleep == nil)
    }

    @Test func sleepingNowStopsEvenInAGap() {
        var m = playing(duration: 10)
        _ = tick(&m, seconds: 10.5)
        _ = m.handle(.sleep(after: 3600))
        #expect(m.handle(.sleepNow) == [])
        #expect(m.status == .idle)
        var playingNow = playing()
        _ = playingNow.handle(.sleep(after: 3600))
        #expect(playingNow.handle(.sleepNow) == [.setGain(0), .stopTrack(skipped: false)])
    }
}
