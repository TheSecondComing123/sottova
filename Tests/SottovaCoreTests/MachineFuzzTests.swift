import Testing
@testable import SottovaCore

/// Random events from every state, checking after each what must always hold.
struct MachineFuzzTests {
    private enum Step {
        case event(Machine.Event)
        case crossfade(Bool)
    }

    private func randomStep(_ rng: inout SplitMix64) -> Step {
        let tick = [0.01, 0.5, 5, 90, 8.0 * 3600].randomElement(using: &rng)!
        let duration = [0.1, 3, 900].randomElement(using: &rng)!
        let length = Double.random(in: 0...1000, using: &rng)
        switch Int.random(in: 0..<30, using: &rng) {
        case 0: return .event(.start)
        case 1: return .event(.stop)
        case 2: return .event(.trackStarted(duration: duration))
        case 3: return .event(.trackFailed)
        case 4: return .event(.skip)
        case 5: return .event(.pause)
        case 6: return .event(.resume)
        case 7: return .event(.sleep(after: length))
        case 8: return .event(.sleepAfterCurrent)
        case 9: return .event(.cancelSleep)
        case 10: return .event(.sleepNow)
        case 11: return .event(.rise)
        case 12: return .event(.seek(to: length))
        case 13: return .event(.restoreTrack(duration: duration, at: length))
        case 14: return .event(.restoreRest(left: length))
        case 15: return .event(.gap(length))
        case 16: return .event(.wait(length))
        case 17: return .event(.hold(Bool.random(using: &rng)))
        case 18: return .crossfade(Bool.random(using: &rng))
        default: return .event(.tick(tick))
        }
    }

    /// What's wrong after `event` took `before` to `m`, if anything.
    private func broken(_ before: Machine, _ event: Machine.Event, _ m: Machine, _ effects: [Machine.Effect]) -> String? {
        if m.phase == .idle, m.sleep != nil || m.rise != nil || m.outgoing != nil || m.paused { return "idle with something left over" }
        if let rise = m.rise, !(rise > 0 && rise <= Machine.riseLength) { return "rise \(rise)" }
        for case .setGain(let gain) in effects where !gain.isFinite || !(0...1).contains(gain) { return "gain \(gain)" }
        for case .setOutgoingGain(let gain) in effects where !gain.isFinite || !(0...1).contains(gain) { return "outgoing gain \(gain)" }
        guard case .tick = event, before.paused || before.held else { return nil }
        if let rest = before.restRemaining, let after = m.restRemaining, rest != after { return "held rest moved from \(rest) to \(after)" }
        // a skip you pressed goes through a hold
        if case .track(let track) = before.phase, track.skipping, !before.paused { return nil }
        return effects.contains(.startNextTrack) ? "next track while paused or held" : nil
    }

    /// Runs one sequence; the final state includes the machine's own random numbers.
    private func run(seed: UInt64, steps: Int) -> (end: String, failure: String?) {
        var rng = SplitMix64(seed: seed)
        var settings = Settings()
        settings.crossfade = seed % 2 == 0
        var m = Machine(settings: settings, seed: seed)
        var answers: [Machine.Event] = []
        var trace: [Step] = []
        for _ in 0..<steps {
            let step = answers.isEmpty ? randomStep(&rng) : .event(answers.removeFirst())
            trace.append(step)
            guard case .event(let event) = step else {
                if case .crossfade(let on) = step { settings.crossfade = on }
                m.settings = settings
                continue
            }
            let before = m
            let effects = m.handle(event)
            if let problem = broken(before, event, m, effects) {
                return ("\(m)", "\(problem)\nseed \(seed)\n" + trace.map { "\($0)" }.joined(separator: "\n"))
            }
            // usually answered as the controller answers; sometimes left waiting while other things happen
            if effects.contains(.startNextTrack), Int.random(in: 0..<4, using: &rng) > 0 {
                answers.append(Bool.random(using: &rng) ? .trackStarted(duration: [0.1, 3, 900].randomElement(using: &rng)!) : .trackFailed)
            }
            if effects.contains(.planGap) { answers.append(.gap(Double.random(in: 0...100, using: &rng))) }
        }
        return ("\(m)", nil)
    }

    @Test func whatMustAlwaysHoldHolds() {
        for seed in UInt64(0)..<4000 {
            let (end, failure) = run(seed: seed, steps: 300)
            if let failure {
                Issue.record(Comment(rawValue: failure))
                return
            }
            if seed % 40 == 0, run(seed: seed, steps: 300).end != end {
                Issue.record("seed \(seed) ended differently the second time")
                return
            }
        }
    }
}
