import Foundation

/// A set of free music on archive.org that Sottova can download, whole, into the user's library.
public struct ShelfSet: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case classical = "Classical"
        case ambient = "Ambient and instrumental"
    }

    /// The archive.org item.
    public let id: String
    public let title: String
    public let creator: String
    public let kind: Kind
    public let license: String
    public let licenseURL: String
    /// The MP3s' total size, for the sheet; the download reads the real sizes.
    public let megabytes: Int
    /// For files that arrive with only a title: the album, artist and composer to write into them.
    let retag: (album: String, artist: String, composer: String)?

    /// The folder it lands in, under the library folder.
    public var folder: String { "\(creator) - \(title)" }
}

/// Downloads sets into `~/Music/Sottova Library` as plain MP3s, with each set's cover and a credits.txt. Opt-in:
/// nothing is fetched until the user asks, and the only host is archive.org.
@Observable @MainActor
public final class Shelf {
    #if SHOT
    public static let folder = ShotEnv.music.appending(path: "Sottova Library")
    #else
    public static let folder = URL.musicDirectory.appending(path: "Sottova Library")
    #endif

    public static let sets: [ShelfSet] = [
        ShelfSet(id: "OpenGoldbergVariations", title: "Open Goldberg Variations", creator: "Kimiko Ishizaka", kind: .classical,
                 license: "CC0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/", megabytes: 102, retag: nil),
        ShelfSet(id: "bach-well-tempered-clavier-book-1", title: "Well-Tempered Clavier, Book 1", creator: "Kimiko Ishizaka",
                 kind: .classical, license: "Public domain", licenseURL: "https://creativecommons.org/publicdomain/mark/1.0/",
                 megabytes: 128, retag: nil),
        ShelfSet(id: "pandacd-715-js-bach-the-art-of-the-fugue-kunst-der-fuge-bwv-1080", title: "The Art of the Fugue",
                 creator: "Kimiko Ishizaka", kind: .classical, license: "CC0",
                 licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/", megabytes: 98, retag: nil),
        ShelfSet(id: "musopen-chopin", title: "The Complete Chopin Collection", creator: "Musopen", kind: .classical,
                 license: "CC0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/", megabytes: 524,
                 retag: ("The Complete Chopin Collection", "Musopen", "Frédéric Chopin")),
        ShelfSet(id: "Musopen-Libre", title: "Orchestral", creator: "Musopen and Libre Classic", kind: .classical,
                 license: "CC BY-SA 3.0", licenseURL: "https://creativecommons.org/licenses/by-sa/3.0/", megabytes: 216, retag: nil),
        ShelfSet(id: "ChrisZabriskieDirectToVideo", title: "Direct to Video", creator: "Chris Zabriskie", kind: .ambient,
                 license: "CC BY 3.0", licenseURL: "https://creativecommons.org/licenses/by/3.0/", megabytes: 55, retag: nil),
        ShelfSet(id: "cz-ogreatqueenelectric", title: "O Great Queen Electric", creator: "Chris Zabriskie", kind: .ambient,
                 license: "CC BY 4.0", licenseURL: "https://creativecommons.org/licenses/by/4.0/", megabytes: 46, retag: nil),
        ShelfSet(id: "leerosevere_musicforpodcasts_5", title: "Music for Podcasts 5", creator: "Lee Rosevere", kind: .ambient,
                 license: "CC BY 4.0", licenseURL: "https://creativecommons.org/licenses/by/4.0/", megabytes: 97, retag: nil),
        ShelfSet(id: "jamendo-160773", title: "Cloud Cover", creator: "Blue Dot Sessions", kind: .ambient,
                 license: "CC BY 3.0", licenseURL: "https://creativecommons.org/licenses/by/3.0/", megabytes: 35, retag: nil),
        ShelfSet(id: "jamendo-160770", title: "Castro", creator: "Blue Dot Sessions", kind: .ambient,
                 license: "CC BY 3.0", licenseURL: "https://creativecommons.org/licenses/by/3.0/", megabytes: 42, retag: nil),
    ]

    /// While downloading: how far each set has come, 0 to 1, a file at a time.
    public private(set) var progress: [ShelfSet.ID: Double] = [:]
    public private(set) var running = false
    public private(set) var problem: String?

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// One set after another into `root`. A file already there was finished (each lands by a move), so asking again
    /// picks up where a stopped download left off. Cancelling the task stops between files.
    public func download(_ sets: [ShelfSet], into root: URL = Shelf.folder) async {
        running = true
        problem = nil
        defer { running = false }
        for set in sets {
            guard !Task.isCancelled else { return }
            do {
                try await fetch(set, into: root.appending(path: set.folder))
            } catch is CancellationError {
                return
            } catch {
                let failure = "couldn't download \(set.title): \(error.localizedDescription)"
                problem = problem.map { $0 + "\n" + failure } ?? failure
            }
        }
    }

    struct Item: Decodable {
        struct File: Decodable {
            let name: String
            let format: String?
            let size: String?
            let title: String?
        }
        let files: [File]
    }

    private func fetch(_ set: ShelfSet, into dir: URL) async throws {
        let base = URL(string: "https://archive.org")!
        let (data, response) = try await session.data(for: Self.request(base.appending(path: "metadata/\(set.id)")))
        try Self.check(response)
        let files = try JSONDecoder().decode(Item.self, from: data).files
        let mp3s = files.filter { $0.format == "VBR MP3" }
        guard !mp3s.isEmpty else { throw Failure(detail: "archive.org lists no songs in it") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let total = Double(mp3s.reduce(0) { $0 + (Int($1.size ?? "") ?? 0) })
        var done = 0.0
        progress[set.id] = 0
        for file in mp3s {
            try Task.checkCancellation()
            let dest = dir.appending(path: (file.name as NSString).lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                let temp = try await download(base.appending(path: "download/\(set.id)/\(file.name)"), size: file.size)
                if let retag = set.retag {
                    let audio = try Data(contentsOf: temp)
                    try ID3.retag(audio, [("TIT2", Self.title(file)), ("TPE1", retag.artist), ("TALB", retag.album),
                                          ("TCOM", retag.composer), ("TCOP", set.license), ("WCOP", set.licenseURL)])
                        .write(to: dest, options: .atomic)
                } else {
                    try FileManager.default.moveItem(at: temp, to: dest)
                }
            }
            done += Double(Int(file.size ?? "") ?? 0)
            progress[set.id] = total > 0 ? done / total : 1
        }

        let cover = dir.appending(path: "cover.jpg")
        if let jpeg = files.first(where: { $0.format == "JPEG" }), !FileManager.default.fileExists(atPath: cover.path) {
            let temp = try await download(base.appending(path: "download/\(set.id)/\(jpeg.name)"), size: jpeg.size)
            try FileManager.default.moveItem(at: temp, to: cover)
        }
        let credits = "\(set.title)\n\(set.creator)\nlicense: \(set.license), \(set.licenseURL)\nsource: https://archive.org/details/\(set.id)\n"
        try credits.write(to: dir.appending(path: "credits.txt"), atomically: true, encoding: .utf8)
        progress[set.id] = 1
    }

    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// A temp file holding the real thing: an error page is a response like any other, and would land as a song.
    private func download(_ url: URL, size: String?) async throws -> URL {
        let (temp, response) = try await session.download(for: Self.request(url))
        do {
            try Self.check(response)
            guard response.mimeType != "text/html" else { throw Failure(detail: "archive.org sent a web page instead of the file") }
            let got = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let want = size.flatMap(Int.init), got != want {
                throw Failure(detail: "a file came through cut short")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return temp
    }

    private static func check(_ response: URLResponse) throws {
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw Failure(detail: "archive.org answered \(status)")
        }
    }

    /// "Ballade no. 1 - Op. 23.mp3" reads as "Ballade No. 1, Op. 23", the way the catalog splits work from number.
    static func title(_ file: Item.File) -> String {
        let raw = file.title ?? ((file.name as NSString).lastPathComponent as NSString).deletingPathExtension
        return raw.replacing(" - ", with: ", ").replacing(#/\bno\. /#, with: "No. ")
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Sottova/0.1 (macOS music player)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
