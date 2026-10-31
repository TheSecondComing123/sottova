import AVFoundation
import Testing
@testable import SottovaCore

/// What the rendered samples say, with test tones in temp files: every number here was measured first.
@MainActor
struct AudioTests {
    private static let rate = 48_000.0

    @MainActor private final class Session {
        let engine = AVAudioEngine()
        let controller: Controller
        let out: AVAudioPCMBuffer
        var left: [Float] = []
        var right: [Float] = []

        init(_ settings: Settings) throws {
            try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: AudioTests.rate, channels: 2)!, maximumFrameCount: 480)
            controller = Controller(engine: engine, storage: nil)
            controller.settings = settings
            out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480)!
        }

        func add(_ url: URL, _ loudness: Loudness = Loudness(lufs: -18, truePeakDb: -10)) {
            controller.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: loudness)
            controller.refreshTracks()
        }

        func render(_ seconds: Double) throws {
            for _ in 0..<Int((seconds * 100).rounded()) { try block() }
        }

        func block() throws {
            _ = try engine.renderOffline(480, to: out)
            left.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: 480))
            right.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![1], count: 480))
            controller.advance(480 / AudioTests.rate)
        }
    }

    private func settings(fade: Double) -> Settings {
        var s = Settings()
        (s.fadeIn, s.fadeOut, s.gapMin, s.gapMax) = (fade, fade, 5, 5)
        return s
    }

    private func file(rate: Double = AudioTests.rate, channels: AVAudioChannelCount = 2, seconds: Double, _ sample: (_ channel: Int, _ frame: Int) -> Float) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for n in 0..<frames { buffer.floatChannelData![channel][n] = sample(channel, n) }
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-audio-\(UUID().uuidString).caf")
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func tone(_ frequency: Double, rate: Double = AudioTests.rate, amplitude: Double = 0.5, seconds: Double) throws -> URL {
        try file(rate: rate, seconds: seconds) { _, n in Float(amplitude * sin(2 * .pi * frequency * Double(n) / rate)) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
    }

    private func biggestJump(_ samples: ArraySlice<Float>) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    /// Wired without a format, the deck mixers take a new mixer's default of 44.1 kHz: every piece went down to that
    /// and back, which took 20 kHz down 14 dB even from a 48 kHz file.
    @Test func a48kFileComesThroughUntouched() throws {
        let session = try Session(settings(fade: 0.5))
        session.add(try tone(20_000, seconds: 4))
        session.controller.toggle()
        try session.render(2)
        let held = rms(session.left[(1 * 48_000)..<(2 * 48_000)])
        #expect(abs(20 * log10(held / (0.5 / 2.0.squareRoot()))) < 0.01, "held \(held)")
    }

    /// A seek used to cut the old spot at full level and play the first 30 ms of the new one through the mixer's way
    /// down to 0: a step 28 times the sine's own biggest, then a burst.
    @Test func aSeekGoesQuietBeforeItJumps() throws {
        let session = try Session(settings(fade: 0.5))
        session.add(try tone(220, seconds: 8))
        session.controller.toggle()
        try session.render(2)
        let at = session.left.count
        session.controller.seek(to: 4.003)
        try session.render(0.2)
        let natural = Float(0.5 * 2 * .pi * 220 / Self.rate)
        #expect(biggestJump(session.left[(at - 1)...]) <= natural * 1.01)
        try session.render(1.6)
        #expect(abs(rms(session.left[(session.left.count - 4_800)...]) - 0.5 / 2.0.squareRoot()) < 1e-3)
    }

    /// The mixer freezes on its way down when its deck stops, and finishes on the next thing that deck plays.
    @Test func aPieceStartsSilentAfterAHardStop() throws {
        let session = try Session(settings(fade: 0.5))
        session.add(try tone(220, seconds: 6))
        session.controller.toggle()
        try session.render(2)
        // closing the lid with a sleep timer set stops at once
        session.controller.sleep(minutes: 5)
        session.controller.systemWillSleep()
        #expect(session.controller.status == .idle)
        let at = session.left.count
        session.controller.toggle()
        try session.render(0.05)
        #expect(rms(session.left[at..<(at + 1_920)]) < 1e-3, "\(rms(session.left[at..<(at + 1_920)]))")
    }

    @Test func aSeekWhilePausedComesBackSilent() throws {
        let session = try Session(settings(fade: 0.5))
        session.add(try tone(220, seconds: 6))
        session.controller.toggle()
        try session.render(2)
        session.controller.pause()
        session.controller.seek(to: 4)
        session.controller.toggle()
        let at = session.left.count
        try session.render(0.05)
        #expect(rms(session.left[at..<(at + 1_920)]) < 1e-3, "\(rms(session.left[at..<(at + 1_920)]))")
    }
}
