import AVFoundation
import CEbur128

public struct Loudness: Codable, Equatable, Sendable {
    public var lufs: Double
    public var truePeakDb: Double

    /// ReplayGain 2.0's −18 LUFS reference, with loudgain's −1 dBTP ceiling.
    public var gainDb: Double {
        // digital silence measures −∞; leave it alone
        guard lufs.isFinite, truePeakDb.isFinite else { return 0 }
        return min(-18 - lufs, -1 - truePeakDb)
    }

    struct Failure: LocalizedError {
        let code: Int32
        var errorDescription: String? { "loudness analysis failed (libebur128 error \(code))" }
    }

    /// Integrated loudness and true peak per ITU-R BS.1770, via libebur128.
    static func measure(_ url: URL) throws -> Loudness {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let format = file.processingFormat
        let mode = Int32(EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue)
        guard let state = ebur128_init(format.channelCount, UInt(format.sampleRate), mode) else {
            throw Failure(code: Int32(EBUR128_ERROR_NOMEM.rawValue))
        }
        defer {
            var pointer: UnsafeMutablePointer<ebur128_state>? = state
            ebur128_destroy(&pointer)
        }

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try check(ebur128_add_frames_float(state, buffer.floatChannelData![0], Int(buffer.frameLength)))
        }

        var lufs = 0.0
        try check(ebur128_loudness_global(state, &lufs))
        var peak = 0.0
        for channel in 0..<format.channelCount {
            var channelPeak = 0.0
            try check(ebur128_true_peak(state, channel, &channelPeak))
            peak = max(peak, channelPeak)
        }
        return Loudness(lufs: lufs, truePeakDb: 20 * log10(peak))
    }

    private static func check(_ code: Int32) throws {
        guard code == Int32(EBUR128_SUCCESS.rawValue) else { throw Failure(code: code) }
    }
}
