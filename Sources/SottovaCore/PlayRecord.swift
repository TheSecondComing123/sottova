import Foundation

/// One line of the dogfood log. M2 imports these into the `play` table.
struct PlayRecord: Codable {
    var file: String
    var startedAt: Date
    var skipped: Bool
    var gapAfterSec: Double

    /// The last files played, oldest first, so avoid-last-N survives a relaunch.
    static func recentFiles(in url: URL, count: Int = 20) -> [String] {
        read(url, last: count).map(\.file)
    }

    static func read(_ url: URL, last count: Int = .max) -> [PlayRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(count).compactMap {
            try? decoder.decode(PlayRecord.self, from: Data($0.utf8))
        }
    }

    /// The plays that started on `day`, with how much of each was heard and how long the quiet after it really lasted.
    /// The log has start times and the planned gap, not lengths: a finished track counts in full, a skipped one gets
    /// the time until the next start minus its gap, and a gap never counts longer than planned (the app may have quit).
    static func plays(_ records: [PlayRecord], durations: [String: Double], on day: Date, calendar: Calendar = .current) -> [Play] {
        let records = records.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
        return records.indices.map { i in
            let record = records[i]
            let duration = durations[record.file] ?? 0
            guard i + 1 < records.count else {
                return Play(file: record.file, startedAt: record.startedAt, played: duration, gapAfter: 0)
            }
            let span = records[i + 1].startedAt.timeIntervalSince(record.startedAt)
            let played = min(duration, max(0, record.skipped ? span - record.gapAfterSec : span))
            return Play(file: record.file, startedAt: record.startedAt, played: played, gapAfter: min(max(0, span - played), record.gapAfterSec))
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
