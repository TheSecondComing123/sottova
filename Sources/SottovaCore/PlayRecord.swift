import Foundation

/// One line of the dogfood log. M2 imports these into the `play` table.
struct PlayRecord: Codable {
    var file: String
    var startedAt: Date
    var skipped: Bool
    var gapAfterSec: Double
    /// Seconds of the track that played. Older lines don't have it.
    var heardSec: Double?

    static func read(_ url: URL, last count: Int = .max) -> [PlayRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(count).compactMap {
            try? decoder.decode(PlayRecord.self, from: Data($0.utf8))
        }
    }

    /// The plays that started on `day`, with how much of each was heard and how long the quiet after it really lasted.
    /// Lines from before heardSec was logged fall back to the track's length, or the time until the next start if that's
    /// shorter. A gap never counts longer than planned: the time until the next start can include a pause or a quit.
    static func plays(_ records: [PlayRecord], on day: Date, calendar: Calendar = .current, duration: (String) -> Double?) -> [Play] {
        let records = records.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
        return records.indices.compactMap { i in
            let record = records[i]
            let next = i + 1 < records.count ? records[i + 1].startedAt.timeIntervalSince(record.startedAt) : nil
            guard let played = record.heardSec ?? duration(record.file).map({ min($0, next ?? $0) }), played > 0 else { return nil }
            let gap = next.map { min(max(0, $0 - played), record.gapAfterSec) } ?? 0
            return Play(file: record.file, startedAt: record.startedAt, played: played, gapAfter: gap)
        }
    }

    func append(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(self)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

public struct Play: Equatable, Sendable {
    public let file: String
    public let startedAt: Date
    /// Seconds heard: the whole track unless it was skipped.
    public let played: Double
    public let gapAfter: Double
}
