import Foundation

public enum FadeCurve: String, Codable, CaseIterable, Sendable {
    case quartic
    case dbLinear

    /// Gain at progress p of a fade-in, from exactly 0 to exactly 1.
    public func fadeIn(_ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        switch self {
        case .quartic:
            return p * p * p * p
        case .dbLinear:
            // −60 dB floor, snapped to silence at the start
            return p == 0 ? 0 : pow(10, (-60 + 60 * p) / 20)
        }
    }

    public func fadeOut(_ p: Double) -> Double {
        fadeIn(1 - p)
    }
}
