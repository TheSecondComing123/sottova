import AVFoundation
import Testing
@testable import SottovaCore

/// What's still true after the app quits and opens again, against files in a temp folder. Rows open a minute ago on
/// the live clock, as in HourTests.
@Suite(.disabled(if: LiveClock.repeatsAnHour(), "rows on the live clock can't be set up while the clocks repeat an hour"))
@MainActor
struct RelaunchTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func engine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        return engine
    }

    private func opened(_ storage: URL) throws -> Controller {
        let c = Controller(engine: try engine(), storage: storage)
        c.saveVolume = { _ in }
        return c
    }

    /// Two three-second pieces in one album, and a third elsewhere that an hour must not wander into.
    private func controller(storage: URL) async throws -> (Controller, Album) {
        let c = try opened(storage)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        silence.frameLength = silence.frameCapacity
        let dir = try temp()
        for (i, album) in ["R", "R", "Elsewhere"].enumerated() {
            let url = dir.appending(path: "\(i).caf")
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: silence)
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                                                        meta: TrackMeta(title: "t\(i)", artist: "a", album: album, trackNumber: i + 1, duration: 3))
        }
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        c.presence = { _ in nil }
        return (c, try #require(c.catalog.albums.first { $0.title == "R" }))
    }

    /// Opens again on the same files with the same library, the catalog not built yet: what the app has at launch.
    private func relaunch(_ first: Controller, storage: URL) throws -> Controller {
        first.quitting()
        let c = try opened(storage)
        c.presence = { _ in nil }
        c.loadAlarms()
        c.restoreResume()
        return c
    }

    private func buildCatalog(_ c: Controller, from first: Controller) async throws {
        c.library = first.library
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func row(_ album: Album, ago: TimeInterval = 60, minutes: Int = 60) -> Alarm {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now - ago)
        var row = Alarm(source: album.id, name: "Overworld", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        row.minutes = minutes
        row.whileHere = true
        return row
    }

    /// An hour with a piece a second in.
    private func hourPlaying(storage: URL) async throws -> (Controller, Album) {
        let (c, album) = try await controller(storage: storage)
        c.addAlarm(row(album))
        c.checkHours()
        c.advance(46)
        c.advance(1)
        #expect(c.status == .playing)
        return (c, album)
    }

    @Test func midHourItGoesOnByItselfAtTheSameSpotOnceThereIsACatalog() async throws {
        let storage = try temp()
        let (first, album) = try await hourPlaying(storage: storage)
        let (piece, origin) = (first.current?.id, first.origin)
        let c = try relaunch(first, storage: storage)
        #expect(c.status == .paused)
        try await buildCatalog(c, from: first)
        for _ in 0..<200 where c.status != .playing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .playing)
        #expect(c.current?.id == piece)
        #expect(abs((c.track?.elapsed ?? 0) - 1) < 0.5)
        #expect(c.origin == origin)
        // and it goes round the hour's collection, not everything
        while !c.upNext.isEmpty { _ = c.dequeue() }
        #expect(album.songs.map(\.id).contains(try #require(c.dequeue())))
    }

    @Test func midSilenceItGoesOnWithTheSameTimeLeft() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        first.addAlarm(row(album))
        first.checkHours()
        let left = try #require(first.machine.restRemaining)
        let c = try relaunch(first, storage: storage)
        try await buildCatalog(c, from: first)
        for _ in 0..<200 where c.status != .resting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.status == .resting)
        #expect(try #require(c.machine.restRemaining) <= left)
        #expect(try #require(c.machine.restRemaining) > left - 5)
    }

    @Test func otherMusicStillComesBackPaused() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        first.play(album.songs)
        first.advance(1)
        let c = try relaunch(first, storage: storage)
        try await buildCatalog(c, from: first)
        #expect(c.status == .paused)
    }

    @Test func anHourYouPausedStaysPaused() async throws {
        let storage = try temp()
        let (first, _) = try await hourPlaying(storage: storage)
        first.pause()
        let c = try relaunch(first, storage: storage)
        try await buildCatalog(c, from: first)
        #expect(c.status == .paused)
    }

    @Test func anHourWhoseWindowClosedWhileClosedEndsLikeAnyOther() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        let over = row(album, ago: 2 * 3600)
        first.addAlarm(over)
        let state = Controller.ResumeState(path: album.songs[0].id, elapsed: 1, restLeft: nil, source: nil,
                                           upNext: [.init(path: album.songs[1].id, source: album.id)], hour: over.id)
        try JSONEncoder().encode(state).write(to: storage.appending(path: "resume.json"))
        let c = try opened(storage)
        c.presence = { _ in nil }
        c.loadAlarms()
        c.restoreResume()
        try await buildCatalog(c, from: first)
        #expect(c.status == .paused)
        c.checkHours()
        #expect(c.status == .paused)
        #expect(c.upNext.isEmpty)
        #expect(c.sleepTimer == .afterCurrent)
    }

    @Test func yesterdaysHourPiecePausedStartsTodaysWindowFresh() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        var open = row(album)
        open.lastFired = open.window(containing: .now)?.start.addingTimeInterval(-86_400)
        first.addAlarm(open)
        let state = Controller.ResumeState(path: album.songs[0].id, elapsed: 1, restLeft: nil, source: nil, upNext: [], hour: open.id)
        try JSONEncoder().encode(state).write(to: storage.appending(path: "resume.json"))
        let c = try opened(storage)
        c.presence = { _ in nil }
        c.loadAlarms()
        c.restoreResume()
        try await buildCatalog(c, from: first)
        c.checkHours()
        #expect(c.status == .resting)
        #expect(c.upNext.count == 2)
    }

    @Test func anHourDoesntStartBeforeThereIsACatalog() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        first.addAlarm(row(album))
        let c = try opened(storage)
        c.presence = { _ in nil }
        c.loadAlarms()
        c.checkHours()
        #expect(c.status == .idle)
        #expect(c.problem == nil)
        try await buildCatalog(c, from: first)
        c.checkHours()
        #expect(c.status == .resting)
    }

    @Test func aSleepTimerAndARiseOutliveARelaunch() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        var compline = Alarm(source: album.id, name: "Compline", hour: LiveClock.farHour, minute: 0, weekdays: Set(1...7))
        compline.minutes = 60
        first.addAlarm(compline)
        first.fire(compline.id, due: .now)
        first.advance(1)
        let (sleep, rise) = (first.machine.sleep, first.machine.rise)
        #expect(rise != nil)
        let c = try relaunch(first, storage: storage)
        try await buildCatalog(c, from: first)
        // it goes on by itself, and still stops at its time
        #expect(c.status == .playing)
        #expect(c.machine.sleep == sleep)
        #expect(c.machine.rise == rise)
        if case .at(let date)? = c.sleepTimer { #expect(date.timeIntervalSinceNow <= 3600 && date.timeIntervalSinceNow > 3590) } else { Issue.record("no timer") }
        c.advance(3600)
        #expect(c.status == .idle)
    }

    @Test func theStopAnHourLeftIsStillTheHoursAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album) = try await hourPlaying(storage: storage)
        first.checkHours(now: .now + 3600)
        #expect(first.sleepTimer == .afterCurrent)
        let c = try relaunch(first, storage: storage)
        try await buildCatalog(c, from: first)
        #expect(c.sleepTimer == .afterCurrent)
        // what you play next isn't cut short by it
        c.play(album.songs)
        #expect(c.sleepTimer == nil)
    }

    // MARK: Volume

    private func alarm(_ album: Album, volume: Double) -> Alarm {
        var row = Alarm(source: album.id, name: "Lauds", hour: LiveClock.farHour, minute: 0, weekdays: Set(1...7))
        row.volume = volume
        return row
    }

    @Test func afterAnAlarmTheVolumeGoesBack() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        let row = alarm(album, volume: 0.15)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.volume == 0.15)
        // over the two pieces and the silence between them
        for _ in 0..<300 where c.status != .idle { c.advance(1) }
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }

    @Test func aChangeByHandWhileItPlaysStays() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        let row = alarm(album, volume: 0.15)
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        c.volume = 0.3
        for _ in 0..<300 where c.status != .idle { c.advance(1) }
        #expect(c.status == .idle)
        #expect(c.volume == 0.3)
    }

    @Test func aRowThatLeavesTheVolumeLeavesIt() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        let row = Alarm(source: album.id, name: "Lauds", hour: LiveClock.farHour, minute: 0, weekdays: Set(1...7))
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        c.sleep(minutes: 1)
        c.systemWillSleep()
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }

    @Test func afterAnHourTheVolumeGoesBack() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        var hour = row(album)
        hour.volume = 0.2
        c.addAlarm(hour)
        c.checkHours()
        #expect(c.volume == 0.2)
        c.checkHours(now: .now + 3600)
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }

    @Test func goingRoundAgainNeverSetsTheVolume() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        var hour = row(album)
        hour.volume = 0.2
        c.addAlarm(hour)
        c.checkHours()
        c.volume = 0.5
        while !c.upNext.isEmpty { _ = c.dequeue() }
        #expect(c.dequeue() != nil)
        #expect(c.volume == 0.5)
    }

    @Test func playingSomethingYourselfGoesBackToYourVolume() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        var hour = row(album)
        hour.volume = 0.2
        c.addAlarm(hour)
        c.checkHours()
        c.play(album.songs)
        #expect(c.volume == 0.6)
    }

    @Test func theNextHourAtItsOwnVolumeStillGoesBackToYours() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        var first = row(album, minutes: 2)
        first.volume = 0.2
        c.addAlarm(first)
        var next = row(album, ago: -60)
        next.volume = 0.4
        c.addAlarm(next)
        c.checkHours()
        #expect(c.volume == 0.2)
        c.checkHours(now: .now + 120)
        #expect(c.status == .resting)
        #expect(c.volume == 0.4)
        c.checkHours(now: .now + 2 * 3600)
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }

    @Test func anAlarmThatFailsLeavesTheVolume() async throws {
        let (c, album) = try await controller(storage: try temp())
        c.volume = 0.6
        let bad = try temp().appending(path: "bad.caf")
        try Data("not audio".utf8).write(to: bad)
        c.library.entries[bad.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                                                    meta: TrackMeta(title: "bad", artist: "c", album: "Bad", duration: 3))
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        var row = alarm(album, volume: 0.15)
        row.source = try #require(c.catalog.albums.first { $0.title == "Bad" }).id
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }

    @Test func theVolumeStillGoesBackAfterARelaunch() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        first.volume = 0.6
        let lauds = alarm(album, volume: 0.15)
        first.addAlarm(lauds)
        first.fire(lauds.id, due: .now)
        first.advance(1)
        first.quitting()
        // the level itself comes back from UserDefaults, which tests stay out of
        let c = try opened(storage)
        c.volume = 0.15
        c.loadAlarms()
        c.restoreResume()
        try await buildCatalog(c, from: first)
        for _ in 0..<300 where c.status != .idle { c.advance(1) }
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }

    @Test func aChangeByHandBeforeTheRelaunchStillStays() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        first.volume = 0.6
        let lauds = alarm(album, volume: 0.15)
        first.addAlarm(lauds)
        first.fire(lauds.id, due: .now)
        first.quitting()
        let c = try opened(storage)
        c.volume = 0.3
        c.loadAlarms()
        c.restoreResume()
        try await buildCatalog(c, from: first)
        for _ in 0..<300 where c.status != .idle { c.advance(1) }
        #expect(c.status == .idle)
        #expect(c.volume == 0.3)
    }

    @Test func aPieceThatsGoneAfterARelaunchStillGivesTheVolumeBack() async throws {
        let storage = try temp()
        let (first, album) = try await controller(storage: storage)
        first.volume = 0.6
        let lauds = alarm(album, volume: 0.15)
        first.addAlarm(lauds)
        first.fire(lauds.id, due: .now)
        first.quitting()
        let saved = storage.appending(path: "resume.json")
        var state = try JSONDecoder().decode(Controller.ResumeState.self, from: Data(contentsOf: saved))
        state.path = "/gone.caf"
        try JSONEncoder().encode(state).write(to: saved)
        let c = try opened(storage)
        c.volume = 0.15
        c.restoreResume()
        #expect(c.status == .idle)
        #expect(c.volume == 0.6)
    }
}
