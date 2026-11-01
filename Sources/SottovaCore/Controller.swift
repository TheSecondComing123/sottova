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
            saveVolume(volume)
            engine.mainMixerNode.outputVolume = Float(volume)
        }
    }
    public let artwork: ArtworkStore?
    public var settings: Settings {
        didSet {
            // editing any field of a preset turns it into Custom; this re-enters didSet once
            if settings.name != "Custom", !allPresets.contains(settings.mode) {
                settings.name = "Custom"
            }
            machine.settings = settings
            saveProfile()
        }
    }
    /// The presets the user has named, after the built-in ones.
    public var customPresets: [Settings] = [] {
        didSet { saveProfile() }
    }
    public var allPresets: [Settings] { Settings.presets + customPresets }
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
    /// Off when a library.json that can't be read can't be moved either, so saving doesn't overwrite it.
    @ObservationIgnored private var libraryWritable = true
    @ObservationIgnored private var needsReschedule = false
    /// Seconds until a seek's jump.
    @ObservationIgnored private var jumpIn: Double?
    /// How long a mixer takes to reach a new volume, at most: measured 35 ms at 44.1 and 48 kHz.
    static let mixerRamp = 0.04
    @ObservationIgnored private var pausedForSleep: Date?
    /// A longer sleep doesn't pick up where it was: often that's a scheduled wake, with nobody there.
    static let resumeWithin: TimeInterval = 60 * 60
    /// An alarm started what's playing: when its music ends it stops, with nobody there to press stop.
    @ObservationIgnored private var fromAlarm = false
    /// Off when alarms.json can't be read or moved, so saving doesn't overwrite it.
    @ObservationIgnored private var alarmsWritable = true
    @ObservationIgnored private var alarmsLoaded = false
    @ObservationIgnored private var alarmsCaughtUp = false
    /// Where a replaced cover goes; a test keeps it out of the real Trash.
    @ObservationIgnored var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Where the level is kept; tests put their own in, since every test process shares these defaults.
    @ObservationIgnored var saveVolume: (Double) -> Void = { UserDefaults.standard.set($0, forKey: "volume") }
    /// How audio starts; a test can make it fail, as a device that's going away does.
    @ObservationIgnored var startEngine: (AVAudioEngine) throws -> Void = { try $0.start() }
    /// A piece waiting for the audio device, which isn't its fault.
    @ObservationIgnored private var retrying: String?
    @ObservationIgnored private var engineFailures = 0
    /// How long to wait for a device that won't start, a try a second.
    static let engineTries = 60
    /// Between those tries; a test shortens it.
    @ObservationIgnored var retryWait = Duration.seconds(1)
    /// An alarm trying the device again after it couldn't go on. A press ends it.
    @ObservationIgnored private var resuming: Task<Void, Never>?
    /// A failure to play, which the next piece that plays puts right; other messages stay until they're read.
    @ObservationIgnored private var playbackProblem: String?
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored var lastTick: ContinuousClock.Instant?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var coversTried = Set<String>()
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchedPaths: [String] = []
    /// What the last scan couldn't read, and what was said about it, which goes once it can.
    @ObservationIgnored private var unreachableFolders: [String] = []
    @ObservationIgnored private var unreachableProblem: String?
    @ObservationIgnored private var emptyRowsProblem: String?
    @ObservationIgnored private var scanned = false
    @ObservationIgnored private var catalogBuilt = true
    @ObservationIgnored private var nowPlaying: NowPlaying?
    /// Songs the listener picked, played in order before shuffle takes over again.
    public private(set) var playlists: [Playlist] = []
    @ObservationIgnored private let playlistStore: PlaylistStore?
    @ObservationIgnored private var playlistWatcher: FolderWatcher?
    @ObservationIgnored private var playlistProblem: String?

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
                playlistFolder: URL? = nil, artworkFolder: URL = .cachesDirectory.appending(path: "Sottova/Artwork")) {
        self.engine = engine
        self.storage = storage
        playlistStore = playlistFolder.map(PlaylistStore.init)
        artwork = storage.map { _ in ArtworkStore(directory: artworkFolder) }
        let (file, unreadable, writable) = Self.loadProfile(from: storage)
        profileWritable = writable
        let profile = file?.settings ?? Settings.presets.first { $0.name == "Short" }!
        settings = profile
        albumSettings = file?.albums ?? [:]
        customPresets = file?.presets ?? []
        machine = Machine(settings: profile)
        // Both decks are wired once with a fixed format; the player converts each file to it.
        // A player connected while the engine runs starts late, by about 8% of the time the engine has been running.
        // The mixers need it said too: left out, they take a new mixer's default of 44.1 kHz and everything goes through that.
        let deckFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for (player, mixer) in zip(players, mixers) {
            engine.attach(player)
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: deckFormat)
            engine.connect(player, to: mixer, format: deckFormat)
            mixer.outputVolume = 0
        }
        _ = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
        // a new zone or a changed clock moves when the next alarm is
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.armAlarm() }
            }
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
        // before alarms, whose message about a damaged file is the one that has to be read
        loadTrims()
        // alarms first: a piece restored mid-hour goes on being the hour's
        loadAlarms()
        restoreResume()
        // a row that minds your calendar can only once it may read it
        if alarms.contains(where: { $0.on && $0.heedsCalendar }) {
            Task { await Presence.askForCalendars() }
        }
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

    /// Keeps `preset` under its name, or as the changed `old`, and whatever plays with `old` follows. A new one, or
    /// the one in use, takes effect now.
    public func savePreset(_ preset: Settings, replacing old: String? = nil) {
        var preset = preset.mode
        preset.name = presetName(preset.name, except: old)
        let inUse = old == nil || settings.name == old
        if let old, let i = customPresets.firstIndex(where: { $0.name == old }) {
            customPresets[i] = preset
        } else {
            customPresets.append(preset)
        }
        if let old { everyoneOn(old) { preset.gaps(over: $0) } }
        if inUse { apply(preset) }
    }

    /// Whatever played with it keeps those gaps, as Custom.
    public func deletePreset(_ name: String) {
        guard let i = customPresets.firstIndex(where: { $0.name == name }) else { return }
        let preset = customPresets.remove(at: i)
        everyoneOn(name) {
            var s = $0
            s.name = "Custom"
            return s
        }
        if settings.name == name { settings.name = "Custom" }
        undo?.registerUndo(withTarget: self) { $0.customPresets.insert(preset, at: min(i, $0.customPresets.count)) }
        undo?.setActionName("Delete preset")
    }

    /// The albums, collections and saved settings that play with this preset.
    private func everyoneOn(_ name: String, change: (Settings) -> Settings) {
        for (id, album) in albumSettings where album.name == name { albumSettings[id] = change(album) }
        for playlist in playlists where playlist.gaps?.name == name { setGaps(playlist.gaps.map(change), for: playlist.id) }
        if ownSettings?.name == name { ownSettings = ownSettings.map(change) }
    }

    /// Names are how presets are told apart, so a taken one gets a number.
    private func presetName(_ wanted: String, except old: String?) -> String {
        let wanted = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set((allPresets.map(\.name) + ["Custom", "Yours"]).filter { $0 != old }.map { $0.lowercased() })
        var name = wanted
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(wanted) \(number)"
            number += 1
        }
        return name
    }

    /// Plays these songs in order from `index`, with the usual fades and gaps, then goes back to shuffling everything.
    /// What the queue was started from (an album, playlist, page) and whether shuffled, so that page's play button
    /// can show it's the one playing. Cleared when the queue runs out.
    public struct Origin: Codable, Equatable, Sendable {
        public let key: String
        public let shuffled: Bool

        public init(key: String, shuffled: Bool) {
            self.key = key
            self.shuffled = shuffled
        }

        /// A playlist by its id; anything else by which songs it holds, whatever their order, so a song clicked in
        /// a list and that page's play button agree. A PlayRow body asks up to four times, so a 10k page can't afford
        /// a joined string of the paths. A sum of FNV-1a hashes doesn't care about order and, saved across launches,
        /// still matches where a hashValue wouldn't. Only a playlist can hold a song twice, and that goes by its id.
        public static func key(of songs: [Song], source: String?) -> String {
            source ?? String(songs.reduce(UInt64(0)) { sum, song in
                sum &+ song.id.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
            }, radix: 16)
        }
    }

    public private(set) var origin: Origin?

    /// `source` is a playlist id, whose gaps the songs play with; without one, songs from one album play with its gaps.
    /// `row` is the alarm this is for and the time it's for.
    public func play(_ songs: [Song], from index: Int = 0, source: String? = nil, shuffled: Bool = false, row: (id: Alarm.ID, time: Date)? = nil) {
        guard songs.indices.contains(index) else { return }
        // first, since it can end what's playing: the check below and the alarm's marks have to come after that
        catchUp()
        releaseHour()
        giveVolumeBack()
        fromAlarm = row != nil
        partDue = row
        origin = Origin(key: Origin.key(of: songs, source: source), shuffled: shuffled)
        let source = source ?? Self.source(of: songs)
        upNext = songs[index...].map { QueueEntry(path: $0.id, source: source) }
        if retrying != nil {
            // nothing's playing to skip, and the piece it was waiting to start is no longer wanted
            retrying = nil
            startNextTrack()
        } else if status == .idle {
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

    /// Counts Play next, so the queue button can show each one landed.
    public private(set) var queuedNext = 0

    /// Queues songs first, or at `index` when they're dropped into the queue.
    public func playNext(_ songs: [Song], source: String? = nil, at index: Int = 0) {
        queuedNext += 1
        let source = source ?? Self.source(of: songs)
        upNext.insert(contentsOf: songs.map { QueueEntry(path: $0.id, source: source) }, at: min(index, upNext.count))
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
        if alarmsWritable, let url = storage?.appending(path: "alarms.json") {
            do {
                try JSONEncoder().encode(alarms).write(to: url, options: .atomic)
            } catch {
                problem = "couldn't save the alarms: \(error.localizedDescription)"
            }
        }
        armAlarm()
        sayEmptyRows()
    }

    /// A row whose collection went away outside the app, as a rename in Finder does, says so now and not when it's
    /// due. Only once the catalog is the library's: until a scan and its analysis finish, an album can be missing or
    /// under another id for a moment.
    private func sayEmptyRows() {
        guard alarmsLoaded, scanned, catalogBuilt, pendingAnalysis == 0 else { return }
        let names = alarms.filter { $0.on && songs(for: $0).isEmpty }.map(\.name)
        let said = names.isEmpty ? nil : "\(names.joined(separator: ", ")) \(names.count == 1 ? "has" : "have") nothing to play: the collection is gone, out of reach or renamed outside sottova"
        guard said != emptyRowsProblem else { return }
        if problem == emptyRowsProblem { problem = nil }
        emptyRowsProblem = said
        if let said { problem = said }
    }

    func loadAlarms() {
        defer {
            alarmsLoaded = true
            catchUpAlarms()
        }
        guard let url = storage?.appending(path: "alarms.json"), FileManager.default.fileExists(atPath: url.path) else { return }
        let saved: [Alarm]
        do {
            saved = try JSONDecoder().decode([Alarm].self, from: Data(contentsOf: url))
        } catch {
            let aside = url.deletingLastPathComponent().appending(path: "alarms.json.unreadable-\(Int(Date.now.timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                problem = "couldn't read your alarms, so none are set. the old file is \(aside.lastPathComponent)"
            } catch {
                alarmsWritable = false
                problem = "couldn't read your alarms or set the file aside, so none are set and changes to them won't be saved: \(error.localizedDescription)"
            }
            return
        }
        // a one-off whose time passed while the app was closed is dropped, not played late, unless it's only just passed
        alarms = saved.filter { $0.next(after: .now - Self.alarmLateness) != nil || $0.whileHere && $0.window(containing: .now) != nil }
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

    /// Alarms whose time passed moments ago without them going off.
    private func dueAlarms(now: Date) -> [(alarm: Alarm, at: Date)] {
        alarms.filter { $0.on && !$0.whileHere }.compactMap { alarm in
            alarm.next(after: now - Self.alarmLateness).flatMap { $0 <= now && $0 != alarm.lastFired ? (alarm, $0) : nil }
        }
    }

    /// Not the library's yet: being built, or from before the first scan and short of what that may bring back.
    private var catalogPending: Bool {
        !catalogBuilt || !scanned && (catalog.songsByID.isEmpty || library.entries.values.contains { $0.unreachable == true })
    }

    /// An alarm whose time passed while the app wasn't running still goes off, the latest one if there are several.
    /// Not before there's a catalog, which it needs to find its songs.
    func catchUpAlarms(now: Date = .now) {
        guard alarmsLoaded, !alarmsCaughtUp, !catalogPending else { return }
        alarmsCaughtUp = true
        if let (alarm, at) = dueAlarms(now: now).max(by: { $0.at < $1.at }) { fire(alarm.id, due: at, now: now) }
    }

    func fire(_ id: Alarm.ID, due: Date, now: Date = .now) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        // not spent: catch-up takes it once the catalog's there
        if catalogPending, now.timeIntervalSince(due) <= Self.alarmLateness {
            alarmsCaughtUp = false
            armAlarm()
            return
        }
        // the clock was set back past it
        if alarms[index].lastFired == due {
            armAlarm()
            return
        }
        alarms[index].lastFired = due
        let alarm = alarms[index]
        if now.timeIntervalSince(due) > Self.alarmLateness {
            problem = "the \(alarm.name) alarm didn't play: the mac was asleep at \(due.formatted(date: .omitted, time: .shortened))"
        } else if alarm.heedsCalendar, calendarBusy() {
            problem = "\(alarm.name) didn't play at \(due.formatted(date: .omitted, time: .shortened)): your calendar had something on"
        } else if case let songs = rowSongs(alarm), !songs.isEmpty {
            let playlist = playlists.contains { $0.id == alarm.source } ? alarm.source : nil
            let history = storage.map { PlayRecord.read($0.appending(path: "plays.jsonl"), last: 2000) } ?? []
            play(alarm.shuffled ? Self.alarmOrder(songs, at: alarm, due: due, history: history, using: &rng) : songs,
                 source: playlist, shuffled: alarm.shuffled, row: (alarm.id, due))
            useRowVolume(alarm.volume)
            // a timer set last night is about last night
            command(.cancelSleep)
            if status == .paused { command(.resume) }
            command(.rise)
            if let minutes = alarm.minutes { sleep(minutes: Double(minutes)) }
            saveResume()
        } else {
            let away = library.entries.values.count { $0.unreachable == true }
            problem = "the \(alarm.name) alarm went off, but there's nothing in it to play" + (away > 0 ? ". \(away) song\(away == 1 ? " is" : "s are") out of reach right now, which may be why" : "")
        }
        // one player: any other due now doesn't play, and says so
        for (other, at) in dueAlarms(now: now) {
            problem = "\(other.name) didn't play at \(at.formatted(date: .omitted, time: .shortened)): \(alarm.name) was starting"
            if let i = alarms.firstIndex(where: { $0.id == other.id }) { alarms[i].lastFired = at }
        }
        alarms.removeAll { $0.weekdays.isEmpty && !$0.whileHere && $0.lastFired != nil }
        alarmsChanged()
    }

    private func songs(for alarm: Alarm) -> [Song] {
        playlists.first { $0.id == alarm.source }.map(songs(of:)) ?? catalog.albumsByID[alarm.source]?.songs ?? []
    }

    /// An alarm's collection in the parts it rotates through: a collection's own breaks, or cut by length.
    public func parts(for alarm: Alarm) -> [[Song]] {
        if let playlist = playlists.first(where: { $0.id == alarm.source }), !playlist.breaks.isEmpty {
            return ownParts(of: playlist).map(\.songs)
        }
        return Self.split(songs(for: alarm), into: alarm.parts)
    }

    /// A part whose files are all gone keeps its place, so the others stay where `nextPart` expects them.
    private func ownParts(of playlist: Playlist) -> [(name: String?, songs: [Song])] {
        zip(playlist.partStarts, playlist.partPaths)
            .map { (playlist.partNames[$0], $1.compactMap { catalog.songsByID[$0] }) }
    }

    /// The part a row plays next: its name, or "part 2".
    public func nextPartName(for alarm: Alarm) -> String {
        let part = partIndex(from: alarm.nextPart, in: parts(for: alarm)) ?? 0
        guard let playlist = playlists.first(where: { $0.id == alarm.source }), !playlist.breaks.isEmpty else { return "part \(part + 1)" }
        let own = ownParts(of: playlist)
        return part < own.count ? own[part].name ?? "part \(part + 1)" : "part \(part + 1)"
    }

    /// `songs` in `count` runs of about equal length, in order: each song goes to the part its middle falls in.
    nonisolated static func split(_ songs: [Song], into count: Int) -> [[Song]] {
        let count = max(1, min(count, songs.count))
        let total = songs.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return songs.isEmpty ? [] : [songs] }
        var parts = Array(repeating: [Song](), count: count)
        var start = 0.0
        for song in songs {
            parts[min(count - 1, Int(Double(count) * (start + song.duration / 2) / total))].append(song)
            start += song.duration
        }
        return parts.filter { !$0.isEmpty }
    }

    /// The first part from `start` on that has songs left.
    private func partIndex(from start: Int, in all: [[Song]]) -> Int? {
        all.indices.map { (start + $0) % all.count }.first { !all[$0].isEmpty }
    }

    /// What a row plays this time: its whole collection, or, rotating, the part it's on: the next one, or, once its
    /// window has used that up, the one before the next.
    func rowSongs(_ alarm: Alarm) -> [Song] {
        guard alarm.rotates else { return songs(for: alarm) }
        let all = parts(for: alarm)
        let spent = alarm.lastFired != nil && alarm.partSpent == alarm.lastFired
        return partIndex(from: alarm.nextPart + (spent ? all.count - 1 : 0), in: all).map { all[$0] } ?? []
    }

    /// A piece has started with a row's part waiting to be used up, which only sound does: a day or a window that
    /// never got that far keeps its part.
    private func spendPart() {
        guard let due = partDue, let i = alarms.firstIndex(where: { $0.id == due.id }) else { return }
        partDue = nil
        guard alarms[i].rotates, alarms[i].partSpent != due.time else { return }
        let all = parts(for: alarms[i])
        guard let part = partIndex(from: alarms[i].nextPart, in: all) else { return }
        alarms[i].nextPart = (part + 1) % all.count
        alarms[i].partSpent = due.time
        alarmsChanged()
    }

    // MARK: Hours

    /// The alarm that plays while you're at the Mac whose collection is playing; nil once anything else is played.
    @ObservationIgnored private var hourPlaying: Alarm.ID?
    /// A relaunch cut an hour off mid-piece or mid-silence, and it hasn't gone on yet.
    @ObservationIgnored private var resumingHour = false
    /// While a row plays at its own volume: your level to go back to, and the one it put in its place.
    @ObservationIgnored private var ownVolume: Double?
    @ObservationIgnored private var rowVolume: Double?
    /// The row whose part the next piece to start uses up, and the time it's for.
    @ObservationIgnored private var partDue: (id: Alarm.ID, time: Date)?
    @ObservationIgnored private var lastHourCheck = Date.distantPast
    /// The stop after this piece is the hour's, not yours, so whatever you play next isn't cut short by it.
    @ObservationIgnored private var hourEnding = false
    /// Reads the Mac for a reason to wait; tests put their own in.
    @ObservationIgnored var presence: @MainActor (_ calendar: Bool) -> Hold? = { Presence.hold(calendar: $0) }
    /// Whether the calendar has something on now; tests put their own in.
    @ObservationIgnored var calendarBusy: @MainActor () -> Bool = { Presence.busy() }
    /// Why the next piece of an hour is waiting.
    public private(set) var hold: Hold?

    /// The hour that has the time: where rows overlap, the one that started latest.
    public func openHour(at now: Date = .now) -> Alarm? {
        alarms.filter { $0.on && $0.whileHere }
            .compactMap { alarm in alarm.window(containing: now).map { (alarm, $0.start) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Starts an hour from silence when its window opens and nothing else is playing, moves to the next hour without
    /// cutting the piece, ends with the piece playing as the window closes, and holds the next piece while you're
    /// away, on a call or listening to something else.
    func checkHours(now: Date = .now) {
        lastHourCheck = now
        let current = openHour(at: now)
        let open = current?.window(containing: now)
        // the same row's next window counts as a new hour: nothing has checked since yesterday's closed
        if let id = hourPlaying, id != current?.id || current?.lastFired != open?.start {
            hourPlaying = nil
            if let current, let window = open, status == .playing || status == .resting {
                follow(current, from: window.start)
            } else {
                upNext.removeAll()
                origin = nil
                // paused counts too: a lid closed mid-hour and opened tomorrow mustn't carry on with everything
                if case .resting = machine.phase {
                    send(.stop)
                } else if status != .idle {
                    hourEnding = true
                    sleepAfterCurrent()
                }
            }
        }
        // paused counts as not playing: often it's only how a relaunch or a restart left things
        // not before there's a catalog, which it needs to find its songs
        if hourPlaying == nil, let current, let window = open, status == .idle || status == .paused,
           current.lastFired != window.start, !catalog.songsByID.isEmpty {
            let songs = rowSongs(begin(current, at: window.start))
            if songs.isEmpty {
                problem = "\(current.name) has nothing in it to play"
            } else {
                if status == .paused { send(.sleepNow) }
                hourPlaying = current.id
                partDue = (current.id, window.start)
                queue(current, songs)
                failures = 0
                // out of silence, but not a long one
                send(.wait(Double.random(in: 10...45, using: &rng)))
                useRowVolume(current.volume)
            }
        }
        // a one-off whose window has closed is done
        let over = alarms.filter { $0.whileHere && $0.weekdays.isEmpty && $0.next(after: now) == nil && $0.window(containing: now) == nil }
        if !over.isEmpty {
            alarms.removeAll { alarm in over.contains { $0.id == alarm.id } }
            alarmsChanged()
        }
        let hour = alarms.first { $0.id == hourPlaying }
        setHold(hour == nil || status == .idle ? nil : presence(hour?.heedsCalendar ?? false))
    }

    /// The next hour takes over from the one playing: its collection is next, and a silence already under way can only
    /// get shorter.
    private func follow(_ hour: Alarm, from start: Date) {
        let hour = begin(hour, at: start)
        hourPlaying = hour.id
        partDue = (hour.id, start)
        queue(hour, rowSongs(hour))
        if case .resting(let elapsed, let gap) = machine.phase {
            send(.gap(elapsed + min(gap - elapsed, Double.random(in: gapRange(beforeNext: upNext.first), using: &rng))))
            refreshNextTrack()
            publish()
        }
        useRowVolume(hour.volume)
        saveResume()
    }

    /// Notes the window an hour started in, so one stopped by hand doesn't start again until its next, even after a relaunch.
    private func begin(_ hour: Alarm, at start: Date) -> Alarm {
        guard hour.lastFired != start, let i = alarms.firstIndex(where: { $0.id == hour.id }) else { return hour }
        alarms[i].lastFired = start
        alarmsChanged()
        return alarms[i]
    }

    /// The hour's collection as what plays next; shuffled, the piece just heard goes last.
    private func queue(_ hour: Alarm, _ songs: [Song]) {
        var order = hour.shuffled ? songs.shuffled(using: &rng) : songs
        if hour.shuffled, let last = file?.url.path, let i = order.firstIndex(where: { $0.id == last }) {
            order.append(order.remove(at: i))
        }
        upNext = order.map { QueueEntry(path: $0.id, source: hour.source) }
        origin = origin(of: hour)
    }

    /// A row's own level goes on. A level you set while the last row played is yours now, so it's the one to go back to.
    private func useRowVolume(_ level: Double?) {
        guard let level, status != .idle else { return }
        if ownVolume == nil || volume != rowVolume { ownVolume = volume }
        rowVolume = level
        volume = level
        saveResume()
    }

    /// When a row is over, unless you changed the level while it played: that's what you chose.
    private func giveVolumeBack() {
        if let ownVolume, volume == rowVolume { volume = ownVolume }
        (ownVolume, rowVolume) = (nil, nil)
    }

    /// Its whole collection, whichever part it's on, so the collection's page knows it's playing.
    private func origin(of hour: Alarm) -> Origin {
        let playlist = playlists.contains { $0.id == hour.source } ? hour.source : nil
        return Origin(key: Origin.key(of: songs(for: hour), source: playlist), shuffled: hour.shuffled)
    }

    /// An hour that's played through its collection goes round again.
    private func refillHour() -> Bool {
        guard let hour = alarms.first(where: { $0.id == hourPlaying }), case let songs = rowSongs(hour), !songs.isEmpty else { return false }
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
    /// Off when trims.json can't be read or moved, so saving doesn't overwrite it.
    @ObservationIgnored private var trimsWritable = true

    /// Takes effect the next time the song starts; nil plays the whole file again.
    public func setTrim(_ trim: Trim?, for path: String) {
        trims[path] = trim
        guard trimsWritable, let url = storage?.appending(path: "trims.json") else { return }
        do {
            try JSONEncoder().encode(trims).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't save the trim: \(error.localizedDescription)"
        }
    }

    private func loadTrims() {
        guard let url = storage?.appending(path: "trims.json"), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            trims = try JSONDecoder().decode([String: Trim].self, from: Data(contentsOf: url))
        } catch {
            let aside = url.deletingLastPathComponent().appending(path: "trims.json.unreadable-\(Int(Date.now.timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                problem = "couldn't read your trims, so songs play whole. the old file is \(aside.lastPathComponent)"
            } catch {
                trimsWritable = false
                problem = "couldn't read your trims or set the file aside, so songs play whole and changes to trims won't be saved: \(error.localizedDescription)"
            }
        }
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
        // written beside it first, so a picture that can't be written leaves the old one where it is
        let fresh = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).new")
        defer { try? FileManager.default.removeItem(at: fresh) }
        do {
            try CoverFile.write(data, to: fresh, credit: credit)
            if FileManager.default.fileExists(atPath: url.path) {
                try trash(url)
            }
            try FileManager.default.moveItem(at: fresh, to: url)
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

        /// None in the silence before an hour's first piece.
        var path: String?
        var elapsed: Double?
        var restLeft: Double?
        var source: String?
        var upNext: [Entry]
        /// The hour this was playing for, if any.
        var hour: UUID?
        /// What it was started from, so that page's play button still knows.
        var origin: Origin?
        var fromAlarm: Bool?
        var sleep: Machine.Sleep?
        var rise: Double?
        var hourEnding: Bool?
        var paused: Bool?
        var ownVolume: Double?
        var rowVolume: Double?
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
        case .track(let track): state = path.map { ResumeState(path: $0, elapsed: track.elapsed, restLeft: nil, source: playingAlbum, upNext: [], origin: origin, fromAlarm: fromAlarm) }
        case .resting: state = ResumeState(path: path, elapsed: nil, restLeft: machine.restRemaining, source: playingAlbum, upNext: [], origin: origin, fromAlarm: fromAlarm)
        case .idle: state = nil
        // a moment between pieces; the next status change saves
        case .loading, .ending: return
        }
        guard var state else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        state.upNext = upNext.map { ResumeState.Entry(path: $0.path, source: $0.source) }
        state.hour = hourPlaying
        (state.sleep, state.rise, state.hourEnding, state.paused) = (machine.sleep, machine.rise, hourEnding, machine.paused && resuming == nil)
        (state.ownVolume, state.rowVolume) = (ownVolume, rowVolume)
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't save where playback is: \(error.localizedDescription)"
        }
    }

    /// Picks up where the last run left off, paused: the same piece at the same spot (it fades back in on play), or
    /// the same gap with the same time left. An hour that was playing goes on by itself while its window is open.
    func restoreResume() {
        guard status == .idle, let url = storage?.appending(path: "resume.json"), let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data) else { return }
        (ownVolume, rowVolume) = (state.ownVolume, state.rowVolume)
        let fileURL = state.path.map { URL(filePath: $0) }
        let file = fileURL.flatMap { try? AVAudioFile(forReading: $0) }
        if let fileURL, file == nil {
            problem = "couldn't pick up where you left off: \(fileURL.lastPathComponent) isn't there anymore"
            giveVolumeBack()
            try? FileManager.default.removeItem(at: url)
            return
        }
        upNext = state.upNext.map { QueueEntry(path: $0.path, source: $0.source) }
        origin = state.origin
        fromAlarm = state.fromAlarm ?? false
        // still the hour's while its window is open; past it, the next check ends it like any closing window
        hourPlaying = state.hour
        if state.paused != true, let hour = alarms.first(where: { $0.id == state.hour }), hour.lastFired != nil,
           hour.window(containing: .now)?.start == hour.lastFired {
            resumingHour = true
        }
        // an alarm too, unless it's from so long ago that nobody wants it
        let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if state.paused != true, fromAlarm, Date.now.timeIntervalSince(saved) < Self.resumeWithin {
            resumingHour = true
        }
        hourEnding = state.hourEnding ?? false
        useAlbumSettings(for: state.source)
        self.file = file
        if let path = state.path, let fileURL {
            current = catalog.songsByID[path]
            title = current?.title ?? fileURL.deletingPathExtension().lastPathComponent
            trackGain = gain(of: path)
        }
        startedAt = Date()
        if let elapsed = state.elapsed, let file {
            // scheduled from that frame when play is pressed, like after a device change
            needsReschedule = true
            send(.restoreTrack(duration: useSpan(of: file), at: elapsed))
        } else {
            send(.restoreRest(left: state.restLeft ?? 0))
        }
        send(.restoreLevels(sleep: state.sleep, rise: state.rise))
        refreshSleep()
        resumeHour()
    }

    /// Not before there's a catalog, which the hour needs to go round its songs.
    private func resumeHour() {
        guard resumingHour, !catalog.songsByID.isEmpty else { return }
        resumingHour = false
        if hourPlaying != nil || fromAlarm, status == .paused { command(.resume) }
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
        // the file too: "A/B" lands on A-B.m3u8, and a file that couldn't be read isn't in the list
        while playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame })
            || FileManager.default.fileExists(atPath: store.url(for: candidate).path) {
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
        update(id) { $0.insert(songs.map(\.id), at: index ?? $0.paths.count) }
    }

    public func removeFromPlaylist(_ id: String, at offsets: IndexSet) {
        guard let before = playlists.first(where: { $0.id == id }) else { return }
        let removed = offsets.filter(before.paths.indices.contains).map { ($0, before.paths[$0]) }
        update(id) { $0.remove(at: offsets) }
        undo?.registerUndo(withTarget: self) { controller in
            controller.update(id) { playlist in
                for (i, path) in removed { playlist.insert([path], at: i) }
                // nothing else has changed since, so the parts can be just as they were
                if playlist.paths == before.paths { (playlist.breaks, playlist.partNames) = (before.breaks, before.partNames) }
            }
            controller.undo?.registerUndo(withTarget: controller) { $0.removeFromPlaylist(id, at: IndexSet(removed.map(\.0))) }
        }
        undo?.setActionName("Remove from collection")
    }

    /// A part of the collection starts at this song, or stops starting there.
    public func setBreak(_ on: Bool, at index: Int, in id: String) {
        update(id) { playlist in
            guard index > 0, index < playlist.paths.count else { return }
            if on { playlist.breaks.insert(index) } else {
                playlist.breaks.remove(index)
                playlist.partNames[index] = nil
            }
        }
    }

    /// Calls the part starting at this song `name`; an empty name puts its number back.
    public func namePart(_ name: String, at index: Int, in id: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.partNames[index] = name.isEmpty ? nil : name }
    }

    public func movePlaylistSongs(_ id: String, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        update(id) { $0.move(offsets, to: destination) }
    }

    public func setGaps(_ gaps: Settings?, for id: String) {
        update(id) {
            $0.gaps = gaps
            $0.unreadGaps = nil
        }
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

    func loadPlaylists() {
        guard let store = playlistStore else { return }
        let (loaded, unreadable) = store.load()
        if loaded != playlists {
            playlists = loaded
        }
        sayPlaylistTrouble(unreadable: unreadable)
        sayEmptyRows()
        loadPlaylistCovers()
        watchPlaylists()
    }

    /// Only when it changes: our own writes come back through the watcher and mustn't bring back what's been dismissed.
    private func sayPlaylistTrouble(unreadable: [String]) {
        var trouble = unreadable.map { "couldn't read \($0), so it isn't listed. the file is left as it is" }
        trouble += playlists.filter { $0.unreadGaps != nil }.map { "couldn't read the gaps in \($0.name), so it plays with yours. the file is left as it is" }
        let said = trouble.isEmpty ? nil : trouble.joined(separator: "; ")
        guard said != playlistProblem else { return }
        if problem == playlistProblem { problem = nil }
        playlistProblem = said
        if let said { problem = said }
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

    /// Plays a queued song now; what was queued after it still follows.
    public func playQueued(_ id: QueueEntry.ID) {
        guard let i = upNext.firstIndex(where: { $0.id == id }) else { return }
        upNext.insert(upNext.remove(at: i), at: 0)
        if status == .idle {
            failures = 0
            command(.start)
        } else {
            command(.skip)
        }
    }

    public func clearQueue() {
        let queued = upNext
        upNext.removeAll()
        undo?.registerUndo(withTarget: self) { controller in
            controller.upNext = queued
            controller.undo?.registerUndo(withTarget: controller) { $0.clearQueue() }
        }
        undo?.setActionName("Clear queue")
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
        // watching a folder's own path says nothing when its drive comes back; a mount shows up only from above it
        let paths = urls.map(\.path) + (unreachableFolders.isEmpty ? [] : ["/Volumes"])
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
            scanned = true
            library.merge(found)
            refreshTracks()
            catchUpAlarms()
            saveLibrary()
            analyzePending()
            if found.unreachable != unreachableFolders {
                sayUnreachable(found.unreachable)
                // once more, so the watcher above can see the drive come back
                rescan()
            }
        }
    }

    private func sayUnreachable(_ paths: [String]) {
        unreachableFolders = paths
        if problem == unreachableProblem { problem = nil }
        unreachableProblem = nil
        guard !paths.isEmpty else { return }
        let names = paths.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ")
        unreachableProblem = "can't reach \(names). the songs there won't play until \(paths.count == 1 ? "it's" : "they're") back, and what's known about them is kept"
        problem = unreachableProblem
    }

    public func toggle() {
        // a press says what happens now, so nothing goes on trying behind it
        defer { endResuming() }
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
        endResuming()
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
            saveResume()
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
            if let preset = allPresets.first(where: { $0.name.lowercased() == name }) {
                apply(preset)
            }
        case "sleep":
            switch url.lastPathComponent.lowercased() {
            case "off": cancelSleep()
            case "after": sleepAfterCurrent()
            // a day at most: the ticker turns what's left into an Int
            case let minutes: if let minutes = Double(minutes), minutes > 0, minutes <= 24 * 60 { sleep(minutes: minutes) }
            }
        default:
            break
        }
    }

    public func systemWillSleep(now: Date = .now) {
        endResuming()
        guard status == .playing || status == .resting else { return }
        // closing the lid with a sleep timer set means stop, not resume in the morning
        if machine.sleep != nil {
            command(.sleepNow)
            return
        }
        pausedForSleep = now
        command(.pause)
    }

    public func systemDidWake(now: Date = .now) {
        // a drive or a share is often back by now, and coming back doesn't always tell the watcher
        if library.entries.values.contains(where: { $0.unreachable == true }) { rescan() }
        guard let since = pausedForSleep else { return }
        pausedForSleep = nil
        if now.timeIntervalSince(since) < Self.resumeWithin { command(.resume) }
    }

    func advance(_ seconds: Double) {
        send(.tick(seconds))
        guard let left = jumpIn, status == .playing else { return }
        jumpIn = left - seconds
        if left - seconds <= 0 {
            reschedule()
            players[active].play()
        }
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
        guard entries != catalogEntries else {
            sayEmptyRows()
            return
        }
        catalogEntries = entries
        catalogBuilt = false
        lastCatalogBuild = .now
        catalogGeneration += 1
        let generation = catalogGeneration
        Task {
            let built = await Task.detached(priority: .userInitiated) { Catalog(entries: entries) }.value
            guard generation == catalogGeneration else { return }
            catalog = built
            catalogBuilt = true
            sayEmptyRows()
            catchUpAlarms()
            resumeHour()
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
        // a stop can come while status still says idle: the first file of an alarm can fail before it says anything else
        var ended = new == .idle && status != .idle
        if case .stop = event { ended = true }
        if ended {
            retrying = nil
            engineFailures = 0
            hourEnding = false
            fromAlarm = false
            partDue = nil
            giveVolumeBack()
        }
        guard new != status else { return }
        status = new
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
            // the last of the sound, as in stopTrack
            if case .track = machine.phase {} else { engine.pause() }
        case .pausePlayback:
            players.forEach { $0.pause() }
            engine.pause()
        case .seekPlayback:
            seeks += 1
            defer { saveResume() }
            // picked up from the new spot on resume, like after a device change
            needsReschedule = true
            if status != .paused {
                // the old spot goes on under the mixer's way down, so the jump itself is silent
                jumpIn = Self.mixerRamp
            }
            if case .track(let track) = machine.phase {
                nowPlaying?.update(status: status, title: title, track: track)
            }
        case .resumePlayback:
            do {
                try startEngine(engine)
                if problem == playbackProblem { problem = nil }
            } catch {
                problem = "couldn't restart audio output: \(error.localizedDescription)"
                playbackProblem = problem
                // not playing, so nothing may say it is
                keepResuming()
                send(.pause)
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
        let queued = retrying ?? dequeue()
        retrying = nil
        guard let path = queued ?? (fromAlarm ? nil : shuffler.next(from: tracks.map(\.path), avoidingLast: settings.avoidLastN, using: &rng)) else {
            if fromAlarm, failures > 0 {
                problem = "the alarm stopped: \(failures) of its files wouldn't open"
                playbackProblem = problem
            }
            send(machine.outgoing == nil ? .stop : .finish)
            return
        }
        let url = URL(filePath: path)
        let deck = players[active]
        do {
            let file = try AVAudioFile(forReading: url)
            deck.stop()
            mixers[active].outputVolume = 0
            do {
                try startEngine(engine)
                engineFailures = 0
            } catch {
                waitForEngine(path, error)
                return
            }
            let duration = useSpan(of: file)
            // a crossfade's incoming deck has to sound from its first frame, and its mixer has already landed
            if machine.outgoing == nil { scheduleSilence(on: deck) }
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
            if problem == playbackProblem { problem = nil }
            send(.trackStarted(duration: duration))
            spendPart()
            publish()
            saveResume()
        } catch {
            failures += 1
            // ponytail: gives up after as many failures in a row as there are tracks, not after trying each one
            guard failures < tracks.count else {
                problem = "couldn't play anything in your folders: \(error.localizedDescription)"
                playbackProblem = problem
                send(.stop)
                return
            }
            send(.trackFailed)
        }
    }

    private func waitForEngine(_ path: String, _ error: Error) {
        engineFailures += 1
        guard engineFailures < (fromAlarm ? Int(Self.alarmLateness) : Self.engineTries) else {
            engineFailures = 0
            problem = "\(fromAlarm ? "the alarm waited ten minutes and gave up. " : "")couldn't start audio output: \(error.localizedDescription)"
            playbackProblem = problem
            send(.stop)
            return
        }
        if engineFailures == 1 {
            problem = "waiting for audio output: \(error.localizedDescription)"
            playbackProblem = problem
        }
        retrying = path
        Task {
            try? await Task.sleep(for: retryWait)
            if retrying == path, case .loading = machine.phase { startNextTrack() }
        }
    }

    func analyzePending() {
        guard analysis == nil else { return }
        // once a run: nothing marks one that won't read, so it would come straight back
        let pending = library.pending.map { ($0, library.entries[$0]?.loudness == nil) } + purgedCovers().filter { coversTried.insert($0).inserted }.map { ($0, false) }
        guard !pending.isEmpty else { return }
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
                        } else if FileManager.default.fileExists(atPath: path) {
                            // already analysed, this was only for its cover, and one failed read doesn't make a bad file
                            if library.entries[path]?.loudness == nil || library.entries[path]?.meta == nil {
                                library.entries[path]?.unplayable = true
                            }
                        } else {
                            // a drive pulled mid-pass, not a bad file; the next scan sorts it out
                            library.entries[path]?.unreachable = true
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

    /// Songs whose cover the system purged from Caches: only reading the file again brings it back. Their tags stay
    /// in place meanwhile, since clearing them would break up their albums for as long as that takes.
    private func purgedCovers() -> [String] {
        guard let artwork else { return [] }
        var there: [String: Bool] = [:]
        return library.entries.compactMap { path, entry in
            guard let key = entry.meta?.artwork, !entry.unplayable, entry.unreachable != true else { return nil }
            let found = there[key] ?? artwork.has(key)
            there[key] = found
            return found ? nil : path
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
        guard let url = storage?.appending(path: "profile.json"), FileManager.default.fileExists(atPath: url.path) else { return (nil, nil, true) }
        do {
            return (try JSONDecoder().decode(ProfileFile.self, from: Data(contentsOf: url)), nil, true)
        } catch {
            let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let aside = url.deletingLastPathComponent().appending(path: "profile.json.unreadable-\(stamp)-\(Int(Date.now.timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                return (nil, "couldn't read your settings or set the old ones aside, so changes to them won't be saved: \(error.localizedDescription)", false)
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
            try encoder.encode(ProfileFile(settings: yourSettings, albums: albumSettings, presets: customPresets)).write(to: url, options: .atomic)
        } catch {
            problem = "couldn't save your settings: \(error.localizedDescription)"
        }
    }

    private func loadLibrary() {
        guard let url = storage?.appending(path: "library.json") else { return }
        do {
            library = try Library.load(from: url)
        } catch {
            // the folder list is in the file too, so there's nothing to rebuild from until they're added again
            let aside = url.deletingLastPathComponent().appending(path: "library.json.broken-\(Int(Date.now.timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                problem = "couldn't read the library, and your list of folders went with it, so add your folders again. the old file is \(aside.lastPathComponent)"
            } catch {
                libraryWritable = false
                problem = "couldn't read the library or set the file aside, so your list of folders is gone for now and changes won't be saved: \(error.localizedDescription)"
            }
        }
        refreshTracks()
    }

    /// Encoding a 20k-entry library takes ~100 ms, so it happens off the main actor, one save after another.
    private func saveLibrary() {
        guard libraryWritable, let url = storage?.appending(path: "library.json") else { return }
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
            problem = "couldn't save what's playing for the alarm backup and other apps to read: \(error.localizedDescription)"
        }
        // userInfo only arrives because the app isn't sandboxed
        DistributedNotificationCenter.default().postNotificationName(.init("com.alanbagel.sottova.status"), object: nil, userInfo: info, deliverImmediately: true)
    }

    /// The engine stops and drops scheduled audio on a device change, so pause and pick up from the same frame on resume.
    /// An alarm goes on by itself, since nobody's there to press play.
    private func engineConfigurationChanged() {
        if case .track = machine.phase { needsReschedule = true }
        guard status == .playing else { return }
        keepResuming()
        command(.pause)
    }

    /// An alarm goes on by itself, since nobody's there to press play.
    private func keepResuming() {
        guard fromAlarm, resuming == nil else { return }
        resuming = Task {
            defer { if !Task.isCancelled { resuming = nil } }
            for _ in 0..<Int(Self.alarmLateness) {
                try? await Task.sleep(for: retryWait)
                guard !Task.isCancelled, fromAlarm, status == .paused else { return }
                command(.resume)
                if status != .paused { return }
            }
            problem = "the alarm waited ten minutes for audio output and gave up, so it's paused"
            playbackProblem = problem
        }
    }

    private func endResuming() {
        guard let task = resuming else { return }
        task.cancel()
        resuming = nil
        saveResume()
    }

    /// ponytail: only the current deck is rescheduled; a crossfade's outgoing track is dropped on a device change
    private func reschedule() {
        needsReschedule = false
        jumpIn = nil
        guard let file, case .track(let track) = machine.phase else { return }
        let deck = players[active]
        let start = span.start + AVAudioFramePosition(track.elapsed * file.processingFormat.sampleRate)
        guard start < span.end else { return }
        deck.stop()
        scheduleSilence(on: deck)
        deck.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(span.end - start), at: nil, completionHandler: nil)
    }

    /// A mixer whose deck stopped on its way down to 0 freezes there and finishes on whatever plays next, so that's silence.
    private func scheduleSilence(on deck: AVAudioPlayerNode) {
        let format = deck.outputFormat(forBus: 0)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.mixerRamp * format.sampleRate))!
        silence.frameLength = silence.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            silence.floatChannelData![channel].update(repeating: 0, count: Int(silence.frameLength))
        }
        deck.scheduleBuffer(silence, completionHandler: nil)
    }

    private func log(skipped: Bool, gap: Double) {
        guard let url = storage?.appending(path: "plays.jsonl"), let file else { return }
        let record = PlayRecord(file: file.url.path, startedAt: startedAt, skipped: skipped, gapAfterSec: gap, heardSec: lastTrack?.elapsed)
        do {
            try record.append(to: url)
        } catch {
            problem = "couldn't save your play history: \(error.localizedDescription)"
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
