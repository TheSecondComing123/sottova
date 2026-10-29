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
    }

    struct FileStamp: Equatable {
        var size: Int
        var modified: Date
        var added: Date?
    }

    var folders: [Folder] = []
    var entries: [String: Entry] = [:]

    var playable: [String] {
        entries.filter { !$0.value.unplayable }.keys.sorted()
    }

    var unplayable: [String] {
        entries.filter { $0.value.unplayable }.keys.sorted()
    }

    var pending: [String] {
        entries.filter { ($0.value.loudness == nil || $0.value.meta == nil) && !$0.value.unplayable }.keys.sorted()
    }

    /// Keeps cached loudness for files whose size and mtime didn't change; drops files that are gone.
    mutating func merge(_ scanned: [String: FileStamp]) {
        var merged: [String: Entry] = [:]
        for (path, stamp) in scanned {
            if let old = entries[path], old.size == stamp.size, old.modified == stamp.modified {
                merged[path] = old
            } else {
                merged[path] = Entry(size: stamp.size, modified: stamp.modified)
            }
            merged[path]?.added = stamp.added
        }
        entries = merged
    }

    /// Resolves bookmarks so moved or renamed folders are followed, refreshing stale ones.
    mutating func resolveFolders() -> [URL] {
        folders.indices.compactMap { i in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: folders[i].bookmark, bookmarkDataIsStale: &stale) else { return nil }
            if stale, let fresh = try? url.bookmarkData() {
                folders[i].bookmark = fresh
            }
            folders[i].path = url.path
            return url
        }
    }

    /// Stat-only walk: no file is opened, so rescans stay cheap.
    static func scan(_ folders: [URL]) -> [String: FileStamp] {
        var found: [String: FileStamp] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .addedToDirectoryDateKey]
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
            while let url = files?.nextObject() as? URL {
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true,
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true
                else { continue }
                found[url.path] = FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast,
                                            added: values.addedToDirectoryDate)
            }
        }
        return found
    }

    static func load(from url: URL) throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
