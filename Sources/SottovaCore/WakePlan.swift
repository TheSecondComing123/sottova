import Foundation

/// What SystemWake decides and how it talks to pmset and sudo, away from the main actor and the UI.
public enum WakePlan {
    /// Enough before the alarm for the Mac to come up and the timer to fire on time.
    public static let lead: TimeInterval = 2 * 60
    /// How far ahead wakes go in, so a repeating alarm doesn't ask for the password every morning.
    public static let ahead: TimeInterval = 14 * 86_400

    /// A sudoers rule that lets this user schedule a wake at a date and time, and nothing else, without a password.
    /// It goes in with the one password prompt, so later wakes are added as the days go by without asking again.
    public static let rule = "/etc/sudoers.d/sottova-2"
    /// The first rule ended in `*`, which also matches spaces, so it let extra arguments through. It still schedules
    /// wakes, and the next password prompt replaces it. The app can't read either file, only see which one exists.
    public static let looseRule = "/etc/sudoers.d/sottova"

    private nonisolated(unsafe) static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return f
    }()

    /// `format` as a sudoers glob, digits only so nothing can follow it: "10/30/2026 06:58:00". The colons are `?`
    /// because sudoers wants a colon escaped.
    static let datePattern = "[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] [0-9][0-9]?[0-9][0-9]?[0-9][0-9]"

    /// The wakes in `pmset -g sched`, from any app.
    public static func scheduled(in output: String) -> Set<Date> {
        Set(output.matches(of: /wake(?:orpoweron)? at (\d\d\/\d\d\/\d{4} \d\d:\d\d:\d\d)/)
            .compactMap { format.date(from: String($0.1)) })
    }

    /// The wakes the alarms that are on need in the next two weeks, soonest first; one that plays while you're at
    /// the Mac needs none.
    public static func needed(for alarms: [Alarm], now: Date) -> [Date] {
        alarms.filter { $0.on && !$0.whileHere }
            .flatMap { $0.times(after: now, until: now + ahead) }
            .map { $0 - lead }
            .filter { $0 > now + 60 }
            .sorted()
    }

    public static func pmsetArguments(for date: Date) -> [String] {
        ["-n", "/usr/bin/pmset", "schedule", "wakeorpoweron", format.string(from: date)]
    }

    /// Written and checked under a name with a dot, which sudo skips, so a bad rule never takes effect; the loose
    /// first rule goes once the new one is in.
    public static func installScript(user: String) -> String {
        let line = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset schedule wakeorpoweron \(datePattern)"
        let install = "echo '\(line)' > /etc/sudoers.d/.sottova && chmod 440 /etc/sudoers.d/.sottova && /usr/sbin/visudo -cf /etc/sudoers.d/.sottova && mv /etc/sudoers.d/.sottova \(rule) && rm -f \(looseRule) || { rm -f /etc/sudoers.d/.sottova; exit 1; }"
        return "do shell script \"\(install)\" with administrator privileges"
    }

    /// What to say when that script failed, from what osascript wrote. Cancel in the password prompt (-128) isn't a
    /// failure: the page still says the Mac won't wake.
    public static func installFailure(_ stderr: String) -> String? {
        if stderr.contains("(-128)") { return nil }
        let said = stderr.firstMatch(of: /execution error: (.*) \(-?\d+\)/).map { String($0.1) }
        return "couldn't let sottova wake the mac: \(said ?? "the system said no")"
    }

    /// Runs a command off the main actor and waits for it; nil when it can't start.
    public static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, output: String, error: String)? {
        #if SHOT
        guard path == "/usr/bin/pmset", arguments == ["-g", "sched"] else { return (0, "", "") }
        #endif
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (output, error) = (Pipe(), Pipe())
                let process = Process()
                process.executableURL = URL(filePath: path)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                // both fit a pipe's buffer: a short schedule and one line of error
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, out, err))
            }
        }
    }
}
