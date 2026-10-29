import Foundation

/// The part of a file that plays: a spoken intro or applause cut off without touching the file.
public struct Trim: Codable, Equatable, Sendable {
    public var start: Double
    /// Seconds into the file where it stops; nil plays to the end.
    public var end: Double?

    public init(start: Double = 0, end: Double? = nil) {
        self.start = start
        self.end = end
    }

    /// The frames to schedule, kept inside the file and at least a second long.
    public func frames(sampleRate: Double, length: Int64) -> (start: Int64, end: Int64) {
        let first = min(max(Int64(start * sampleRate), 0), max(length - Int64(sampleRate), 0))
        let last = end.map { Int64($0 * sampleRate) } ?? length
        return (first, min(max(last, first + Int64(sampleRate)), length))
    }
}
