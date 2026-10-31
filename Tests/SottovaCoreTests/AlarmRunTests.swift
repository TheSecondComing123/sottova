import AVFoundation
import Testing
@testable import SottovaCore

/// What keeps an alarm from missing, or from doing the wrong thing with nobody there to stop it.
@MainActor
struct AlarmRunTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-alarmrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `songs` one-second pieces in one album, offline.
    private func controller(songs: Int = 2, storage: URL? = nil, dir: URL? = nil) async throws -> (Controller, Album, AVAudioEngine) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: storage)
        var settings = Settings()
        (settings.gapMin, settings.gapMax, settings.fadeIn, settings.fadeOut) = (0, 0, 0.1, 0.1)
        c.settings = settings
        let dir = try temp()
        for i in 0..<songs {
            let url = dir.appending(path: "\(i).caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                meta: TrackMeta(title: "t\(i)", artist: "a", album: "R", trackNumber: i + 1, duration: 1))
        }
        // and something else in the library, which an alarm must not wander into
        let other = dir.appending(path: "other.caf")
        try FileManager.default.copyItem(at: dir.appending(path: "0.caf"), to: other)
        c.library.entries[other.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
            meta: TrackMeta(title: "other", artist: "b", album: "Elsewhere", duration: 1))
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        return (c, try #require(c.catalog.albums.first { $0.title == "R" }), engine)
    }

    private func alarm(_ album: Album) -> Alarm {
        Alarm(source: album.id, name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))
    }

    @Test func anAlarmStopsWhenItsMusicEndsInsteadOfShufflingEverything() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        var heard = Set<String>()
        for _ in 0..<1500 where c.status != .idle {
            c.advance(0.01)
            if let title = c.current?.title { heard.insert(title) }
        }
        #expect(c.status == .idle)
        #expect(!heard.contains("other"))
    }

    @Test func anAlarmStillStopsAtTheEndOfItsMusicAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album, _) = try await controller(storage: storage)
        let row = alarm(album)
        first.addAlarm(row)
        first.fire(row.id, due: .now)
        first.advance(0.2)
        first.quitting()
        let resume = try JSONDecoder().decode(Controller.ResumeState.self, from: Data(contentsOf: storage.appending(path: "resume.json")))
        #expect(resume.fromAlarm == true)
    }

    @Test func aSleepTimerSetLastNightDoesntCutAnAlarmShort() async throws {
        let (c, album, _) = try await controller()
        c.play(album.songs)
        c.sleepAfterCurrent()
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.machine.sleep == nil)
    }

    @Test func anAlarmWithItsOwnLengthStillSetsIt() async throws {
        let (c, album, _) = try await controller()
        var row = alarm(album)
        row.minutes = 60
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.machine.sleep != nil)
    }

    @Test func anUnreadableAlarmsFileIsSetAsideAndSaid() throws {
        let storage = try temp()
        let url = storage.appending(path: "alarms.json")
        try Data("[{\"broken".utf8).write(to: url)
        let c = Controller(storage: storage)
        c.run()
        #expect(c.problem?.contains("alarms") == true)
        c.addAlarm(Alarm(source: "a", name: "A", hour: 7, minute: 2, weekdays: [2]))
        let files = try FileManager.default.contentsOfDirectory(atPath: storage.path)
        let aside = try #require(files.first { $0.hasPrefix("alarms.json.unreadable") })
        #expect(try String(contentsOf: storage.appending(path: aside), encoding: .utf8) == "[{\"broken")
    }

    /// One real file, measured by the app, in a folder that then can't be read.
    @Test func aFolderOutOfReachIsSaidAndComesBackWithItsAnalysis() async throws {
        let folder = try temp()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        try AVAudioFile(forWriting: folder.appending(path: "a.caf"), settings: format.settings).write(from: buffer)
        let c = Controller(storage: try temp())
        c.addFolders([folder])
        for _ in 0..<500 where c.tracks.isEmpty || c.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.tracks.count == 1)
        let entries = c.library.entries

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        c.rescan()
        for _ in 0..<500 where c.problem == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.problem?.contains(folder.lastPathComponent) == true)
        #expect(c.tracks.isEmpty)
        #expect(c.library.entries.count == 1)
        #expect(c.folders.count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        c.rescan()
        for _ in 0..<500 where c.problem != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.problem == nil)
        #expect(c.library.entries == entries)
        #expect(c.tracks.count == 1)
    }

    /// Unplugged while it's being analyzed: that's not a bad file.
    @Test func aFileGoneDuringAnalysisIsntMarkedUnplayable() async throws {
        let c = Controller(storage: nil)
        let path = try temp().appending(path: "gone.flac").path
        c.library.entries[path] = Library.Entry(size: 1, modified: .now)
        c.analyzePending()
        for _ in 0..<500 where c.library.entries[path]?.unreachable != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.library.entries[path]?.unplayable == false)
        #expect(c.library.entries[path]?.unreachable == true)
    }

    /// Damaged before, and again: the earlier copy isn't deleted to make room.
    @Test func aDamagedLibraryIsKeptAndSaysTheFoldersWentWithIt() throws {
        let storage = try temp()
        let url = storage.appending(path: "library.json")
        try Data("first {".utf8).write(to: storage.appending(path: "library.json.broken"))
        try Data("second {".utf8).write(to: url)
        let c = Controller(storage: storage)
        #expect(c.problem?.contains("folders") == true)
        #expect(c.problem?.contains("rebuilt") == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: storage.path).filter { $0.hasPrefix("library.json.broken") }
        let texts = try kept.map { try String(contentsOf: storage.appending(path: $0), encoding: .utf8) }
        #expect(Set(texts) == ["first {", "second {"])
    }

    /// Can't be opened at all, which isn't the same as not being there.
    @Test func aProfileThatCantBeOpenedIsSetAsideToo() throws {
        let storage = try temp()
        let url = storage.appending(path: "profile.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let c = Controller(storage: storage)
        #expect(c.problem?.contains("profile.json.unreadable-") == true)
        var changed = c.settings
        changed.gapMin = 7
        c.settings = changed
        let files = try FileManager.default.contentsOfDirectory(atPath: storage.path)
        let aside = storage.appending(path: try #require(files.first { $0.hasPrefix("profile.json.unreadable-") }))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aside.path)
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{}")
    }

    @Test func anUnreadableTrimsFileIsSetAsideAndSaid() throws {
        let storage = try temp()
        let url = storage.appending(path: "trims.json")
        try Data("{\"broken".utf8).write(to: url)
        let c = Controller(storage: storage)
        c.run()
        #expect(c.problem?.contains("trims.json.unreadable-") == true)
        c.setTrim(Trim(), for: "/a.flac")
        let files = try FileManager.default.contentsOfDirectory(atPath: storage.path)
        let aside = try #require(files.first { $0.hasPrefix("trims.json.unreadable") })
        #expect(try String(contentsOf: storage.appending(path: aside), encoding: .utf8) == "{\"broken")
    }

    /// Both damaged: losing every alarm is what must be read.
    @Test func theAlarmsMessageOutlivesTheTrimsOne() throws {
        let storage = try temp()
        try Data("{\"broken".utf8).write(to: storage.appending(path: "trims.json"))
        try Data("[{\"broken".utf8).write(to: storage.appending(path: "alarms.json"))
        let c = Controller(storage: storage)
        c.run()
        #expect(c.problem?.contains("alarms") == true)
    }

    @Test func aMissingAlarmsFileIsNothingToMention() throws {
        let c = Controller(storage: try temp())
        c.run()
        #expect(c.problem?.contains("alarms") != true)
    }

    @Test func aMessageOutlivesTheNextPiece() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        c.problem = "the Lauds alarm went off, but there's nothing in it to play"
        c.fire(row.id, due: .now)
        #expect(c.status == .playing)
        #expect(c.problem != nil)
    }

    @Test func aLongSleepDoesntResumeLastNightsPiece() async throws {
        let (c, album, _) = try await controller()
        c.play(album.songs)
        let night = Date.now
        c.systemWillSleep(now: night)
        c.systemDidWake(now: night.addingTimeInterval(8 * 3600))
        #expect(c.status == .paused)
    }

    @Test func aShortSleepStillResumes() async throws {
        let (c, album, _) = try await controller()
        c.play(album.songs)
        let now = Date.now
        c.systemWillSleep(now: now)
        c.systemDidWake(now: now.addingTimeInterval(600))
        #expect(c.status == .playing)
    }

    @Test func aSleepLinkWithNoRealLengthIsIgnored() async throws {
        let (c, album, _) = try await controller()
        c.play(album.songs)
        for length in ["inf", "1e300", "nan", "-5"] {
            c.open(URL(string: "sottova://sleep/\(length)")!)
            #expect(c.machine.sleep == nil)
        }
    }

    private struct DeviceGone: Error {}

    @Test func aDeviceThatWontStartWaitsAndKeepsTheQueue() async throws {
        let (c, album, _) = try await controller(songs: 3)
        var fails = 2
        c.startEngine = { engine in
            if fails > 0 {
                fails -= 1
                throw DeviceGone()
            }
            try engine.start()
        }
        c.play(album.songs)
        #expect(c.current == nil)
        for _ in 0..<400 where c.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.current?.id == album.songs[0].id)
        #expect(c.upNext.map(\.path) == album.songs.dropFirst().map(\.id))
    }

    @Test func anAlarmGoesOnAfterADeviceChange() async throws {
        let (c, album, engine) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        var fails = 1
        c.startEngine = { engine in
            if fails > 0 {
                fails -= 1
                throw DeviceGone()
            }
            try engine.start()
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.status == .paused)
        for _ in 0..<400 where c.status != .playing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
        #expect(c.current != nil)
    }

    @Test func musicYouStartedStaysPausedAfterADeviceChange() async throws {
        let (c, album, engine) = try await controller()
        c.play(album.songs)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(c.status == .paused)
    }

    /// A row set for a few minutes ago, on every day.
    private func justPassed(_ album: Album) -> (Alarm, Date) {
        let ago = Date.now - 180
        let parts = Calendar.current.dateComponents([.hour, .minute], from: ago)
        let row = Alarm(source: album.id, name: "Lauds", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        return (row, row.next(after: .now - Controller.alarmLateness)!)
    }

    @Test func anAlarmMissedWhileTheAppWasClosedPlaysOnce() async throws {
        let storage = try temp()
        let (c, album, _) = try await controller(storage: storage)
        let (row, due) = justPassed(album)
        c.addAlarm(row)
        c.loadAlarms()
        #expect(c.status == .playing)
        #expect(c.alarms.first?.lastFired == due)
        // quit and opened again a minute later
        let (again, _, _) = try await controller(storage: storage)
        again.loadAlarms()
        #expect(again.status == .idle)
        #expect(again.problem == nil)
    }

    @Test func aMissedAlarmWaitsForTheCatalog() async throws {
        let (first, album, engine) = try await controller()
        let (row, _) = justPassed(album)
        let storage = try temp()
        try JSONEncoder().encode([row]).write(to: storage.appending(path: "alarms.json"))
        let c = Controller(engine: engine, storage: storage)
        c.loadAlarms()
        #expect(c.status == .idle)
        c.library = first.library
        c.refreshTracks()
        for _ in 0..<500 where c.status == .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
    }

    @Test func aClockSetBackDoesntPlayItTwice() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        let due = Date.now
        c.fire(row.id, due: due)
        let queued = c.upNext.count
        c.fire(row.id, due: due)
        // played again, the whole collection would be queued
        #expect(c.upNext.count == queued)
    }

    @Test func aSecondAlarmDueAtTheSameTimeSaysItDidntPlay() async throws {
        let (c, album, _) = try await controller()
        let (row, due) = justPassed(album)
        var other = row
        other.id = UUID()
        other.name = "Compline"
        c.addAlarm(row)
        c.addAlarm(other)
        c.fire(row.id, due: due)
        #expect(c.problem?.contains("Compline didn't play") == true)
        #expect(c.alarms.allSatisfy { $0.lastFired == due })
    }

    @Test func aOneOffIsGoneOnceItsWentOff() async throws {
        let (c, album, _) = try await controller()
        let (row, due) = justPassed(album)
        var once = row
        once.weekdays = []
        once.day = .now
        c.addAlarm(once)
        c.fire(once.id, due: due)
        #expect(c.alarms.isEmpty)
    }
}
