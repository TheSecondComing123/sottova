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

    @Test func peopleAreGroupedByComposerWithCountsAndACover() {
        func song(_ path: String, _ artist: String, composer: String?, artwork: String?) -> (String, Library.Entry) {
            var meta = TrackMeta(title: path, artist: artist, album: "x", duration: 60)
            meta.composer = composer
            meta.artwork = artwork
            return (path, Library.Entry(size: 0, modified: .now, meta: meta))
        }
        let catalog = Catalog(entries: Dictionary(uniqueKeysWithValues: [
            song("/1", "Ishizaka", composer: "Bach", artwork: nil),
            song("/2", "Ishizaka", composer: "Bach", artwork: "art"),
            song("/3", "Komiku", composer: nil, artwork: nil),
        ]))
        let people = Person.all(in: catalog.songs)
        #expect(people.map(\.name) == catalog.songs.map(\.who).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.sorted())
        #expect(people.first { $0.songs == 2 }?.artwork == "art")
        #expect(people.first { $0.songs == 1 }?.artwork == nil)
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

    @Test func aSortedPageIsTheSortOfItsFilteredSongs() {
        var entries: [String: Library.Entry] = [:]
        let names = ["Étude", "夜想曲", "Ноктюрн", "étude", "Prélude"]
        for i in 0..<300 {
            var meta = TrackMeta(title: "\(names[i % 5]) \(i % 7), Op. \(i % 11)", artist: "Dvořák \(i % 13)", album: "Sämtliche \(i % 17)", trackNumber: i % 3 + 1, duration: Double(i % 5))
            meta.composer = i % 2 == 0 ? "Fauré \(i % 3)" : nil
            entries["/m/\(i).flac"] = Library.Entry(size: 0, modified: .distantPast, meta: meta, added: Date(timeIntervalSince1970: Double(i % 9)))
        }
        let catalog = Catalog(entries: entries)
        for sort in SongSort.allCases {
            #expect(catalog.songs(by: sort).map(\.id) == sort.sorted(catalog.songs).map(\.id))
            for typed in ["ETUDE", "夜", "sämt", "dvorak 1", "nothing like this"] {
                let needle = Song.folded(typed)
                #expect(catalog.songs(by: sort, matching: needle).map(\.id) == sort.sorted(catalog.songs.filter { $0.searchKey.contains(needle) }).map(\.id))
            }
        }
        #expect(Catalog().songs(by: .title).isEmpty)
    }

    @Test func aDecomposedFileNameMatchesWhatsTyped() {
        // file names can arrive decomposed; a keyboard types composed
        let names = ["Dvor\u{30C}a\u{301}k", "\u{1112}\u{1161}\u{11AB}"]
        let catalog = Catalog(entries: Dictionary(uniqueKeysWithValues: names.map { ("/m/\($0).flac", Library.Entry(size: 0, modified: .distantPast)) }))
        #expect(catalog.songs(by: .title, matching: Song.folded("dvořák")).count == 1)
        #expect(catalog.songs(by: .title, matching: Song.folded("\u{D55C}")).count == 1)
        #expect(catalog.songs(by: .title, matching: Song.folded("X")).isEmpty)
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

    @Test @MainActor func anOriginsKeyIsShortAndStaysTheSameAcrossLaunches() {
        func song(_ path: String) -> Song {
            Song(id: path, title: "", work: "", detail: nil, artist: "", album: "", albumID: "", albumArtist: "", composer: nil,
                 trackNumber: nil, discNumber: nil, year: nil, duration: 0, artwork: nil, searchKey: "")
        }
        let (a, b) = (song("/Music/é/a.flac"), song("/Music/é/b.flac"))
        // saved in resume.json, so a page's play button still knows after a relaunch: changing this forgets that once
        #expect(Controller.Origin.key(of: [a, b], source: nil) == "b95a60d13113890b")
        #expect(Controller.Origin.key(of: [b, a], source: nil) == Controller.Origin.key(of: [a, b], source: nil))
        #expect(Controller.Origin.key(of: [a], source: nil) != Controller.Origin.key(of: [a, b], source: nil))
        #expect(Controller.Origin.key(of: [a, b], source: "/p.m3u8") == "/p.m3u8")
        let tenThousand = (0..<10_000).map { song("/Music/some folder/\($0).flac") }
        #expect(Controller.Origin.key(of: tenThousand, source: nil).utf8.count <= 16)
    }

    private func song(_ artist: String, composer: String?, title: String = "x") -> Song {
        Song(id: UUID().uuidString, title: title, work: title, detail: nil, artist: artist, album: "a", albumID: "a", albumArtist: artist,
             composer: composer, trackNumber: nil, discNumber: nil, year: nil, duration: 1, artwork: nil, searchKey: "")
    }

    @Test(arguments: [
        ("Luke Faulkner", "Chopin", "Chopin", "Luke Faulkner"),
        ("Komiku", nil, "Komiku", nil),
        ("Komiku", "", "Komiku", nil),
        ("Komiku", "Komiku", "Komiku", nil),
        ("Hot Five", "Armstrong, Oliver", "Hot Five", nil),
        ("Hot Five", "Armstrong / Oliver", "Hot Five", nil),
        ("Hot Five", "Armstrong & Oliver", "Hot Five", nil),
        ("Hot Five", "Armstrong; Oliver", "Hot Five", nil),
    ] as [(String, String?, String, String?)])
    func whoLeadsAndPerformerBlanksWhenEqual(artist: String, composer: String?, who: String, performer: String?) {
        #expect(song(artist, composer: composer).who == who)
        #expect(song(artist, composer: composer).performer == performer)
    }

    @Test func sortsByWhoThenTitle() {
        let songs = [song("B", composer: "Zed", title: "2"), song("Y", composer: nil, title: "1"), song("A", composer: "Zed", title: "1")]
        #expect(SongSort.who.sorted(songs).map(\.artist) == ["Y", "A", "B"])
        #expect(SongSort.performer.sorted(songs).map(\.artist) == ["A", "B", "Y"])
    }

    @Test func theOldMenuKeepsItsFive() {
        #expect(SongSort.menu.map(\.rawValue) == ["title", "composer", "album", "longest", "newest"])
    }
}
