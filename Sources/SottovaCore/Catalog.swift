import Foundation

public struct Song: Identifiable, Hashable, Sendable {
    /// The file path.
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let albumID: String
    public let albumArtist: String
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let duration: Double
    public let artwork: String?
    /// Title, artist and album folded once, so search doesn't fold 20k strings per keystroke.
    public let searchKey: String
}

public struct Album: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let year: Int?
    public let artwork: String?
    public let songs: [Song]

    public var duration: Double {
        songs.reduce(0) { $0 + $1.duration }
    }
}

public struct Artist: Identifiable, Hashable, Sendable {
    /// The artist name.
    public let id: String
    public let albums: [Album]

    public var name: String { id }
    public var songs: [Song] { albums.flatMap(\.songs) }
    public var artwork: String? { albums.first { $0.artwork != nil }?.artwork }
}

/// Songs grouped into albums and artists, rebuilt from the library cache whenever it changes.
public struct Catalog: Sendable {
    public private(set) var songs: [Song] = []
    public private(set) var albums: [Album] = []
    public private(set) var artists: [Artist] = []
    public private(set) var songsByID: [String: Song] = [:]
    public private(set) var albumsByID: [String: Album] = [:]
    public private(set) var artistsByName: [String: Artist] = [:]

    public init() {}

    init(entries: [String: Library.Entry]) {
        songs = entries.compactMap { path, entry in entry.unplayable ? nil : Self.song(path: path, meta: entry.meta) }
            .sorted(by: Self.libraryOrder)
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })

        albums = Dictionary(grouping: songs, by: \.albumID).map { id, songs in
            let artists = Set(songs.map(\.albumArtist))
            // tracks without an album-artist tag fall back to their own artist; mixed ones make a compilation
            let artist = artists.count == 1 ? songs[0].albumArtist : "Various Artists"
            return Album(id: id, title: songs[0].album, artist: artist, year: songs.compactMap(\.year).first,
                         artwork: songs.lazy.compactMap(\.artwork).first, songs: songs.sorted(by: Self.albumOrder))
        }
        .sorted {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            return byArtist == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : byArtist == .orderedAscending
        }
        albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })

        artists = Dictionary(grouping: albums, by: \.artist).map { Artist(id: $0, albums: $1) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artistsByName = Dictionary(uniqueKeysWithValues: artists.map { ($0.name, $0) })
    }

    /// The artist page a song belongs to: its album's artist, which may be "Various Artists".
    public func artist(of song: Song) -> String {
        albumsByID[song.albumID]?.artist ?? song.albumArtist
    }

    private static func song(path: String, meta: TrackMeta?) -> Song {
        let url = URL(filePath: path)
        let folder = url.deletingLastPathComponent()
        let artist = meta?.artist ?? "Unknown Artist"
        let albumArtist = meta?.albumArtist ?? artist
        // untagged files group by folder, so a folder of rips still reads as one album
        let album = meta?.album ?? folder.lastPathComponent
        let albumID: String
        if let tagged = meta?.album, let taggedArtist = meta?.albumArtist {
            albumID = "\(taggedArtist.lowercased())\u{1F}\(tagged.lowercased())"
        } else {
            // without an album-artist tag, the folder keeps a compilation together and two same-named albums apart
            albumID = "\(album.lowercased())\u{1F}\(folder.path)"
        }
        let title = meta?.title ?? url.deletingPathExtension().lastPathComponent
        return Song(
            id: path, title: title, artist: artist, album: album, albumID: albumID, albumArtist: albumArtist,
            trackNumber: meta?.trackNumber, discNumber: meta?.discNumber, year: meta?.year, duration: meta?.duration ?? 0,
            artwork: meta?.artwork, searchKey: "\(title) \(artist) \(album)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        )
    }

    private static func libraryOrder(_ a: Song, _ b: Song) -> Bool {
        // compare results, not equality: "ABBA" and "Abba" are different strings but sort as the same
        let byArtist = a.albumArtist.localizedStandardCompare(b.albumArtist)
        if byArtist != .orderedSame { return byArtist == .orderedAscending }
        let byAlbum = a.album.localizedStandardCompare(b.album)
        if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
        return albumOrder(a, b)
    }

    private static func albumOrder(_ a: Song, _ b: Song) -> Bool {
        if a.discNumber != b.discNumber { return (a.discNumber ?? 0) < (b.discNumber ?? 0) }
        if a.trackNumber != b.trackNumber { return (a.trackNumber ?? .max) < (b.trackNumber ?? .max) }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
