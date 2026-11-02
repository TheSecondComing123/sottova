import AVFoundation
import Testing
@testable import SottovaCore

/// What keeps an alarm from missing, or from doing the wrong thing with nobody there to stop it.
@Suite(.disabled(if: LiveClock.repeatsAnHour(), "rows on the live clock can't be set up while the clocks repeat an hour"))
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
        Alarm(source: album.id, name: "Lauds", hour: LiveClock.farHour, minute: 2, weekdays: Set(1...7))
    }

    @Test func playingAMissedRowNowLeavesItsTurnAndAsksForItsVolume() async throws {
        let (c, album, _) = try await controller()
        c.volume = 0.8
        var row = alarm(album)
        (row.rotates, row.parts, row.volume) = (true, 2, 0.25)
        c.addAlarm(row)
        c.playNow(row)
        #expect(c.status == .playing)
        #expect(c.volume == 0.25)
        #expect(c.alarms.first?.lastFired == nil)
        #expect(c.alarms.first?.nextPart == 0)
        #expect(c.partChoices(for: row).names == ["part 1", "part 2"])
        #expect(c.partChoices(for: row).next == 0)
    }

    @Test func playingAMissedRowNowPlaysThePartItSaysIsNext() async throws {
        let (c, album, _) = try await controller(songs: 2)
        var row = alarm(album)
        let yesterday = Date.now - 86_400
        (row.rotates, row.parts, row.nextPart, row.lastFired, row.partSpent) = (true, 2, 1, yesterday, yesterday)
        c.addAlarm(row)
        c.playNow(row)
        #expect(c.current?.title == "t1")
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

    private func oneSongFolder() throws -> URL {
        let folder = try temp()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        try AVAudioFile(forWriting: folder.appending(path: "a.caf"), settings: format.settings).write(from: buffer)
        return folder
    }

    @Test func aCollectionRenamedInFinderIsSaidBeforeItsRowIsDue() async throws {
        let list = try temp()
        let c = Controller(storage: try temp(), playlistFolder: list)
        c.loadAlarms()
        c.addFolders([try oneSongFolder()])
        for _ in 0..<500 where c.catalog.songs.isEmpty || c.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(c.newPlaylist(named: "Mornings", songs: c.catalog.songs))
        c.addAlarm(Alarm(source: id, name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7)))
        #expect(c.problem == nil)

        try FileManager.default.moveItem(at: list.appending(path: "Mornings.m3u8"), to: list.appending(path: "Renamed.m3u8"))
        c.loadPlaylists()
        for _ in 0..<500 where c.problem == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.problem?.contains("Lauds") == true)

        // and it goes once there's no such row
        c.removeAlarm(c.alarms[0].id)
        #expect(c.problem == nil)
    }

    @Test func anAlbumFolderRenamedInFinderIsSaidBeforeItsRowIsDue() async throws {
        let folder = try oneSongFolder()
        let c = Controller(storage: try temp())
        c.loadAlarms()
        c.addFolders([folder])
        for _ in 0..<500 where c.catalog.albums.isEmpty || c.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let album = try #require(c.catalog.albums.first)
        c.addAlarm(Alarm(source: album.id, name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7)))
        #expect(c.problem == nil)

        let moved = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + "-renamed")
        try FileManager.default.moveItem(at: folder, to: moved)
        c.rescan()
        for _ in 0..<500 where c.problem == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.problem?.contains("Lauds") == true)
    }

    /// Before the first scan the catalog isn't the library yet, so nothing can be called missing.
    @Test func aRowIsntCalledEmptyBeforeTheFirstScan() async throws {
        let storage = try temp()
        try JSONEncoder().encode([Alarm(source: "not yet", name: "Lauds", hour: 7, minute: 2, weekdays: Set(1...7))]).write(to: storage.appending(path: "alarms.json"))
        let c = Controller(storage: storage)
        c.loadAlarms()
        #expect(c.problem == nil)
    }

    private func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func coversPurgedFromCachesComeBackWithTheirTagsInPlace() async throws {
        let folder = try oneSongFolder()
        try jpeg().write(to: folder.appending(path: "cover.jpg"))
        let art = try temp().appending(path: "Artwork")
        let c = Controller(storage: try temp(), artworkFolder: art)
        c.addFolders([folder])
        for _ in 0..<500 where c.catalog.songs.first?.artwork == nil { try await Task.sleep(for: .milliseconds(10)) }
        let key = try #require(c.catalog.songs.first?.artwork)
        let path = try #require(c.catalog.songs.first?.id)
        let file = art.appending(path: "\(key).jpg")
        #expect(FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.removeItem(at: art)
        c.rescan()
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: file.path) {
            #expect(c.library.entries[path]?.meta != nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(c.library.entries[path]?.meta?.artwork == key)
    }

    private func playlistWithCover(_ old: Data) throws -> (Controller, URL, trashed: () -> [URL]) {
        let c = Controller(storage: nil, playlistFolder: try temp())
        let id = try #require(c.newPlaylist(named: "Mornings"))
        let cover = Controller.coverURL(forPlaylist: id)
        try old.write(to: cover)
        let trashed = Box()
        c.trash = { trashed.urls.append($0); try FileManager.default.removeItem(at: $0) }
        return (c, cover, { trashed.urls })
    }

    private final class Box { var urls: [URL] = [] }

    @Test func aCoverThatCantBeWrittenLeavesTheOldOneInPlace() throws {
        let old = try jpeg()
        let (c, cover, trashed) = try playlistWithCover(old)
        c.setCover(Data("not an image".utf8), credit: nil, forPlaylist: c.playlists[0].id)
        #expect(c.problem?.contains("cover") == true)
        #expect(trashed().isEmpty)
        #expect(try Data(contentsOf: cover) == old)
    }

    @Test func aCoverThatCantBeTrashedLeavesTheOldOneInPlace() throws {
        let old = try jpeg()
        let (c, cover, _) = try playlistWithCover(old)
        c.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        c.setCover(old, credit: "someone", forPlaylist: c.playlists[0].id)
        #expect(c.problem?.contains("cover") == true)
        #expect(try Data(contentsOf: cover) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cover.deletingLastPathComponent().path).filter { $0.contains("jpg") } == [cover.lastPathComponent])
    }

    @Test func aNewCoverReplacesTheOldOneWhichGoesToTheTrash() throws {
        let (c, cover, trashed) = try playlistWithCover(Data("old".utf8))
        c.setCover(try jpeg(), credit: "someone", forPlaylist: c.playlists[0].id)
        #expect(c.problem == nil)
        #expect(trashed().map(\.lastPathComponent) == [cover.lastPathComponent])
        #expect(CoverFile.credit(at: cover) == "someone")
        #expect(try FileManager.default.contentsOfDirectory(atPath: cover.deletingLastPathComponent().path).filter { $0.contains("jpg") } == [cover.lastPathComponent])
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
        for _ in 0..<50 where c.status != .paused { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .paused)
        for _ in 0..<400 where c.status != .playing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
        #expect(c.current != nil)
    }

    @Test func musicYouStartedStaysPausedAfterADeviceChange() async throws {
        let (c, album, engine) = try await controller()
        c.retryWait = .milliseconds(5)
        c.play(album.songs)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<500 where c.status != .paused { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .paused)
        // long enough for an alarm's retry to have started it again, which this mustn't
        try await Task.sleep(for: .milliseconds(50))
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

    /// Fails until `tries` have gone by, or for good.
    private func failing(_ c: Controller, tries: Int = .max) {
        var left = tries
        c.startEngine = { engine in
            if left > 0 {
                left -= 1
                throw DeviceGone()
            }
            try engine.start()
        }
    }

    /// The usual morning: last night's piece paused, and the device not ready at 7:02.
    @Test func anAlarmOverAPausedPieceKeepsTryingTheDevice() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(5)
        c.play(album.songs)
        c.toggle()
        #expect(c.status == .paused)
        let row = alarm(album)
        c.addAlarm(row)
        failing(c, tries: 5)
        c.fire(row.id, due: .now)
        #expect(c.problem?.contains("audio output") == true)
        for _ in 0..<400 where c.status != .playing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
        #expect(c.problem == nil)
        #expect(c.machine.rise != nil)
    }

    @Test func musicYouStartedDoesntKeepTryingAfterAFailedResume() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(5)
        c.play(album.songs)
        c.toggle()
        failing(c, tries: 1)
        c.toggle()
        #expect(c.status == .paused)
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.status == .paused)
    }

    @Test func anAlarmWaitsTenMinutesForADeviceThenSaysSo() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(1)
        let row = alarm(album)
        c.addAlarm(row)
        failing(c, tries: 100)
        c.fire(row.id, due: .now)
        for _ in 0..<500 where c.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.current != nil)
        #expect(c.problem == nil)

        let (gone, album2, _) = try await controller()
        gone.retryWait = .milliseconds(1)
        let row2 = alarm(album2)
        gone.addAlarm(row2)
        failing(gone)
        gone.fire(row2.id, due: .now)
        for _ in 0..<1000 where gone.status != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gone.status == .idle)
        #expect(gone.problem?.contains("ten minutes") == true)
    }

    @Test func aFailedResumeGivesUpAfterTenMinutesAndSaysSo() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(1)
        c.play(album.songs)
        c.toggle()
        let row = alarm(album)
        c.addAlarm(row)
        failing(c)
        c.fire(row.id, due: .now)
        for _ in 0..<1000 where c.problem?.contains("ten minutes") != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.problem?.contains("ten minutes") == true)
        #expect(c.status == .paused)
    }

    @Test func otherMusicGivesUpOnADeviceSooner() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(1)
        failing(c, tries: 100)
        c.play(album.songs)
        for _ in 0..<500 where c.status != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .idle)
        #expect(c.current == nil)
    }

    @Test func aPauseAfterADeviceChangeStays() async throws {
        let (c, album, engine) = try await controller()
        c.retryWait = .milliseconds(5)
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        failing(c, tries: 1)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<400 where c.status != .playing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(c.status == .playing)
        c.pause()
        #expect(c.status == .paused)
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.status == .paused)
    }

    /// Pressed while it's trying: already paused, so pause changes nothing but ends the trying.
    @Test func aPressEndsTheTrying() async throws {
        for press in [{ (c: Controller) in c.pause() }, { (c: Controller) in c.toggle() }] {
            let (c, album, engine) = try await controller()
            c.retryWait = .milliseconds(5)
            let row = alarm(album)
            c.addAlarm(row)
            c.fire(row.id, due: .now)
            failing(c)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
            for _ in 0..<50 where c.status != .paused { try await Task.sleep(for: .milliseconds(5)) }
            press(c)
            c.startEngine = { try $0.start() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(c.status == .paused)
        }
    }

    @Test func anAlarmWhoseFilesWontOpenSaysSo() async throws {
        let (c, album, _) = try await controller()
        for song in album.songs { try FileManager.default.removeItem(atPath: song.id) }
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.status == .idle)
        #expect(c.problem?.contains("wouldn't open") == true)
    }

    @Test func anAlarmThatPlayedThroughSaysNothing() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        for _ in 0..<1500 where c.status != .idle { c.advance(0.01) }
        #expect(c.status == .idle)
        #expect(c.problem == nil)
    }

    private func relaunched(_ storage: URL) async throws -> Controller {
        let (again, _, _) = try await controller(storage: storage)
        again.restoreResume()
        return again
    }

    @Test func anAlarmGoesOnByItselfAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album, _) = try await controller(storage: storage)
        let row = alarm(album)
        first.addAlarm(row)
        first.fire(row.id, due: .now)
        first.advance(0.2)
        first.quitting()
        let again = try await relaunched(storage)
        #expect(again.status == .playing)
    }

    @Test func anAlarmYouPausedStaysPausedAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album, _) = try await controller(storage: storage)
        let row = alarm(album)
        first.addAlarm(row)
        first.fire(row.id, due: .now)
        first.advance(0.2)
        first.pause()
        first.quitting()
        let again = try await relaunched(storage)
        #expect(again.status == .paused)
    }

    /// Picked up hours later, by which time nobody wants it, the same as a long sleep.
    @Test func anAlarmSavedLongAgoStaysPausedAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album, _) = try await controller(storage: storage)
        let row = alarm(album)
        first.addAlarm(row)
        first.fire(row.id, due: .now)
        first.advance(0.2)
        first.quitting()
        try FileManager.default.setAttributes([.modificationDate: Date.now - 2 * Controller.resumeWithin], ofItemAtPath: storage.appending(path: "resume.json").path)
        let again = try await relaunched(storage)
        #expect(again.status == .paused)
    }

    /// It was only paused by the device, so that's not a pause to keep.
    @Test func anAlarmCutOffWhileTryingTheDeviceGoesOnAfterACrash() async throws {
        let storage = try temp()
        let (first, album, engine) = try await controller(storage: storage)
        let row = alarm(album)
        first.addAlarm(row)
        first.fire(row.id, due: .now)
        first.advance(0.2)
        failing(first)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<50 where first.status != .paused { try await Task.sleep(for: .milliseconds(5)) }
        #expect(first.status == .paused)
        let again = try await relaunched(storage)
        #expect(again.status == .playing)
    }

    @Test func aTimerBeforeTheCatalogDoesntSpendTheAlarm() async throws {
        let (first, album, engine) = try await controller()
        let (row, due) = justPassed(album)
        let storage = try temp()
        try JSONEncoder().encode([row]).write(to: storage.appending(path: "alarms.json"))
        let c = Controller(engine: engine, storage: storage)
        c.loadAlarms()
        c.fire(row.id, due: due)
        #expect(c.alarms.first?.lastFired == nil)
        #expect(c.problem == nil)
        c.library = first.library
        c.refreshTracks()
        for _ in 0..<500 where c.status == .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
        #expect(c.alarms.first?.lastFired == due)
    }

    /// Saved as out of reach by a run that's over, so the catalog lacks it until the first scan looks again.
    @Test func aMissedAlarmWaitsForTheFirstScanToBringItsSongsBack() async throws {
        let (_, _, engine) = try await controller()
        let (wanted, elsewhere) = (try oneSongFolder(), try oneSongFolder())
        let setup = Controller(storage: try temp())
        setup.addFolders([wanted, elsewhere])
        for _ in 0..<500 where setup.catalog.albums.count < 2 || setup.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let album = try #require(setup.catalog.albums.first { $0.songs[0].id.contains(wanted.lastPathComponent) })
        let storage = try temp()
        var library = setup.library
        library.entries[album.songs[0].id]?.unreachable = true
        try library.save(to: storage.appending(path: "library.json"))
        let (row, due) = justPassed(album)
        try JSONEncoder().encode([row]).write(to: storage.appending(path: "alarms.json"))

        let c = Controller(engine: engine, storage: storage)
        c.loadAlarms()
        for _ in 0..<500 where c.catalog.albums.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.status == .idle)
        #expect(c.alarms.first?.lastFired == nil)
        c.rescan()
        for _ in 0..<500 where c.status == .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
        #expect(c.alarms.first?.lastFired == due)
    }

    @Test func anAlarmWithNoLibraryAfterTheFirstScanStillSaysSo() async throws {
        let c = Controller(storage: try temp())
        c.loadAlarms()
        let row = Alarm(source: "gone", name: "Lauds", hour: LiveClock.farHour, minute: 2, weekdays: Set(1...7))
        c.addAlarm(row)
        c.rescan()
        // not used up while it waits for that scan
        for _ in 0..<500 where c.problem?.contains("nothing in it") != true {
            c.fire(row.id, due: .now)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.problem?.contains("nothing in it") == true)
    }

    /// The tick the press itself runs ends the timer: what it starts must see that, not what the status said before.
    @Test func anAlarmStartsWhenItsOwnTickEndsASleepTimer() async throws {
        let (c, album, _) = try await controller()
        c.play(album.songs)
        c.sleep(minutes: 0.005)
        let row = alarm(album)
        c.addAlarm(row)
        c.lastTick = .now - .seconds(1)
        c.fire(row.id, due: .now)
        #expect(c.status == .playing)
        #expect(c.machine.rise != nil)
        #expect(c.upNext.count == album.songs.count - 1)
    }

    private func elsewhere(_ c: Controller) throws -> Album {
        try #require(c.catalog.albums.first { $0.title == "Elsewhere" })
    }

    @Test func aStopWhileWaitingForTheDeviceForgetsThePiece() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(5)
        failing(c)
        c.play(try elsewhere(c).songs)
        c.sleep(minutes: 60)
        c.systemWillSleep()
        #expect(c.status == .idle)
        c.startEngine = { try $0.start() }
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.current?.id == album.songs[0].id)
    }

    @Test func anAlarmWhileOtherMusicWaitsForTheDeviceOpensWithItsOwnPiece() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(5)
        failing(c, tries: 1)
        c.play(try elsewhere(c).songs)
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.current?.id == album.songs[0].id)
    }

    /// Continuous: the last piece hands off to nothing, and goes on fading until it's done.
    @Test func aCrossfadedAlarmsLastPieceFinishesItsFadeThenStops() async throws {
        let (c, album, engine) = try await controller()
        c.saveVolume = { _ in }
        c.volume = 0.6
        var settings = c.settings
        (settings.crossfade, settings.crossfadeSec) = (true, 0.3)
        c.settings = settings
        var row = alarm(album)
        row.volume = 0.15
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        var fading = 0
        for _ in 0..<1500 where c.status != .idle {
            c.advance(0.01)
            if c.upNext.isEmpty, c.machine.outgoing != nil, c.machine.phase == .ending {
                fading += 1
                #expect(c.volume == 0.15)
            }
        }
        #expect(c.status == .idle)
        #expect(fading > 20)
        #expect(c.machine.outgoing == nil)
        #expect(c.mixerVolumes == [0, 0])
        #expect(!engine.isRunning)
        #expect(c.volume == 0.6)
    }

    /// The cover's gone and the file can't be opened just now: it's been analysed, so that's not a bad file.
    @Test func aFailedCoverReReadDoesntMarkASongUnplayable() async throws {
        let folder = try oneSongFolder()
        try jpeg().write(to: folder.appending(path: "cover.jpg"))
        let art = try temp().appending(path: "Artwork")
        let c = Controller(storage: try temp(), artworkFolder: art)
        c.addFolders([folder])
        for _ in 0..<500 where c.catalog.songs.first?.artwork == nil || c.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let path = try #require(c.catalog.songs.first?.id)
        try FileManager.default.removeItem(at: art)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        c.analyzePending()
        for _ in 0..<100 where c.library.entries[path]?.unplayable != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.library.entries[path]?.unplayable == false)
    }

    @Test func aWakeLooksAgainWhenSomethingIsOutOfReach() async throws {
        let setup = Controller(storage: try temp())
        setup.addFolders([try oneSongFolder()])
        for _ in 0..<500 where setup.tracks.isEmpty || setup.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let path = try #require(setup.tracks.first?.path)
        var library = setup.library
        library.entries[path]?.unreachable = true
        let storage = try temp()
        try library.save(to: storage.appending(path: "library.json"))
        // not scanned, so there's no watcher that could be what finds it
        let c = Controller(storage: storage)
        #expect(c.tracks.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.tracks.isEmpty)
        c.systemDidWake()
        for _ in 0..<500 where c.tracks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.tracks.count == 1)
    }

    @Test func anAlarmWithNothingToPlaySaysWhenSongsAreOutOfReach() async throws {
        let folder = try oneSongFolder()
        let c = Controller(storage: try temp())
        c.addFolders([folder])
        for _ in 0..<500 where c.catalog.albums.isEmpty || c.pendingAnalysis > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let row = Alarm(source: try #require(c.catalog.albums.first).id, name: "Lauds", hour: LiveClock.farHour, minute: 2, weekdays: Set(1...7))
        c.addAlarm(row)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        c.rescan()
        for _ in 0..<500 where !c.catalog.albums.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<500 where c.problem?.contains("nothing in it") != true {
            c.fire(row.id, due: .now)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.problem?.contains("nothing in it") == true)
        #expect(c.problem?.contains("1 song") == true)
        #expect(c.problem?.contains("out of reach") == true)
    }

    private func published(_ storage: URL) throws -> String? {
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: storage.appending(path: "status.json"))) as? [String: Any]
        return info?["status"] as? String
    }

    /// What the alarm backup reads at 7:04: "playing" there means it stays out of the way.
    @Test func waitingForTheDeviceIsntPublishedAsPlaying() async throws {
        let storage = try temp()
        let (c, album, _) = try await controller(storage: storage)
        c.run()
        c.retryWait = .milliseconds(200)
        let row = alarm(album)
        c.addAlarm(row)
        failing(c)
        c.fire(row.id, due: .now)
        #expect(c.status == .playing)
        #expect(try published(storage) == "waiting")
        c.startEngine = { try $0.start() }
        for _ in 0..<400 where try published(storage) == "waiting" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try published(storage) == "playing")
    }

    /// Between pieces the status doesn't change, so nothing else would have written it.
    @Test func aDeviceLostBetweenPiecesIsntPublishedAsPlaying() async throws {
        let storage = try temp()
        let (c, album, _) = try await controller(storage: storage)
        c.run()
        c.retryWait = .milliseconds(200)
        c.play(album.songs)
        #expect(try published(storage) == "playing")
        failing(c)
        c.skip()
        for _ in 0..<400 where c.machine.phase != .loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.machine.phase == .loading)
        #expect(c.status == .playing)
        #expect(try published(storage) == "waiting")
    }

    @Test func anAlarmTryingToGoOnIsPublishedAsPaused() async throws {
        let storage = try temp()
        let (c, album, engine) = try await controller(storage: storage)
        c.run()
        c.retryWait = .milliseconds(5)
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        failing(c)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<50 where c.status != .paused { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try published(storage) == "paused")
    }

    /// An alarm whose device went away mid-piece, trying to go on.
    private func tryingToGoOn(_ album: Album, _ c: Controller, _ engine: AVAudioEngine, due: Date) async throws {
        c.retryWait = .milliseconds(5)
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: due)
        failing(c)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<50 where c.status != .paused { try await Task.sleep(for: .milliseconds(5)) }
        #expect(c.status == .paused)
    }

    @Test func aSleepDoesntEndAnAlarmsTryingWhileItsStillOnTime() async throws {
        let (c, album, engine) = try await controller()
        let due = Date.now
        try await tryingToGoOn(album, c, engine, due: due)
        c.systemWillSleep(now: due + 60)
        // the device still isn't there at the wake, and comes back a few tries later
        failing(c, tries: 5)
        c.systemDidWake(now: due + 240)
        for _ in 0..<400 where c.status != .playing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(c.status == .playing)
    }

    @Test func aWakePastAnAlarmsTimeLeavesItPausedAndSaysSo() async throws {
        let (c, album, engine) = try await controller()
        let due = Date.now
        try await tryingToGoOn(album, c, engine, due: due)
        c.systemWillSleep(now: due + 60)
        c.startEngine = { try $0.start() }
        c.systemDidWake(now: due + Controller.alarmLateness + 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.status == .paused)
        #expect(c.problem?.contains("slept past") == true)
    }

    /// Still on its first piece, and with a length of its own: a sleep timer's lid-closed stop isn't for this.
    @Test func aSleepDoesntEndAnAlarmWaitingToStart() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(5)
        var row = alarm(album)
        row.minutes = 60
        c.addAlarm(row)
        failing(c)
        let due = Date.now
        c.fire(row.id, due: due)
        c.systemWillSleep(now: due + 60)
        #expect(c.status == .paused)
        c.startEngine = { try $0.start() }
        c.systemDidWake(now: due + 240)
        for _ in 0..<400 where c.machine.phase == .loading || c.status != .playing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(c.status == .playing)
        #expect(c.current != nil)
    }

    @Test func aWakePastAnAlarmsTimeStopsOneThatNeverStarted() async throws {
        let (c, album, _) = try await controller()
        c.retryWait = .milliseconds(5)
        let row = alarm(album)
        c.addAlarm(row)
        failing(c)
        let due = Date.now
        c.fire(row.id, due: due)
        c.systemWillSleep(now: due + 60)
        c.systemDidWake(now: due + Controller.alarmLateness + 1)
        #expect(c.status == .idle)
        #expect(c.problem?.contains("slept past") == true)
    }

    /// The Mac restarted in that sleep: it's still the alarm's, and still knows when it was due.
    @Test func anAlarmTryingOverASleepGoesOnAfterACrash() async throws {
        let storage = try temp()
        let (first, album, engine) = try await controller(storage: storage)
        let due = Date.now
        try await tryingToGoOn(album, first, engine, due: due)
        first.systemWillSleep(now: due + 60)
        let resume = try JSONDecoder().decode(Controller.ResumeState.self, from: Data(contentsOf: storage.appending(path: "resume.json")))
        #expect(resume.alarmDue == due)
        let again = try await relaunched(storage)
        #expect(again.status == .playing)
    }

    /// A row whose window is open now.
    private func openNow(_ album: Album) -> Alarm {
        let ago = Date.now - 60
        let parts = Calendar.current.dateComponents([.hour, .minute], from: ago)
        var hour = Alarm(source: album.id, name: "Hour", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        hour.whileHere = true
        hour.minutes = 30
        return hour
    }

    @Test func anHourDoesntTakeOverFromAnAlarmStillTrying() async throws {
        let (c, album, engine) = try await controller()
        c.presence = { _ in nil }
        try await tryingToGoOn(album, c, engine, due: .now)
        let row = try #require(c.alarms.first)
        c.addAlarm(openNow(album))
        c.checkHours()
        #expect(c.status == .paused)
        c.startEngine = { try $0.start() }
        for _ in 0..<400 where c.status != .playing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(c.status == .playing)
        #expect(c.machine.rise != nil)
        #expect(c.alarms.first { $0.id == row.id } != nil)
    }

    /// Its alarm has given up: paused is free again, as it is for anything else.
    @Test func anHourStartsOverAnAlarmThatGaveUp() async throws {
        let (c, album, _) = try await controller()
        c.presence = { _ in nil }
        c.retryWait = .milliseconds(1)
        c.play(album.songs)
        c.toggle()
        let row = alarm(album)
        c.addAlarm(row)
        failing(c)
        c.fire(row.id, due: .now)
        for _ in 0..<1000 where c.problem?.contains("ten minutes") != true { try await Task.sleep(for: .milliseconds(10)) }
        c.startEngine = { try $0.start() }
        c.addAlarm(openNow(album))
        c.checkHours()
        #expect(c.status == .resting)
    }

    /// Asleep past its time, then the clock's notice comes before the timer.
    @Test func reArmingDoesntStepOverATimerThatsDue() async throws {
        let (c, album, _) = try await controller()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now + 180)
        let row = Alarm(source: album.id, name: "Lauds", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        c.addAlarm(row)
        let due = try #require(row.next(after: .now))
        c.armAlarm(now: due + 60)
        for _ in 0..<200 where c.status == .idle { try await Task.sleep(for: .milliseconds(5)) }
        #expect(c.status == .playing)
        #expect(c.alarms.first?.lastFired == due)
    }

    /// Only a timer that was set: a row saved for a minute ago is for next time, and arming again doesn't wake it.
    @Test func reArmingLeavesARowSetForAMomentAgo() async throws {
        let (c, album, _) = try await controller()
        c.addAlarm(justPassed(album).0)
        c.armAlarm()
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.status == .idle)
    }

    /// Moved or turned off since its timer was set, that timer isn't its time anymore.
    @Test func reArmingLeavesATimeThatsBeenEditedAway() async throws {
        let (c, album, _) = try await controller()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now + 180)
        var row = Alarm(source: album.id, name: "Lauds", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        c.addAlarm(row)
        let due = try #require(row.next(after: .now))
        row.on = false
        c.changeAlarm(row.id) { $0 = row }
        c.armAlarm(now: due + 60)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.status == .idle)
        #expect(c.alarms.first?.lastFired == nil)
    }

    @Test func theScreensCanSeeTheAlarmThatsRising() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        #expect(c.soundingRow == nil && !c.rising && c.playingFrom == nil)
        c.fire(row.id, due: .now)
        #expect(c.soundingRow?.id == row.id)
        #expect(c.rising)
        #expect(c.playingFrom == album.id)
        c.play(album.songs)
        #expect(c.soundingRow == nil)
    }

    @Test func theAlarmsRowAndWhereItCameFromComeBackAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album, _) = try await controller(storage: storage)
        let row = alarm(album)
        first.addAlarm(row)
        first.fire(row.id, due: .now)
        first.advance(0.2)
        first.quitting()
        let (second, _, _) = try await controller(storage: storage)
        second.loadAlarms()
        second.restoreResume()
        #expect(second.soundingRow?.id == row.id)
        #expect(second.playingFrom == album.id)
    }

    @Test func silenceCountsPausedOrNotAndEasingOnlyOnceItStarts() async throws {
        let (c, album, _) = try await controller(songs: 2)
        var settings = c.settings
        (settings.gapMin, settings.gapMax) = (5, 5)
        c.settings = settings
        c.play(album.songs)
        #expect(!c.inSilence)
        for _ in 0..<300 where !c.inSilence { c.advance(0.01) }
        #expect(c.inSilence && c.status == .resting)
        c.toggle()
        #expect(c.inSilence && c.status == .paused)
        c.play(album.songs)
        c.sleep(minutes: 30)
        #expect(!c.easing)
        c.sleep(minutes: 1)
        #expect(!c.easing)
        c.advance(0.5)
        #expect(c.easing)
    }

    @Test func theScreensCanSeeAPieceHeldUpByTheDevice() async throws {
        let (c, album, _) = try await controller()
        c.startEngine = { _ in throw CocoaError(.featureUnsupported) }
        c.retryWait = .seconds(60)
        c.play(album.songs)
        #expect(c.waitingForDevice)
        #expect(c.status == .playing)
        c.startEngine = { try $0.start() }
        c.play(album.songs)
        #expect(!c.waitingForDevice)
    }

    @Test func aMixOfAlbumsAndTheShufflersPickComeFromNowhere() async throws {
        let (c, album, _) = try await controller()
        let other = try #require(c.catalog.albums.first { $0.id != album.id })
        c.play(album.songs + other.songs)
        #expect(c.playingFrom == nil)
    }

    @Test func aRowThatPassedWithTheAppGoneIsMissedAtTheNextLaunch() async throws {
        // a time 30 minutes ago has to still be today
        guard Calendar.current.component(.hour, from: .now) >= 1 else { return }
        let storage = try temp()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now - 1800)
        let row = Alarm(source: "a", name: "Lauds", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        let url = storage.appending(path: "alarms.json")
        try JSONEncoder().encode([row]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date.now - 7200], ofItemAtPath: url.path)
        let c = Controller(storage: storage)
        c.loadAlarms()
        #expect(c.alarms[0].missed?.at == row.next(after: .now - 1860))
        #expect(c.alarms[0].lastFired == nil)
        let saved = try JSONDecoder().decode([Alarm].self, from: Data(contentsOf: url))
        #expect(saved[0].missed == c.alarms[0].missed)
    }

    @Test func aMacAsleepThroughAnAlarmMarksItAndTheNextOneClearsIt() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now - 3600)
        #expect(c.alarms[0].missed?.why == .asleep)
        c.fire(row.id, due: .now)
        #expect(c.alarms[0].missed == nil)
    }

    @Test func whatPlayedTodayNamesItsRowAndTheOneThatsOn() async throws {
        let storage = try temp()
        let (c, album, _) = try await controller(storage: storage)
        let row = alarm(album)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        c.advance(0.2)
        #expect(c.playedToday().map(\.title) == ["t0"])
        #expect(c.playedToday().first?.row == "Lauds")
        c.play(album.songs.reversed())
        for _ in 0..<300 where c.current?.title != "t1" { c.advance(0.01) }
        let played = c.playedToday()
        #expect(played.map(\.title) == ["t0", "t1"])
        #expect(played.map(\.row) == ["Lauds", nil])
        #expect(c.playedToday(now: .now + 2 * 86_400).isEmpty)
    }

    @Test func aRowThatWentOffThenBecameAOneOffIsntDeletedByTheNextAlarm() async throws {
        let (c, album, _) = try await controller()
        let row = alarm(album)
        var other = alarm(album)
        other.name = "Compline"
        c.addAlarm(row)
        c.addAlarm(other)
        c.fire(row.id, due: .now)
        c.changeAlarm(row.id) { $0.weekdays = [] }
        c.fire(other.id, due: .now + 1)
        #expect(c.alarms.contains { $0.id == row.id })
    }

    @Test func aDeletedOneOffBroughtBackGetsATimeStillAhead() {
        let c = Controller(storage: nil)
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undo = undo
        let once = Alarm(source: "a", name: "A", hour: 7, minute: 2, day: .now - 86_400)
        c.addAlarm(once)
        undo.beginUndoGrouping()
        c.removeAlarm(once.id)
        undo.endUndoGrouping()
        undo.undo()
        #expect(c.alarms[0].next(after: .now) != nil)
    }

    @Test func aMacAsleepThroughTwoAlarmsMarksBoth() async throws {
        guard Calendar.current.component(.hour, from: .now) >= 3 else { return }
        let (c, album, _) = try await controller()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now - 3600)
        let first = alarm(album)
        let later = Alarm(source: album.id, name: "Later", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        c.addAlarm(first)
        c.addAlarm(later)
        c.fire(first.id, due: .now - 7200)
        let row = try #require(c.alarms.first { $0.id == later.id })
        #expect(row.missed?.why == .asleep)
        #expect(row.missed?.at == later.next(after: .now - 3660))
    }

    /// One too late to play can't take the turn of one still in time.
    @Test func aLateAlarmLeavesTheOneStillDueToPlay() async throws {
        guard Calendar.current.component(.hour, from: .now) >= 2 else { return }
        let (c, album, _) = try await controller()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now - 120)
        let early = alarm(album)
        let due = Alarm(source: album.id, name: "Due", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        c.addAlarm(early)
        c.addAlarm(due)
        c.fire(early.id, due: .now - 3600)
        #expect(c.status != .idle)
        #expect(c.soundingRow?.id == due.id)
        #expect(c.alarms.first { $0.id == early.id }?.missed?.why == .asleep)
    }
}
