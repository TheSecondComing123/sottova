import Foundation
import Testing
@testable import SottovaCore

@MainActor
struct PlaylistTests {
    private let minecraft = Settings.presets.first { $0.name == "Minecraft" }!

    private func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-playlists-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func song(_ path: String, album: String = "a") -> Song {
        Song(id: path, title: "t", work: "t", detail: nil, artist: "p", album: album, albumID: album, albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 61.4, artwork: nil, searchKey: path)
    }

    @Test func roundTripsRelativePathsGapsAndItsAlbum() {
        let file = URL(filePath: "/Users/x/Music/Sottova Playlists/Nuit é.m3u8")
        var p = Playlist(id: file.path, name: "Nuit é", paths: ["/Users/x/Music/Compline/01 Nocturne.flac", "/Volumes/Disk/a.mp3"])
        p.gaps = minecraft
        p.fromAlbum = "Compline\u{1f}/Users/x/Music/Compline"
        let text = p.render { _ in (61.4, "p - t") }
        #expect(text.contains("\n../Compline/01 Nocturne.flac\n"))
        #expect(text.contains("\n/Volumes/Disk/a.mp3\n"))
        #expect(text.contains("#EXTINF:61,p - t"))
        #expect(!text.contains("\u{1f}"))
        #expect(Playlist.parse(text, at: file) == p)
    }

    @Test func readsWhatOtherPlayersWrite() {
        let file = URL(filePath: "/m/lists/x.m3u8")
        let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:12,Someone - Something\r\n../music/a.flac\r\n#EXTVLCOPT:foo\r\n"
            + "file:///m/music/b%20c.flac\r\n/m/music/../music/d.flac\r\n\r\n"
        #expect(Playlist.parse(text, at: file).paths == ["/m/music/a.flac", "/m/music/b c.flac", "/m/music/d.flac"])
        #expect(Playlist.parse(text, at: file).name == "x")
    }

    @Test func namesStayUniqueAndRenameMovesTheFileAndTheQueue() throws {
        let dir = temp()
        let c = Controller(storage: nil, playlistFolder: dir)
        let first = try #require(c.newPlaylist(songs: [song("/s/1.flac")]))
        let second = try #require(c.newPlaylist())
        #expect(c.playlists.map(\.name) == ["New collection", "New collection 2"])
        c.playNext([song("/s/1.flac")], source: second)
        let renamed = try #require(c.rename(second, to: "Évening"))
        #expect(FileManager.default.fileExists(atPath: renamed))
        #expect(!FileManager.default.fileExists(atPath: second))
        #expect(c.upNext.first?.source == renamed)
        #expect(c.rename(first, to: "Évening") == nil)
        // a fresh controller reads the same files back
        #expect(Controller(storage: nil, playlistFolder: dir).playlists.map(\.name) == ["Évening", "New collection"])
    }

    @Test func aPlaylistsSongsPlayWithItsGaps() throws {
        let c = Controller(storage: nil, playlistFolder: temp())
        let own = c.settings
        let id = try #require(c.newPlaylist(songs: [song("/s/1.flac", album: "x"), song("/s/2.flac", album: "y")]))
        c.setGaps(minecraft, for: id)
        c.playNext([song("/s/1.flac", album: "x"), song("/s/2.flac", album: "y")], source: id)
        _ = c.dequeue()
        #expect(c.settings.gapRange == 600...1200)
        _ = c.dequeue()
        _ = c.dequeue()
        #expect(c.settings == own)
    }

    @Test func makingAnAlbumYoursMovesItsGapsAndHidesIt() throws {
        let dir = temp()
        let c = Controller(storage: nil, playlistFolder: dir)
        let album = Album(id: "Compline\u{1f}/m/Compline", title: "Compline", artist: "Various Artists", year: nil, artwork: nil,
                          songs: [song("/m/Compline/1.flac", album: "Compline\u{1f}/m/Compline")])
        c.albumSettings[album.id] = minecraft
        let id = try #require(c.makeYours(album))
        #expect(c.albumSettings.isEmpty)
        #expect(c.albumsInPlaylists == [album.id])
        let reread = Controller(storage: nil, playlistFolder: dir).playlists
        #expect(reread.first?.gaps == minecraft)
        #expect(reread.first?.fromAlbum == album.id)
        // a second time gives back the same copy
        #expect(c.makeYours(album) == id)
        #expect(c.playlists.count == 1)
    }

    @Test func alarmsFollowAnAlbumToItsCopyAndBack() throws {
        let c = Controller(storage: nil, playlistFolder: temp())
        let album = Album(id: "lauds\u{1f}/m/Lauds", title: "Lauds", artist: "Various Artists", year: nil, artwork: nil,
                          songs: [song("/m/Lauds/1.flac", album: "lauds\u{1f}/m/Lauds")])
        c.addAlarm(Alarm(source: album.id, name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6]))
        c.albumSettings[album.id] = minecraft
        let id = try #require(c.makeYours(album))
        #expect(c.alarms.map(\.source) == [id])
        let renamed = try #require(c.rename(id, to: "Morning"))
        #expect(c.alarms.map(\.source) == [renamed])
        #expect(c.alarms.map(\.name) == ["Morning"])
        // deleting the copy gives the album back its alarm and its gaps
        c.forget(renamed)
        #expect(c.alarms.map(\.source) == [album.id])
        #expect(c.albumSettings[album.id] == minecraft)
        #expect(c.albumsInPlaylists.isEmpty)
    }

    @Test func removingAndMovingSongs() throws {
        let c = Controller(storage: nil, playlistFolder: temp())
        let id = try #require(c.newPlaylist(songs: ["/a", "/b", "/c", "/a"].map { song($0) }))
        c.removeFromPlaylist(id, at: [3])
        c.movePlaylistSongs(id, fromOffsets: [0], toOffset: 3)
        #expect(c.playlists.first?.paths == ["/b", "/c", "/a"])
    }
}
