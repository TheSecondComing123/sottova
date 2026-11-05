import AVFoundation
import Testing
@testable import SottovaCore

@Suite(.disabled(if: LiveClock.repeatsAnHour(), "rows on the live clock can't be set up while the clocks repeat an hour"))
@MainActor
struct NowScreenTests {
    private func controller(titled title: String = "A piece", seconds: Int = 200) async throws -> (Controller, Album) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: nil)
        var settings = Settings()
        (settings.gapMin, settings.gapMax, settings.fadeIn, settings.fadeOut) = (30, 30, 6, 8)
        c.settings = settings
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-now-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        let url = dir.appending(path: "0.caf")
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8_000))!
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]).write(from: buffer)
        c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
            meta: TrackMeta(title: title, artist: "Komiku", album: "Overworld", trackNumber: 1, duration: Double(seconds)))
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.albums.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        return (c, c.catalog.albums[0])
    }

    private func playing() async throws -> (Controller, Album) {
        let (c, album) = try await controller()
        c.play(album.songs, source: album.id)
        return (c, album)
    }

    @Test func nothingAtAllIsFirstRun() throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let screen = Controller(engine: engine, storage: nil).nowScreen()
        #expect(screen.kind == .firstRun)
        #expect(screen.title == "Start with your music")
    }

    @Test func aPieceSaysWhoAndTimeLeft() async throws {
        let (c, _) = try await playing()
        c.advance(91)
        let screen = c.nowScreen()
        #expect(screen.kind == .piece)
        #expect(screen.title == "A piece")
        #expect(screen.sub == "Komiku")
        #expect(screen.third == "1:49 left")
        #expect(screen.action == nil)
    }

    @Test func pausedSaysTheTimeLeft() async throws {
        let (c, _) = try await playing()
        c.advance(91)
        c.toggle()
        #expect(c.nowScreen().third == "Paused, 1:49 left")
    }

    @Test func pausedWinsOverAnEasing() async throws {
        let (c, _) = try await playing()
        c.advance(20)
        c.sleep(minutes: 1)
        c.advance(55)
        #expect(c.easing)
        c.toggle()
        #expect(c.nowScreen().third?.hasSuffix("left") == true)
    }

    @Test func silenceLeavesSkipToTheTitleBar() async throws {
        let (c, _) = try await playing()
        while c.status != .resting { c.advance(0.5) }
        let screen = c.nowScreen()
        #expect(screen.title == "Silence")
        #expect(screen.sub == "")
        #expect(screen.action == nil)
    }

    @Test func theTailOfAFadeAlreadyReadsAsSilence() async throws {
        let (c, _) = try await playing()
        c.advance(195)
        #expect(c.status == .playing)
        #expect(c.nowScreen(silent: true).title == "Silence")
        #expect(c.nowScreen(silent: false).title == "A piece")
    }

    @Test func pausedInSilenceSaysTheNextPieceIsHeld() async throws {
        let (c, _) = try await playing()
        while c.status != .resting { c.advance(0.5) }
        c.toggle()
        let screen = c.nowScreen()
        #expect(screen.title == "Holding")
        #expect(screen.sub.hasSuffix("waits for Play"))
        #expect(screen.action == nil)
    }

    /// You've had your quiet: Play brings the next piece, not the rest of the countdown.
    @Test func playInAHeldSilenceStartsTheNextPiece() async throws {
        let (c, _) = try await playing()
        while c.status != .resting { c.advance(0.5) }
        c.toggle()
        c.toggle()
        #expect(c.machine.restRemaining == nil)
        #expect(c.status == .playing)
    }

    /// A preview isn't your quiet being over: the silence goes on from where it was.
    @Test func aPreviewInASilenceLeavesTheRestOfItToCome() async throws {
        let (c, _) = try await playing()
        while c.status != .resting { c.advance(0.5) }
        c.advance(5)
        let left = try #require(c.machine.restRemaining)
        let piece = c.current?.id
        #expect(c.holdForPreview())
        #expect(c.status == .paused)
        // held past where the silence would have ended: nothing starts and the countdown stays put
        c.advance(left + 5)
        #expect(c.status == .paused)
        #expect(c.current?.id == piece)
        #expect(c.machine.restRemaining == left)
        c.endPreview()
        #expect(c.status == .resting)
        #expect(c.machine.restRemaining == left)
        c.advance(left + 1)
        #expect(c.status == .playing)
    }

    @Test(arguments: [(Hold.away, "away"), (.call, "call"), (.busy, "busy"), (.media, "playing")])
    func aHoldSaysWhy(hold: Hold, line: String) {
        #expect(NowScreen.waiting(hold).sub.contains(line))
        #expect(NowScreen.waiting(hold).title == "Waiting")
        #expect(NowScreen.waiting(hold).action == nil)
    }

    @Test func musicLoadedBeforeTheCatalogIsNeverFirstRun() throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-now-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = Controller.ResumeState(path: nil, elapsed: nil, restLeft: 30, source: nil, upNext: [], hour: nil)
        try JSONEncoder().encode(state).write(to: dir.appending(path: "resume.json"))
        let c = Controller(engine: engine, storage: dir)
        c.restoreResume()
        #expect(c.catalog.albums.isEmpty)
        #expect(c.status != .idle)
        #expect(c.nowScreen().kind != .firstRun)
        #expect(c.nowFoot() == nil)
    }

    @Test func idleReadsTheDay() async throws {
        let (c, _) = try await controller()
        let screen = c.nowScreen()
        #expect(screen.kind == .quiet)
        #expect(screen.title == "Nothing on your day")
        #expect(screen.sub == "")
        #expect(screen.action == .openDay)
        c.addAlarm(Alarm(source: c.catalog.albums[0].id, name: "Overworld", hour: LiveClock.farHour, minute: 0, weekdays: Set(1...7)))
        #expect(c.nowScreen().action == nil)
        #expect(c.nowScreen().title == "Overworld")
    }

    @Test func aRowThatsSoundingSaysWhatFollowsAsALink() async throws {
        let (c, album) = try await controller()
        let row = Alarm(source: album.id, name: "Overworld", hour: LiveClock.farHour, minute: 0, weekdays: Set(1...7))
        c.addAlarm(row)
        c.fire(row.id, due: .now)
        let foot = try #require(c.nowFoot())
        #expect(foot.note == nil)
        #expect(foot.next?.hasPrefix("Overworld at") == true)
    }

    @Test func aPieceWithNoRowSaysWhatFollows() async throws {
        let (c, _) = try await playing()
        #expect(c.nowFoot() == NowFoot(note: "Overworld, then everything shuffled."))
    }

    @Test func aSkipIsCountedSoNowCanStartOver() async throws {
        let (c, _) = try await playing()
        c.advance(50)
        let before = c.skips
        c.skip()
        #expect(c.skips == before + 1)
        #expect(c.seeks == 0)
    }
}
