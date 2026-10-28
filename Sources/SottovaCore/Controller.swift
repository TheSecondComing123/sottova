import AVFoundation
import IOKit.pwr_mgt
import Observation
import UniformTypeIdentifiers

/// Runs the machine's effects against the audio engine. Main-actor bound: the work per tick is one volume write.
@MainActor @Observable
public final class Controller {
    public private(set) var status = PlaybackStatus.idle
    public private(set) var title: String?
    public private(set) var nextTrackAt: Date?
    public internal(set) var tracks: [URL] = []
    public private(set) var skippedFiles: [URL] = []
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
    @ObservationIgnored private var machine: Machine
    @ObservationIgnored private var bag: [URL] = []
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var lastTrack: Track?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var needsReschedule = false
    @ObservationIgnored private var pausedForSleep = false
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(engine: AVAudioEngine = AVAudioEngine(), logURL: URL? = .applicationSupportDirectory.appending(path: "Sottova/plays.jsonl")) {
        let saved = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        settings = saved ?? Settings()
        machine = Machine(settings: saved ?? Settings())
        self.engine = engine
        self.logURL = logURL
        engine.attach(deck)
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        _ = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    /// Starts the 100 Hz envelope clock. Tests skip this and call `advance` themselves.
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
    }

    public func load(folder: URL) async {
        let (playable, skipped) = await Task.detached { Self.scan(folder) }.value
        tracks = playable
        skippedFiles = skipped
        bag = []
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
            mixer.outputVolume = Float(gain)
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
        if bag.isEmpty {
            bag = tracks.shuffled()
        }
        guard let url = bag.popLast() else {
            send(.stop)
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            deck.stop()
            mixer.outputVolume = 0
            engine.connect(deck, to: mixer, format: file.processingFormat)
            try engine.start()
            deck.scheduleFile(file, at: nil, completionHandler: nil)
            deck.play()
            self.file = file
            title = url.deletingPathExtension().lastPathComponent
            startedAt = Date()
            failures = 0
            problem = nil
            send(.trackStarted(duration: Double(file.length) / file.processingFormat.sampleRate))
        } catch {
            failures += 1
            // ponytail: gives up after as many failures in a row as there are tracks, not after trying each one
            guard failures < tracks.count else {
                problem = "couldn't play anything in this folder: \(error.localizedDescription)"
                send(.stop)
                return
            }
            send(.trackFailed)
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

    nonisolated private static func scan(_ folder: URL) -> ([URL], [URL]) {
        var playable: [URL] = []
        var skipped: [URL] = []
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else { continue }
            if (try? AVAudioFile(forReading: url)) != nil {
                playable.append(url)
            } else {
                skipped.append(url)
            }
        }
        return (playable, skipped)
    }
}
