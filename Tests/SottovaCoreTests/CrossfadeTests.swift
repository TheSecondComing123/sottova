import Foundation
import Testing
@testable import SottovaCore

struct CrossfadeTests {
    private func continuous() -> Machine {
        var m = Machine(settings: Settings.presets.first { $0.name == "Continuous" }!, seed: 1)
        _ = m.handle(.start)
        _ = m.handle(.trackStarted(duration: 20))
        return m
    }

    /// Ticks until the hand-off and starts the next track right away, as the controller does.
    private func handOff(_ m: inout Machine) {
        while !m.handle(.tick(0.01)).contains(.handOff) {}
        _ = m.handle(.trackStarted(duration: 20))
    }

    private func tick(_ m: inout Machine, seconds: Double) -> [Machine.Effect] {
        (0..<Int((seconds * 100).rounded())).flatMap { _ in m.handle(.tick(0.01)) }
    }

    @Test func nextTrackStartsFourSecondsBeforeTheEnd() {
        var m = continuous()
        let effects = tick(&m, seconds: 15.98)
        #expect(effects.suffix(2) == [.handOff, .startNextTrack])
        #expect(m.outgoing != nil)
        #expect(!effects.contains(.stopTrack(skipped: false)))
    }

    @Test func overlapKeepsConstantPowerAndNeverRests() {
        var m = continuous()
        handOff(&m)
        var incoming = 0.0
        var outgoing = 0.0
        var overlapTicks = 0
        for _ in 0..<500 {
            for effect in m.handle(.tick(0.01)) {
                switch effect {
                case .setGain(let g): incoming = g
                case .setOutgoingGain(let g): outgoing = g
                default: break
                }
            }
            guard m.outgoing != nil else { break }
            overlapTicks += 1
            // the two decks tick a hair apart, so allow one tick's worth of drift
            #expect(abs(incoming * incoming + outgoing * outgoing - 1) < 0.01)
        }
        #expect(overlapTicks > 390 && overlapTicks <= 400)
        #expect(m.outgoing == nil)
        #expect(m.status == .playing)
    }

    @Test func equalPowerHalvesSumToOne() {
        var track = Track(duration: 8, fadeIn: 4, outStart: 4, outLength: 4)
        track.equalPowerIn = true
        track.equalPowerOut = true
        var rng = SplitMix64(seed: 9)
        for _ in 0..<10_000 {
            let p = Double.random(in: 0...1, using: &rng)
            let fadingIn = track.gain(at: 4 * p, .quartic)
            let fadingOut = track.gain(at: 4 + 4 * p, .quartic)
            #expect(abs(fadingIn * fadingIn + fadingOut * fadingOut - 1) < 1e-9)
        }
    }

    @Test func pauseDuringOverlapPausesBothDecks() {
        var m = continuous()
        handOff(&m)
        #expect(m.handle(.pause) == [.pausePlayback])
        #expect(tick(&m, seconds: 10).isEmpty)
        #expect(m.handle(.resume) == [.resumePlayback])
        #expect(m.outgoing != nil)
    }
}

struct ProfileTests {
    @Test func profileRoundTripsThroughSchemaOneJSON() throws {
        for preset in Settings.presets {
            let data = try JSONEncoder().encode(preset)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["schema"] as? Int == 1)
            #expect((json["gap"] as? [String: Double])?["maxSec"] == preset.gapMax)
            #expect(try JSONDecoder().decode(Settings.self, from: data) == preset)
        }
    }

    @Test func newerSchemaIsRejected() {
        let json = #"{"schema": 2, "name": "x"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
    }

    @Test @MainActor func editingAPresetMakesItCustom() {
        let controller = Controller(storage: nil)
        controller.apply(Settings.presets[0])
        #expect(controller.settings.name == "Minecraft")
        controller.settings.gapMin = 300
        #expect(controller.settings.name == "Custom")
        #expect(controller.settings.gapMin == 300)
    }

    @Test @MainActor func urlSchemeDrivesPresets() {
        let controller = Controller(storage: nil)
        controller.open(URL(string: "sottova://preset/sparse")!)
        #expect(controller.settings.name == "Sparse")
        controller.acceptsURLs = false
        controller.open(URL(string: "sottova://preset/minecraft")!)
        #expect(controller.settings.name == "Sparse")
        controller.acceptsURLs = true
    }
}
