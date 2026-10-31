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
    /// A gaps line that can't be read, as written, so an edit doesn't erase it; gaps picked by hand replace it.
    public var unreadGaps: String?
    /// The album it was made from, which Albums then leaves out.
    public var fromAlbum: String?
    /// Where a new part starts: the index of its first song. A row that plays one part each time takes these.
    public var breaks: Set<Int> = []
    /// What parts are called, by the index of their first song; the rest go by their number.
    public var partNames: [Int: String] = [:]

    public init(id: String, name: String, paths: [String] = [], gaps: Settings? = nil, fromAlbum: String? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.gaps = gaps
        self.fromAlbum = fromAlbum
    }

    private static let gapsTag = "#SOTTOVA-GAPS:"
    private static let fromAlbumTag = "#SOTTOVA-FROM-ALBUM:"
    /// On its own line before the song that starts a part, with the part's name after a colon if it has one.
    private static let partTag = "#SOTTOVA-PART"

    /// Reads absolute paths, paths relative to the file and file:// URLs; skips every other `#` line.
    static func parse(_ text: String, at url: URL) -> Playlist {
        var playlist = Playlist(id: url.path, name: url.deletingPathExtension().lastPathComponent)
        let folder = url.deletingLastPathComponent()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(["\u{FEFF}"]))
            if line.hasPrefix(gapsTag) {
                playlist.gaps = try? JSONDecoder().decode(Settings.self, from: Data(line.dropFirst(gapsTag.count).utf8))
                if playlist.gaps == nil { playlist.unreadGaps = line }
            } else if line.hasPrefix(fromAlbumTag) {
                playlist.fromAlbum = String(line.dropFirst(fromAlbumTag.count)).removingPercentEncoding
            } else if line == partTag || line.hasPrefix(partTag + ":") {
                if !playlist.paths.isEmpty { playlist.breaks.insert(playlist.paths.count) }
                let partName = line.dropFirst(partTag.count + 1)
                if !partName.isEmpty { playlist.partNames[playlist.paths.count] = String(partName) }
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
        var lines = ["#EXTM3U", "#PLAYLIST:\(Self.oneLine(name))"]
        if let gaps, let json = try? JSONEncoder().encode(gaps), let text = String(data: json, encoding: .utf8) {
            lines.append(Self.gapsTag + text)
        } else if let unreadGaps {
            lines.append(unreadGaps)
        }
        if let fromAlbum {
            // album ids hold a unit separator and a path; percent-encoded they stay on one plain line
            lines.append(Self.fromAlbumTag + (fromAlbum.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fromAlbum))
        }
        let folder = URL(filePath: id).deletingLastPathComponent().standardizedFileURL.pathComponents
        for (index, path) in paths.enumerated() {
            if let partName = partNames[index] {
                lines.append(Self.partTag + ":" + Self.oneLine(partName))
            } else if breaks.contains(index) {
                lines.append(Self.partTag)
            }
            if let (seconds, title) = info(path) {
                lines.append("#EXTINF:\(Int(seconds.rounded())),\(Self.oneLine(title))")
            }
            let line = Self.relative(path, from: folder)
            // parse wouldn't give these back as the same path; a URL escapes them
            let plain = !line.contains(where: \.isNewline) && !line.hasPrefix("#") && line == line.trimmingCharacters(in: .whitespaces.union(["\u{FEFF}"]))
            lines.append(plain ? line : URL(filePath: path).absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A line break in a tag would come back as a song.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Songs added at `index` join the part that's there; the parts after move along with them.
    mutating func insert(_ added: [String], at index: Int) {
        let index = min(index, paths.count)
        paths.insert(contentsOf: added, at: index)
        breaks = Set(breaks.map { $0 > index ? $0 + added.count : $0 })
        partNames = Dictionary(uniqueKeysWithValues: partNames.map { ($0 > index ? $0 + added.count : $0, $1) })
    }

    /// A part keeps its place when songs leave it; one left empty goes.
    mutating func remove(at offsets: IndexSet) {
        paths = paths.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        // a later part wins the place of one that emptied, name or no name
        var names: [Int: String] = [:]
        for start in [0] + breaks.sorted() { names[start - offsets.count { $0 < start }] = partNames[start] }
        partNames = names.filter { $0.key < paths.count }
        breaks = Set(breaks.map { b in b - offsets.count { $0 < b } }.filter { $0 > 0 && $0 < paths.count })
    }

    /// The songs part by part, in order; one part when there are no breaks.
    public var partPaths: [[String]] {
        var parts: [[String]] = [[]]
        for (index, path) in paths.enumerated() {
            if breaks.contains(index), !parts[parts.count - 1].isEmpty { parts.append([]) }
            parts[parts.count - 1].append(path)
        }
        return parts.filter { !$0.isEmpty }
    }

    /// The index of each part's first song, lining up with `partPaths`.
    public var partStarts: [Int] {
        [0] + breaks.sorted().filter { $0 < paths.count }
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

    /// The playlists, and the names of files that couldn't be read, not being UTF-8 or not opening.
    func load() -> (playlists: [Playlist], unreadable: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var playlists: [Playlist] = [], unreadable: [String] = []
        for url in files where url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "m3u" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                playlists.append(Playlist.parse(text, at: url))
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        return (playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, unreadable.sorted())
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
