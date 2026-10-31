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
    private func controller(songs: Int = 2, storage: URL? = nil) async throws -> (Controller, Album, AVAudioEngine) {
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
}
