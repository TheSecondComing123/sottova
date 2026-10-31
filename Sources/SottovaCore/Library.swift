import Foundation
import UniformTypeIdentifiers

/// Watched folders plus a per-file loudness cache, saved as one JSON file.
struct Library: Codable {
    struct Folder: Codable, Equatable {
        var bookmark: Data
        var path: String
    }

    struct Entry: Codable, Equatable {
        var size: Int
        var modified: Date
        var loudness: Loudness?
        var meta: TrackMeta?
        var unplayable = false
        /// When the file landed in its folder, as Finder's Date Added. Optional so older library.json files still load.
        var added: Date?
        /// Couldn't be read at the last scan, so it's out of play until a scan can see it. Its analysis stays.
        var unreachable: Bool?
    }

    struct FileStamp: Equatable {
        var size: Int
        var modified: Date
        var added: Date?
    }

    struct Scan {
        var found: [String: FileStamp] = [:]
        /// What couldn't be read, so its files can't be said to be gone.
        var unreachable: [String] = []
    }

    var folders: [Folder] = []
    var entries: [String: Entry] = [:]

    var playable: [String] {
        entries.filter { !$0.value.unplayable && $0.value.unreachable != true }.keys.sorted()
    }

    var unplayable: [String] {
        entries.filter { $0.value.unplayable }.keys.sorted()
    }

    var pending: [String] {
        entries.filter { ($0.value.loudness == nil || $0.value.meta == nil) && !$0.value.unplayable && $0.value.unreachable != true }.keys.sorted()
    }

    /// Keeps cached loudness for files whose size and mtime didn't change; drops files a scan got through without seeing.
    mutating func merge(_ scan: Scan) {
        var merged: [String: Entry] = [:]
        for (path, stamp) in scan.found {
            if let old = entries[path], old.size == stamp.size, old.modified == stamp.modified {
                merged[path] = old
            } else {
                merged[path] = Entry(size: stamp.size, modified: stamp.modified)
            }
            merged[path]?.added = stamp.added
            merged[path]?.unreachable = nil
        }
        for (path, entry) in entries where merged[path] == nil
            && scan.unreachable.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            merged[path] = entry
            merged[path]?.unreachable = true
        }
        entries = merged
    }

    /// Resolves bookmarks so moved or renamed folders are followed, refreshing stale ones. One that can't be found
    /// stays by its last path, listed and removable; the scan then says it can't be reached.
    mutating func resolveFolders() -> [URL] {
        folders.indices.map { i in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: folders[i].bookmark, bookmarkDataIsStale: &stale) else { return URL(filePath: folders[i].path) }
            if stale, let fresh = try? url.bookmarkData() {
                folders[i].bookmark = fresh
            }
            folders[i].path = url.path
            return url
        }
    }

    /// Stat-only walk: no file is opened, so rescans stay cheap.
    static func scan(_ folders: [URL]) -> Scan {
        var scan = Scan()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .addedToDirectoryDateKey]
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) { url, _ in
                scan.unreachable.append(url.path)
                return true
            }
            while let url = files?.nextObject() as? URL {
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    scan.unreachable.append(url.path)
                    continue
                }
                guard values.isRegularFile == true else { continue }
                scan.found[url.path] = FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast,
                                            added: values.addedToDirectoryDate)
            }
        }
        return scan
    }

    static func load(from url: URL) throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(Library.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // a silent file measures −∞, which plain JSON can't hold; gainDb plays it at unity
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
