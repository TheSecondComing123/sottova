import Foundation

/// One line of the dogfood log. M2 imports these into the `play` table.
struct PlayRecord: Codable {
    var file: String
    var startedAt: Date
    var skipped: Bool
    var gapAfterSec: Double

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
