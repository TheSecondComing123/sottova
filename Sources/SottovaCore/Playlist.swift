import Foundation

/// A playlist is an .m3u8 file, so other players can open it and it can be edited by hand: UTF-8, paths relative to
/// the file, and Sottova's own settings on `#SOTTOVA-` lines, which other players skip as comments.
public struct Playlist: Identifiable, Equatable, Sendable {
    /// The file's path, so renaming the playlist changes it.
    public var id: String
    public var name: String
    public var paths: [String]
    /// The gaps it plays with, like an album's; nil plays with the user's own.
    public var gaps: Settings?
    /// The album it was made from, which Albums then leaves out.
    public var fromAlbum: String?

    public init(id: String, name: String, paths: [String] = [], gaps: Settings? = nil, fromAlbum: String? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.gaps = gaps
        self.fromAlbum = fromAlbum
    }

    private static let gapsTag = "#SOTTOVA-GAPS:"
    private static let fromAlbumTag = "#SOTTOVA-FROM-ALBUM:"

    /// Reads absolute paths, paths relative to the file and file:// URLs; skips every other `#` line.
    static func parse(_ text: String, at url: URL) -> Playlist {
        var playlist = Playlist(id: url.path, name: url.deletingPathExtension().lastPathComponent)
        let folder = url.deletingLastPathComponent()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(["\u{FEFF}"]))
            if line.hasPrefix(gapsTag) {
                playlist.gaps = try? JSONDecoder().decode(Settings.self, from: Data(line.dropFirst(gapsTag.count).utf8))
            } else if line.hasPrefix(fromAlbumTag) {
                playlist.fromAlbum = String(line.dropFirst(fromAlbumTag.count)).removingPercentEncoding
            } else if line.isEmpty || line.hasPrefix("#") {
                continue
            } else if line.hasPrefix("file://") {
                if let path = URL(string: line)?.standardizedFileURL.path { playlist.paths.append(path) }
            } else if line.hasPrefix("/") {
                playlist.paths.append(URL(filePath: line).standardizedFileURL.path)
            } else {
                playlist.paths.append(folder.appending(path: line).standardizedFileURL.path)
            }
        }
        return playlist
    }

    /// The file's text. `info` gives a song's length and "artist - title" for the #EXTINF lines other players show.
    func render(info: (String) -> (Double, String)?) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        if let gaps, let json = try? JSONEncoder().encode(gaps), let text = String(data: json, encoding: .utf8) {
            lines.append(Self.gapsTag + text)
        }
        if let fromAlbum {
            // album ids hold a unit separator and a path; percent-encoded they stay on one plain line
            lines.append(Self.fromAlbumTag + (fromAlbum.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fromAlbum))
        }
        let folder = URL(filePath: id).deletingLastPathComponent().standardizedFileURL.pathComponents
        for path in paths {
            if let (seconds, title) = info(path) {
                lines.append("#EXTINF:\(Int(seconds.rounded())),\(title)")
            }
            lines.append(Self.relative(path, from: folder))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `path` relative to the folder, so moving the music and its playlists together keeps them working.
    static func relative(_ path: String, from folder: [String]) -> String {
        let target = URL(filePath: path).standardizedFileURL.pathComponents
        let common = zip(folder, target).prefix { $0 == $1 }.count
        // only the root in common: nothing relative is shorter or sturdier than the absolute path
        guard common > 1 else { return path }
        return (Array(repeating: "..", count: folder.count - common) + target[common...]).joined(separator: "/")
    }
}

/// The playlists folder: one .m3u8 per playlist, written atomically.
struct PlaylistStore {
    let folder: URL

    func load() -> [Playlist] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "m3u8" || $0.pathExtension.lowercased() == "m3u" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { Playlist.parse($0, at: url) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func url(for name: String) -> URL {
        // a name is a file name here, so slashes and colons can't be in it
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appending(path: safe + ".m3u8")
    }

    func write(_ playlist: Playlist, info: (String) -> (Double, String)?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(playlist.render(info: info).utf8).write(to: URL(filePath: playlist.id), options: .atomic)
    }
}
