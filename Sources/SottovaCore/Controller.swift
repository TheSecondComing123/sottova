import AVFoundation
import IOKit.pwr_mgt
import Observation

/// Runs the machine's effects against the audio engine. Main-actor bound: the work per tick is one volume write.
@MainActor @Observable
public final class Controller {
    public private(set) var status = PlaybackStatus.idle
    public private(set) var title: String?
    public private(set) var nextTrackAt: Date?
    public private(set) var folders: [URL] = []
    public private(set) var tracks: [URL] = []
    public private(set) var skippedFiles: [URL] = []
    public private(set) var pendingAnalysis = 0
    public private(set) var problem: String?
    public var settings: Settings {
        didSet {
            machine.settings = settings
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "settings")
        }
    }

    @ObservationIgnored private let engine: AVAudioEngine
    @ObservationIgnored private let deck = AVAudioPlayerNode()
    @ObservationIgnored private let mixer = AVAudioMixerNode()
    @ObservationIgnored private let logURL: URL?
    @ObservationIgnored private let libraryURL: URL?
    @ObservationIgnored var library = Library()
    @ObservationIgnored private var machine: Machine
    @ObservationIgnored private var shuffler = Shuffler()
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var trackGain = 1.0
    @ObservationIgnored private var lastTrack: Track?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var needsReschedule = false
    @ObservationIgnored private var pausedForSleep = false
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchedPaths: [String] = []

    /// `storage` holds library.json and plays.jsonl; tests pass nil to keep nothing on disk.
    public init(engine: AVAudioEngine = AVAudioEngine(), storage: URL? = .applicationSupportDirectory.appending(path: "Sottova")) {
        let saved = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        settings = saved ?? Settings()
        machine = Machine(settings: saved ?? Settings())
        self.engine = engine
        logURL = storage?.appending(path: "plays.jsonl")
        libraryURL = storage?.appending(path: "library.json")
        engine.attach(deck)
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        _ = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
        loadLibrary()
        if let logURL {
            shuffler.recent = PlayRecord.recentFiles(in: logURL)
        }
    }

    /// Starts the 100 Hz envelope clock and the first scan. Tests skip this and call `advance` themselves.
    public func run() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(10))
                let now = clock.now
                self?.advance((now - last) / .seconds(1))
                last = now
            }
        }
        rescan()
    }

    public func addFolders(_ urls: [URL]) {
        for url in urls where !library.folders.contains(where: { $0.path == url.path }) {
            do {
                library.folders.append(Library.Folder(bookmark: try url.bookmarkData(), path: url.path))
            } catch {
                problem = "couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        rescan()
    }

    public func removeFolder(_ url: URL) {
        library.folders.removeAll { $0.path == url.path }
        rescan()
    }

    public func rescan() {
        let urls = library.resolveFolders()
        folders = urls
        let paths = urls.map(\.path)
        if paths != watchedPaths {
            watchedPaths = paths
            // hop out of the FSEvents callback before rescanning, since a rescan may replace this watcher
            watcher = FolderWatcher(paths: paths) { [weak self] in
                Task { self?.rescan() }
            }
        }
        scanGeneration += 1
        let generation = scanGeneration
        Task {
            let found = await Task.detached(priority: .utility) { Library.scan(urls) }.value
            guard generation == scanGeneration else { return }
            library.merge(found)
            refreshTracks()
            saveLibrary()
            analyzePending()
        }
    }

    public func toggle() {
        switch status {
        case .idle:
            guard !tracks.isEmpty else { return }
            failures = 0
            send(.start)
        case .paused:
            send(.resume)
        case .playing, .resting:
            send(.pause)
        }
    }

    public func skip() {
        send(.skip)
    }

    public func systemWillSleep() {
        guard status == .playing || status == .resting else { return }
        pausedForSleep = true
        send(.pause)
    }

    public func systemDidWake() {
        guard pausedForSleep else { return }
        pausedForSleep = false
        send(.resume)
    }

    func advance(_ seconds: Double) {
        send(.tick(seconds))
    }

    var deckGain: Float {
        mixer.outputVolume
    }

    /// The playing track, or the last one during a gap. Not observed: it changes 100 times a second, so views poll it.
    public var track: Track? {
        lastTrack
    }

    func refreshTracks() {
        tracks = library.playable.map { URL(filePath: $0) }
        skippedFiles = library.unplayable.map { URL(filePath: $0) }
        pendingAnalysis = library.pending.count
    }

    private func send(_ event: Machine.Event) {
        for effect in machine.handle(event) {
            perform(effect)
        }
        if case .track(let track) = machine.phase {
            lastTrack = track
        }
        let new = machine.status
        guard new != status else { return }
        status = new
        nextTrackAt = machine.restRemaining.map { Date(timeIntervalSinceNow: $0) }
        keepAwake(new == .playing || new == .resting)
    }

    private func perform(_ effect: Machine.Effect) {
        switch effect {
        case .startNextTrack:
            startNextTrack()
        case .setGain(let gain):
            // above 1 boosts: measured on macOS 26 despite the documented 0–1 range, and covered by RenderTests
            mixer.outputVolume = Float(gain * trackGain)
        case .stopTrack(let skipped):
            deck.stop()
            // Apple recommends pausing an idle engine; it also drops coreaudiod's sleep assertion, hence keepAwake
            engine.pause()
            log(skipped: skipped)
        case .pausePlayback:
            deck.pause()
            engine.pause()
        case .resumePlayback:
            do {
                try engine.start()
            } catch {
                problem = "couldn't restart audio output: \(error.localizedDescription)"
                return
            }
            if needsReschedule {
                reschedule()
            }
            deck.play()
        }
    }

    private func startNextTrack() {
        guard let path = shuffler.next(from: tracks.map(\.path), using: &rng) else {
            send(.stop)
            return
        }
        let url = URL(filePath: path)
        do {
            let file = try AVAudioFile(forReading: url)
            deck.stop()
            mixer.outputVolume = 0
            engine.connect(deck, to: mixer, format: file.processingFormat)
            try engine.start()
            deck.scheduleFile(file, at: nil, completionHandler: nil)
            deck.play()
            self.file = file
            // tracks not analyzed yet play at a provisional −6 dB
            trackGain = pow(10, (library.entries[path]?.loudness?.gainDb ?? -6) / 20)
            title = url.deletingPathExtension().lastPathComponent
            startedAt = Date()
            failures = 0
            problem = nil
            send(.trackStarted(duration: Double(file.length) / file.processingFormat.sampleRate))
        } catch {
            failures += 1
            // ponytail: gives up after as many failures in a row as there are tracks, not after trying each one
            guard failures < tracks.count else {
                problem = "couldn't play anything in your folders: \(error.localizedDescription)"
                send(.stop)
                return
            }
            send(.trackFailed)
        }
    }

    private func analyzePending() {
        let pending = library.pending
        guard analysis == nil, !pending.isEmpty else { return }
        analysis = Task {
            await withTaskGroup(of: (String, Loudness?).self) { group in
                var queue = pending[...]
                func addNext() {
                    guard let path = queue.popFirst() else { return }
                    group.addTask(priority: .utility) { (path, try? Loudness.measure(URL(filePath: path))) }
                }
                for _ in 0..<Self.analysisWidth {
                    addNext()
                }
                var unsaved = 0
                for await (path, loudness) in group {
                    if library.entries[path] != nil {
                        if let loudness {
                            library.entries[path]?.loudness = loudness
                        } else {
                            library.entries[path]?.unplayable = true
                            refreshTracks()
                        }
                    }
                    pendingAnalysis = max(0, pendingAnalysis - 1)
                    unsaved += 1
                    if unsaved == 50 {
                        saveLibrary()
                        unsaved = 0
                    }
                    addNext()
                }
            }
            saveLibrary()
            pendingAnalysis = library.pending.count
            analysis = nil
            // files may have arrived while this pass ran
            analyzePending()
        }
    }

    /// Performance cores minus one, so analysis never takes the whole machine.
    private static var analysisWidth: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0)
        return max(1, Int(cores) - 1)
    }

    private func loadLibrary() {
        guard let libraryURL else { return }
        do {
            library = try Library.load(from: libraryURL)
        } catch {
            // keep the unreadable file for inspection instead of overwriting it on the next save
            let aside = libraryURL.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: libraryURL, to: aside)
            problem = "couldn't read the library, moved it to library.json.broken and started fresh: \(error.localizedDescription)"
        }
        refreshTracks()
    }

    private func saveLibrary() {
        guard let libraryURL else { return }
        do {
            try library.save(to: libraryURL)
        } catch {
            problem = "couldn't save the library: \(error.localizedDescription)"
        }
    }

    /// The engine stops and drops scheduled audio on a device change, so pause and pick up from the same frame on resume.
    private func engineConfigurationChanged() {
        guard status == .playing else { return }
        needsReschedule = true
        send(.pause)
    }

    private func reschedule() {
        needsReschedule = false
        guard let file, case .track(let track) = machine.phase else { return }
        let start = AVAudioFramePosition(track.elapsed * file.processingFormat.sampleRate)
        guard start < file.length else { return }
        deck.stop()
        deck.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil, completionHandler: nil)
    }

    private func log(skipped: Bool) {
        guard let logURL, let file else { return }
        let record = PlayRecord(file: file.url.path, startedAt: startedAt, skipped: skipped, gapAfterSec: machine.restRemaining ?? 0)
        do {
            try record.append(to: logURL)
        } catch {
            problem = "couldn't write the play log: \(error.localizedDescription)"
        }
    }

    /// The engine is paused during gaps, so nothing else stops idle sleep there.
    private func keepAwake(_ on: Bool) {
        if on, assertion == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "sottova: waiting for the next track" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertion = id
            }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
