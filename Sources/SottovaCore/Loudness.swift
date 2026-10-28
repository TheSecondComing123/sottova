import AVFoundation
import CEbur128

public struct Loudness: Codable, Equatable, Sendable {
    public var lufs: Double
    public var truePeakDb: Double

    /// Defaults are ReplayGain 2.0's −18 LUFS reference with loudgain's −1 dBTP ceiling.
    public func gainDb(target: Double = -18, ceiling: Double = -1) -> Double {
        // digital silence measures −∞; leave it alone
        guard lufs.isFinite, truePeakDb.isFinite else { return 0 }
        return min(target - lufs, ceiling - truePeakDb)
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
        // the decks play mono on both speakers at full level, so measure it that way
        if format.channelCount == 1 {
            try check(ebur128_set_channel(state, 0, Int32(EBUR128_DUAL_MONO.rawValue)))
        }

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536)!
        // counts frames instead of asking framePosition: on a file the decoder rejects, framePosition raises an
        // Objective-C exception no Swift code can catch, while read(into:) throws. Reading past the end throws too,
        // so each read asks for no more than what's left.
        var remaining = file.length
        while remaining > 0 {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity))))
            guard buffer.frameLength > 0 else { break }
            remaining -= Int64(buffer.frameLength)
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
