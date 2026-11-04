import AVFoundation
import Foundation
import Testing
@testable import SottovaCore

@MainActor
struct UndoSafetyTests {
    private func controller(folder: URL? = nil) throws -> Controller {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        return Controller(engine: engine, storage: nil, playlistFolder: folder)
    }

    private func song(_ path: String) -> Song {
        Song(id: path, title: path, work: path, detail: nil, artist: "artist", album: "album", albumID: "album", albumArtist: "artist",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: 60, artwork: nil, searchKey: path)
    }

    @Test func undoingClearLeavesAQueueThatMovedOn() throws {
        let c = try controller()
        c.playNext([song("/old")])
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        let older = Alarm(source: "other", name: "Earlier", hour: LiveClock.farHour, minute: 2, weekdays: Set(1...7))
        undo.beginUndoGrouping()
        c.addAlarm(older)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        c.clearQueue()
        undo.endUndoGrouping()
        c.undo = nil
        c.playNext([song("/new")])
        let newer = c.upNext
        c.undo = undo
        undo.undo()
        #expect(c.upNext == newer)
        #expect(c.notice?.text.contains("queue has moved on") == true)
        #expect(c.notice?.undoable == false)
        #expect(!undo.canRedo)
        #expect(undo.canUndo)
        undo.undo()
        #expect(!c.alarms.contains { $0.id == older.id })
    }

    @Test func undoingClearDoesntReviveAQueueAfterAnotherSongWasTaken() throws {
        let c = try controller()
        c.playNext([song("/old")])
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        undo.beginUndoGrouping()
        c.clearQueue()
        undo.endUndoGrouping()
        c.undo = nil
        c.playNext([song("/new")])
        #expect(c.dequeue() == "/new")
        #expect(c.upNext.isEmpty)
        c.undo = undo
        undo.undo()
        #expect(c.upNext.isEmpty)
        #expect(c.notice?.text.contains("queue has moved on") == true)
        #expect(!undo.canRedo)
    }

    @Test func failedTrashRestoreKeepsEarlierUndoAndOffersNoFalseRedo() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sottova-undo-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let c = try controller(folder: folder)
        let id = try #require(c.newPlaylist(named: "Compline"))
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        let older = Alarm(source: "other", name: "Earlier", hour: LiveClock.farHour, minute: 2, weekdays: Set(1...7))
        undo.beginUndoGrouping()
        c.addAlarm(older)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        c.trashPlaylist(id)
        undo.endUndoGrouping()
        try Data("another file".utf8).write(to: URL(filePath: id))
        undo.undo()
        #expect(c.notice?.text.contains("couldn't get Compline back") == true)
        #expect(undo.canUndo)
        #expect(!undo.canRedo)
        undo.undo()
        #expect(!c.alarms.contains { $0.id == older.id })
    }
}
