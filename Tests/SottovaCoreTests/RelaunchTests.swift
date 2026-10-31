import AVFoundation
import Testing
@testable import SottovaCore

/// What's still true after the app quits and opens again, against files in a temp folder. Rows open a minute ago on
/// the live clock, as in HourTests.
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

    /// Two three-second pieces in one album, and a third elsewhere that an hour must not wander into.
    private func controller(storage: URL) async throws -> (Controller, Album) {
        let c = Controller(engine: try engine(), storage: storage)
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
        let c = Controller(engine: try engine(), storage: storage)
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
        let c = Controller(engine: try engine(), storage: storage)
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
        let c = Controller(engine: try engine(), storage: storage)
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
        let c = Controller(engine: try engine(), storage: storage)
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
        var compline = Alarm(source: album.id, name: "Compline", hour: 20, minute: 0, weekdays: Set(1...7))
        compline.minutes = 60
        first.addAlarm(compline)
        first.fire(compline.id, due: .now)
        first.advance(1)
        let (sleep, rise) = (first.machine.sleep, first.machine.rise)
        #expect(rise != nil)
        let c = try relaunch(first, storage: storage)
        try await buildCatalog(c, from: first)
        #expect(c.status == .paused)
        #expect(c.machine.sleep == sleep)
        #expect(c.machine.rise == rise)
        if case .paused(let left)? = c.sleepTimer { #expect(left <= 3600 && left > 3590) } else { Issue.record("no timer") }
        // pressed play, it still stops at its time
        c.toggle()
        #expect(c.status == .playing)
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
}
