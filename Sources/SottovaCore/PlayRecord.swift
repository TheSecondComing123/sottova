import Foundation

/// One line of the dogfood log. M2 imports these into the `play` table.
struct PlayRecord: Codable {
    var file: String
    var startedAt: Date
    var skipped: Bool
    var gapAfterSec: Double
    /// Seconds of the track that played. Older lines don't have it.
    var heardSec: Double?
    /// The row it played for. Older lines don't have it.
    var row: UUID?

    static func read(_ url: URL, last count: Int = .max) -> [PlayRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(count).compactMap {
            try? decoder.decode(PlayRecord.self, from: Data($0.utf8))
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
