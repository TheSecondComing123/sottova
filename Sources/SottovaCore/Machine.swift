import Foundation

public enum PlaybackStatus: Sendable {
    case idle, playing, resting, paused
}

public struct Track: Equatable, Sendable {
    public internal(set) var elapsed = 0.0
    public internal(set) var duration: Double
    public internal(set) var fadeIn: Double
    public internal(set) var outStart: Double
    public internal(set) var outLength: Double
    var outFrom = 1.0
    var skipping = false
    /// Where the last seek landed: from there the sound comes back up from silence, never starting loud.
    var seekedAt: Double?

    /// A seek's own fade-in: short, so trying a few spots isn't seconds of quiet each time.
    static let seekFade = 1.5
    /// Crossfade halves use sin/cos so the overlap keeps constant power.
    var equalPowerIn = false
    var equalPowerOut = false

    var finished: Bool {
        elapsed >= outStart + outLength || elapsed >= duration
    }

    /// Envelope gain at any point of the track, so the UI can draw the whole shape.
    public func gain(at t: Double, _ curve: FadeCurve) -> Double {
        let envelope = baseGain(at: t, curve)
        guard let seekedAt, t >= seekedAt else { return envelope }
        return envelope * curve.fadeIn((t - seekedAt) / Self.seekFade)
    }

    /// Seconds from t during which the gain holds still; 0 while it's moving. The audio clock and the hero both
    /// slow down for exactly this stretch.
    public func steady(from t: Double) -> Double {
        if let seekedAt, t < seekedAt + Self.seekFade { return 0 }
        return t >= fadeIn && t < outStart ? outStart - t : 0
    }

    private func baseGain(at t: Double, _ curve: FadeCurve) -> Double {
        if t >= outStart {
            let p = outLength > 0 ? min((t - outStart) / outLength, 1) : 1
            return outFrom * (equalPowerOut ? cos(.pi / 2 * p) : curve.fadeOut(p))
        }
        guard fadeIn > 0 else { return 1 }
        let p = min(max(t / fadeIn, 0), 1)
        return equalPowerIn ? sin(.pi / 2 * p) : curve.fadeIn(p)
    }

    func gain(_ curve: FadeCurve) -> Double {
        gain(at: elapsed, curve)
    }

    /// Shares of the drawn width for each fade. At true scale an 8 s fade is 2% of an 8-minute piece and the shape reads as a flat bar.
    static let fadeInShare = 0.12
    static let fadeOutShare = 0.16

    /// Where time t falls along the drawn track, 0...1: the fade-in takes 12%, the fade-out 16%, the hold what's left.
    public func position(at t: Double) -> Double {
        let (a, b, c) = landmarks
        let hold = 1 - Self.fadeInShare - Self.fadeOutShare
        if t <= a { return a > 0 ? Self.fadeInShare * max(t, 0) / a : 0 }
        if t <= b { return Self.fadeInShare + hold * (t - a) / (b - a) }
        return Self.fadeInShare + hold + Self.fadeOutShare * (c > b ? min((t - b) / (c - b), 1) : 1)
    }

    /// The inverse of position(at:), so a drawing can sample the envelope evenly across its width.
    public func time(at position: Double) -> Double {
        let (a, b, c) = landmarks
        let p = min(max(position, 0), 1)
        let holdEnd = 1 - Self.fadeOutShare
        if p <= Self.fadeInShare { return a * p / Self.fadeInShare }
        if p <= holdEnd { return a + (b - a) * (p - Self.fadeInShare) / (holdEnd - Self.fadeInShare) }
        return b + (c - b) * (p - holdEnd) / Self.fadeOutShare
    }

    /// End of fade-in, start and end of fade-out, kept in order for very short tracks.
    private var landmarks: (Double, Double, Double) {
        let b = max(outStart, fadeIn)
        return (fadeIn, b, max(outStart + outLength, b))
    }
}

/// Pure playback logic: events in, effects out. All time is in seconds of unpaused playback.
struct Machine: Sendable {
    enum Phase: Equatable {
        case idle
        case loading
        case track(Track)
        case resting(elapsed: Double, gap: Double)
    }

    enum Event {
        case start, stop, trackStarted(duration: Double), trackFailed, tick(Double), skip, pause, resume
        case sleep(after: Double), sleepAfterCurrent, cancelSleep, sleepNow
        /// An alarm: start silent and come up to full over `riseLength` seconds of sound.
        case rise
        case seek(to: Double)
        /// After a relaunch: the piece at this point, or a gap with this much left, paused. Nothing plays until resume.
        case restoreTrack(duration: Double, at: Double)
        case restoreRest(left: Double)
        /// The answer to `planGap`: how long this silence lasts.
        case gap(Double)
    }

    /// Stop after `left` more seconds of playing time, easing the volume down over the last `fade` of them;
    /// or stop when the piece playing ends (in a gap: the next one).
    enum Sleep: Equatable {
        case timer(left: Double, fade: Double)
        case afterCurrent
    }

    /// How long the sleep timer takes to ease the volume down to nothing.
    static let sleepFade = 180.0
    static let riseLength = 90.0

    enum Effect: Equatable {
        case startNextTrack, setGain(Double), stopTrack(skipped: Bool), pausePlayback, resumePlayback
        /// Play the current file from this many seconds in.
        case seekPlayback(Double)
        /// Crossfade: the current deck keeps fading out as the outgoing one; the next track starts on the other deck.
        case handOff, setOutgoingGain(Double), stopOutgoing
        /// A piece ended and the silence began: choose its length, now that what comes next can be seen.
        case planGap
    }

    var settings: Settings
    private(set) var phase = Phase.idle
    private(set) var paused = false
    /// The track fading out under the next one during a crossfade.
    private(set) var outgoing: Track?
    private(set) var sleep: Sleep?
    /// Seconds of sound left in an alarm's rise.
    private(set) var rise: Double?
    private var crossfadeNext = false
    private var rng: SplitMix64

    init(settings: Settings, seed: UInt64 = .random(in: .min ... .max)) {
        self.settings = settings
        rng = SplitMix64(seed: seed)
    }

    var status: PlaybackStatus {
        if paused { return .paused }
        switch phase {
        case .idle: return .idle
        case .loading, .track: return .playing
        case .resting: return .resting
        }
    }

    var restRemaining: Double? {
        guard case .resting(let elapsed, let gap) = phase else { return nil }
        return gap - elapsed
    }

    private var hasAudio: Bool {
        if case .track = phase { return true }
        return outgoing != nil
    }

    /// The sleep timer's ease-down, over whatever the envelope is doing. dB-linear, so it gets quieter at an even rate.
    /// How far into the ease-down, for drawing: 1 until it starts, 0 at the end. Linear, unlike the sound, which
    /// is at −20 dB by the last two minutes and would draw as nothing.
    var sleepLevel: Double {
        guard case .timer(let left, let fade) = sleep, left < fade, fade > 0 else { return 1 }
        return max(left, 0) / fade
    }

    var sleepGain: Double {
        guard case .timer(let left, let fade) = sleep, left < fade, fade > 0 else { return 1 }
        return FadeCurve.dbLinear.fadeIn(max(left, 0) / fade)
    }

    /// The alarm's rise, dB-linear like the ease-down, so it gets louder at an even rate.
    var riseGain: Double {
        guard let rise else { return 1 }
        return FadeCurve.dbLinear.fadeIn(1 - rise / Self.riseLength)
    }

    /// What the sleep timer and an alarm's rise do to the envelope.
    private var level: Double {
        sleepGain * riseGain
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .sleep(let seconds):
            guard phase != .idle, seconds > 0 else { return [] }
            sleep = .timer(left: seconds, fade: min(Self.sleepFade, seconds))
            return currentGains()
        case .sleepAfterCurrent:
            guard phase != .idle else { return [] }
            sleep = .afterCurrent
            return currentGains()
        case .cancelSleep:
            sleep = nil
            return currentGains()
        case .sleepNow:
            return goToSleep()
        case .rise:
            guard phase != .idle else { return [] }
            rise = Self.riseLength
            return currentGains()
        default:
            break
        }
        // only sound counts, so a gap or a pause holds the rise where it is
        if case .tick(let dt) = event, !paused, hasAudio, let left = rise {
            rise = left - dt > 0 ? left - dt : nil
        }
        if case .tick(let dt) = event, !paused, case .timer(let left, let fade) = sleep {
            sleep = .timer(left: left - dt, fade: fade)
            // once the ease-down has begun, a gap ends here rather than starting a piece to fade out
            if left - dt <= 0 || (left - dt <= fade && !hasAudio) {
                return goToSleep()
            }
        }
        var effects: [Effect] = []
        if case .tick(let dt) = event, !paused, var track = outgoing {
            track.elapsed += dt
            if track.finished {
                outgoing = nil
                effects.append(.stopOutgoing)
            } else {
                outgoing = track
                effects.append(.setOutgoingGain(track.gain(settings.curve) * level))
            }
        }
        return effects + handleCurrent(event)
    }

    private func makeTrack(duration: Double) -> Track {
        // each fade gets at most half of a short track
        let crossfadeLength = min(settings.crossfadeSec, duration / 2)
        let fadeIn = crossfadeNext ? crossfadeLength : min(settings.fadeIn, duration / 2)
        let fadeOut = settings.crossfade ? crossfadeLength : min(settings.fadeOut, duration / 2)
        // A mixer whose input runs out freezes its volume ramp and finishes it when that deck's next track starts.
        // Ending the crossfade 30 ms before the audio lets the mixer land on 0 while it still has input.
        let tail = settings.crossfade ? min(0.03, duration / 4) : 0
        var track = Track(duration: duration, fadeIn: fadeIn, outStart: duration - fadeOut - tail, outLength: fadeOut)
        track.equalPowerIn = crossfadeNext
        track.equalPowerOut = settings.crossfade
        return track
    }

    /// Gains for the decks right now, after the sleep timer or the rise changed.
    private func currentGains() -> [Effect] {
        var effects: [Effect] = []
        if case .track(let track) = phase {
            effects.append(.setGain(track.gain(settings.curve) * level))
        }
        if let outgoing {
            effects.append(.setOutgoingGain(outgoing.gain(settings.curve) * level))
        }
        return effects
    }

    private mutating func goToSleep() -> [Effect] {
        var effects: [Effect] = []
        if outgoing != nil {
            outgoing = nil
            effects.append(.stopOutgoing)
        }
        if case .track = phase {
            effects += [.setGain(0), .stopTrack(skipped: false)]
        }
        phase = .idle
        paused = false
        sleep = nil
        rise = nil
        crossfadeNext = false
        return effects
    }

    private mutating func handleCurrent(_ event: Event) -> [Effect] {
        switch (event, phase) {
        case (.start, .idle):
            phase = .loading
            return [.startNextTrack]

        case (.stop, _):
            phase = .idle
            paused = false
            sleep = nil
            rise = nil
            outgoing = nil
            crossfadeNext = false
            return []

        case (.trackStarted(let duration), .loading):
            phase = .track(makeTrack(duration: duration))
            crossfadeNext = false
            return paused ? [.setGain(0), .pausePlayback] : [.setGain(0)]

        case (.restoreTrack(let duration, let at), .idle):
            var track = makeTrack(duration: duration)
            // it comes back up from silence, like a seek
            track.elapsed = min(max(at, 0), max(duration - 0.5, 0))
            track.seekedAt = track.elapsed
            phase = .track(track)
            paused = true
            return []

        case (.restoreRest(let left), .idle):
            phase = .resting(elapsed: 0, gap: max(left, 0))
            paused = true
            return []

        case (.trackFailed, .loading):
            return [.startNextTrack]

        case (.pause, _) where !paused && phase != .idle:
            paused = true
            return hasAudio ? [.pausePlayback] : []

        case (.resume, _) where paused:
            paused = false
            return hasAudio ? [.resumePlayback] : []

        case (.skip, .track(var track)) where !track.skipping:
            track.outFrom = track.gain(settings.curve)
            track.outStart = track.elapsed
            track.outLength = min(1, track.duration - track.elapsed)
            track.skipping = true
            track.equalPowerOut = false
            phase = .track(track)
            let wasPaused = paused
            paused = false
            return wasPaused ? [.resumePlayback] : []

        case (.seek(let target), .track(var track)) where !track.skipping:
            // never past the last half second, which would end the piece before its fade could start
            let to = min(max(target, 0), max(track.duration - 0.5, 0))
            track.elapsed = to
            track.seekedAt = to
            phase = .track(track)
            return [.setGain(0), .seekPlayback(to)]

        case (.skip, .resting):
            paused = false
            phase = .loading
            return [.startNextTrack]

        case (.tick(let dt), .track(var track)) where !paused:
            track.elapsed += dt
            if track.equalPowerOut, settings.crossfade, sleep != .afterCurrent, track.elapsed >= track.outStart {
                // the next track starts underneath while this one keeps fading on the other deck
                outgoing = track
                crossfadeNext = true
                phase = .loading
                return [.handOff, .startNextTrack]
            }
            guard track.finished else {
                phase = .track(track)
                return [.setGain(track.gain(settings.curve) * level)]
            }
            if sleep == .afterCurrent, !track.skipping {
                return goToSleep()
            }
            if track.skipping {
                phase = .loading
                return [.setGain(0), .stopTrack(skipped: true), .startNextTrack]
            }
            // a draw from these settings stands until `planGap` is answered, as it never is when the machine runs alone
            phase = .resting(elapsed: 0, gap: Double.random(in: settings.gapRange, using: &rng))
            return [.setGain(0), .planGap, .stopTrack(skipped: false)]

        case (.gap(let gap), .resting(let elapsed, _)):
            phase = .resting(elapsed: elapsed, gap: gap)
            return []

        case (.tick(let dt), .resting(let elapsed, let gap)) where !paused:
            guard elapsed + dt >= gap else {
                phase = .resting(elapsed: elapsed + dt, gap: gap)
                return []
            }
            phase = .loading
            return [.startNextTrack]

        default:
            return []
        }
    }
}
