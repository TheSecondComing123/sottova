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

    @Test func undoingAnEditBringsBackWhatYouSetAndNotWhenItLastWentOff() {
        let c = Controller(storage: nil)
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        c.addAlarm(lauds)
        let undo = undoing(c) { c.changeAlarm(lauds.id) { $0.hour = 8 } }
        #expect(undo.undoActionName == "Change Lauds")
        let fired = Date.now
        c.undo = nil
        c.changeAlarm(lauds.id) { $0.lastFired = fired }
        c.undo = undo
        undo.undo()
        #expect(c.alarms[0].hour == 7)
        #expect(c.alarms[0].lastFired == fired)
        undo.redo()
        #expect(c.alarms[0].hour == 8)
        #expect(c.alarms[0].lastFired == fired)
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

    @Test func undoPutsPartsBackAsTheyWere() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: ["/1", "/2", "/3", "/4"].map(song)))
        c.setBreak(true, at: 2, in: id)
        c.namePart("Dusk", at: 2, in: id)
        var parts: [[String]] { c.playlists.first?.partPaths ?? [] }
        // the last song of a part: it goes back to that part, not the next
        var undo = undoing(c) { c.removeFromPlaylist(id, at: [1]) }
        undo.undo()
        #expect(parts == [["/1", "/2"], ["/3", "/4"]])
        // a whole part, with its name
        undo = undoing(c) { c.removeFromPlaylist(id, at: [2, 3]) }
        #expect(parts == [["/1", "/2"]])
        undo.undo()
        #expect(parts == [["/1", "/2"], ["/3", "/4"]])
        #expect(c.playlists.first?.partNames == [2: "Dusk"])
        // something added since isn't lost
        undo = undoing(c) { c.removeFromPlaylist(id, at: [0]) }
        c.add([song("/5")], to: id)
        undo.undo()
        #expect(c.playlists.first?.paths == ["/1", "/2", "/3", "/4", "/5"])
    }

    @Test func partEditsUndoOneAtATimeAndNextStaysOnItsPart() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: ["/1", "/2", "/3", "/4"].map(song)))
        var row = Alarm(source: id, name: "Compline", hour: 20, minute: 0, weekdays: [2])
        (row.rotates, row.nextPart) = (true, 1)
        c.addAlarm(row)
        var p: Playlist { c.playlists[0] }
        var next: Int { c.alarms[0].nextPart }

        var undo = undoing(c) { c.setBreak(true, at: 2, in: id) }
        #expect(undo.undoActionName == "New part")
        #expect(p.partPaths == [["/1", "/2"], ["/3", "/4"]])
        undo.undo()
        #expect(p.breaks.isEmpty)
        undo.redo()
        #expect(p.breaks == [2])

        undo = undoing(c) { c.namePart("Dusk", at: 2, in: id) }
        #expect(undo.undoActionName == "Rename part")
        undo.undo()
        #expect(p.partNames.isEmpty)
        undo.redo()
        #expect(p.partNames == [2: "Dusk"])

        // the row plays Dusk next, wherever Dusk goes
        undo = undoing(c) { c.movePart(1, to: 0, in: id) }
        #expect(undo.undoActionName == "Move part")
        #expect(p.paths == ["/3", "/4", "/1", "/2"])
        #expect(p.partNames == [0: "Dusk"])
        #expect(next == 0)
        undo.undo()
        #expect(p.paths == ["/1", "/2", "/3", "/4"])
        #expect(p.partNames == [2: "Dusk"])
        #expect(next == 1)
        undo.redo()
        #expect(next == 0)

        undo = undoing(c) { c.setBreak(false, at: 2, in: id) }
        #expect(undo.undoActionName == "Join parts")
        #expect(p.breaks.isEmpty)
        undo.undo()
        #expect(p.breaks == [2])
        #expect(p.partNames == [0: "Dusk"])

        // nothing changed, nothing to undo
        undo = undoing(c) { c.namePart("Dusk", at: 0, in: id) }
        #expect(undo.undoActionName == "")
    }

    @Test func splittingOrJoiningKeepsNextOnItsPart() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: ["/1", "/2", "/3", "/4", "/5", "/6"].map(song)))
        c.setBreak(true, at: 2, in: id)
        c.setBreak(true, at: 4, in: id)
        var row = Alarm(source: id, name: "Compline", hour: 20, minute: 0, weekdays: [2])
        (row.rotates, row.nextPart) = (true, 2)
        c.addAlarm(row)
        var next: Int { c.alarms[0].nextPart }

        // a new part before it pushes it along; one after it doesn't
        var undo = undoing(c) { c.setBreak(true, at: 1, in: id) }
        #expect(next == 3)
        undo.undo()
        #expect(next == 2)
        undo.redo()
        #expect(next == 3)
        undo.undo()
        c.undo = nil
        c.setBreak(true, at: 5, in: id)
        #expect(next == 2)
        c.setBreak(false, at: 5, in: id)
        #expect(next == 2)

        // joining the part before pulls it back; joining it into that part keeps it there
        undo = undoing(c) { c.setBreak(false, at: 2, in: id) }
        #expect(next == 1)
        undo.undo()
        #expect(next == 2)
        c.undo = nil
        c.setBreak(false, at: 4, in: id)
        #expect(next == 1)
        #expect(c.playlists[0].partPaths[next] == ["/3", "/4", "/5", "/6"])
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
