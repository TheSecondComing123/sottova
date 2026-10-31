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
    /// The last thing that went wrong, until something works again or it's dismissed.
    public var problem: String?
    public private(set) var catalog = Catalog()
    public private(set) var current: Song?
    public private(set) var recent: [Song] = []
    public var volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            engine.mainMixerNode.outputVolume = Float(volume)
        }
    }
    public let artwork: ArtworkStore?
    public var settings: Settings {
        didSet {
            // editing any field of a preset turns it into Custom; this re-enters didSet once
            if settings.name != "Custom", !settings.matchesPreset {
                settings.name = "Custom"
            }
            machine.settings = settings
            saveProfile()
        }
    }
    /// Albums that play with their own gaps and fades, by album id.
    public var albumSettings: [String: Settings] = [:] {
        didSet {
            saveProfile()
            // a change to the album that's playing takes effect now
            if let playingAlbum {
                useAlbumSettings(for: playingAlbum)
            }
        }
    }
    /// While an album plays with its own gaps: which one, the user's settings to go back to, and what the album put in their place.
    @ObservationIgnored private var playingAlbum: String?
    @ObservationIgnored private var ownSettings: Settings?
    @ObservationIgnored private var albumApplied: Settings?
    /// The user's own settings, even while an album plays with its own gaps in their place.
    public var yourSettings: Settings {
        ownSettings != nil && settings == albumApplied ? ownSettings! : settings
    }
    public var keepsMacAwake = UserDefaults.standard.object(forKey: "keepsMacAwake") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepsMacAwake, forKey: "keepsMacAwake")
            keepAwake(wantsAwake)
        }
    }
    public var acceptsURLs = UserDefaults.standard.object(forKey: "acceptsURLs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(acceptsURLs, forKey: "acceptsURLs") }
    }

    @ObservationIgnored private let engine: AVAudioEngine
    @ObservationIgnored private let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    @ObservationIgnored private let mixers = [AVAudioMixerNode(), AVAudioMixerNode()]
    /// Which deck plays the current track; the other one only carries a crossfade's outgoing track.
    @ObservationIgnored private var active = 0
    @ObservationIgnored private let storage: URL?
    @ObservationIgnored var library = Library()
    @ObservationIgnored private(set) var machine: Machine
    @ObservationIgnored private var shuffler = Shuffler()
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var trackGain = 1.0
    @ObservationIgnored private var outgoingGain = 1.0
    @ObservationIgnored private var lastTrack: Track?
    @ObservationIgnored private(set) var startedAt = Date()
    @ObservationIgnored private var failures = 0
    /// False when an unreadable profile.json couldn't be moved aside: saving would overwrite it.
    @ObservationIgnored private var profileWritable = true
    @ObservationIgnored private var needsReschedule = false
    @ObservationIgnored private var pausedForSleep = false
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastTick: ContinuousClock.Instant?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchedPaths: [String] = []
    @ObservationIgnored private var nowPlaying: NowPlaying?
    /// Songs the listener picked, played in order before shuffle takes over again.
    public private(set) var playlists: [Playlist] = []
    @ObservationIgnored private let playlistStore: PlaylistStore?
    @ObservationIgnored private var playlistWatcher: FolderWatcher?

    /// What plays next, in order; once it's empty the shuffler picks from everything. Read it only where it's shown:
    /// playing from Songs puts the whole library in it.
    public private(set) var upNext: [QueueEntry] = []
    @ObservationIgnored private var lastCatalogBuild = Date.distantPast
    @ObservationIgnored private var catalogEntries: [String: Library.Entry] = [:]
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var saving: Task<Void, Never>?

    /// `storage` holds library.json, profile.json, status.json and plays.jsonl; tests pass nil to keep nothing on disk.
    /// `playlistFolder` holds the .m3u8 files; nil keeps playlists in memory only.
    public init(engine: AVAudioEngine = AVAudioEngine(), storage: URL? = .applicationSupportDirectory.appending(path: "Sottova"),
                playlistFolder: URL? = nil) {
        self.engine = engine
        self.storage = storage
        playlistStore = playlistFolder.map(PlaylistStore.init)
        artwork = storage.map { _ in ArtworkStore(directory: .cachesDirectory.appending(path: "Sottova/Artwork")) }
        let (file, unreadable, writable) = Self.loadProfile(from: storage)
        profileWritable = writable
        let profile = file?.settings ?? Settings.presets.first { $0.name == "Short" }!
        settings = profile
        albumSettings = file?.albums ?? [:]
        machine = Machine(settings: profile)
        // Both decks are wired once with a fixed format; the player converts each file to it.
        // A player connected while the engine runs starts late, by about 8% of the time the engine has been running.
        let deckFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for (player, mixer) in zip(players, mixers) {
            engine.attach(player)
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: nil)
            engine.connect(player, to: mixer, format: deckFormat)
            mixer.outputVolume = 0
        }
        _ = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
        engine.mainMixerNode.outputVolume = Float(volume)
        if let storage {
            // avoid-last-N survives a relaunch
            shuffler.recent = PlayRecord.read(storage.appending(path: "plays.jsonl"), last: 20).map(\.file)
        }
        problem = unreadable
        loadLibrary()
        loadPlaylists()
    }

    /// Starts the envelope clock, media keys and the first scan. Tests skip this and call `advance` themselves.
    public func run() {
        guard ticker == nil else { return }
        lastTick = .now
        startTicker()
        nowPlaying = NowPlaying(controller: self)
        // alarms first: a piece restored mid-hour goes on being the hour's
        loadAlarms()
        restoreResume()
        loadTrims()
        publish()
        rescan()
    }

    /// Ticks at 100 Hz only while a gain is moving. Holding a track, resting or paused it sleeps up to 500 ms,
    /// which brought playback from about 2.5% CPU down to the 1% decoding floor.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tickInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.catchUp()
                // here, not in catchUp, which a command runs first: an hour starting there would swallow a press of play
                if let self, Date.now.timeIntervalSince(lastHourCheck) >= 5 {
                    checkHours()
                }
            }
        }
    }

    private var tickInterval: Duration {
        let envelope = envelopeInterval
        // the sleep timer's ease-down moves the gain too: at 10 Hz its steps are 0.03 dB; an alarm's rise, 0.07 dB
        guard status == .playing else { return envelope }
        if machine.rise != nil { return min(envelope, .milliseconds(100)) }
        guard case .timer(let left, let fade)? = machine.sleep else { return envelope }
        return min(envelope, .milliseconds(Int(max(0.1, left - fade) * 1000)))
    }

    private var envelopeInterval: Duration {
        guard status == .playing, machine.outgoing == nil, case .track(let track) = machine.phase else {
            return status == .playing ? .milliseconds(10) : .milliseconds(500)
        }
        let holdLeft = track.steady(from: track.elapsed) - 0.5
        guard holdLeft > 0.01 else { return .milliseconds(10) }
        return .milliseconds(Int(min(0.5, holdLeft) * 1000))
    }

    private func catchUp() {
        guard let lastTick else { return }
        let now = ContinuousClock.now
        self.lastTick = now
        advance((now - lastTick) / .seconds(1))
    }

    /// A skip or pause mid-hold must not wait for the slow tick: bring the clock up to now, act, then restart the clock.
    private func command(_ event: Machine.Event) {
        catchUp()
        send(event)
        if ticker != nil {
            startTicker()
        }
    }

    /// Switches mode and keeps the loudness the user set.
    public func apply(_ preset: Settings) {
        var preset = preset
        (preset.targetLufs, preset.ceilingDbtp) = (settings.targetLufs, settings.ceilingDbtp)
        settings = preset
    }

    /// Plays these songs in order from `index`, with the usual fades and gaps, then goes back to shuffling everything.
    /// What the queue was started from (an album, playlist, page) and whether shuffled, so that page's play button
    /// can show it's the one playing. Cleared when the queue runs out.
    public struct Origin: Equatable, Sendable {
        public let key: String
        public let shuffled: Bool

        public init(key: String, shuffled: Bool) {
            self.key = key
            self.shuffled = shuffled
        }

        /// A playlist by its id; anything else by which songs it holds, whatever their order, so a song clicked in
        /// a list and that page's play button agree.
        public static func key(of songs: [Song], source: String?) -> String {
            source ?? String(Set(songs.map(\.id)).hashValue)
        }
    }

    public private(set) var origin: Origin?

    /// `source` is a playlist id, whose gaps the songs play with; without one, songs from one album play with its gaps.
    public func play(_ songs: [Song], from index: Int = 0, source: String? = nil, shuffled: Bool = false) {
        guard songs.indices.contains(index) else { return }
        releaseHour()
        origin = Origin(key: Origin.key(of: songs, source: source), shuffled: shuffled)
        let source = source ?? Self.source(of: songs)
        upNext = songs[index...].map { QueueEntry(path: $0.id, source: source) }
        if status == .idle {
            failures = 0
            command(.start)
        } else {
            // fades the current track out over a second (resuming it for that second if paused); from a gap it starts right away
            command(.skip)
        }
    }

    /// An album with its own gaps plays with them; anything else goes back to the user's own settings, unless they
    /// changed them by hand while the album played, in which case their change stays.
    func useAlbumSettings(for id: String?) {
        let untouched = ownSettings != nil && settings == albumApplied
        if let id, let album = albumSettings[id] ?? playlists.first(where: { $0.id == id })?.gaps {
            let own = yourSettings
            playingAlbum = id
            ownSettings = own
            albumApplied = album.gaps(over: own)
            settings = albumApplied!
            // didSet can rename the result Custom, which the comparison above has to see
            albumApplied = settings
            saveProfile()
        } else if ownSettings != nil {
            if untouched {
                settings = ownSettings!
            }
            playingAlbum = nil
            ownSettings = nil
            albumApplied = nil
        }
    }

    public func playNext(_ songs: [Song], source: String? = nil) {
        let source = source ?? Self.source(of: songs)
        upNext.insert(contentsOf: songs.map { QueueEntry(path: $0.id, source: source) }, at: 0)
    }

    // MARK: Alarms

    public private(set) var alarms: [Alarm] = []
    /// The main window's, so Edit › Undo brings back what was removed.
    @ObservationIgnored public weak var undo: UndoManager?
    @ObservationIgnored private var alarmTimer: DispatchSourceTimer?
    /// Held while an alarm is set: an idle menu-bar app gets App Nap, which may hold its timers back.
    @ObservationIgnored private var alarmActivity: NSObjectProtocol?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions?

    public func addAlarm(_ alarm: Alarm) {
        alarms.append(alarm)
        alarmsChanged()
    }

    /// Saves an edited alarm in its place.
    public func updateAlarm(_ alarm: Alarm) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i] = alarm
        alarmsChanged()
    }

    public func removeAlarm(_ id: Alarm.ID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        let alarm = alarms.remove(at: i)
        alarmsChanged()
        undo?.registerUndo(withTarget: self) { $0.insertAlarm(alarm, at: i) }
        undo?.setActionName("Delete \(alarm.name)")
    }

    private func insertAlarm(_ alarm: Alarm, at i: Int) {
        alarms.insert(alarm, at: min(i, alarms.count))
        alarmsChanged()
        undo?.registerUndo(withTarget: self) { $0.removeAlarm(alarm.id) }
    }

    /// The soonest alarm that starts by itself and when it goes off.
    public func nextAlarm(after now: Date = .now) -> (alarm: Alarm, at: Date)? {
        alarms.filter { $0.on && !$0.whileHere }.compactMap { alarm in alarm.next(after: now).map { (alarm, $0) } }.min { $0.1 < $1.1 }
    }

    private func alarmsChanged() {
        if let url = storage?.appending(path: "alarms.json") {
            do {
                try JSONEncoder().encode(alarms).write(to: url, options: .atomic)
            } catch {
                problem = "couldn't save the alarms: \(error.localizedDescription)"
            }
        }
        armAlarm()
    }

    private func loadAlarms() {
        guard let url = storage?.appending(path: "alarms.json"), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Alarm].self, from: data) else { return }
        // a one-off whose time passed while the app was closed is dropped, not played late
        alarms = saved.filter { $0.next(after: .now) != nil || $0.whileHere && $0.window(containing: .now) != nil }
        if alarms != saved {
            alarmsChanged()
        } else {
            armAlarm()
        }
    }

    /// One timer for the soonest alarm, on the wall clock: it still fires on time after the Mac has slept, and
    /// `.strict` keeps App Nap from sliding it while the app sits idle in the menu bar.
    private func armAlarm() {
        alarmTimer?.cancel()
        alarmTimer = nil
        let next = nextAlarm()
        // an alarm keeps the app awake to its timer and the Mac from sleeping when idle (the screen still turns off);
        // an hour only needs its checks on time, since it plays only while you're there
        let wanted: ProcessInfo.ActivityOptions? = next != nil ? .userInitiated
            : alarms.contains { $0.on && $0.whileHere } ? .userInitiatedAllowingIdleSystemSleep : nil
        if wanted != activityOptions {
            alarmActivity.map(ProcessInfo.processInfo.endActivity)
            alarmActivity = wanted.map { ProcessInfo.processInfo.beginActivity(options: $0, reason: next != nil ? "an alarm is set" : "an hour is set") }
            activityOptions = wanted
        }
        guard let (alarm, at) = next else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + max(at.timeIntervalSinceNow, 0), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fire(alarm.id, due: at) }
        }
        timer.resume()
        alarmTimer = timer
    }

    /// How late an alarm may still start: a Mac that slept through it and wakes at noon stays quiet.
    static let alarmLateness: TimeInterval = 10 * 60

    /// A shuffled alarm doesn't open with what an alarm opened with at the same time on any of the last seven days:
    /// those pieces move back from the front of the order, as long as something else is left to go first.
    nonisolated static func alarmOrder(_ songs: [Song], at alarm: Alarm, due: Date, history: [PlayRecord],
                           calendar: Calendar = .current, using rng: inout some RandomNumberGenerator) -> [Song] {
        let opened = Set(history.filter { record in
            (1...7).contains { back in
                guard let day = calendar.date(byAdding: .day, value: -back, to: due),
                      let then = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: day) else { return false }
                return (0..<120).contains(record.startedAt.timeIntervalSince(then))
            }
        }.map(\.file))
        var order = songs.shuffled(using: &rng)
        if let fresh = order.firstIndex(where: { !opened.contains($0.id) }) {
            order.insert(order.remove(at: fresh), at: 0)
        }
        return order
    }

    func fire(_ id: Alarm.ID, due: Date, now: Date = .now) {
        guard let alarm = alarms.first(where: { $0.id == id }) else { return }
        let songs = songs(for: alarm)
        if now.timeIntervalSince(due) > Self.alarmLateness {
            problem = "the \(alarm.name) alarm didn't play: the mac was asleep at \(due.formatted(date: .omitted, time: .shortened))"
        } else if !songs.isEmpty {
            if let volume = alarm.volume { self.volume = volume }
            let playlist = playlists.contains { $0.id == alarm.source } ? alarm.source : nil
            let history = storage.map { PlayRecord.read($0.appending(path: "plays.jsonl"), last: 2000) } ?? []
            play(alarm.shuffled ? Self.alarmOrder(songs, at: alarm, due: due, history: history, using: &rng) : songs,
                 source: playlist, shuffled: alarm.shuffled)
            if status == .paused { toggle() }
            command(.rise)
            if let minutes = alarm.minutes { sleep(minutes: Double(minutes)) }
        } else {
            problem = "the \(alarm.name) alarm went off, but there's nothing in it to play"
        }
        if alarm.weekdays.isEmpty {
            alarms.removeAll { $0.id == id }
            alarmsChanged()
        } else {
            armAlarm()
        }
    }

    private func songs(for alarm: Alarm) -> [Song] {
        playlists.first { $0.id == alarm.source }.map(songs(of:)) ?? catalog.albumsByID[alarm.source]?.songs ?? []
    }

    // MARK: Hours

    /// The alarm that plays while you're at the Mac whose collection is playing; nil once anything else is played.
    @ObservationIgnored private var hourPlaying: Alarm.ID?
    /// Where each hour's last window began, so one stopped by hand doesn't start again until its next window.
    @ObservationIgnored private var hourBegun: [Alarm.ID: Date] = [:]
    @ObservationIgnored private var lastHourCheck = Date.distantPast
    /// The stop after this piece is the hour's, not yours, so whatever you play next isn't cut short by it.
    @ObservationIgnored private var hourEnding = false
    /// Reads the Mac for a reason to wait; tests put their own in.
    @ObservationIgnored var presence: @MainActor () -> Hold? = { Presence.hold() }
    /// Why the next piece of an hour is waiting.
    public private(set) var hold: Hold?

    /// Starts an hour from silence when its window opens and nothing else is playing, moves to the next hour without
    /// cutting the piece, ends with the piece playing as the window closes, and holds the next piece while you're
    /// away, on a call or listening to something else.
    func checkHours(now: Date = .now) {
        lastHourCheck = now
        let current = alarms.first { $0.on && $0.whileHere && $0.window(containing: now) != nil }
        if let id = hourPlaying, id != current?.id {
            hourPlaying = nil
            if let current, status != .idle {
                follow(current, now: now)
            } else {
                upNext.removeAll()
                origin = nil
                // paused counts too: a lid closed mid-hour and opened tomorrow mustn't carry on with everything
                if case .resting = machine.phase {
                    send(.stop)
                } else if status != .idle {
                    sleepAfterCurrent()
                    hourEnding = true
                }
            }
        }
        if hourPlaying == nil, let current, status == .idle, let window = current.window(containing: now), hourBegun[current.id] != window.start {
            let songs = songs(for: current)
            hourBegun[current.id] = window.start
            if songs.isEmpty {
                problem = "\(current.name) has nothing in it to play"
            } else {
                hourPlaying = current.id
                queue(current, songs)
                failures = 0
                // out of silence, but not a long one
                send(.wait(Double.random(in: 10...45, using: &rng)))
            }
        }
        // a one-off whose window has closed is done
        let over = alarms.filter { $0.whileHere && $0.weekdays.isEmpty && $0.next(after: now) == nil && $0.window(containing: now) == nil }
        if !over.isEmpty {
            alarms.removeAll { alarm in over.contains { $0.id == alarm.id } }
            alarmsChanged()
        }
        setHold(hourPlaying == nil || status == .idle ? nil : presence())
    }

    /// The next hour takes over from the one playing: its collection is next, and a silence already under way can only
    /// get shorter.
    private func follow(_ hour: Alarm, now: Date) {
        hourPlaying = hour.id
        hourBegun[hour.id] = hour.window(containing: now)?.start
        queue(hour, songs(for: hour))
        if case .resting(let elapsed, let gap) = machine.phase {
            send(.gap(elapsed + min(gap - elapsed, Double.random(in: gapRange(beforeNext: upNext.first), using: &rng))))
            refreshNextTrack()
            publish()
        }
    }

    /// The hour's collection as what plays next, at its volume; shuffled, the piece just heard goes last.
    private func queue(_ hour: Alarm, _ songs: [Song]) {
        var order = hour.shuffled ? songs.shuffled(using: &rng) : songs
        if hour.shuffled, let last = file?.url.path, let i = order.firstIndex(where: { $0.id == last }) {
            order.append(order.remove(at: i))
        }
        upNext = order.map { QueueEntry(path: $0.id, source: hour.source) }
        let playlist = playlists.contains { $0.id == hour.source } ? hour.source : nil
        origin = Origin(key: Origin.key(of: songs, source: playlist), shuffled: hour.shuffled)
        if let volume = hour.volume { self.volume = volume }
    }

    /// An hour that's played through its collection goes round again.
    private func refillHour() -> Bool {
        guard let hour = alarms.first(where: { $0.id == hourPlaying }) else { return false }
        let songs = songs(for: hour)
        guard !songs.isEmpty else { return false }
        queue(hour, songs)
        return true
    }

    /// Something played by hand or by an alarm takes over from the hour.
    private func releaseHour() {
        hourPlaying = nil
        setHold(nil)
        if hourEnding {
            hourEnding = false
            cancelSleep()
        }
    }

    private func setHold(_ new: Hold?) {
        guard new != hold else { return }
        hold = new
        send(.hold(new != nil))
        refreshNextTrack()
        keepAwake(wantsAwake)
        publish()
    }

    /// When the silence ends; none while it's held.
    private func refreshNextTrack() {
        nextTrackAt = hold == nil ? machine.restRemaining.map { Date(timeIntervalSinceNow: $0) } : nil
    }

    /// The engine is paused during gaps, so nothing else stops idle sleep there; a held silence lets the Mac sleep.
    private var wantsAwake: Bool {
        keepsMacAwake && (status == .playing || status == .resting) && hold == nil
    }

    /// What brings a file to the target loudness, as a multiplier; tracks not analyzed yet play at a provisional −6 dB.
    public func gain(of path: String) -> Double {
        pow(10, (library.entries[path]?.loudness?.gainDb(target: settings.targetLufs, ceiling: settings.ceilingDbtp) ?? -6) / 20)
    }

    // MARK: Trims

    /// By file path; saved in trims.json, the audio files are never touched.
    public private(set) var trims: [String: Trim] = [:]
    /// The frames of the file on deck that play, past its trim.
    @ObservationIgnored private var span: (start: Int64, end: Int64) = (0, 0)

    /// Takes effect the next time the song starts; nil plays the whole file again.
    public func setTrim(_ trim: Trim?, for path: String) {
        trims[path] = trim
        guard let url = storage?.appending(path: "trims.json") else { return }
        do {
            try JSONEncoder().encode(trims).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't save the trim: \(error.localizedDescription)"
        }
    }

    private func loadTrims() {
        guard let url = storage?.appending(path: "trims.json"), let data = try? Data(contentsOf: url) else { return }
        trims = (try? JSONDecoder().decode([String: Trim].self, from: data)) ?? [:]
    }

    /// Sets `span` for the file and returns how long that part plays.
    private func useSpan(of file: AVAudioFile) -> Double {
        let rate = file.processingFormat.sampleRate
        span = (trims[file.url.path] ?? Trim()).frames(sampleRate: rate, length: file.length)
        return Double(span.end - span.start) / rate
    }

    // MARK: Covers

    /// Art keys for playlists with a picture beside their file.
    public private(set) var playlistCovers: [String: String] = [:]

    /// Writes cover.jpg into the album's folder (an old one goes to the Trash) and reads the album's art again.
    /// Art embedded in the files still wins over it.
    public func setCover(_ data: Data, credit: String?, forAlbum id: String) {
        guard let album = catalog.albumsByID[id], let first = album.songs.first else { return }
        let url = URL(filePath: first.id).deletingLastPathComponent().appending(path: "cover.jpg")
        guard replaceCover(at: url, with: data, credit: credit) else { return }
        for song in album.songs {
            library.entries[song.id]?.meta = nil
        }
        analyzePending()
    }

    /// Writes the picture beside the playlist's file, as "<name>.jpg".
    public func setCover(_ data: Data, credit: String?, forPlaylist id: String) {
        guard replaceCover(at: Self.coverURL(forPlaylist: id), with: data, credit: credit) else { return }
        loadPlaylistCovers()
    }

    public static func coverURL(forPlaylist id: String) -> URL {
        URL(filePath: id).deletingPathExtension().appendingPathExtension("jpg")
    }

    private func replaceCover(at url: URL, with data: Data, credit: String?) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            try CoverFile.write(data, to: url, credit: credit)
            return true
        } catch {
            problem = "couldn't save the cover: \(error.localizedDescription)"
            return false
        }
    }

    private func loadPlaylistCovers() {
        var covers: [String: String] = [:]
        for playlist in playlists {
            if let data = try? Data(contentsOf: Self.coverURL(forPlaylist: playlist.id)), let key = artwork?.save(data) {
                covers[playlist.id] = key
            }
        }
        if covers != playlistCovers {
            playlistCovers = covers
        }
    }

    // MARK: Resume

    /// resume.json: the piece and how far in (or the gap's time left), what's queued, and whose gaps are playing.
    struct ResumeState: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var path: String
            var source: String?
        }

        var path: String
        var elapsed: Double?
        var restLeft: Double?
        var source: String?
        var upNext: [Entry]
        /// The hour this was playing for, if any.
        var hour: UUID?
    }

    /// Brings the clock up to now and saves, for when the app quits.
    public func quitting() {
        catchUp()
        saveResume()
    }

    /// Written on every status change, new piece and seek; removed once playback stops.
    func saveResume() {
        guard let url = storage?.appending(path: "resume.json") else { return }
        let path = file?.url.path
        let state: ResumeState?
        switch machine.phase {
        case .track(let track): state = path.map { ResumeState(path: $0, elapsed: track.elapsed, restLeft: nil, source: playingAlbum, upNext: []) }
        case .resting: state = path.map { ResumeState(path: $0, elapsed: nil, restLeft: machine.restRemaining, source: playingAlbum, upNext: []) }
        case .idle: state = nil
        // a moment between pieces; the next status change saves
        case .loading: return
        }
        guard var state else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        state.upNext = upNext.map { ResumeState.Entry(path: $0.path, source: $0.source) }
        state.hour = hourPlaying
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't save where playback is: \(error.localizedDescription)"
        }
    }

    /// Picks up where the last run left off, paused: the same piece at the same spot (it fades back in on play), or
    /// the same gap with the same time left.
    func restoreResume() {
        guard status == .idle, let url = storage?.appending(path: "resume.json"), let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data) else { return }
        let fileURL = URL(filePath: state.path)
        guard let file = try? AVAudioFile(forReading: fileURL) else {
            problem = "couldn't pick up where you left off: \(fileURL.lastPathComponent) isn't there anymore"
            try? FileManager.default.removeItem(at: url)
            return
        }
        upNext = state.upNext.map { QueueEntry(path: $0.path, source: $0.source) }
        // still the hour's while its window is open; past it, the next check ends it like any closing window
        if let id = state.hour, let window = alarms.first(where: { $0.id == id })?.window(containing: .now) {
            hourPlaying = id
            hourBegun[id] = window.start
        }
        useAlbumSettings(for: state.source)
        self.file = file
        current = catalog.songsByID[state.path]
        title = current?.title ?? fileURL.deletingPathExtension().lastPathComponent
        trackGain = gain(of: state.path)
        startedAt = Date()
        if let elapsed = state.elapsed {
            // scheduled from that frame when play is pressed, like after a device change
            needsReschedule = true
            send(.restoreTrack(duration: useSpan(of: file), at: elapsed))
        } else {
            send(.restoreRest(left: state.restLeft ?? 0))
        }
    }

    // MARK: Playlists

    /// Albums turned into playlists, which the Albums page leaves out.
    public var albumsInPlaylists: Set<String> {
        Set(playlists.compactMap(\.fromAlbum))
    }

    public func songs(of playlist: Playlist) -> [Song] {
        playlist.paths.compactMap { catalog.songsByID[$0] }
    }

    /// A new playlist named `name`, or "name 2" when that's taken. Returns its id.
    @discardableResult
    public func newPlaylist(named name: String = "New collection", songs: [Song] = [], fromAlbum: String? = nil) -> String? {
        guard let store = playlistStore else { return nil }
        var candidate = name, n = 2
        while playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) \(n)"
            n += 1
        }
        let playlist = Playlist(id: store.url(for: candidate).path, name: candidate, paths: songs.map(\.id),
                                gaps: fromAlbum.flatMap { albumSettings[$0] }, fromAlbum: fromAlbum)
        guard save(playlist) else { return nil }
        playlists.append(playlist)
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return playlist.id
    }

    /// Adds at the end, or before `index`.
    public func add(_ songs: [Song], to id: String, at index: Int? = nil) {
        update(id) { $0.paths.insert(contentsOf: songs.map(\.id), at: min(index ?? $0.paths.count, $0.paths.count)) }
    }

    public func removeFromPlaylist(_ id: String, at offsets: IndexSet) {
        guard let paths = playlists.first(where: { $0.id == id })?.paths else { return }
        let removed = offsets.filter(paths.indices.contains).map { ($0, paths[$0]) }
        update(id) { $0.paths = $0.paths.enumerated().filter { !offsets.contains($0.offset) }.map(\.element) }
        undo?.registerUndo(withTarget: self) { controller in
            controller.update(id) { playlist in
                for (i, path) in removed { playlist.paths.insert(path, at: min(i, playlist.paths.count)) }
            }
            controller.undo?.registerUndo(withTarget: controller) { $0.removeFromPlaylist(id, at: IndexSet(removed.map(\.0))) }
        }
        undo?.setActionName("Remove from Collection")
    }

    public func movePlaylistSongs(_ id: String, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        update(id) { playlist in
            let moving = offsets.map { playlist.paths[$0] }
            var rest = playlist.paths.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            rest.insert(contentsOf: moving, at: destination - offsets.count { $0 < destination })
            playlist.paths = rest
        }
    }

    public func setGaps(_ gaps: Settings?, for id: String) {
        update(id) { $0.gaps = gaps }
        if playingAlbum == id {
            useAlbumSettings(for: id)
        }
    }

    /// Renames the file too, so the playlist's id changes; queued songs and a playing playlist follow it.
    @discardableResult
    public func rename(_ id: String, to name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = playlistStore, let index = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return nil }
        let url = store.url(for: name)
        guard url.path == id || !FileManager.default.fileExists(atPath: url.path) else {
            problem = "there's already a collection called \(name)"
            return nil
        }
        do {
            try FileManager.default.moveItem(at: URL(filePath: id), to: url)
            // the picture keeps the playlist's name
            try? FileManager.default.moveItem(at: Self.coverURL(forPlaylist: id), to: Self.coverURL(forPlaylist: url.path))
        } catch {
            problem = "couldn't rename \(playlists[index].name): \(error.localizedDescription)"
            return nil
        }
        playlists[index].id = url.path
        playlists[index].name = name
        save(playlists[index])
        repointAlarms(from: id, to: url.path)
        upNext = upNext.map { $0.source == id ? QueueEntry(path: $0.path, source: url.path) : $0 }
        if playingAlbum == id {
            playingAlbum = url.path
        }
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loadPlaylistCovers()
        return url.path
    }

    /// Moves the file to the Trash, where it can be put back.
    public func trashPlaylist(_ id: String) {
        do {
            try FileManager.default.trashItem(at: URL(filePath: id), resultingItemURL: nil)
            try? FileManager.default.trashItem(at: Self.coverURL(forPlaylist: id), resultingItemURL: nil)
            forget(id)
            // what's left pointing at it has nothing to play; the window asks before this happens
            if alarms.contains(where: { $0.source == id }) {
                alarms.removeAll { $0.source == id }
                alarmsChanged()
            }
        } catch {
            problem = "couldn't move the collection to the Trash: \(error.localizedDescription)"
        }
    }

    /// A playlist whose file is gone. One made from an album gives the album back its place, its gaps and its alarms.
    func forget(_ id: String) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        playlists.removeAll { $0.id == id }
        if let album = playlist.fromAlbum {
            albumSettings[album] = playlist.gaps
            repointAlarms(from: id, to: album)
        }
    }

    /// Makes an album yours: a copy you can reorder and add to, with its gaps, cover and alarms, shown in the
    /// album's place. The files stay where they are; library.json and profile.json are backed up first. Returns
    /// the copy's id.
    @discardableResult
    public func makeYours(_ album: Album) -> String? {
        if let copy = playlists.first(where: { $0.fromAlbum == album.id }) { return copy.id }
        backUpData()
        // the playlist file is written before the album's gaps move into it
        guard let id = newPlaylist(named: album.title, songs: album.songs, fromAlbum: album.id) else { return nil }
        albumSettings[album.id] = nil
        if let first = album.songs.first {
            let cover = URL(filePath: first.id).deletingLastPathComponent().appending(path: "cover.jpg")
            if (try? FileManager.default.copyItem(at: cover, to: Self.coverURL(forPlaylist: id))) != nil {
                loadPlaylistCovers()
            }
        }
        repointAlarms(from: album.id, to: id)
        return id
    }

    /// Alarms follow a collection whose id changes: made yours, its copy deleted, renamed.
    private func repointAlarms(from old: String, to new: String) {
        guard alarms.contains(where: { $0.source == old }) else { return }
        let name = playlists.first { $0.id == new }?.name ?? catalog.albumsByID[new]?.title
        for i in alarms.indices where alarms[i].source == old {
            alarms[i].source = new
            if let name { alarms[i].name = name }
        }
        alarmsChanged()
    }

    private func backUpData() {
        guard let storage else { return }
        let backup = storage.appending(path: "backups/\(ISO8601DateFormatter().string(from: .now))")
        try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["library.json", "profile.json"] {
            try? FileManager.default.copyItem(at: storage.appending(path: name), to: backup.appending(path: name))
        }
    }

    private func update(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[index])
        save(playlists[index])
    }

    @discardableResult
    private func save(_ playlist: Playlist) -> Bool {
        guard let store = playlistStore else { return true }
        do {
            try store.write(playlist) { [catalog] path in
                catalog.songsByID[path].map { ($0.duration, "\($0.artist) - \($0.title)") }
            }
            watchPlaylists()
            return true
        } catch {
            problem = "couldn't save \(playlist.name): \(error.localizedDescription)"
            return false
        }
    }

    private func loadPlaylists() {
        guard let store = playlistStore else { return }
        let loaded = store.load()
        if loaded != playlists {
            playlists = loaded
        }
        loadPlaylistCovers()
        watchPlaylists()
    }

    /// Its own stream, so a playlist edit reloads only playlists, never rescans the music. Our own writes come back
    /// here too and change nothing.
    private func watchPlaylists() {
        guard playlistWatcher == nil, let store = playlistStore, FileManager.default.fileExists(atPath: store.folder.path) else { return }
        playlistWatcher = FolderWatcher(paths: [store.folder.path]) { [weak self] in
            Task { self?.loadPlaylists() }
        }
    }

    public func moveQueued(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        // List's move(fromOffsets:) lives in SwiftUI, which Core doesn't link
        let moving = offsets.map { upNext[$0] }
        var rest = upNext.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - offsets.count { $0 < destination })
        upNext = rest
    }

    public func removeQueued(_ id: QueueEntry.ID) {
        upNext.removeAll { $0.id == id }
    }

    public func clearQueue() {
        let queued = upNext
        upNext.removeAll()
        undo?.registerUndo(withTarget: self) { controller in
            controller.upNext = queued
            controller.undo?.registerUndo(withTarget: controller) { $0.clearQueue() }
        }
        undo?.setActionName("Clear Queue")
    }

    /// Songs from one album play with that album's gaps, wherever they were queued from.
    private static func source(of songs: [Song]) -> String? {
        let albums = Set(songs.map(\.albumID))
        return albums.count == 1 ? albums.first : nil
    }

    /// The silence before a piece belongs to where it comes from: an album or playlist with gaps of its own brings
    /// them, anything else (or the shuffler's pick, when nothing is queued) has the user's. Worked out the way
    /// `useAlbumSettings` will apply them when the piece starts, without applying them.
    func gapRange(beforeNext entry: QueueEntry?) -> ClosedRange<Double> {
        if let id = entry?.source, let album = albumSettings[id] ?? playlists.first(where: { $0.id == id })?.gaps {
            return album.gaps(over: yourSettings).gapRange
        }
        return yourSettings.gapRange
    }

    /// The next path to play, putting its source's gaps in place, or nil when the shuffler should pick.
    func dequeue() -> String? {
        guard !upNext.isEmpty || refillHour() else {
            useAlbumSettings(for: nil)
            origin = nil
            return nil
        }
        let entry = upNext.removeFirst()
        useAlbumSettings(for: entry.source)
        shuffler.note(entry.path)
        return entry.path
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
        guard let i = library.folders.firstIndex(where: { $0.path == url.path }) else { return }
        let folder = library.folders.remove(at: i)
        rescan()
        undo?.registerUndo(withTarget: self) { controller in
            controller.library.folders.insert(folder, at: min(i, controller.library.folders.count))
            controller.rescan()
            controller.undo?.registerUndo(withTarget: controller) { $0.removeFolder(url) }
        }
        undo?.setActionName("Remove \(url.lastPathComponent)")
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
            command(.start)
        case .paused:
            command(.resume)
        case .playing, .resting:
            command(.pause)
        }
    }

    public func play() {
        if status == .idle || status == .paused { toggle() }
    }

    public func pause() {
        if status == .playing || status == .resting { toggle() }
    }

    public func skip() {
        command(.skip)
    }

    /// Bumped on every seek, so views drawing the unobserved `track` know to start over.
    public private(set) var seeks = 0

    /// Jumps within the playing piece; the sound comes back up from silence over a second and a half.
    public func seek(to seconds: Double) {
        command(.seek(to: seconds))
    }

    /// The sleep timer as the UI shows it. Set on commands and status changes, never per tick.
    public enum SleepTimer: Equatable, Sendable {
        case at(Date)
        case paused(left: Double)
        case afterCurrent
    }

    public private(set) var sleepTimer: SleepTimer?

    /// The sleep timer's ease-down for drawing: 1 until its last minutes, then down to 0.25 as playback stops.
    /// Not observed, like `track`: views poll it.
    public var sleepLevel: Double {
        0.25 + 0.75 * machine.sleepLevel
    }

    public func sleep(minutes: Double) {
        command(.sleep(after: minutes * 60))
        refreshSleep()
        publish()
    }

    public func sleepAfterCurrent() {
        command(.sleepAfterCurrent)
        refreshSleep()
        publish()
    }

    public func cancelSleep() {
        command(.cancelSleep)
        refreshSleep()
        publish()
    }

    private func refreshSleep() {
        let timer: SleepTimer? = switch machine.sleep {
        case .timer(let left, _)?: status == .paused ? .paused(left: left) : .at(Date(timeIntervalSinceNow: left))
        case .afterCurrent?: .afterCurrent
        case nil: nil
        }
        if timer != sleepTimer {
            sleepTimer = timer
        }
    }

    /// sottova://play, pause, toggle, skip, preset/<name>, sleep/<minutes>, sleep/after, sleep/off
    public func open(_ url: URL) {
        guard acceptsURLs, url.scheme == "sottova" else { return }
        switch url.host()?.lowercased() {
        case "play": play()
        case "pause": pause()
        case "toggle": toggle()
        case "skip": skip()
        case "preset":
            let name = url.lastPathComponent.lowercased()
            if let preset = Settings.presets.first(where: { $0.name.lowercased() == name }) {
                apply(preset)
            }
        case "sleep":
            switch url.lastPathComponent.lowercased() {
            case "off": cancelSleep()
            case "after": sleepAfterCurrent()
            case let minutes: if let minutes = Double(minutes), minutes > 0 { sleep(minutes: minutes) }
            }
        default:
            break
        }
    }

    public func systemWillSleep() {
        guard status == .playing || status == .resting else { return }
        // closing the lid with a sleep timer set means stop, not resume in the morning
        if machine.sleep != nil {
            command(.sleepNow)
            return
        }
        pausedForSleep = true
        command(.pause)
    }

    public func systemDidWake() {
        guard pausedForSleep else { return }
        pausedForSleep = false
        command(.resume)
    }

    func advance(_ seconds: Double) {
        send(.tick(seconds))
    }

    var deckGain: Float {
        mixers[active].outputVolume
    }

    var mixerVolumes: [Float] {
        mixers.map(\.outputVolume)
    }

    /// The playing track, or the last one during a gap. Not observed: it changes 100 times a second, so views poll it.
    public var track: Track? {
        lastTrack
    }

    func refreshTracks() {
        tracks = library.playable.map { URL(filePath: $0) }
        skippedFiles = library.unplayable.map { URL(filePath: $0) }
        pendingAnalysis = library.pending.count
        rebuildCatalog()
    }

    /// Grouping 20k songs takes ~80 ms, so it runs off the main actor, and only when the entries actually changed.
    private func rebuildCatalog() {
        let entries = library.entries
        guard entries != catalogEntries else { return }
        catalogEntries = entries
        lastCatalogBuild = .now
        catalogGeneration += 1
        let generation = catalogGeneration
        Task {
            let built = await Task.detached(priority: .userInitiated) { Catalog(entries: entries) }.value
            guard generation == catalogGeneration else { return }
            catalog = built
            if let path = file?.url.path {
                current = catalog.songsByID[path]
                // a piece restored before the catalog was built has only its file name as a title so far
                if let song = current, title != song.title {
                    title = song.title
                    publish()
                }
            }
            refreshRecent()
        }
    }

    private func refreshRecent() {
        var seen = Set<String>()
        recent = shuffler.recent.reversed().filter { seen.insert($0).inserted }.prefix(12).compactMap { catalog.songsByID[$0] }
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
        if new == .idle { hourEnding = false }
        refreshNextTrack()
        keepAwake(wantsAwake)
        refreshSleep()
        publish()
        saveResume()
    }

    private func perform(_ effect: Machine.Effect) {
        let deck = players[active]
        switch effect {
        case .startNextTrack:
            startNextTrack()
        case .planGap:
            send(.gap(Double.random(in: gapRange(beforeNext: upNext.first), using: &rng)))
        case .setGain(let gain):
            // above 1 boosts: measured on macOS 26 despite the documented 0–1 range, and covered by RenderTests
            mixers[active].outputVolume = Float(gain * trackGain)
        case .stopTrack(let skipped):
            deck.stop()
            log(skipped: skipped, gap: machine.restRemaining ?? 0)
            // Apple recommends pausing an idle engine; it also drops coreaudiod's sleep assertion, hence keepAwake
            if machine.outgoing == nil {
                engine.pause()
            }
        case .handOff:
            log(skipped: false, gap: 0)
            outgoingGain = trackGain
            active = 1 - active
        case .setOutgoingGain(let gain):
            mixers[1 - active].outputVolume = Float(gain * outgoingGain)
        case .stopOutgoing:
            players[1 - active].stop()
            mixers[1 - active].outputVolume = 0
        case .pausePlayback:
            players.forEach { $0.pause() }
            engine.pause()
        case .seekPlayback:
            seeks += 1
            defer { saveResume() }
            if status == .paused {
                // picked up from the new spot on resume, like after a device change
                needsReschedule = true
            } else {
                reschedule()
                deck.play()
            }
            if case .track(let track) = machine.phase {
                nowPlaying?.update(status: status, title: title, track: track)
            }
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
            if case .track = machine.phase {
                deck.play()
            }
            if machine.outgoing != nil {
                players[1 - active].play()
            }
        }
    }

    private func startNextTrack() {
        guard let path = dequeue() ?? shuffler.next(from: tracks.map(\.path), avoidingLast: settings.avoidLastN, using: &rng) else {
            send(.stop)
            return
        }
        let url = URL(filePath: path)
        let deck = players[active]
        do {
            let file = try AVAudioFile(forReading: url)
            deck.stop()
            mixers[active].outputVolume = 0
            try engine.start()
            let duration = useSpan(of: file)
            deck.scheduleSegment(file, startingFrame: span.start, frameCount: AVAudioFrameCount(span.end - span.start), at: nil, completionHandler: nil)
            deck.prepare(withFrameCount: 8192)
            deck.play()
            self.file = file
            trackGain = gain(of: path)
            current = catalog.songsByID[path]
            title = current?.title ?? url.deletingPathExtension().lastPathComponent
            refreshRecent()
            startedAt = Date()
            failures = 0
            problem = nil
            send(.trackStarted(duration: duration))
            publish()
            saveResume()
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
        let pending = library.pending.map { ($0, library.entries[$0]?.loudness == nil) }
        guard analysis == nil, !pending.isEmpty else { return }
        let store = artwork
        analysis = Task {
            await withTaskGroup(of: (String, TrackMeta?, Loudness?).self) { group in
                var queue = pending[...]
                func addNext() {
                    guard let next = queue.popFirst() else { return }
                    let (path, needsLoudness) = next
                    group.addTask(priority: .utility) {
                        let url = URL(filePath: path)
                        guard let meta = try? await Metadata.read(url, artwork: store) else { return (path, nil, nil) }
                        let loudness = needsLoudness ? try? Loudness.measure(url) : nil
                        // a file that opened but couldn't be measured still counts as unplayable
                        return needsLoudness && loudness == nil ? (path, nil, nil) : (path, meta, loudness)
                    }
                }
                for _ in 0..<Self.analysisWidth {
                    addNext()
                }
                var unsaved = 0
                for await (path, meta, loudness) in group {
                    if library.entries[path] != nil {
                        if let meta {
                            library.entries[path]?.meta = meta
                            if let loudness {
                                library.entries[path]?.loudness = loudness
                            }
                        } else {
                            library.entries[path]?.unplayable = true
                        }
                    }
                    pendingAnalysis = max(0, pendingAnalysis - 1)
                    unsaved += 1
                    if unsaved == 50 {
                        saveLibrary()
                        unsaved = 0
                    }
                    // tags arrive one file at a time; regroup albums at most once a second
                    if Date.now.timeIntervalSince(lastCatalogBuild) > 1 {
                        refreshTracks()
                    }
                    addNext()
                }
            }
            saveLibrary()
            refreshTracks()
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

    /// A profile that won't decode (damaged, or written by a newer build) is moved aside before the defaults take over,
    /// so the next save can't overwrite it.
    private static func loadProfile(from storage: URL?) -> (ProfileFile?, problem: String?, writable: Bool) {
        guard let url = storage?.appending(path: "profile.json"), let data = try? Data(contentsOf: url) else { return (nil, nil, true) }
        do {
            return (try JSONDecoder().decode(ProfileFile.self, from: data), nil, true)
        } catch {
            let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let aside = url.deletingLastPathComponent().appending(path: "profile.json.unreadable-\(stamp)-\(Int(Date.now.timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                return (nil, "couldn't read profile.json or move it aside, so settings won't be saved this time: \(error.localizedDescription)", false)
            }
            return (nil, "couldn't read your settings, so these are the defaults. the old file is \(aside.lastPathComponent)", true)
        }
    }

    private func saveProfile() {
        guard profileWritable, let url = storage?.appending(path: "profile.json") else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // while an album plays with its own gaps, the user's settings are what a restart should come back to
            try encoder.encode(ProfileFile(settings: yourSettings, albums: albumSettings)).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't save the profile: \(error.localizedDescription)"
        }
    }

    private func loadLibrary() {
        guard let url = storage?.appending(path: "library.json") else { return }
        do {
            library = try Library.load(from: url)
        } catch {
            // keep the unreadable file for inspection instead of overwriting it on the next save
            let aside = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            problem = "couldn't read the library, moved it to library.json.broken and started fresh: \(error.localizedDescription)"
        }
        refreshTracks()
    }

    /// Encoding a 20k-entry library takes ~100 ms, so it happens off the main actor, one save after another.
    private func saveLibrary() {
        guard let url = storage?.appending(path: "library.json") else { return }
        let snapshot = library
        saving = Task { [previous = saving] in
            await previous?.value
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try snapshot.save(to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                problem = "couldn't save the library: \(failure)"
            }
        }
    }

    /// Writes status.json and posts a distributed notification, for status-bar plugins and hotkey tools.
    private func publish() {
        nowPlaying?.update(status: status, title: title, track: lastTrack)
        guard ticker != nil, let url = storage?.appending(path: "status.json") else { return }
        var info: [String: Any] = ["status": "\(status)", "preset": settings.name]
        if let title { info["title"] = title }
        if let nextTrackAt { info["nextTrackAt"] = ISO8601DateFormatter().string(from: nextTrackAt) }
        switch sleepTimer {
        case .at(let date)?: info["sleepAt"] = ISO8601DateFormatter().string(from: date)
        case .paused(let left)?: info["sleepLeftSec"] = Int(left)
        case .afterCurrent?: info["sleepAt"] = "afterCurrent"
        case nil: break
        }
        do {
            try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't write status.json: \(error.localizedDescription)"
        }
        // userInfo only arrives because the app isn't sandboxed
        DistributedNotificationCenter.default().postNotificationName(.init("com.alanbagel.sottova.status"), object: nil, userInfo: info, deliverImmediately: true)
    }

    /// The engine stops and drops scheduled audio on a device change, so pause and pick up from the same frame on resume.
    private func engineConfigurationChanged() {
        guard status == .playing else { return }
        needsReschedule = true
        command(.pause)
    }

    /// ponytail: only the current deck is rescheduled; a crossfade's outgoing track is dropped on a device change
    private func reschedule() {
        needsReschedule = false
        guard let file, case .track(let track) = machine.phase else { return }
        let deck = players[active]
        let start = span.start + AVAudioFramePosition(track.elapsed * file.processingFormat.sampleRate)
        guard start < span.end else { return }
        deck.stop()
        deck.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(span.end - start), at: nil, completionHandler: nil)
    }

    private func log(skipped: Bool, gap: Double) {
        guard let url = storage?.appending(path: "plays.jsonl"), let file else { return }
        let record = PlayRecord(file: file.url.path, startedAt: startedAt, skipped: skipped, gapAfterSec: gap, heardSec: lastTrack?.elapsed)
        do {
            try record.append(to: url)
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
