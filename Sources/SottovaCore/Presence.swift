import CoreAudio
import CoreGraphics
import Foundation

/// Why music that plays while you're at the Mac is waiting to start its next piece.
public enum Hold: Equatable, Sendable {
    case away, call, media
}

/// What the Mac says right now about whether it's a time for music. Read fresh each time and never kept; none of it
/// needs a permission.
enum Presence {
    /// No key, click or scroll for this long counts as away.
    static let awayAfter: TimeInterval = 5 * 60

    static func hold() -> Hold? {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if idle > awayAfter || locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return .away }
        let (output, input) = otherAudio()
        // a call plays sound too
        if input { return .call }
        if output { return .media }
        return nil
    }

    /// Whether any other app is playing sound or using the mic: Core Audio's per-process flags, which, unlike the
    /// device-wide one, don't count Sottova's own playback.
    private static func otherAudio() -> (output: Bool, input: Bool) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return (false, false) }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return (false, false) }
        var output = false, input = false
        // most processes aren't running, and one read rules them out
        for process in processes where value(kAudioProcessPropertyIsRunning, of: process) != 0 && value(kAudioProcessPropertyPID, of: process) != getpid() {
            output = output || value(kAudioProcessPropertyIsRunningOutput, of: process) != 0
            input = input || value(kAudioProcessPropertyIsRunningInput, of: process) != 0
        }
        return (output, input)
    }

    private static func value(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Int32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
}
