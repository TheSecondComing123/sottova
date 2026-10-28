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
    /// Crossfade halves use sin/cos so the overlap keeps constant power.
    var equalPowerIn = false
    var equalPowerOut = false

    var finished: Bool {
        elapsed >= outStart + outLength || elapsed >= duration
    }

    /// Envelope gain at any point of the track, so the UI can draw the whole shape.
    public func gain(at t: Double, _ curve: FadeCurve) -> Double {
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
    }

    enum Effect: Equatable {
        case startNextTrack, setGain(Double), stopTrack(skipped: Bool), pausePlayback, resumePlayback
        /// Crossfade: the current deck keeps fading out as the outgoing one; the next track starts on the other deck.
        case handOff, setOutgoingGain(Double), stopOutgoing
    }

    var settings: Settings
    private(set) var phase = Phase.idle
    private(set) var paused = false
    /// The track fading out under the next one during a crossfade.
    private(set) var outgoing: Track?
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

    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        if case .tick(let dt) = event, !paused, var track = outgoing {
            track.elapsed += dt
            if track.finished {
                outgoing = nil
                effects.append(.stopOutgoing)
            } else {
                outgoing = track
                effects.append(.setOutgoingGain(track.gain(settings.curve)))
            }
        }
        return effects + handleCurrent(event)
    }

    private mutating func handleCurrent(_ event: Event) -> [Effect] {
        switch (event, phase) {
        case (.start, .idle):
            phase = .loading
            return [.startNextTrack]

        case (.stop, _):
            phase = .idle
            paused = false
            outgoing = nil
            crossfadeNext = false
            return []

        case (.trackStarted(let duration), .loading):
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
            crossfadeNext = false
            phase = .track(track)
            return paused ? [.setGain(0), .pausePlayback] : [.setGain(0)]

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

        case (.skip, .resting):
            paused = false
            phase = .loading
            return [.startNextTrack]

        case (.tick(let dt), .track(var track)) where !paused:
            track.elapsed += dt
            if track.equalPowerOut, settings.crossfade, track.elapsed >= track.outStart {
                // the next track starts underneath while this one keeps fading on the other deck
                outgoing = track
                crossfadeNext = true
                phase = .loading
                return [.handOff, .startNextTrack]
            }
            guard track.finished else {
                phase = .track(track)
                return [.setGain(track.gain(settings.curve))]
            }
            if track.skipping {
                phase = .loading
                return [.setGain(0), .stopTrack(skipped: true), .startNextTrack]
            }
            phase = .resting(elapsed: 0, gap: Double.random(in: settings.gapRange, using: &rng))
            return [.setGain(0), .stopTrack(skipped: false)]

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
