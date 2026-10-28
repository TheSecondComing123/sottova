import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var gapMin = 30.0
    public var gapMax = 120.0
    public var fadeIn = 4.0
    public var fadeOut = 6.0
    public var curve = FadeCurve.quartic

    public init() {}

    public var gapRange: ClosedRange<Double> {
        min(gapMin, gapMax)...max(gapMin, gapMax)
    }
}

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

    var finished: Bool {
        elapsed >= outStart + outLength || elapsed >= duration
    }

    /// Envelope gain at any point of the track, so the UI can draw the whole shape.
    public func gain(at t: Double, _ curve: FadeCurve) -> Double {
        if t >= outStart {
            return outFrom * curve.fadeOut(outLength > 0 ? (t - outStart) / outLength : 1)
        }
        return fadeIn > 0 ? curve.fadeIn(t / fadeIn) : 1
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
    }

    var settings: Settings
    private(set) var phase = Phase.idle
    private(set) var paused = false
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

    mutating func handle(_ event: Event) -> [Effect] {
        switch (event, phase) {
        case (.start, .idle):
            phase = .loading
            return [.startNextTrack]

        case (.stop, _):
            phase = .idle
            paused = false
            return []

        case (.trackStarted(let duration), .loading):
            // each fade gets at most half of a short track
            let fadeIn = min(settings.fadeIn, duration / 2)
            let fadeOut = min(settings.fadeOut, duration / 2)
            phase = .track(Track(duration: duration, fadeIn: fadeIn, outStart: duration - fadeOut, outLength: fadeOut))
            return paused ? [.setGain(0), .pausePlayback] : [.setGain(0)]

        case (.trackFailed, .loading):
            return [.startNextTrack]

        case (.pause, _) where !paused && phase != .idle:
            paused = true
            if case .track = phase { return [.pausePlayback] }
            return []

        case (.resume, _) where paused:
            paused = false
            if case .track = phase { return [.resumePlayback] }
            return []

        case (.skip, .track(var track)) where !track.skipping:
            track.outFrom = track.gain(settings.curve)
            track.outStart = track.elapsed
            track.outLength = min(1, track.duration - track.elapsed)
            track.skipping = true
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
