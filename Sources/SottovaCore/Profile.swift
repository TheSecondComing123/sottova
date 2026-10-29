import Foundation

/// A playback profile. Saved as versioned JSON (schema 1) so v0.2's arc can reuse it as a list of profiles.
public struct Settings: Equatable, Sendable {
    public var name = "Short"
    public var gapMin = 30.0
    public var gapMax = 120.0
    public var fadeIn = 4.0
    public var fadeOut = 6.0
    public var curve = FadeCurve.quartic
    /// Overlaps tracks with an equal-power crossfade instead of resting between them.
    public var crossfade = false
    public var crossfadeSec = 4.0
    public var avoidLastN = 10
    public var targetLufs = -18.0
    public var ceilingDbtp = -1.0

    public init() {}

    public var gapRange: ClosedRange<Double> {
        min(gapMin, gapMax)...max(gapMin, gapMax)
    }

    /// How long `count` tracks take with an average gap between each pair, for "about 2 h with gaps".
    public func lengthWithGaps(count: Int, music: Double) -> Double {
        guard !crossfade, count > 1 else { return music }
        return music + (gapRange.lowerBound + gapRange.upperBound) / 2 * Double(count - 1)
    }

    public static let presets: [Settings] = [
        preset("Minecraft", gap: 600...1200, fadeIn: 6, fadeOut: 8),
        preset("Sparse", gap: 180...480, fadeIn: 6, fadeOut: 8),
        preset("Short", gap: 30...120, fadeIn: 4, fadeOut: 6),
        preset("Continuous", gap: 0...0, fadeIn: 3, fadeOut: 3, crossfade: true),
    ]

    private static func preset(_ name: String, gap: ClosedRange<Double>, fadeIn: Double, fadeOut: Double, crossfade: Bool = false) -> Settings {
        var s = Settings()
        s.name = name
        s.gapMin = gap.lowerBound
        s.gapMax = gap.upperBound
        s.fadeIn = fadeIn
        s.fadeOut = fadeOut
        s.crossfade = crossfade
        return s
    }

    /// True when every field but the name matches the preset of the same name.
    public var matchesPreset: Bool {
        Self.presets.contains(self)
    }
}

extension Settings: Codable {
    private enum Keys: String, CodingKey {
        case schema, name, gap, fade, crossfade, selection, loudness
    }

    private struct Gap: Codable { var minSec, maxSec: Double }
    private struct Fade: Codable { var inSec, outSec: Double; var curve: FadeCurve }
    private struct Crossfade: Codable { var enabled: Bool; var sec: Double }
    private struct Selection: Codable { var avoidLastN: Int }
    private struct Level: Codable { var targetLufs, ceilingDbtp: Double }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let schema = try c.decode(Int.self, forKey: .schema)
        guard schema == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: c, debugDescription: "profile schema \(schema) is newer than this build understands")
        }
        name = try c.decode(String.self, forKey: .name)
        let gap = try c.decode(Gap.self, forKey: .gap)
        let fade = try c.decode(Fade.self, forKey: .fade)
        let crossfade = try c.decode(Crossfade.self, forKey: .crossfade)
        let level = try c.decode(Level.self, forKey: .loudness)
        (gapMin, gapMax) = (gap.minSec, gap.maxSec)
        (fadeIn, fadeOut, curve) = (fade.inSec, fade.outSec, fade.curve)
        (self.crossfade, crossfadeSec) = (crossfade.enabled, crossfade.sec)
        avoidLastN = try c.decode(Selection.self, forKey: .selection).avoidLastN
        (targetLufs, ceilingDbtp) = (level.targetLufs, level.ceilingDbtp)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(1, forKey: .schema)
        try c.encode(name, forKey: .name)
        try c.encode(Gap(minSec: gapMin, maxSec: gapMax), forKey: .gap)
        try c.encode(Fade(inSec: fadeIn, outSec: fadeOut, curve: curve), forKey: .fade)
        try c.encode(Crossfade(enabled: crossfade, sec: crossfadeSec), forKey: .crossfade)
        try c.encode(Selection(avoidLastN: avoidLastN), forKey: .selection)
        try c.encode(Level(targetLufs: targetLufs, ceilingDbtp: ceilingDbtp), forKey: .loudness)
    }
}

extension Settings {
    /// These gaps and fades over `base`'s curve, shuffle and loudness, for an album that plays with its own gaps.
    public func gaps(over base: Settings) -> Settings {
        var s = base
        s.name = name
        (s.gapMin, s.gapMax) = (gapMin, gapMax)
        (s.fadeIn, s.fadeOut) = (fadeIn, fadeOut)
        (s.crossfade, s.crossfadeSec) = (crossfade, crossfadeSec)
        return s
    }
}

/// profile.json: the user's own settings at the top level, plus the albums that play with their own gaps.
struct ProfileFile: Codable {
    var settings: Settings
    var albums: [String: Settings]

    private enum Keys: String, CodingKey {
        case albums
    }

    init(settings: Settings, albums: [String: Settings]) {
        self.settings = settings
        self.albums = albums
    }

    init(from decoder: any Decoder) throws {
        settings = try Settings(from: decoder)
        albums = try decoder.container(keyedBy: Keys.self).decodeIfPresent([String: Settings].self, forKey: .albums) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
        try settings.encode(to: encoder)
        if !albums.isEmpty {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(albums, forKey: .albums)
        }
    }
}
