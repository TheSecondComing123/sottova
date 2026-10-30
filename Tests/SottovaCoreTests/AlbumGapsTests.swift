import Foundation
import Testing
@testable import SottovaCore

@MainActor
struct AlbumGapsTests {
    private let minecraft = Settings.presets.first { $0.name == "Minecraft" }!
    private let sparse = Settings.presets.first { $0.name == "Sparse" }!

    /// Sparse at −23 LUFS, still Sparse: loudness isn't part of the mode.
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
        #expect(c.settings.name == "Minecraft")
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

    @Test func theSilenceBeforeAPieceIsWhereItComesFrom() {
        let (c, _) = controller()
        let yours = c.settings.gapRange
        // shuffle playing, Compline queued next: its own silence comes before it
        #expect(c.gapRange(beforeNext: QueueEntry(path: "/a.flac", source: "compline")) == minecraft.gapRange)
        // Compline ending, nothing queued: the shuffler's pick comes back with yours at once
        c.useAlbumSettings(for: "compline")
        #expect(c.gapRange(beforeNext: nil) == yours)
        #expect(c.gapRange(beforeNext: QueueEntry(path: "/b.flac", source: "lauds")) == yours)
        #expect(c.gapRange(beforeNext: QueueEntry(path: "/c.flac", source: "compline")) == minecraft.gapRange)
    }

    @Test func aProfileThisBuildCantReadIsSetAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-album-gaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // from a newer build
        let newer = Data(#"{"schema":2,"settings":{"schema":2}}"#.utf8)
        try newer.write(to: dir.appending(path: "profile.json"))
        let c = Controller(storage: dir)
        #expect(c.problem?.contains("profile.json.unreadable-") == true)
        c.settings = sparse
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try #require(files.first { $0.hasPrefix("profile.json.unreadable-") })
        #expect(try Data(contentsOf: dir.appending(path: aside)) == newer)
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

    @Test func loudnessIsNotPartOfAMode() {
        let c = Controller(storage: nil)
        c.apply(sparse)
        c.settings.targetLufs = -23
        #expect(c.settings.name == "Sparse")
        c.apply(minecraft)
        #expect(c.settings.name == "Minecraft")
        #expect(c.settings.targetLufs == -23)
    }
}
