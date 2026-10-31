import Foundation
import Testing
@testable import SottovaCore

/// What Edit › Undo brings back.
@MainActor
struct UndoTests {
    private func undoing(_ c: Controller, _ action: () -> Void) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
        return undo
    }

    private func song(_ path: String) -> Song {
        Song(id: path, title: "t", work: "t", detail: nil, artist: "p", album: "a", albumID: "a", albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: path)
    }

    @Test func aDeletedAlarmComesBackInItsPlaceAndGoesAgainOnRedo() {
        let c = Controller(storage: nil)
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        let compline = Alarm(source: "c", name: "Compline", hour: 20, minute: 0, weekdays: [2])
        c.addAlarm(lauds)
        c.addAlarm(compline)
        let undo = undoing(c) { c.removeAlarm(lauds.id) }
        #expect(c.alarms == [compline])
        #expect(undo.undoActionName == "Delete Lauds")
        undo.undo()
        #expect(c.alarms == [lauds, compline])
        undo.redo()
        #expect(c.alarms == [compline])
    }

    @Test func songsRemovedFromACollectionGoBackWhereTheyWere() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: ["/1", "/2", "/3", "/4"].map(song)))
        let undo = undoing(c) { c.removeFromPlaylist(id, at: [1, 3]) }
        #expect(c.playlists.first?.paths == ["/1", "/3"])
        undo.undo()
        #expect(c.playlists.first?.paths == ["/1", "/2", "/3", "/4"])
        undo.redo()
        #expect(c.playlists.first?.paths == ["/1", "/3"])
    }

    @Test func aClearedQueueComesBack() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2"].map(song))
        let queued = c.upNext
        let undo = undoing(c) { c.clearQueue() }
        #expect(c.upNext.isEmpty)
        undo.undo()
        #expect(c.upNext == queued)
    }
}

@MainActor
struct QueueTests {
    private func song(_ path: String) -> Song {
        Song(id: path, title: "t", work: "t", detail: nil, artist: "p", album: "a", albumID: "a", albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: path)
    }

    @Test func songsDroppedIntoTheQueueLandWhereTheyFall() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2", "/3"].map(song))
        c.playNext([song("/x")], at: 2)
        #expect(c.upNext.map(\.path) == ["/1", "/2", "/x", "/3"])
        c.playNext([song("/y")], at: 99)
        #expect(c.upNext.last?.path == "/y")
    }

    @Test func playNowTakesAQueuedSongAndLeavesTheRestInOrder() throws {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2", "/3"].map(song))
        let third = try #require(c.upNext.last)
        c.playQueued(third.id)
        // it went first and was taken to play; the file isn't there, so nothing does
        #expect(c.upNext.map(\.path) == ["/1", "/2"])
    }
}
