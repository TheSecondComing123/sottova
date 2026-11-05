import AVFoundation
import Foundation
import Testing
@testable import SottovaCore

/// Collections and rows kept in step: a rename while playing, parts emptied by a removal, a save that fails, and
/// which of two open rows Now names.
@Suite(.disabled(if: LiveClock.repeatsAnHour(), "rows on the live clock can't be set up while the clocks repeat an hour"))
@MainActor
struct CollectionRowTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-coll-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func controller(_ root: URL) throws -> Controller {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: root, playlistFolder: root.appending(path: "collections"), artworkFolder: root.appending(path: "art"))
        c.saveVolume = { _ in }
        return c
    }

    private func seed(_ c: Controller, in root: URL, count: Int = 6) async throws -> [Song] {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<count {
            let url = root.appending(path: "song-\(i).caf")
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10), meta: TrackMeta(title: "Song \(i)", artist: "Artist", album: "Album", trackNumber: i + 1, duration: 3))
        }
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.songs.count != count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.catalog.songs.count == count)
        return c.catalog.albums[0].songs
    }

    private func rotatingRow(_ id: String, next: Int) -> Alarm {
        var row = Alarm(source: id, name: "Morning", hour: Calendar.current.component(.hour, from: .now + 6 * 3600), minute: 2, weekdays: Set(1...7))
        row.rotates = true
        row.nextPart = next
        return row
    }

    @Test func renameKeepsCollectionPlaybackIdentity() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Before", songs: songs))
        c.play(songs, source: id)
        #expect(c.status == .playing)
        #expect(c.collectionState(songs, source: id) != nil)
        let renamed = try #require(c.rename(id, to: "After"))
        #expect(c.collectionState(songs, source: renamed) != nil)
        c.pause()
    }

    @Test func aPickFromThePlayingCollectionPlaysThePickAndOneRowPlaysOnFromThere() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Compline", songs: songs))
        c.play(songs, source: id)
        c.playPick([3, 4], of: songs, source: id)
        c.advance(1.5)
        #expect(c.current?.id == songs[3].id)
        #expect(c.upNext.map(\.path) == [songs[4].id])
        #expect(c.upNext.allSatisfy { $0.source == id })
        #expect(c.collectionState(songs, source: id) == nil)
        #expect(c.pickState([3, 4], of: songs, source: id)?.paused == false)

        c.playPick([2], of: songs, source: id)
        c.advance(1.5)
        #expect(c.current?.id == songs[2].id)
        #expect(c.upNext.map(\.path) == songs[3...].map(\.id))
        // the bar's Play on one row: Pause while the list it plays on through is going
        #expect(c.pickState([2], of: songs, source: id)?.paused == false)
        #expect(c.pickState([3, 4], of: songs, source: id) == nil)
        c.pause()
    }

    @Test func oneRowsPlayBringsItBackWhenItsTheOneSoundingAndPlaysAnotherOnFromThere() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Compline", songs: songs))
        c.playPick([2], of: songs, source: id)
        c.advance(1)
        c.pause()
        #expect(c.pickState([2], of: songs, source: id)?.paused == true)
        // another row of the same list isn't what's going
        #expect(c.pickState([4], of: songs, source: id) == nil)
        let skips = c.skips
        c.playPick([2], of: songs, source: id)
        #expect(c.status == .playing)
        #expect(c.skips == skips)
        #expect(c.current?.id == songs[2].id)

        c.playPick([4], of: songs, source: id)
        c.advance(1.5)
        #expect(c.current?.id == songs[4].id)
        c.pause()
    }

    @Test func theSamePickFromTwoCollectionsIsTwoPicksAndARenameKeepsIt() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let a = try #require(c.newPlaylist(named: "Lauds", songs: songs))
        let b = try #require(c.newPlaylist(named: "Vespers", songs: songs))
        c.playPick([0, 1], of: songs, source: a)
        #expect(c.pickState([0, 1], of: songs, source: b) == nil)
        c.playPick([0, 1], of: songs, source: b)
        #expect(c.upNext.allSatisfy { $0.source == b })
        let renamed = try #require(c.rename(b, to: "Compline"))
        #expect(c.pickState([0, 1], of: songs, source: renamed) != nil)
        c.pause()
    }

    @Test func renameUpdatesSavedQueueBeforeCrash() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Before", songs: songs))
        c.play(songs, source: id)
        let renamed = try #require(c.rename(id, to: "After"))
        let state = try JSONDecoder().decode(Controller.ResumeState.self, from: Data(contentsOf: dir.appending(path: "resume.json")))
        #expect(state.playingFrom == renamed)
        #expect(state.upNext.allSatisfy { $0.source == renamed })
        c.pause()
    }

    @Test func removingEarlierPartKeepsRowsNextPartOnItsSongs() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Parts", songs: songs))
        c.setBreak(true, at: 2, in: id)
        c.setBreak(true, at: 4, in: id)
        c.namePart("First", at: 0, in: id)
        c.namePart("Middle", at: 2, in: id)
        c.namePart("Last", at: 4, in: id)
        let row = rotatingRow(id, next: 1)
        c.addAlarm(row)
        #expect(c.nextPartName(for: row) == "Middle")
        c.removeFromPlaylist(id, at: [0, 1])
        let changed = try #require(c.alarms.first)
        #expect(c.nextPartName(for: changed) == "Middle")
        #expect(c.rowSongs(changed).map(\.id) == Array(songs[2..<4]).map(\.id))
        c.fire(row.id, due: .now)
        #expect(c.current?.id == songs[2].id)
        c.pause()
    }

    @Test func undoingARemovalThatEmptiedAPartPutsTheRowsNextPartBack() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Parts", songs: songs))
        c.setBreak(true, at: 2, in: id)
        c.setBreak(true, at: 4, in: id)
        c.namePart("Middle", at: 2, in: id)
        c.addAlarm(rotatingRow(id, next: 1))
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        undo.beginUndoGrouping()
        c.removeFromPlaylist(id, at: [0, 1])
        undo.endUndoGrouping()
        #expect(c.alarms[0].nextPart == 0)
        undo.undo()
        #expect(c.playlists[0].paths == songs.map(\.id))
        #expect(c.alarms[0].nextPart == 1)
        #expect(c.nextPartName(for: c.alarms[0]) == "Middle")
    }

    @Test func movingAPartsSongsAwayKeepsRowsNextPartOnItsSongs() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Parts", songs: songs))
        c.setBreak(true, at: 2, in: id)
        c.setBreak(true, at: 4, in: id)
        c.namePart("Last", at: 4, in: id)
        let row = rotatingRow(id, next: 2)
        c.addAlarm(row)
        c.movePlaylistSongs(id, fromOffsets: [2, 3], toOffset: 6)
        let changed = try #require(c.alarms.first)
        #expect(c.nextPartName(for: changed) == "Last")
        #expect(c.rowSongs(changed).map(\.id).prefix(2) == songs[4..<6].map(\.id)[...])
    }

    @Test func failedPartSaveDoesNotPersistDifferentAlarmRotation() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Parts", songs: songs))
        c.setBreak(true, at: 2, in: id)
        let row = rotatingRow(id, next: 1)
        c.addAlarm(row)
        let original = URL(filePath: id), backup = dir.appending(path: "original.m3u8")
        try FileManager.default.moveItem(at: original, to: backup)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        c.setBreak(true, at: 1, in: id)
        let saved = try JSONDecoder().decode([Alarm].self, from: Data(contentsOf: dir.appending(path: "alarms.json")))
        let disk = Playlist.parse(try String(contentsOf: backup, encoding: .utf8), at: original)
        #expect(c.problem?.contains("couldn't save") == true)
        #expect(c.playlists[0].breaks == disk.breaks)
        #expect(saved[0].nextPart == row.nextPart)
    }

    @Test func unchangedRenameIsHarmless() throws {
        let dir = try root(), c = try controller(dir)
        let id = try #require(c.newPlaylist(named: "Same"))
        let result = c.rename(id, to: "Same")
        #expect(result == id)
        #expect(c.problem == nil)
    }

    @Test func deletingSongsWithoutDeletingPartKeepsRotation() async throws {
        let dir = try root(), c = try controller(dir)
        let songs = try await seed(c, in: dir)
        let id = try #require(c.newPlaylist(named: "Control", songs: songs))
        c.setBreak(true, at: 2, in: id)
        c.namePart("Middle", at: 2, in: id)
        c.addAlarm(rotatingRow(id, next: 1))
        c.removeFromPlaylist(id, at: [0])
        #expect(c.nextPartName(for: try #require(c.alarms.first)) == "Middle")
    }

    @Test func quietPageNamesLatestStartingOpenRow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 16, minute: 30)))
        var early = Alarm(source: "early", name: "Earlier", hour: 15, minute: 0, weekdays: Set(1...7))
        early.whileHere = true
        early.minutes = 240
        var later = Alarm(source: "later", name: "Later", hour: 16, minute: 0, weekdays: Set(1...7))
        later.whileHere = true
        later.minutes = 60
        let plan = DayPlan(alarms: [early, later], now: now, calendar: calendar)
        #expect(plan.quiet().headline == "Later")
        #expect(plan.quietSource == later.source)
    }
}
