import AVFoundation
import Testing
@testable import SottovaCore

/// Renders a session offline, stepping the envelope once per 10 ms render call.
@MainActor
struct RenderTests {
    private static let rate = 48_000.0
    private static let level: Float = 0.5

    /// `lufs` nil means not analyzed yet, which plays at the provisional −6 dB.
    /// −24 LUFS gets +6 dB: the boost path through outputVolume above 1.
    @Test(arguments: [
        (AVAudioChannelCount(2), -18.0 as Double?, 0.0),
        (1, -18, 0),
        (2, -24, 6),
        (2, nil, -6),
    ])
    func outputFollowsEnvelopeAndGain(channels: AVAudioChannelCount, lufs: Double?, gainDb: Double) throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!, maximumFrameCount: 480)
        let controller = Controller(engine: engine, storage: nil)
        var settings = Settings()
        settings.fadeIn = 1
        settings.fadeOut = 1
        settings.gapMin = 5
        settings.gapMax = 5
        controller.settings = settings
        let url = try constantFile(channels: channels, seconds: 3)
        controller.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: lufs.map { Loudness(lufs: $0, truePeakDb: -10) })
        controller.refreshTracks()
        controller.toggle()

        // The decks are wired stereo, so mono plays at full level on both speakers.
        // Loudness measures mono as dual mono to match.
        let scale = pow(10, gainDb / 20)
        let expected = Double(Self.level) * scale
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480)!
        var previous = 0.0
        var worst = 0.0
        var held: [Double] = []
        while controller.status == .playing {
            let gain = Double(controller.deckGain) / scale
            #expect(try engine.renderOffline(480, to: buffer) == .success)
            let level = rms(buffer)
            // the mixer ramps from the previous volume to the new one within a render cycle
            let low = expected * min(previous, gain)
            let high = expected * max(previous, gain)
            worst = max(worst, low - level, level - high)
            if abs(previous - 1) < 1e-6, abs(gain - 1) < 1e-6 {
                held.append(level)
            }
            previous = gain
            controller.advance(480 / Self.rate)
        }
        print("channels \(channels), gain \(gainDb) dB: worst envelope miss \(worst), held level \(held.min() ?? 0)...\(held.max() ?? 0), expected \(expected)")
        #expect(worst < 1e-4)
        #expect(!held.isEmpty && held.allSatisfy { abs($0 - expected) < 1e-4 })
        #expect(controller.status == .resting)
        #expect(!engine.isRunning)
    }

    /// Continuous preset: both decks sound during the overlap and the session never rests.
    @Test func crossfadeOverlapsTwoDecks() throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!, maximumFrameCount: 480)
        let controller = Controller(engine: engine, storage: nil)
        var settings = Settings.presets.first { $0.name == "Continuous" }!
        settings.fadeIn = 1
        settings.crossfadeSec = 1
        controller.settings = settings
        let url = try constantFile(channels: 2, seconds: 3)
        controller.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10))
        controller.refreshTracks()
        controller.toggle()

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480)!
        // the mixer smooths a volume change over about 20 ms, so a block can still carry the volume from two blocks back
        var history = [controller.mixerVolumes.map(Double.init), controller.mixerVolumes.map(Double.init)]
        var worst = 0.0
        var overlapBlocks = 0
        for _ in 0..<800 {
            let volumes = controller.mixerVolumes.map(Double.init)
            #expect(try engine.renderOffline(480, to: buffer) == .success)
            let window = history + [volumes]
            // the same constant signal on both decks adds in amplitude
            let low = Double(Self.level) * (0..<2).map { deck in window.map { $0[deck] }.min()! }.reduce(0, +)
            let high = Double(Self.level) * (0..<2).map { deck in window.map { $0[deck] }.max()! }.reduce(0, +)
            let level = rms(buffer)
            worst = max(worst, low - level, level - high)
            if volumes.allSatisfy({ $0 > 0.3 }) {
                overlapBlocks += 1
            }
            #expect(controller.status == .playing)
            history = [history[1], volumes]
            controller.advance(480 / Self.rate)
        }
        print("crossfade: worst miss \(worst), overlap blocks \(overlapBlocks)")
        #expect(worst < 1e-4)
        #expect(overlapBlocks > 50)
    }

    /// The first 3 s are quiet and the last 3 s loud, so the level after a seek says where playback really is.
    @Test func seekPlaysFromTheNewSpotAfterFadingBackIn() throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!, maximumFrameCount: 480)
        let controller = Controller(engine: engine, storage: nil)
        var settings = Settings()
        settings.fadeIn = 0.5
        settings.fadeOut = 0.5
        controller.settings = settings
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let half = AVAudioFrameCount(3 * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: half * 2)!
        buffer.frameLength = half * 2
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: 0.1, count: Int(half))
            (buffer.floatChannelData![channel] + Int(half)).update(repeating: 0.5, count: Int(half))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-seek.caf")
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        controller.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10))
        controller.refreshTracks()
        controller.toggle()

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480)!
        func render(seconds: Double) throws -> Double {
            var level = 0.0
            for _ in 0..<Int(seconds * 100) {
                _ = try engine.renderOffline(480, to: out)
                level = rms(out)
                controller.advance(480 / Self.rate)
            }
            return level
        }
        #expect(abs(try render(seconds: 1.5) - 0.1) < 0.01)
        controller.seek(to: 3.2)
        #expect(controller.deckGain == 0)
        // past the 1.5 s seek fade: the loud half, at full gain
        #expect(abs(try render(seconds: 1.6) - 0.5) < 0.01)
    }

    @Test func aRelaunchPicksUpPausedAtTheSameSpot() throws {
        let storage = FileManager.default.temporaryDirectory.appending(path: "sottova-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let url = try constantFile(channels: 2, seconds: 3)
        func controller() throws -> (Controller, AVAudioEngine) {
            let engine = AVAudioEngine()
            try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!, maximumFrameCount: 480)
            let c = Controller(engine: engine, storage: storage)
            var settings = Settings()
            settings.fadeIn = 0.5
            settings.fadeOut = 0.2
            c.settings = settings
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10))
            c.refreshTracks()
            return (c, engine)
        }
        let (first, engine) = try controller()
        first.toggle()
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480)!
        for _ in 0..<100 {
            _ = try engine.renderOffline(480, to: out)
            first.advance(480 / Self.rate)
        }
        first.quitting()

        let (second, engine2) = try controller()
        second.restoreResume()
        #expect(second.status == .paused)
        #expect(abs((second.track?.elapsed ?? 0) - 1) < 0.02)
        second.toggle()
        let out2 = AVAudioPCMBuffer(pcmFormat: engine2.manualRenderingFormat, frameCapacity: 480)!
        var level = 0.0
        for _ in 0..<160 {
            _ = try engine2.renderOffline(480, to: out2)
            level = rms(out2)
            second.advance(480 / Self.rate)
        }
        // past the seek fade and still in the hold: full level, from the file's second second on
        #expect(abs(level - Double(Self.level)) < 1e-3)
        #expect(abs((second.track?.elapsed ?? 0) - 2.6) < 0.02)
    }

    private func constantFile(channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            buffer.floatChannelData![channel].update(repeating: Self.level, count: Int(frames))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-render-\(channels)ch.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
    }
}
