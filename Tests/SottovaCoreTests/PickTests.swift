import Foundation
import Testing
@testable import SottovaCore

/// What Songs does with a pick.
@MainActor
struct PickTests {
    private func song(_ path: String) -> Song {
        Song(id: path, title: "t", work: "t", detail: nil, artist: "p", album: "a", albumID: "a", albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: path)
    }

    @Test func aCollectionMadeFromAPickGoesOnUndoAndComesBackOnRedo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        undo.beginUndoGrouping()
        let id = try #require(c.newPlaylist(named: "Vespers", songs: ["/1", "/2"].map(song)))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "New Collection")
        undo.undo()
        #expect(c.playlists.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: id))
        undo.redo()
        #expect(c.playlists.map(\.name) == ["Vespers"])
        #expect(c.playlists.first?.paths == ["/1", "/2"])
    }

    @Test func undoLeavesANewCollectionAYourDayRowPlays() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        undo.beginUndoGrouping()
        let id = try #require(c.newPlaylist(named: "Vespers", songs: ["/1", "/2"].map(song)))
        undo.endUndoGrouping()
        c.undo = nil
        c.addAlarm(Alarm(source: id, name: "Vespers", hour: 18, minute: 0, weekdays: [2]))
        c.undo = undo
        undo.undo()
        #expect(c.playlists.map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: id))
        #expect(c.alarms.map(\.source) == [id])
        #expect(c.notice?.text == "Vespers is on your day, so it stays")
    }

    @Test func addToQueueGoesAfterWhatsQueued() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2"].map(song))
        c.playNext(["/3"].map(song), at: c.upNext.count)
        #expect(c.upNext.map(\.path) == ["/1", "/2", "/3"])
    }
}
