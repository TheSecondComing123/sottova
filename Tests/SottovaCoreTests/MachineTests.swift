import Testing
@testable import SottovaCore

struct MachineTests {
    private static let settings: Settings = {
        var s = Settings()
        s.gapMin = 30
        s.gapMax = 120
        s.fadeIn = 4
        s.fadeOut = 6
        return s
    }()

    private func playing(duration: Double = 180, seed: UInt64 = 1) -> Machine {
        var m = Machine(settings: Self.settings, seed: seed)
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

    @Test func startAsksForATrack() {
        var m = Machine(settings: Self.settings)
        #expect(m.handle(.start) == [.startNextTrack])
        #expect(m.handle(.trackStarted(duration: 180)) == [.setGain(0)])
        #expect(m.status == .playing)
    }

    @Test func theGapIsChosenAsThePieceEnds() {
        var m = playing(duration: 10)
        let effects = tick(&m, seconds: 10.01)
        // asked for before the stop, so the play log records the gap that was chosen
        #expect(effects.suffix(3) == [.setGain(0), .planGap, .stopTrack(skipped: false)])
        #expect(m.handle(.gap(7)) == [])
        #expect(m.restRemaining == 7)
        #expect(tick(&m, seconds: 6.9).isEmpty)
        #expect(tick(&m, seconds: 0.11) == [.startNextTrack])
    }

    @Test func breathRestsAFewSeconds() {
        let breath = Settings.presets.first { $0.name == "Breath" }!
        for seed in UInt64(1)...200 {
            var m = Machine(settings: breath, seed: seed)
            _ = m.handle(.start)
            _ = m.handle(.trackStarted(duration: 20))
            _ = tick(&m, seconds: 20.01)
            #expect((2...15).contains(m.restRemaining ?? -1))
        }
    }

    @Test func fullTrackFadesInHoldsFadesOutThenRests() {
        var m = playing()
        let effects = tick(&m, seconds: 181)
        let stop = effects.firstIndex(of: .stopTrack(skipped: false))!
        let g = gains(Array(effects[..<stop]))
        // 10 ms ticks: 4 s fade-in is the first 400 gains, 6 s fade-out the last 600.
        // Summing 0.01 drifts, so the hold check starts a few ticks past each boundary.
        #expect(zip(g[..<400], g[1..<400]).allSatisfy { $0 <= $1 })
        #expect(g[405..<(g.count - 605)].allSatisfy { $0 == 1 })
        #expect(zip(g[(g.count - 600)...], g[(g.count - 599)...]).allSatisfy { $0 >= $1 })
        #expect(g.last! < 0.001)
        #expect(m.status == .resting)
        #expect(Self.settings.gapRange.contains(m.restRemaining!))
    }

    @Test func gapsStayWithinBounds() {
        for seed in UInt64(0)..<1000 {
            var m = playing(duration: 10, seed: seed)
            _ = tick(&m, seconds: 10.5)
            guard case .resting(_, let gap) = m.phase else {
                Issue.record("not resting after the track")
                return
            }
            #expect(Self.settings.gapRange.contains(gap))
        }
    }

    @Test func restEndsWithNextTrack() {
        var m = playing(duration: 10)
        _ = tick(&m, seconds: 10.5)
        let effects = tick(&m, seconds: 121)
        #expect(effects == [.startNextTrack])
        #expect(m.phase == .loading)
    }

    @Test func shortTrackSplitsFadesInHalf() {
        var m = playing(duration: 4)
        guard case .track(let track) = m.phase else {
            Issue.record("not playing")
            return
        }
        #expect(track.fadeIn == 2)
        #expect(track.outStart == 2 && track.outLength == 2)
        #expect(tick(&m, seconds: 4.01).contains(.stopTrack(skipped: false)))
    }

    @Test func skipFadesOutInOneSecondAndSkipsTheGap() {
        var m = playing()
        _ = tick(&m, seconds: 60)
        #expect(m.handle(.skip) == [])
        let effects = tick(&m, seconds: 1.01)
        let g = gains(effects)
        #expect(zip(g, g.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(effects.suffix(2) == [.stopTrack(skipped: true), .startNextTrack])
        #expect(m.phase == .loading)
    }

    @Test func skipDuringFadeOutNeverJumpsUp() {
        var m = playing()
        let before = gains(tick(&m, seconds: 177)).last!
        _ = m.handle(.skip)
        #expect(gains(tick(&m, seconds: 1)).allSatisfy { $0 <= before })
    }

    @Test func skipWhileRestingStartsNextTrackNow() {
        var m = playing(duration: 10)
        _ = tick(&m, seconds: 10.5)
        #expect(m.handle(.skip) == [.startNextTrack])
    }

    @Test func skipWhilePausedResumesPlayback() {
        var m = playing()
        _ = m.handle(.pause)
        #expect(m.handle(.skip) == [.resumePlayback])
        #expect(m.status == .playing)
    }

    @Test func pauseInTrackFreezesGain() {
        var m = playing()
        _ = tick(&m, seconds: 2)
        #expect(m.handle(.pause) == [.pausePlayback])
        #expect(tick(&m, seconds: 100).isEmpty)
        #expect(m.handle(.resume) == [.resumePlayback])
        #expect(gains(tick(&m, seconds: 0.01)).first! < 1)
    }

    @Test func pauseInGapKeepsRemainingTime() {
        var m = playing(duration: 10)
        _ = tick(&m, seconds: 10.5)
        let remaining = m.restRemaining!
        #expect(m.handle(.pause) == [])
        _ = tick(&m, seconds: 1000)
        #expect(m.handle(.resume) == [])
        #expect(m.restRemaining == remaining)
        #expect(m.status == .resting)
    }

    @Test func failedTrackAsksForAnother() {
        var m = Machine(settings: Self.settings)
        _ = m.handle(.start)
        #expect(m.handle(.trackFailed) == [.startNextTrack])
    }

    @Test func trackThatLoadsWhilePausedStaysPaused() {
        var m = Machine(settings: Self.settings)
        _ = m.handle(.start)
        _ = m.handle(.pause)
        #expect(m.handle(.trackStarted(duration: 180)) == [.setGain(0), .pausePlayback])
    }

    @Test func stopReturnsToIdle() {
        var m = playing()
        _ = m.handle(.pause)
        _ = m.handle(.stop)
        #expect(m.status == .idle)
    }
}
