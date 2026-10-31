import CoreAudio
import CoreGraphics
import EventKit
import Foundation

/// Why music that plays while you're at the Mac is waiting to start its next piece.
public enum Hold: Equatable, Sendable {
    case away, call, busy, media
}

/// What the Mac says right now about whether it's a time for music. Read fresh each time and never kept; only the
/// calendar needs a permission.
public enum Presence {
    /// No key, click or scroll for this long counts as away.
    static let awayAfter: TimeInterval = 5 * 60

    /// `calendar`: whether something on your calendar is a reason to wait.
    @MainActor static func hold(calendar: Bool) -> Hold? {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if idle > awayAfter || locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return .away }
        let (output, input) = otherAudio()
        // a call plays sound too
        if input { return .call }
        if calendar, busy() { return .busy }
        if output { return .media }
        return nil
    }

    // MARK: Calendar

    /// macOS Calendar's events, Google's included through the account added there; Sottova never talks to Google.
    @MainActor static let events = EKEventStore()

    /// Birthdays and holidays fill whole days and say nothing about whether you're at your desk.
    static func countsByDefault(birthday: Bool, title: String) -> Bool {
        !birthday && !title.localizedCaseInsensitiveContains("holiday")
    }

    @MainActor public static var calendars: [EKCalendar] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return events.calendars(for: .event).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @MainActor public static func counts(_ calendar: EKCalendar) -> Bool {
        (UserDefaults.standard.dictionary(forKey: "calendars") as? [String: Bool])?[calendar.calendarIdentifier]
            ?? countsByDefault(birthday: calendar.type == .birthday, title: calendar.title)
    }

    @MainActor public static func setCounts(_ on: Bool, for calendar: EKCalendar) {
        var choices = UserDefaults.standard.dictionary(forKey: "calendars") as? [String: Bool] ?? [:]
        choices[calendar.calendarIdentifier] = on
        UserDefaults.standard.set(choices, forKey: "calendars")
    }

    /// Asks once; after that the answer lives in System Settings.
    @MainActor public static func askForCalendars() async {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        _ = try? await events.requestFullAccessToEvents()
    }

    /// Something on a calendar that counts, right now; an event marked free doesn't.
    @MainActor static func busy(at now: Date = .now) -> Bool {
        let counted = calendars.filter(counts)
        guard !counted.isEmpty else { return false }
        return events.events(matching: events.predicateForEvents(withStart: now, end: now + 1, calendars: counted))
            .contains { $0.availability != .free }
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
