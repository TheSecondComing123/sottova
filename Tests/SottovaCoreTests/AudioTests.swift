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
}
