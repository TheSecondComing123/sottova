import AVFoundation
import Foundation
import Testing
@testable import SottovaCore

/// EBU Tech 3341 minimum-requirement signals, synthesized at 48 kHz.
struct LoudnessTests {
    private static let rate = 48_000.0

    /// Cases 1–5: stereo 1 kHz tones at the listed (seconds, dBFS peak) steps.
    @Test(arguments: [
        (1, [(20.0, -23.0)], -23.0),
        (2, [(20.0, -33.0)], -33.0),
        (3, [(10.0, -36.0), (60.0, -23.0), (10.0, -36.0)], -23.0),
        (4, [(10.0, -72.0), (10.0, -36.0), (60.0, -23.0), (10.0, -36.0), (10.0, -72.0)], -23.0),
        (5, [(20.0, -26.0), (20.1, -20.0), (20.0, -26.0)], -23.0),
    ])
    func integratedLoudness(case number: Int, steps: [(Double, Double)], expected: Double) throws {
        var samples: [Float] = []
        for (seconds, dbfs) in steps {
            let amplitude = pow(10, dbfs / 20)
            let start = samples.count
            for n in 0..<Int(seconds * Self.rate) {
                samples.append(Float(amplitude * sin(2 * .pi * 1000 * Double(start + n) / Self.rate)))
            }
        }
        let measured = try Loudness.measure(stereoFile(samples, name: "3341-\(number)"))
        #expect(abs(measured.lufs - expected) <= 0.1, "case \(number): \(measured.lufs) LUFS")
    }

    /// Cases 15–19: sines at fs/4, fs/6, fs/8 with phase offsets, so the true peak falls between samples.
    @Test(arguments: [
        (15, 4.0, 0.50, 0.0, -6.0),
        (16, 4.0, 0.50, 45.0, -6.0),
        (17, 6.0, 0.50, 60.0, -6.0),
        (18, 8.0, 0.50, 67.5, -6.0),
        (19, 4.0, 1.41, 45.0, 3.0),
    ])
    func truePeak(case number: Int, divisor: Double, amplitude: Double, phaseDegrees: Double, expected: Double) throws {
        let count = Int(Self.rate)
        let taper = Int(0.01 * Self.rate)
        let samples = (0..<count).map { n -> Float in
            let fade = min(1, Double(min(n, count - 1 - n)) / Double(taper))
            return Float(fade * amplitude * sin(2 * .pi * Double(n) / divisor + phaseDegrees * .pi / 180))
        }
        let measured = try Loudness.measure(stereoFile(samples, name: "3341-\(number)"))
        #expect(measured.truePeakDb >= expected - 0.4 && measured.truePeakDb <= expected + 0.2, "case \(number): \(measured.truePeakDb) dBTP")
    }

    /// Mono plays on both speakers at full level, so it measures 3 dB louder than one channel alone.
    @Test func monoIsMeasuredAsDualMono() throws {
        let samples = (0..<Int(20 * Self.rate)).map { Float(pow(10, -23.0 / 20) * sin(2 * .pi * 1000 * Double($0) / Self.rate)) }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-mono.caf")
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let stereo = try Loudness.measure(stereoFile(samples, name: "mono-reference"))
        #expect(abs(try Loudness.measure(url).lufs - stereo.lufs) < 0.01)
    }

    @Test func gainTakesTheStricterOfLoudnessAndPeak() {
        #expect(Loudness(lufs: -10, truePeakDb: -0.5).gainDb() == -8)
        #expect(Loudness(lufs: -25, truePeakDb: -3).gainDb() == 2)
        #expect(Loudness(lufs: -.infinity, truePeakDb: -.infinity).gainDb() == 0)
    }

    private func stereoFile(_ samples: [Float], name: String) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(from: samples, count: samples.count)
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-\(name).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
