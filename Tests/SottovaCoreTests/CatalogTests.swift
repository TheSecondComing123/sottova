import Foundation
import Testing
@testable import SottovaCore

struct CatalogTests {
    @Test(arguments: [
        ("Polonaise in G-flat major, B. 36", "Polonaise in G-flat major", "B. 36"),
        ("Impromptu No. 3 in G-flat major, Op. 51", "Impromptu No. 3 in G-flat major", "Op. 51"),
        ("Étude in E-flat minor, Op. 10 No. 6 \"Lament\"", "Étude in E-flat minor", "Op. 10 No. 6 · “Lament”"),
        ("Polonaise in B-flat minor, B. 13 “Adieu”", "Polonaise in B-flat minor", "B. 13 · “Adieu”"),
        ("Prelude and Fugue in C major, BWV 846", "Prelude and Fugue in C major", "BWV 846"),
        ("Piano Sonata No. 11 in A major, K. 331", "Piano Sonata No. 11 in A major", "K. 331"),
        ("Andante spianato & Grande polonaise brillante, Op.22", "Andante spianato & Grande polonaise brillante", "Op.22"),
        ("Symphony No. 9 in D minor, Op. 125, \"Choral\"", "Symphony No. 9 in D minor", "Op. 125 · “Choral”"),
        ("Piano Sonata in E-flat major, Hob. XVI:52", "Piano Sonata in E-flat major", "Hob. XVI:52"),
        ("Polonaise in B-flat major, KK IVa/1", "Polonaise in B-flat major", "KK IVa/1"),
    ])
    func splitsClassicalTitles(title: String, work: String, detail: String) {
        let split = Catalog.splitWork(title)
        #expect(split.work == work)
        #expect(split.detail == detail)
    }

    @Test(arguments: ["Sweden", "Hello, World", "Rain, Bus Stop, 3 AM", "Opus, Live", "Bombs Away, B.O.B."])
    func leavesOtherTitlesWhole(title: String) {
        let split = Catalog.splitWork(title)
        #expect(split.work == title)
        #expect(split.detail == nil)
    }

    @Test func worksGroupRecordingsAndFollowCatalogOrder() {
        func song(_ path: String, _ title: String, _ artist: String, composer: String? = "Frédéric Chopin") -> (String, Library.Entry) {
            var meta = TrackMeta(title: title, artist: artist, album: "x", duration: 60)
            meta.composer = composer
            return (path, Library.Entry(size: 0, modified: .now, meta: meta))
        }
        let catalog = Catalog(entries: Dictionary(uniqueKeysWithValues: [
            song("/1", "Nocturne in C minor, Op. 48 No. 1", "B"),
            song("/2", "Nocturne in C minor, B. 108", "A"),
            song("/3", "Nocturne in E-flat major, Op. 9 No. 2", "C"),
            song("/4", "Nocturne in C minor, Op. 48 No. 1", "A"),
            song("/5", "Polonaise in G-flat major, B. 36", "D"),
            song("/6", "Berceuse", "E"),
            song("/7", "Goldberg Variation 13, BWV 988", "F", composer: "Johann Sebastian Bach"),
        ]))
        let works = catalog.works(by: "Frédéric Chopin")
        #expect(works.map { $0.catalogNumber ?? $0.title } == ["B. 36", "B. 108", "Op. 9 No. 2", "Op. 48 No. 1", "Berceuse"])
        #expect(works[3].recordings.map(\.artist) == ["A", "B"])
        #expect(catalog.composers == ["Frédéric Chopin", "Johann Sebastian Bach"])
    }

    @Test func songSortsReadLikeAProgram() {
        func song(_ title: String, _ artist: String, composer: String?, album: String, track: Int, seconds: Double, added: Double?) -> Song {
            let (work, detail) = Catalog.splitWork(title)
            return Song(id: title + artist, title: title, work: work, detail: detail, artist: artist, album: album, albumID: album,
                        albumArtist: "", composer: composer, trackNumber: track, discNumber: nil, year: nil, duration: seconds,
                        artwork: nil, searchKey: "", added: added.map { Date(timeIntervalSince1970: $0) })
        }
        let songs = [
            song("Polonaise in G-flat major, B. 108", "A", composer: "Chopin", album: "y", track: 2, seconds: 300, added: 1),
            song("Polonaise in G-flat major, B. 36", "B", composer: "Chopin", album: "y", track: 1, seconds: 100, added: 3),
            song("Air", "C", composer: nil, album: "x", track: 1, seconds: 200, added: nil),
            song("Fugue", "D", composer: "Bach", album: "x", track: 2, seconds: 50, added: 2),
        ]
        #expect(SongSort.title.sorted(songs).map(\.artist) == ["C", "D", "B", "A"])
        #expect(SongSort.composer.sorted(songs).map(\.artist) == ["D", "B", "A", "C"])
        #expect(SongSort.album.sorted(songs).map(\.artist) == ["C", "D", "B", "A"])
        #expect(SongSort.longest.sorted(songs).map(\.artist) == ["A", "C", "B", "D"])
        #expect(SongSort.newest.sorted(songs).map(\.artist) == ["B", "D", "A", "C"])
    }

    @Test func performersAndComposersBothGetPages() {
        let catalog = Catalog(entries: [
            "/m/1.flac": entry(title: "Nocturne", artist: "Luke Faulkner"),
            "/m/2.flac": entry(title: "Waltz", artist: "Olga Gurevich"),
            "/m/3.flac": entry(title: "Polonaise", artist: "Luke Faulkner"),
        ])
        #expect(catalog.artists.map(\.name) == ["Frédéric Chopin", "Luke Faulkner", "Olga Gurevich"])
        #expect(catalog.artistsByName["Frédéric Chopin"]?.songs.count == 3)
        #expect(catalog.artistsByName["Luke Faulkner"]?.songs.map(\.title).sorted() == ["Nocturne", "Polonaise"])
        #expect(catalog.artistsByName["Olga Gurevich"]?.albums.map(\.title) == ["Perfect Chopin"])
    }

    @Test func searchFindsAPerformersSongsByComposer() {
        let catalog = Catalog(entries: ["/m/1.flac": entry(title: "Nocturne", artist: "Luke Faulkner")])
        #expect(catalog.songs[0].searchKey.contains("frederic chopin"))
    }

    private func entry(title: String, artist: String) -> Library.Entry {
        Library.Entry(size: 1, modified: .distantPast, loudness: nil,
                      meta: TrackMeta(title: title, artist: artist, album: "Perfect Chopin", albumArtist: "Frédéric Chopin", duration: 60))
    }
}

struct EnvelopeTests {
    private let track = Track(duration: 480, fadeIn: 6, outStart: 471.97, outLength: 8)

    @Test func fadesGetFixedShares() {
        #expect(track.position(at: 0) == 0)
        #expect(abs(track.position(at: 6) - 0.12) < 1e-9)
        #expect(abs(track.position(at: 471.97) - 0.84) < 1e-9)
        #expect(track.position(at: 479.97) == 1)
        #expect(track.position(at: 480) == 1)
    }

    @Test func timeInvertsPosition() {
        for i in 0...1000 {
            let t = 479.97 * Double(i) / 1000
            #expect(abs(track.time(at: track.position(at: t)) - t) < 1e-6, "t = \(t)")
        }
    }

    @Test func positionNeverGoesBackwards() {
        var last = -1.0
        for i in 0...2000 {
            let p = track.position(at: 480 * Double(i) / 2000)
            #expect(p >= last)
            last = p
        }
    }

    @Test func zeroLengthFadesStayInOrder() {
        // a crossfade's incoming half has no fade-in of its own here, and a two-second file has no hold
        for track in [Track(duration: 60, fadeIn: 0, outStart: 57, outLength: 3), Track(duration: 2, fadeIn: 1, outStart: 0.97, outLength: 1)] {
            var last = -1.0
            for i in 0...200 {
                let p = track.position(at: track.duration * Double(i) / 200)
                #expect(p >= last && (0...1).contains(p))
                last = p
            }
            #expect((0...track.duration).contains(track.time(at: 0.5)))
        }
    }
}

struct GapEstimateTests {
    @Test func gapEstimateUsesTheAverageGap() {
        var s = Settings()
        s.gapMin = 180
        s.gapMax = 480
        #expect(s.lengthWithGaps(count: 12, music: 3720) == 3720 + 330 * 11)
        s.crossfade = true
        #expect(s.lengthWithGaps(count: 12, music: 3720) == 3720)
    }
}
