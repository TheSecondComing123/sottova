import AVFoundation
import Testing
@testable import SottovaCore

/// What the rendered samples say, with test tones in temp files: every number here was measured first.
@MainActor
final class AudioTests {
    private static let rate = 48_000.0
    private let folder = FileManager.default.temporaryDirectory.appending(path: "sottova-audio-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor private final class Session {
        let engine = AVAudioEngine()
        let controller: Controller
        let out: AVAudioPCMBuffer
        var left: [Float] = []
        var right: [Float] = []

        init(_ settings: Settings) throws {
            try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: AudioTests.rate, channels: 2)!, maximumFrameCount: 480)
            controller = Controller(engine: engine, storage: nil)
            controller.volume = 1
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
        let url = folder.appending(path: "\(UUID().uuidString).caf")
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

    /// Analyzed for real, rendered, then measured again the same way.
    @Test func quietPiecesReachTheTargetAndTheCeilingHolds() throws {
        let quiet = try tone(1_000, amplitude: pow(10, -30.0 / 20), seconds: 12)
        // the same quiet tone, with a loud burst every second that the ceiling has to answer to
        let peaky = try file(seconds: 12) { _, n in
            Float((n % 48_000 < 24 ? 0.5 : 0.01) * sin(2 * .pi * 1_000 * Double(n) / Self.rate))
        }
        for (url, boosted) in [(quiet, true), (peaky, false)] {
            let analyzed = try Loudness.measure(url)
            let session = try Session(settings(fade: 0.5))
            session.add(url, analyzed)
            session.controller.toggle()
            try session.render(11)
            let held = try Loudness.measure(try written(Array(session.left[(1 * 48_000)..<(11 * 48_000)]), Array(session.right[(1 * 48_000)..<(11 * 48_000)])))
            print("in \(analyzed.lufs) LUFS \(analyzed.truePeakDb) dBTP, gain \(analyzed.gainDb()), out \(held.lufs) LUFS \(held.truePeakDb) dBTP")
            #expect(analyzed.gainDb() > 4)
            #expect(held.truePeakDb < -1 + 0.01)
            if boosted {
                #expect(abs(held.lufs + 18) < 0.05)
            }
        }
    }

    /// One impulse a second says which frame of the file is playing: 40 ms late after the deck's silence, and it stays there.
    @Test(arguments: [(44_100.0, AVAudioChannelCount(2)), (96_000, 2), (44_100, 1), (48_000, 1)])
    func everyRatePlaysOnTimeAndEndsOnTime(rate: Double, channels: AVAudioChannelCount) throws {
        var hard = settings(fade: 0)
        hard.gapMin = 60
        let session = try Session(hard)
        session.add(try file(rate: rate, channels: channels, seconds: 30) { _, n in
            n % Int(rate) == 0 ? 0.9 : 0.1
        })
        session.controller.toggle()
        #expect(session.controller.track?.duration == 30)
        while session.controller.track!.elapsed < 29.9 { try session.block() }
        // the clock stops here, so whatever plays on is the file's own length
        for _ in 0..<50 {
            _ = try session.engine.renderOffline(480, to: session.out)
            session.left.append(contentsOf: UnsafeBufferPointer(start: session.out.floatChannelData![0], count: 480))
        }
        for second in [1, 10, 29] {
            let expected = Int((Double(second) + Controller.mixerRamp) * Self.rate)
            let window = (expected - 48)..<(expected + 48)
            let peak = window.max { session.left[$0] < session.left[$1] }!
            #expect(abs(peak - expected) <= 1, "second \(second) landed at \(peak - expected) frames")
        }
        let last = session.left.lastIndex { abs($0) > 1e-3 }!
        #expect(abs(last - Int((30 + Controller.mixerRamp) * Self.rate)) <= 1, "ended \(last)")
    }

    /// Ten minutes, an impulse a second, on the clock the test drives: rendered frames and elapsed agree, the file doesn't drift.
    @Test func tenMinutesDontDrift() throws {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let second = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        second.frameLength = second.frameCapacity
        second.floatChannelData![0].update(repeating: 0, count: Int(rate))
        second.floatChannelData![0][0] = 0.9
        let url = folder.appending(path: "ten-minutes.caf")
        do {
            let out = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<600 { try out.write(from: second) }
        }
        let session = try Session(settings(fade: 4))
        session.add(url)
        session.controller.toggle()
        var frames = 0
        while frames < 590 * 48_000 {
            _ = try session.engine.renderOffline(480, to: session.out)
            session.controller.advance(480 / Self.rate)
            frames += 480
        }
        #expect(abs(session.controller.track!.elapsed - 590) < 1e-6)
        // the second at 590 s is 40 ms on
        try session.render(0.05)
        let peak = session.left.indices.max { session.left[$0] < session.left[$1] }!
        #expect(abs(peak - Int(Controller.mixerRamp * Self.rate)) <= 1, "\(peak)")
        // the fade lands on the end of the file
        while session.controller.status == .playing { try session.block() }
        #expect(abs(session.controller.track!.elapsed - 600) < 0.011)
    }

    /// Each piece on its own channel, so the two decks are read apart.
    @Test func aCrossfadeKeepsItsPowerAndHasNoGap() throws {
        var continuous = Settings.presets.first { $0.name == "Continuous" }!
        (continuous.fadeIn, continuous.crossfadeSec) = (2, 2)
        let session = try Session(continuous)
        for side in [0, 1] {
            session.add(try file(seconds: 6) { channel, n in
                channel == side ? Float(0.5 * sin(2 * .pi * 1_000 * Double(n) / Self.rate)) : 0
            })
        }
        session.controller.toggle()
        try session.render(9)
        let firstIsLeft = rms(session.left[(2 * 48_000)..<(3 * 48_000)]) > rms(session.right[(2 * 48_000)..<(3 * 48_000)])
        let (one, two) = firstIsLeft ? (session.left, session.right) : (session.right, session.left)
        let full = 0.5 / 2.0.squareRoot()
        // the overlap runs from 3.97 to 5.97 s on the clock
        var worst = 0.0
        for start in stride(from: Int(3.8 * Self.rate), to: Int(6.2 * Self.rate), by: 480) {
            let a = rms(one[start..<(start + 480)]), b = rms(two[start..<(start + 480)])
            worst = max(worst, abs(10 * log10((a * a + b * b) / (full * full))))
        }
        #expect(worst < 0.1, "\(worst) dB")
        // silent before its file ends, so the end of the file is never heard as a cut; the third piece starts near 8 s
        #expect(rms(one[Int(6.0 * Self.rate)..<Int(7.5 * Self.rate)]) < 1e-3)
    }

    @Test func fadesASkipAndTrimPointsNeverStep() throws {
        let natural = Float(0.5 * 2 * .pi * 220 / Self.rate)
        let url = try tone(220, seconds: 6)
        let session = try Session(settings(fade: 0.5))
        session.controller.setTrim(Trim(start: 1.2, end: 4.7), for: url.path)
        session.add(url)
        session.controller.toggle()
        // all the way through, past both trim points
        while session.controller.status == .playing { try session.block() }
        #expect(abs(Double(session.left.count) / Self.rate - 3.5) < 0.02)
        // again from the gap, then out through a skip's fade
        session.controller.skip()
        try session.render(2)
        session.controller.skip()
        try session.render(1.1)
        #expect(biggestJump(session.left[...]) <= natural * 1.01)
    }

    private func written(_ left: [Float], _ right: [Float]) throws -> URL {
        var i = -1
        return try file(seconds: Double(left.count) / Self.rate) { channel, _ in
            i += 1
            return channel == 0 ? left[i] : right[i - left.count]
        }
    }
}
