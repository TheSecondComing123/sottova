import Foundation
import Testing
@testable import SottovaCore

@MainActor
struct AlbumGapsTests {
    private let minecraft = Settings.presets.first { $0.name == "Minecraft" }!
    private let sparse = Settings.presets.first { $0.name == "Sparse" }!

    /// Sparse at -23 LUFS, which the controller files as Custom.
    private func controller() -> (Controller, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-album-gaps-\(UUID().uuidString)")
        let c = Controller(storage: dir)
        var own = sparse
        own.targetLufs = -23
        c.settings = own
        c.albumSettings["compline"] = minecraft
        return (c, dir)
    }

    @Test func albumPlaysWithItsGapsOverTheUsersLoudness() {
        let (c, _) = controller()
        c.useAlbumSettings(for: "compline")
        #expect(c.settings.name == "Custom")  // Minecraft gaps at -23 LUFS isn't the preset
        #expect(c.settings.gapRange == 600...1200)
        #expect(c.settings.targetLufs == -23)
    }

    @Test func otherMusicBringsTheUsersSettingsBack() {
        let (c, _) = controller()
        let own = c.settings
        c.useAlbumSettings(for: "compline")
        c.useAlbumSettings(for: nil)
        #expect(c.settings == own)
        c.useAlbumSettings(for: "compline")
        c.useAlbumSettings(for: "lauds")  // no gaps of its own
        #expect(c.settings == own)
    }

    @Test func aChangeByHandDuringTheAlbumStays() {
        let (c, _) = controller()
        c.useAlbumSettings(for: "compline")
        c.apply(Settings.presets.first { $0.name == "Short" }!)
        c.useAlbumSettings(for: nil)
        #expect(c.settings.name == "Short")
    }

    @Test func editingThePlayingAlbumTakesEffectAndClearingItRestores() {
        let (c, _) = controller()
        let own = c.settings
        c.useAlbumSettings(for: "compline")
        var custom = minecraft
        custom.name = "Custom"
        custom.gapMin = 60
        c.albumSettings["compline"] = custom
        #expect(c.settings.gapMin == 60)
        c.albumSettings["compline"] = nil
        #expect(c.settings == own)
    }

    @Test func aRestartComesBackToTheUsersSettingsAndKeepsTheAlbums() {
        let (c, dir) = controller()
        let own = c.settings
        c.useAlbumSettings(for: "compline")
        let reopened = Controller(storage: dir)
        #expect(reopened.settings == own)
        #expect(reopened.albumSettings == ["compline": minecraft])
    }

    @Test func aProfileFromBeforeAlbumGapsStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-album-gaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(sparse).write(to: dir.appending(path: "profile.json"))
        let c = Controller(storage: dir)
        #expect(c.settings == sparse)
        #expect(c.albumSettings.isEmpty)
    }

    private func song(_ path: String, album: String) -> Song {
        Song(id: path, title: path, work: path, detail: nil, artist: "", album: album, albumID: album, albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: path)
    }

    @Test func eachQueuedSongPlaysWithTheGapsOfWhereItCameFrom() {
        let (c, _) = controller()
        let own = c.settings
        c.play([song("/c1", album: "compline"), song("/c2", album: "compline")])
        c.playNext([song("/other", album: "lauds")])
        c.playNext([song("/c3", album: "compline")])
        #expect(c.dequeue() == "/c3")
        #expect(c.settings.gapRange == 600...1200)
        #expect(c.dequeue() == "/other")
        #expect(c.settings == own)
        // play() from idle already started /c1
        #expect(c.dequeue() == "/c2")
        #expect(c.settings.gapRange == 600...1200)
        #expect(c.dequeue() == nil)
        #expect(c.settings == own)
    }

    @Test func theSameSongQueuedTwiceMovesAndGoesOnItsOwn() {
        let (c, _) = controller()
        let a = song("/a", album: "x"), b = song("/b", album: "x")
        c.playNext([a, b])
        c.playNext([a])
        #expect(c.upNext.map(\.path) == ["/a", "/a", "/b"])
        c.removeQueued(c.upNext[1].id)
        #expect(c.upNext.map(\.path) == ["/a", "/b"])
        c.moveQueued(fromOffsets: [0], toOffset: 2)
        #expect(c.upNext.map(\.path) == ["/b", "/a"])
    }
}
