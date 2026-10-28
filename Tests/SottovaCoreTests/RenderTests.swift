import AVFoundation
import Testing
@testable import SottovaCore

/// Renders a session offline, stepping the envelope once per 10 ms render call.
@MainActor
struct RenderTests {
    private static let rate = 48_000.0
    private static let level: Float = 0.5

    @Test(arguments: [AVAudioChannelCount(2), 1])
    func outputFollowsEnvelope(channels: AVAudioChannelCount) throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!, maximumFrameCount: 480)
        let controller = Controller(engine: engine, logURL: nil)
        var settings = Settings()
        settings.fadeIn = 1
        settings.fadeOut = 1
        settings.gapMin = 5
        settings.gapMax = 5
        controller.settings = settings
        controller.tracks = [try constantFile(channels: channels, seconds: 3)]
        controller.toggle()

        // The mixer spreads mono to both speakers at −3 dB each. That keeps the summed loudness
        // equal to the mono file's own BS.1770 measurement, which normalization will rely on.
        let expected = Double(Self.level) * (channels == 1 ? 0.5.squareRoot() : 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480)!
        var previous = 0.0
        var worst = 0.0
        var held: [Double] = []
        while controller.status == .playing {
            let gain = Double(controller.deckGain)
            #expect(try engine.renderOffline(480, to: buffer) == .success)
            let level = rms(buffer)
            // the mixer ramps from the previous volume to the new one within a render cycle
            let low = expected * min(previous, gain)
            let high = expected * max(previous, gain)
            worst = max(worst, low - level, level - high)
            if previous == 1, gain == 1 {
                held.append(level)
            }
            previous = gain
            controller.advance(480 / Self.rate)
        }
        print("channels \(channels): worst envelope miss \(worst), held level \(held.min() ?? 0)...\(held.max() ?? 0)")
        #expect(worst < 1e-4)
        #expect(!held.isEmpty && held.allSatisfy { abs($0 - expected) < 1e-4 })
        #expect(controller.status == .resting)
        #expect(!engine.isRunning)
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
