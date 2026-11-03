import AVFoundation
import Testing
@testable import SottovaCore

/// A row that plays one part of its collection each time, in turn.
@MainActor
struct RotationTests {
    private func song(_ path: String, _ minutes: Double) -> Song {
        Song(id: path, title: "t", work: "t", detail: nil, artist: "p", album: "a", albumID: "a", albumArtist: "",
             composer: nil, trackNumber: nil, discNumber: nil, year: nil, duration: minutes * 60, artwork: nil, searchKey: path)
    }

    @Test func aCollectionIsCutIntoRunsOfAboutEqualLengthInOrder() {
        let songs = [song("/a", 10), song("/b", 10), song("/c", 5), song("/d", 5), song("/e", 10), song("/f", 20)]
        let parts = Controller.split(songs, into: 2)
        #expect(parts.map { $0.map(\.id) } == [["/a", "/b", "/c", "/d"], ["/e", "/f"]])
        #expect(Controller.split(songs, into: 1).count == 1)
        // never more parts than songs, and never an empty one
        #expect(Controller.split(Array(songs.prefix(2)), into: 5).map(\.count) == [1, 1])
    }

    @Test func breaksSurviveTheFileAndMoveWithAddsAndRemoves() {
        let file = URL(filePath: "/m/lists/Compline.m3u8")
        var p = Playlist(id: file.path, name: "Compline", paths: ["/m/1", "/m/2", "/m/3", "/m/4", "/m/5"])
        p.breaks = [2, 4]
        let text = p.render { _ in nil }
        #expect(text.components(separatedBy: "#SOTTOVA-PART").count == 3)
        #expect(Playlist.parse(text, at: file) == p)
        #expect(p.partPaths == [["/m/1", "/m/2"], ["/m/3", "/m/4"], ["/m/5"]])
        p.insert(["/m/x"], at: 1)
        #expect(p.partPaths == [["/m/1", "/m/x", "/m/2"], ["/m/3", "/m/4"], ["/m/5"]])
        p.remove(at: [3, 4])
        // the second part lost both its songs and went
        #expect(p.partPaths == [["/m/1", "/m/x", "/m/2"], ["/m/5"]])
    }

    @Test func aPartsNameSurvivesTheFileAndStaysWithItsSongs() {
        let file = URL(filePath: "/m/lists/Compline.m3u8")
        var p = Playlist(id: file.path, name: "Compline", paths: ["/m/1", "/m/2", "/m/3", "/m/4", "/m/5"])
        p.breaks = [2, 4]
        p.partNames = [0: "Dusk", 2: "Sorrow, stay: II"]
        let text = p.render { _ in nil }
        #expect(text.contains("#SOTTOVA-PART:Dusk\n"))
        #expect(Playlist.parse(text, at: file) == p)
        p.insert(["/m/x"], at: 1)
        #expect(p.partNames == [0: "Dusk", 3: "Sorrow, stay: II"])
        // the first part goes whole: the second moves up with its name, the unnamed third keeps none
        p.remove(at: [0, 1, 2])
        #expect(p.partNames == [0: "Sorrow, stay: II"])
        #expect(p.breaks == [2])
        p.remove(at: [0, 1])
        #expect(p.partNames.isEmpty)
    }

    @Test func aPartMovesWholeWithItsNameAndSaysWhereEachPartWent() {
        var p = Playlist(id: "/m/lists/Compline.m3u8", name: "Compline", paths: ["/m/1", "/m/2", "/m/3", "/m/4", "/m/5"])
        p.breaks = [2, 4]
        p.partNames = [0: "Dusk", 4: "Night"]
        // the unnamed middle part up to the top: it takes no name with it, and Dusk keeps its own
        #expect(p.movePart(1, to: 0) == [1, 0, 2])
        #expect(p.partPaths == [["/m/3", "/m/4"], ["/m/1", "/m/2"], ["/m/5"]])
        #expect(p.breaks == [2, 4])
        #expect(p.partNames == [2: "Dusk", 4: "Night"])
        #expect(p.movePart(2, to: 1) == [0, 2, 1])
        #expect(p.partPaths == [["/m/3", "/m/4"], ["/m/5"], ["/m/1", "/m/2"]])
        #expect(p.breaks == [2, 3])
        #expect(p.partNames == [2: "Night", 3: "Dusk"])
    }

    @Test func movingASongLeavesTheOthersInTheirParts() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: [1, 2, 3, 4, 5].map { song("/\($0)", 1) }))
        c.setBreak(true, at: 2, in: id)
        c.setBreak(true, at: 4, in: id)
        c.namePart("Dusk", at: 2, in: id)
        c.namePart("Night", at: 4, in: id)
        var parts: [[String]] { c.playlists.first?.partPaths ?? [] }
        var names: [Int: String] { c.playlists.first?.partNames ?? [:] }
        // the first song of a part goes to the last part, and the part it left keeps its name
        c.movePlaylistSongs(id, fromOffsets: [2], toOffset: 5)
        #expect(parts == [["/1", "/2"], ["/4"], ["/5", "/3"]])
        #expect(names == [2: "Dusk", 3: "Night"])
        // and back up, landing where it was: first in Dusk again
        c.movePlaylistSongs(id, fromOffsets: [4], toOffset: 2)
        #expect(parts == [["/1", "/2"], ["/3", "/4"], ["/5"]])
        #expect(names == [2: "Dusk", 4: "Night"])
        // dropped where it already is, nothing changes
        c.movePlaylistSongs(id, fromOffsets: [1], toOffset: 2)
        #expect(parts == [["/1", "/2"], ["/3", "/4"], ["/5"]])
        // a part left empty goes, and it's all still there in the file
        c.movePlaylistSongs(id, fromOffsets: [4], toOffset: 0)
        #expect(parts == [["/5", "/1", "/2"], ["/3", "/4"]])
        #expect(Controller(storage: nil, playlistFolder: dir).playlists.first?.partPaths == parts)
    }

    @Test func aRowSaysThePartItPlaysNextByName() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        for i in 1...3 {
            c.library.entries["/\(i)"] = Library.Entry(size: 0, modified: .now, meta: TrackMeta(title: "t", artist: "a", album: "R", duration: 60))
        }
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.songsByID.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(c.newPlaylist(songs: [1, 2, 3].map { song("/\($0)", 1) }))
        c.setBreak(true, at: 1, in: id)
        c.namePart(" Dusk ", at: 1, in: id)
        #expect(Controller(storage: nil, playlistFolder: dir).playlists.first?.partNames == [1: "Dusk"])
        var alarm = Alarm(source: id, name: "r", hour: 8, minute: 0)
        #expect(c.nextPartName(for: alarm) == "part 1")
        alarm.nextPart = 1
        #expect(c.nextPartName(for: alarm) == "Dusk")
        c.namePart("", at: 1, in: id)
        #expect(c.nextPartName(for: alarm) == "part 2")
        c.namePart("Dusk", at: 1, in: id)
        c.setBreak(false, at: 1, in: id)
        #expect(c.playlists.first?.partNames.isEmpty == true)
    }

    @Test func aPartStartsOnlyInsideTheList() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: nil, playlistFolder: dir)
        let id = try #require(c.newPlaylist(songs: [song("/1", 1), song("/2", 1), song("/3", 1)]))
        c.setBreak(true, at: 2, in: id)
        c.setBreak(true, at: 0, in: id)
        c.setBreak(true, at: 3, in: id)
        #expect(c.playlists.first?.breaks == [2])
        // read back from the file
        #expect(Controller(storage: nil, playlistFolder: dir).playlists.first?.breaks == [2])
        c.setBreak(false, at: 2, in: id)
        #expect(c.playlists.first?.breaks.isEmpty == true)
    }

    @Test func eachTimeItPlaysItTakesTheNextPartButASkippedDayDoesnt() async throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        silence.frameLength = 48_000
        for i in 0..<4 {
            let url = dir.appending(path: "\(i).caf")
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: silence)
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, meta: TrackMeta(title: "t\(i)", artist: "a", album: "R", duration: 60))
        }
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let album = try #require(c.catalog.albums.first)
        var alarm = Alarm(source: album.id, name: "R", hour: 20, minute: 0, weekdays: Set(1...7))
        alarm.rotates = true
        alarm.parts = 2
        c.addAlarm(alarm)
        c.fire(alarm.id, due: .now)
        #expect(c.alarms.first?.nextPart == 1)
        let parts = c.parts(for: try #require(c.alarms.first))
        #expect(parts.count == 2)
        // the next time it takes the second part, then the first again
        c.fire(alarm.id, due: .now)
        #expect(Set(c.upNext.map(\.path)) == Set(parts[1].map(\.id)))
        c.advance(1.1)
        #expect(c.alarms.first?.nextPart == 0)
        c.fire(alarm.id, due: .now)
        #expect(Set(c.upNext.map(\.path)) == Set(parts[0].map(\.id)))
        c.advance(1.1)
        #expect(c.alarms.first?.nextPart == 1)
        c.calendarBusy = { true }
        var minding = try #require(c.alarms.first)
        minding.heedsCalendar = true
        c.changeAlarm(minding.id) { $0 = minding }
        c.fire(alarm.id, due: .now)
        #expect(c.alarms.first?.nextPart == 1)
        c.calendarBusy = { false }
        c.fire(alarm.id, due: .now)
        c.advance(1.1)
        #expect(c.alarms.first?.nextPart == 0)
    }
}
