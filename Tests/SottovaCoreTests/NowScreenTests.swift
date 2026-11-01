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
        #expect(screen.title == "Drop your music here")
    }

    @Test func aPieceSaysWhoWhereAndTimeLeft() async throws {
        let (c, _) = try await playing()
        c.advance(91)
        let screen = c.nowScreen()
        #expect(screen.kind == .piece)
        #expect(screen.title == "A piece")
        #expect(screen.sub == "Komiku, in Overworld")
        #expect(screen.third == "1:49 left")
        #expect(screen.action == nil)
    }

    @Test func pausedSaysSo() async throws {
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
        #expect(c.nowScreen().third?.hasPrefix("Paused,") == true)
    }

    @Test func silenceOffersTheNextSong() async throws {
        let (c, _) = try await playing()
        while c.status != .resting { c.advance(0.5) }
        let screen = c.nowScreen()
        #expect(screen.title == "Silence")
        #expect(screen.sub == "Next song in a while")
        #expect(screen.action == .skip)
        #expect(screen.actionTitle == "Play the next song now")
    }

    @Test func theTailOfAFadeAlreadyReadsAsSilence() async throws {
        let (c, _) = try await playing()
        c.advance(195)
        #expect(c.status == .playing)
        #expect(c.nowScreen(silent: true).title == "Silence")
        #expect(c.nowScreen(silent: false).title == "A piece")
    }

    @Test func pausedInSilenceSaysPaused() async throws {
        let (c, _) = try await playing()
        while c.status != .resting { c.advance(0.5) }
        c.toggle()
        let screen = c.nowScreen()
        #expect((screen.title, screen.sub) == ("Silence", "Paused"))
        #expect(screen.action == .skip)
    }

    @Test(arguments: [(Hold.away, "You're away. It picks up when you're back."), (.call, "You're on a call. It picks up after."),
                      (.busy, "Your calendar is busy."), (.media, "Something else is playing. It waits for it.")])
    func aHoldSaysWhy(hold: Hold, line: String) {
        #expect(NowScreen.waiting(hold, row: nil).sub == line)
        #expect(NowScreen.waiting(hold, row: nil).title == "Waiting")
    }

    @Test func aHoldNamesTheRow() {
        #expect(NowScreen.waiting(.away, row: "Overworld").sub == "You're away. Overworld picks up when you're back.")
    }

    @Test func idleReadsTheDay() async throws {
        let (c, _) = try await controller()
        let screen = c.nowScreen()
        #expect(screen.kind == .quiet)
        #expect(screen.title == "Nothing on your day")
        #expect(screen.action == .openDay)
    }

    @Test func aPieceWithNoRowSaysWhatFollows() async throws {
        let (c, _) = try await playing()
        #expect(c.nowFoot() == "Overworld, then everything shuffled.")
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
