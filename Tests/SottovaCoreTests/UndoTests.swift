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

    @Test func aRemoveSaysWhatWentAndUndoSaysItCameBack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(named: "Compline", songs: ["/m/Weep you no more.flac", "/2", "/3", "/4"].map(song)))
        var undo = undoing(c) { c.removeFromPlaylist(id, at: [0]) }
        #expect(undo.undoActionName == "Remove Song")
        #expect(c.notice?.text == "Removed Weep you no more")
        #expect(c.notice?.undoable == true)
        undo.undo()
        #expect(c.notice?.text == "Put back Weep you no more")
        #expect(c.notice?.undoable == false)
        undo.redo()
        #expect(c.notice?.text == "Removed Weep you no more")

        undo = undoing(c) { c.removeFromPlaylist(id, at: [0, 1, 2]) }
        #expect(undo.undoActionName == "Remove 3 Songs")
        #expect(c.notice?.text == "Removed 3 songs from Compline")
        let shown = c.notice?.id
        undo.undo()
        #expect(c.notice?.text == "Put back 3 songs")
        #expect(c.notice?.id != shown)
    }

    @Test func aNoticeNamesTheUndoItOffers() {
        let c = Controller(storage: nil)
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        c.addAlarm(lauds)
        let undo = undoing(c) { c.removeAlarm(lauds.id) }
        #expect(c.notice?.action == "Delete Lauds")
        #expect(c.notice?.action == undo.undoActionName)
        undo.undo()
        undo.redo()
        #expect(c.notice?.action == undo.undoActionName)
    }

    @Test func aDeleteAndAClearSayWhatWent() {
        let c = Controller(storage: nil)
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        c.addAlarm(lauds)
        var undo = undoing(c) { c.removeAlarm(lauds.id) }
        #expect(c.notice?.text == "Deleted Lauds")
        undo.undo()
        #expect(c.notice?.text == "Put back Lauds")
        c.undo = nil
        c.playNext((1...12).map { song("/\($0)") })
        undo = undoing(c) { c.clearQueue() }
        #expect(undo.undoActionName == "Clear Queue")
        #expect(c.notice?.text == "Cleared the queue, 12 songs")
    }

    @Test func anAddedRowGoesOnUndoAndComesBackOnRedo() {
        let c = Controller(storage: nil)
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        let undo = undoing(c) { c.addAlarm(lauds) }
        #expect(undo.undoActionName == "Add Lauds")
        #expect(c.notice?.text == "Added Lauds to your day")
        undo.undo()
        #expect(c.alarms.isEmpty)
        #expect(c.notice?.text == "Took Lauds off your day")
        undo.redo()
        #expect(c.alarms == [lauds])
    }

    @Test func aTrashedCollectionComesBackWithItsRows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(named: "Compline", songs: ["/1", "/2"].map(song)))
        let lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        let row = Alarm(source: id, name: "Compline", hour: 20, minute: 0, weekdays: [2])
        c.addAlarm(row)
        c.addAlarm(lauds)
        let undo = undoing(c) { c.trashPlaylist(id) }
        #expect(undo.undoActionName == "Move Compline to Trash")
        #expect(c.notice?.text == "Moved Compline to the Trash")
        #expect(!FileManager.default.fileExists(atPath: id))
        #expect(c.alarms == [lauds])
        undo.undo()
        #expect(FileManager.default.fileExists(atPath: id))
        #expect(c.playlists.map(\.id) == [id])
        #expect(c.playlists.first?.paths == ["/1", "/2"])
        #expect(c.alarms == [row, lauds])
        #expect(c.notice?.text == "Put back Compline")
        undo.redo()
        #expect(c.playlists.isEmpty)
        #expect(c.alarms == [lauds])
    }

    @Test func aCollectionThatCantComeBackNamesItsRowsAndLeavesNoRedo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(named: "Compline", songs: ["/1"].map(song)))
        c.addAlarm(Alarm(source: id, name: "Night", hour: 20, minute: 0, weekdays: [2]))
        let undo = undoing(c) { c.trashPlaylist(id) }
        // something new in its place: the move back fails
        try Data().write(to: URL(filePath: id))
        undo.undo()
        #expect(c.notice?.text.contains("Night") == true)
        #expect(c.notice?.undoable == false)
        #expect(!undo.canRedo)
    }

    @Test func aCopyMadeYoursGoesOnUndoAndTheAlbumGetsItsRowsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let album = Album(id: "lauds\u{1f}/m/Lauds", title: "Lauds", artist: "Various Artists", year: nil, artwork: nil, songs: [song("/m/Lauds/1.flac")])
        c.addAlarm(Alarm(source: album.id, name: "Lauds", hour: 7, minute: 2, weekdays: [2]))
        var id: String?
        let undo = undoing(c) { id = c.makeYours(album) }
        let copy = try #require(id)
        #expect(undo.undoActionName == "Make Lauds Yours")
        #expect(c.alarms.map(\.source) == [copy])
        undo.undo()
        #expect(c.playlists.isEmpty)
        #expect(c.alarms.map(\.source) == [album.id])
        undo.redo()
        #expect(c.playlists.map(\.id) == [copy])
        #expect(c.alarms.map(\.source) == [copy])
    }

    @Test func playNextAndAddToQueueUndoUnlessTheQueueMovedOn() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2"].map(song))
        let queued = c.upNext
        var undo = undoing(c) { c.playNext([song("/m/Ave verum corpus.flac")]) }
        #expect(undo.undoActionName == "Play Next")
        #expect(c.notice?.text == "Playing Ave verum corpus next")
        undo.undo()
        #expect(c.upNext == queued)
        undo = undoing(c) { c.playNext(["/3", "/4"].map(song), at: c.upNext.count) }
        #expect(undo.undoActionName == "Add 2 Songs to Queue")
        #expect(c.notice?.text == "Added 2 songs to the queue")
        _ = c.dequeue()
        let now = c.upNext
        undo.undo()
        #expect(c.upNext == now)
        #expect(c.notice?.text == "the queue has moved on since, so undo leaves it")
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

    @Test func undoingAPickedNextPartBringsTheOldOneBackAndAnEditLeavesAnAdvancedOneAlone() {
        let c = Controller(storage: nil)
        var lauds = Alarm(source: "l", name: "Lauds", hour: 7, minute: 2, weekdays: [2])
        (lauds.rotates, lauds.parts) = (true, 3)
        c.addAlarm(lauds)
        var undo = undoing(c) { c.changeAlarm(lauds.id) { $0.nextPart = 2 } }
        undo.undo()
        #expect(c.alarms[0].nextPart == 0)
        undo.redo()
        #expect(c.alarms[0].nextPart == 2)

        undo = undoing(c) { c.changeAlarm(lauds.id) { $0.hour = 8 } }
        c.undo = nil
        c.changeAlarm(lauds.id) { $0.nextPart = 0 }
        c.undo = undo
        undo.undo()
        #expect(c.alarms[0].hour == 7)
        #expect(c.alarms[0].nextPart == 0)
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
        c.undo = nil
        c.add([song("/5")], to: id)
        c.undo = undo
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
        #expect(undo.undoActionName == "New Part")
        #expect(p.partPaths == [["/1", "/2"], ["/3", "/4"]])
        undo.undo()
        #expect(p.breaks.isEmpty)
        undo.redo()
        #expect(p.breaks == [2])

        undo = undoing(c) { c.namePart("Dusk", at: 2, in: id) }
        #expect(undo.undoActionName == "Rename Part")
        undo.undo()
        #expect(p.partNames.isEmpty)
        undo.redo()
        #expect(p.partNames == [2: "Dusk"])

        // the row plays Dusk next, wherever Dusk goes
        undo = undoing(c) { c.movePart(1, to: 0, in: id) }
        #expect(undo.undoActionName == "Move Part")
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
        #expect(undo.undoActionName == "Join Parts")
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

    @Test func addingMovingRenamingAndSilenceUndo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let first = try #require(c.newPlaylist(named: "Vespers", songs: ["/1", "/2"].map(song)))
        c.setBreak(true, at: 1, in: first)
        var p: Playlist { c.playlists[0] }

        var undo = undoing(c) { c.add([song("/3")], to: first, at: 1) }
        #expect(undo.undoActionName == "Add Song")
        #expect(p.paths == ["/1", "/3", "/2"])
        undo.undo()
        #expect(p.paths == ["/1", "/2"])
        #expect(p.breaks == [1])
        undo.redo()
        #expect(p.paths == ["/1", "/3", "/2"])

        undo = undoing(c) { c.movePlaylistSongs(first, fromOffsets: [0], toOffset: 3) }
        #expect(undo.undoActionName == "Move Song")
        #expect(p.paths == ["/3", "/2", "/1"])
        undo.undo()
        #expect(p.paths == ["/1", "/3", "/2"])
        undo.redo()
        #expect(p.paths == ["/3", "/2", "/1"])

        let minecraft = Settings.presets.first { $0.name == "Minecraft" }!
        undo = undoing(c) { c.setGaps(minecraft, for: first) }
        #expect(undo.undoActionName == "Change Silence")
        undo.undo()
        #expect(p.gaps == nil)
        undo.redo()
        #expect(p.gaps == minecraft)

        undo = undoing(c) { c.rename(first, to: "Compline") }
        #expect(undo.undoActionName == "Rename Vespers")
        #expect(p.name == "Compline")
        undo.undo()
        #expect(p.name == "Vespers")
        #expect(p.id == first)
        #expect(FileManager.default.fileExists(atPath: first))
        undo.redo()
        #expect(p.name == "Compline")
    }

    @Test func pickedRowsBecomeAPartInOneUndo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: ["/1", "/2", "/3", "/4", "/5"].map(song)))
        var p: Playlist { c.playlists[0] }
        let undo = undoing(c) { c.newPart(from: [1, 3], in: id) }
        #expect(undo.undoActionName == "New Part")
        #expect(p.partPaths == [["/1"], ["/2", "/4"], ["/3", "/5"]])
        undo.undo()
        #expect(p.paths == ["/1", "/2", "/3", "/4", "/5"])
        #expect(p.breaks.isEmpty)
        undo.redo()
        #expect(p.partPaths == [["/1"], ["/2", "/4"], ["/3", "/5"]])
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

    @Test func removedQueuedSongsComeBackInTheirPlaces() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2", "/3", "/4"].map(song))
        let queued = c.upNext
        let undo = undoing(c) { c.removeQueued([queued[1].id, queued[3].id]) }
        #expect(c.upNext.map(\.path) == ["/1", "/3"])
        #expect(undo.undoActionName == "Remove 2 Songs from Queue")
        undo.undo()
        #expect(c.upNext == queued)
        undo.redo()
        #expect(c.upNext.map(\.path) == ["/1", "/3"])
    }

    @Test func aReorderedQueueGoesBack() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2", "/3"].map(song))
        let queued = c.upNext
        let undo = undoing(c) { c.moveQueued(fromOffsets: [0], toOffset: 3) }
        #expect(c.upNext.map(\.path) == ["/2", "/3", "/1"])
        #expect(undo.undoActionName == "Move in Queue")
        undo.undo()
        #expect(c.upNext == queued)
        undo.redo()
        #expect(c.upNext.map(\.path) == ["/2", "/3", "/1"])
    }

    @Test func aQueueEditDoesntUndoOverWhatChangedSince() {
        let c = Controller(storage: nil)
        c.playNext(["/1", "/2", "/3"].map(song))
        let undo = undoing(c) { c.removeQueued([c.upNext[1].id]) }
        c.undo = nil
        c.playNext([song("/4")], at: 2)
        c.undo = undo
        let now = c.upNext
        undo.undo()
        #expect(c.upNext == now)
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
