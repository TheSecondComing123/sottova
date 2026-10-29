import Testing
@testable import SottovaCore

struct SeekTests {
    private static let settings: Settings = {
        var s = Settings()
        s.fadeIn = 4
        s.fadeOut = 6
        return s
    }()

    private func playing(duration: Double = 180) -> Machine {
        var m = Machine(settings: Self.settings, seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: duration))
        return m
    }

    private func tick(_ m: inout Machine, seconds: Double) -> [Machine.Effect] {
        (0..<Int((seconds * 100).rounded())).flatMap { _ in m.handle(.tick(0.01)) }
    }

    private func gains(_ effects: [Machine.Effect]) -> [Double] {
        effects.compactMap { if case .setGain(let g) = $0 { g } else { nil } }
    }

    private func track(_ m: Machine) -> Track? {
        if case .track(let t) = m.phase { t } else { nil }
    }

    @Test func midHoldItComesBackUpFromSilence() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        #expect(m.handle(.seek(to: 90)) == [.setGain(0), .seekPlayback(90)])
        let g = gains(tick(&m, seconds: 2))
        #expect(zip(g, g.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(g.first! < 0.01)
        #expect(g.last! == 1)
        #expect(abs(track(m)!.elapsed - 92) < 0.001)
    }

    @Test func intoTheFadeOutItRisesToThatLevel() {
        var m = playing()
        _ = m.handle(.seek(to: 176))
        let g = gains(tick(&m, seconds: 1.5))
        let t = track(m)!
        #expect(abs(g.last! - t.gain(at: t.elapsed, Self.settings.curve)) < 0.0001)
        #expect(g.last! < 1)
    }

    @Test func pastTheEndIsClamped() {
        var m = playing()
        #expect(m.handle(.seek(to: 500)) == [.setGain(0), .seekPlayback(179.5)])
        #expect(m.handle(.seek(to: -3)) == [.setGain(0), .seekPlayback(0)])
    }

    @Test func aSkipInProgressIgnoresSeeks() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        _ = m.handle(.skip)
        #expect(m.handle(.seek(to: 60)) == [])
    }

    @Test func pausedStaysPaused() {
        var m = playing()
        _ = tick(&m, seconds: 10)
        _ = m.handle(.pause)
        _ = m.handle(.seek(to: 60))
        #expect(m.status == .paused)
        #expect(gains(tick(&m, seconds: 5)).isEmpty)
        #expect(track(m)!.elapsed == 60)
    }

    @Test func theGainIsMovingUntilTheSeekFadeEnds() {
        var m = playing()
        _ = m.handle(.seek(to: 60))
        let t = track(m)!
        #expect(t.steady(from: 60.5) == 0)
        #expect(t.steady(from: 62) == t.outStart - 62)
        #expect(t.steady(from: 2) == 0)
    }

    @Test func restoringAPieceIsPausedSilentAndFadesInOnResume() {
        var m = Machine(settings: Self.settings, seed: 1)
        #expect(m.handle(.restoreTrack(duration: 180, at: 60)) == [])
        #expect(m.status == .paused)
        #expect(gains(tick(&m, seconds: 5)).isEmpty)
        #expect(m.handle(.resume) == [.resumePlayback])
        let g = gains(tick(&m, seconds: 2))
        #expect(g.first! < 0.01 && g.last! == 1)
    }

    @Test func restoringAGapKeepsItsTimeLeft() {
        var m = Machine(settings: Self.settings, seed: 1)
        #expect(m.handle(.restoreRest(left: 40)) == [])
        #expect(m.status == .paused)
        _ = m.handle(.resume)
        #expect(m.status == .resting)
        #expect(tick(&m, seconds: 39).isEmpty)
        #expect(tick(&m, seconds: 1.5).contains(.startNextTrack))
    }
}
