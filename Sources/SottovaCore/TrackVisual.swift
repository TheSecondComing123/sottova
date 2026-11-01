import Foundation

/// What Now draws at a point in a piece. Pure, from the envelope, and shorter than the audio's fades: the sound is
/// already nearly gone when its quartic curve is halfway.
extension Track {
    public struct Visual: Equatable, Sendable {
        /// This piece's cover.
        public var cover: Double
        /// The last piece's cover, under this one as it rises.
        public var under: Double
        public var scale: Double
        public var text: Double
        public var hairline: Double
        /// "Silence" has the title's place.
        public var silent: Bool

        /// Held still by a pause: never a blank page, since the words say what to do.
        public var paused: Visual {
            var held = self
            held.text = 1
            held.cover = max(cover, Track.afterimage)
            return held
        }

        public static let full = Visual(cover: 1, under: 0, scale: 1, text: 1, hairline: 1, silent: false)
        /// A silence with nothing moving, as when a relaunch lands in one.
        public static let resting = Visual(cover: afterimage, under: 0, scale: 1, text: 1, hairline: 0, silent: true)
    }

    public static let afterimage = 0.25
    static let silenceFade = 1.5

    public var fallLength: Double { outLength * 0.5625 }
    public var riseLength: Double { fadeIn * 2 / 3 }

    public func visual(at t: Double) -> Visual {
        if t >= outStart {
            let from = visualFrom ?? arrival(at: outStart)
            // a skip once the screen already reads as silence has nothing left to fall
            if from.silent { return Visual(cover: from.cover, under: 0, scale: 1, text: from.text, hairline: 0, silent: true) }
            let floor = min(Self.afterimage, from.cover)
            let end = outStart + fallLength
            guard t < end else {
                return Visual(cover: floor, under: 0, scale: 1, text: Self.clamp((t - end) / Self.silenceFade), hairline: 0, silent: true)
            }
            let p = (t - outStart) / fallLength
            let g = (1 - p) * (1 - p)
            return Visual(cover: floor + (from.cover - floor) * g, under: from.under * g, scale: from.scale,
                          text: min(from.text, Self.clamp(g * 1.6)), hairline: Self.clamp(1 - (p - 0.8) / 0.2), silent: false)
        }
        return arrival(at: t)
    }

    /// Seconds from t in which nothing above changes; infinity once a silence has settled.
    public func stillFor(at t: Double) -> Double {
        if t >= outStart { return t >= outStart + fallLength + Self.silenceFade ? .infinity : 0 }
        return seekedAt == nil && t < riseLength ? 0 : outStart - t
    }

    /// A multiplied layer needs more strength than a plain one to read the same.
    public static func multiplied(_ opacity: Double) -> Double {
        opacity * (1 + 0.8 * (1 - opacity))
    }

    /// A seek's own 1.5 s fade doesn't dim anything: only a piece arriving rises.
    private func arrival(at t: Double) -> Visual {
        guard seekedAt == nil, t < riseLength else { return .full }
        let p = t / riseLength
        let eased = Self.ease(p)
        return Visual(cover: Self.ease(min(p * 1.15, 1)), under: (equalPowerIn ? 1 : Self.afterimage) * (1 - eased),
                      scale: 0.985 + 0.015 * eased, text: Self.clamp((p - 0.1) / 0.6), hairline: 1, silent: false)
    }

    private static func ease(_ p: Double) -> Double { p * p * (3 - 2 * p) }
    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
