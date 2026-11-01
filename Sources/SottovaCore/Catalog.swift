import Foundation

public struct Song: Identifiable, Hashable, Sendable {
    /// The file path.
    public let id: String
    public let title: String
    /// The title before its catalog number: "Polonaise in G-flat major" of "Polonaise in G-flat major, B. 36".
    public let work: String
    /// Catalog number and nickname, as a concert program sets them: "B. 13 · “Adieu”". nil for most non-classical titles.
    public let detail: String?
    public let artist: String
    public let album: String
    public let albumID: String
    public let albumArtist: String
    public let composer: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let duration: Double
    public let artwork: String?
    /// Title, artist and album folded once, so search doesn't fold 20k strings per keystroke.
    public let searchKey: String
    /// When the file landed in its folder.
    public var added: Date? = nil

    /// Who a row leads with: the composer when the tag is one name, else the artist.
    public var who: String {
        guard let composer, !composer.isEmpty, composer.rangeOfCharacter(from: CharacterSet(charactersIn: ",/&;")) == nil else { return artist }
        return composer
    }

    /// Who plays it, or nil when that only repeats `who`.
    public var performer: String? {
        artist == who ? nil : artist
    }

    /// Folded as `searchKey` is. NFC too: a file name can arrive decomposed, what's typed doesn't.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// `needle` already folded. Bytes, since String's contains takes 15 ms over 10k songs, a whole frame per keystroke.
    public func matches(_ needle: String) -> Bool {
        var key = searchKey, needle = needle
        return key.withUTF8 { key in needle.withUTF8 { memmem(key.baseAddress, key.count, $0.baseAddress, $0.count) != nil } }
    }
}

/// One song waiting to play. Its own id, so the same song queued twice moves and goes away on its own.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let path: String
    /// The album it was queued from, whose gaps it plays with; nil plays with the user's own.
    public let source: String?
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
    /// A performer's own tracks, or every track on a composer's (album artist's) albums.
    public let songs: [Song]

    public var name: String { id }
    /// Only from the artist's own albums: a performer on a composer's album shouldn't wear the composer's portrait.
    public var artwork: String? { albums.first { $0.artist == id && $0.artwork != nil }?.artwork }
}

/// Songs grouped into albums and artists, rebuilt from the library cache whenever it changes.
public struct Catalog: Sendable {
    public private(set) var songs: [Song] = []
    /// Every order the Songs page offers, sorted here off the main actor: by title takes 100 ms at 10k.
    private var orders: [SongSort: [Song]] = [:]
    public private(set) var albums: [Album] = []
    public private(set) var artists: [Artist] = []
    public private(set) var songsByID: [String: Song] = [:]
    public private(set) var albumsByID: [String: Album] = [:]
    public private(set) var artistsByName: [String: Artist] = [:]

    public init() {}

    /// `needle` already folded.
    public func songs(by sort: SongSort, matching needle: String = "") -> [Song] {
        let sorted = orders[sort] ?? []
        return needle.isEmpty ? sorted : sorted.filter { $0.matches(needle) }
    }

    init(entries: [String: Library.Entry]) {
        songs = entries.compactMap { path, entry in entry.unplayable || entry.unreachable == true ? nil : Self.song(path: path, meta: entry.meta, added: entry.added) }
            .sorted(by: Self.libraryOrder)
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        for sort in SongSort.allCases { orders[sort] = sort.sorted(songs) }

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

        // classical tags put the composer in album artist and the performer in artist: both get a page
        var byName: [String: [Album]] = [:]
        for album in albums {
            for name in Set([album.artist] + album.songs.map(\.artist)) {
                byName[name, default: []].append(album)
            }
        }
        artists = byName.map { name, albums in
            Artist(id: name, albums: albums, songs: albums.flatMap { $0.artist == name ? $0.songs : $0.songs.filter { $0.artist == name } })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artistsByName = Dictionary(uniqueKeysWithValues: artists.map { ($0.name, $0) })
    }

    private static func song(path: String, meta: TrackMeta?, added: Date?) -> Song {
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
        let (work, detail) = splitWork(title)
        return Song(
            id: path, title: title, work: work, detail: detail, artist: artist, album: album, albumID: albumID, albumArtist: albumArtist,
            composer: meta?.composer,
            trackNumber: meta?.trackNumber, discNumber: meta?.discNumber, year: meta?.year, duration: meta?.duration ?? 0,
            artwork: meta?.artwork, searchKey: Song.folded("\(title) \(artist) \(albumArtist) \(meta?.composer ?? "") \(album)"),
            added: added
        )
    }

    // a regex literal compiles again at every use: 200 µs per song, nearly all of a build at 10k. These can be shared
    // between builds, which overlap, where a Regex can't.
    private static let catalogCut = try! NSRegularExpression(pattern: #", (?=(?:Op\.?|op\.|BWV|BI|B\.|KV|K\.|D\.|S\.|WoO|L\.|RV|HWV) ?\d|(?:Hob\.|KK) ?[IVX\d])"#)
    private static let nickname = try! NSRegularExpression(pattern: #",?\s*["“]([^"”]+)["”]"#)

    /// Splits at the comma before a catalog number (Op., B., BWV, K., D., Hob., ...) and sets a quoted nickname after a dot.
    static func splitWork(_ title: String) -> (work: String, detail: String?) {
        // Hoboken and Kobylańska numbers start with a roman numeral: "Hob. XVI:52", "KK IVa/16"
        guard let cut = catalogCut.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)).flatMap({ Range($0.range, in: title) }) else {
            return (title, nil)
        }
        let rest = String(title[cut.upperBound...])
        let detail = nickname.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: " · “$1”")
        return (String(title[..<cut.lowerBound]), detail)
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

/// One work by a composer and every recording of it in the library.
public struct Work: Identifiable, Sendable {
    public var id: String { "\(title)\u{1f}\(catalogNumber ?? "")" }
    public let title: String
    /// "Op. 48 No. 2", "B. 36", "BWV 988"; nil when the title carries none.
    public let catalogNumber: String?
    public let recordings: [Song]
}

extension Catalog {
    /// A composer's works, as a concert program would list them: numbered works in catalog order (B. 36 before
    /// B. 108, Op. 9 before Op. 48), then the rest by title. Two pieces with one title and different numbers stay apart.
    public func works(by composer: String) -> [Work] {
        let songs = songs.filter { $0.composer == composer }
        let groups = Dictionary(grouping: songs) { song -> String in
            "\(song.work)\u{1f}\(Self.catalogNumber(of: song) ?? "")"
        }
        return groups.values.map { recordings in
            Work(title: recordings[0].work, catalogNumber: Self.catalogNumber(of: recordings[0]),
                 recordings: recordings.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending })
        }
        .sorted { a, b in
            switch (a.catalogNumber, b.catalogNumber) {
            case let (x?, y?) where x != y: x.localizedStandardCompare(y) == .orderedAscending
            case (_?, nil): true
            case (nil, _?): false
            default: a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Composers with at least one tagged recording, by name.
    public var composers: [String] {
        Set(songs.compactMap(\.composer)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The part of the detail before the nickname: "Op. 48 No. 2" of "Op. 48 No. 2 · “Lament”".
    static func catalogNumber(of song: Song) -> String? {
        guard let first = song.detail?.components(separatedBy: " · ").first, let c = first.first, !"“\"‘'".contains(c) else { return nil }
        return first
    }
}

/// The orders the Songs page offers.
public enum SongSort: String, CaseIterable, Sendable {
    case title, composer, album, longest, newest, who, performer

    /// What the old page's sort menu offers.
    public static let menu: [SongSort] = [.title, .composer, .album, .longest, .newest]

    public var label: String {
        switch self {
        case .who: "by who"
        case .performer: "by performer"
        case .title: "by title"
        case .composer: "by composer"
        case .album: "by collection"
        case .longest: "longest first"
        case .newest: "newest first"
        }
    }

    /// Titles sort as a program would: by work, then catalog number in number order (B. 36 before B. 108).
    public func sorted(_ songs: [Song]) -> [Song] {
        func byTitle(_ a: Song, _ b: Song) -> Bool {
            let key = { (s: Song) in "\(s.work) \(s.detail ?? "") \(s.artist)" }
            return key(a).localizedStandardCompare(key(b)) == .orderedAscending
        }
        return songs.sorted { a, b in
            switch self {
            case .title: return byTitle(a, b)
            case .composer:
                if a.composer != b.composer {
                    guard let x = a.composer else { return false }
                    guard let y = b.composer else { return true }
                    return x.localizedStandardCompare(y) == .orderedAscending
                }
                return byTitle(a, b)
            case .who:
                if a.who != b.who { return a.who.localizedStandardCompare(b.who) == .orderedAscending }
                return byTitle(a, b)
            case .performer:
                if a.artist != b.artist { return a.artist.localizedStandardCompare(b.artist) == .orderedAscending }
                return byTitle(a, b)
            case .album:
                if a.album != b.album { return a.album.localizedStandardCompare(b.album) == .orderedAscending }
                return (a.discNumber ?? 0, a.trackNumber ?? 0) < (b.discNumber ?? 0, b.trackNumber ?? 0)
            case .longest: return a.duration > b.duration
            case .newest: return (a.added ?? .distantPast) > (b.added ?? .distantPast)
            }
        }
    }
}
