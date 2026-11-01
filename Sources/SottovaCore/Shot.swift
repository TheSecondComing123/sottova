#if SHOT
import Foundation

/// The copy that takes pictures: everything it keeps lives under one temp folder. It won't start any other way.
public enum ShotEnv {
    public static let bundleID = "com.alanbagel.sottova.shot"

    public static let root: URL = {
        guard Bundle.main.bundleIdentifier == bundleID else { refuse("not the \(bundleID) bundle") }
        guard let path = ProcessInfo.processInfo.environment["SOTTOVA_SHOT_STORAGE"] else { refuse("SOTTOVA_SHOT_STORAGE isn't set") }
        let root = URL(filePath: path).resolvingSymlinksInPath()
        guard ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: { root.path.hasPrefix($0) }) else { refuse("\(root.path) isn't under a temp folder") }
        return root
    }()

    /// What the screens take the time to be; the machine runs on the real clock.
    nonisolated(unsafe) public static var now: Date?

    nonisolated(unsafe) private static var worstTick = Duration.zero
    nonisolated(unsafe) private static var fastTicks = 0

    /// The longest wait between ticks while a gain moves, kept in a file for the CPU measure.
    static func noteTick(_ gap: Duration, fast: Bool) {
        guard fast else { return }
        worstTick = max(worstTick, gap)
        fastTicks += 1
        if fastTicks % 100 == 0 {
            try? Data("\(fastTicks) ticks, worst \(worstTick)\n".utf8).write(to: root.appending(path: "ticks"))
        }
    }

    public static var storage: URL { folder("Application Support") }
    public static var music: URL { folder("Music") }
    public static var artwork: URL { folder("Artwork") }

    private static func folder(_ name: String) -> URL {
        let url = root.appending(path: name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func refuse(_ why: String) -> Never {
        FileHandle.standardError.write(Data("SottovaShot refuses to run: \(why)\n".utf8))
        exit(78)
    }
}
#endif
