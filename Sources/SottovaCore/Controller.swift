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
    /// What was just done, for the window's toast; a new one replaces it.
    public var notice: Notice?
    private final class NoticeUndoTarget: NSObject {}
    @ObservationIgnored private var noticeUndo: NoticeUndoTarget?
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
    @ObservationIgnored private var pausedByHand: Date?
    /// A longer sleep doesn't pick up where it was: often that's a scheduled wake, with nobody there.
    static let resumeWithin: TimeInterval = 60 * 60
    /// An alarm started what's playing: when its music ends it stops, with nobody there to press stop.
    @ObservationIgnored private var fromAlarm = false
    /// When that alarm was for.
    @ObservationIgnored private var alarmDue: Date?
    /// The Mac went to sleep with an alarm still after the device: the wake decides whether it goes on.
    @ObservationIgnored private var tryingOverSleep = false
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
    @ObservationIgnored private var queueTaken = 0
    @ObservationIgnored private var lastCatalogBuild = Date.distantPast
    @ObservationIgnored private var catalogEntries: [String: Library.Entry] = [:]
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var saving: Task<Void, Never>?

    /// `storage` holds library.json, profile.json, status.json and plays.jsonl; tests pass nil to keep nothing on disk.
    /// `playlistFolder` holds the .m3u8 files; nil keeps playlists in memory only.
    public init(engine: AVAudioEngine = AVAudioEngine(), storage: URL? = .applicationSupportDirectory.appending(path: "Sottova"),
                playlistFolder: URL? = nil, artworkFolder: URL = .cachesDirectory.appending(path: "Sottova/Covers")) {
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
        #if SHOT
        ShotEnv.noteTick(now - lastTick, fast: tickInterval <= .milliseconds(10))
        #endif
        self.lastTick = now
        advance((now - lastTick) / .seconds(1))
    }

    /// A skip or pause mid-hold must not wait for the slow tick: bring the clock up to now, act, then restart the clock.
    private func command(_ event: Machine.Event) {
        catchUp()
        if case .skip = event { skips += 1 }
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
        // collections' silence undoes itself, through setGaps
        let albums = albumSettings.keys.filter { albumSettings[$0]?.name == name }
        // yours, and not what a playing album lays over it
        let yours = yourSettings.name == name
        let preset = customPresets.remove(at: i)
        everyoneOn(name) {
            var s = $0
            s.name = "Custom"
            return s
        }
        if settings.name == name { settings.name = "Custom" }
        saveProfile()
        undo?.registerUndo(withTarget: self) { controller in
            // the Custom copy this made gets its name back; a change since stays as it is
            func named(_ s: Settings) -> Settings? {
                var back = s
                back.name = name
                return s.name == "Custom" && preset.gaps(over: s) == back ? back : nil
            }
            // first: settings named for a preset that isn't there turn Custom
            controller.customPresets.insert(preset, at: min(i, controller.customPresets.count))
            for id in albums { if let back = controller.albumSettings[id].flatMap(named) { controller.albumSettings[id] = back } }
            if yours {
                if let own = controller.ownSettings, controller.settings == controller.albumApplied {
                    controller.ownSettings = named(own) ?? own
                } else if let back = named(controller.settings) {
                    controller.settings = back
                }
            }
            controller.saveProfile()
            controller.undo?.registerUndo(withTarget: controller) { $0.deletePreset(name) }
        }
        did("Delete \(name)", "Deleted \(name)", back: "Put back \(name)")
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
    /// `row` is the alarm this is for and the time it's for. `key` is what Play buttons know it by, when that isn't
    /// its songs and source.
    public func play(_ songs: [Song], from index: Int = 0, source: String? = nil, shuffled: Bool = false, row: (id: Alarm.ID, time: Date)? = nil,
                     key: String? = nil) {
        guard songs.indices.contains(index) else { return }
        // first, since it can end what's playing: the check below and the alarm's marks have to come after that
        catchUp()
        releaseHour()
        giveVolumeBack()
        // what you paused is gone, so the pause is too
        pausedByHand = nil
        fromAlarm = row != nil
        alarmDue = row?.time
        partDue = row
        origin = Origin(key: key ?? Origin.key(of: songs, source: source), shuffled: shuffled)
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
        let at = min(index, upNext.count)
        var queue = upNext
        queue.insert(contentsOf: songs.map { QueueEntry(path: $0.id, source: source) }, at: at)
        let what = called(songs.map(\.id)), back = "Took \(what) out of the queue"
        if at == 0 {
            setQueue(queue, songs.count == 1 ? "Play next" : "Play \(Self.songsTitle(songs.count)) next", "Playing \(what) next", back: back)
        } else {
            setQueue(queue, "Add \(Self.songsTitle(songs.count)) to queue", "Added \(what) to the queue", back: back)
        }
    }

    public struct Notice: Equatable {
        public let id = UUID()
        public let text: String
        /// The toast offers Undo.
        public let undoable: Bool
        /// Edit › Undo's name for it: the toast's Undo only stands while it's still the one on top.
        public let action: String?

        public init(_ text: String, undoable: Bool, action: String? = nil) {
            (self.text, self.undoable, self.action) = (text, undoable, action)
        }
    }

    /// Next to an undo registration: names it in Edit › Undo and says it in the toast. Undo says `back`, redo says
    /// `text` again. Steps run by an undo or redo say nothing of their own.
    public func did(_ action: String, _ text: String, back: String) {
        undo?.setActionName(action)
        if let undo, undo.isUndoing || undo.isRedoing { return }
        say(text, undoable: undo != nil, then: back, action: action)
    }

    /// Registered after the change, so an undo runs it first and a can't-undo said by the change itself wins.
    private func say(_ text: String, undoable: Bool, then other: String, action: String) {
        notice = Notice(text, undoable: undoable, action: action)
        let target = NoticeUndoTarget()
        noticeUndo = target
        undo?.registerUndo(withTarget: target) { [weak self, target] _ in
            withExtendedLifetime(target) {
                self?.say(other, undoable: !undoable, then: text, action: action)
            }
        }
    }

    /// "Weep you no more", or "3 songs".
    private func called(_ paths: [String]) -> String {
        guard paths.count == 1, let path = paths.first else { return "\(paths.count) songs" }
        return catalog.songsByID[path]?.title ?? URL(filePath: path).deletingPathExtension().lastPathComponent
    }

    /// "song" or "3 songs", for Edit › Undo.
    private static func songsTitle(_ n: Int) -> String {
        n == 1 ? "song" : "\(n) songs"
    }

    // MARK: Alarms

    public private(set) var alarms: [Alarm] = []
    /// The main window's, or Settings' while it's in front, so Edit › Undo brings back what was removed.
    @ObservationIgnored public weak var undo: UndoManager?
    @ObservationIgnored private var alarmTimer: DispatchSourceTimer?
    /// What that timer is for.
    @ObservationIgnored private var armed: (id: Alarm.ID, at: Date)?
    /// Held while an alarm is set: an idle menu-bar app gets App Nap, which may hold its timers back.
    @ObservationIgnored private var alarmActivity: NSObjectProtocol?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions?

    public func addAlarm(_ alarm: Alarm) {
        alarms.append(alarm)
        alarmsChanged()
        undo?.registerUndo(withTarget: self) { $0.removeAlarm(alarm.id) }
        did("Add \(alarm.name)", "Added \(alarm.name) to your day", back: "Took \(alarm.name) off your day")
    }

    /// The one way to edit an alarm, on the row as it is now: a copy held since before it last went off would bring
    /// back a time already played. Undo brings back what you set, never when it last went off.
    /// `action` names it in Edit › Undo; "Change Lauds" without one.
    public func changeAlarm(_ id: Alarm.ID, action: String? = nil, _ change: (inout Alarm) -> Void) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        let old = alarms[i]
        change(&alarms[i])
        alarms[i].prune()
        // or a one-off whose day has gone drops at the next launch
        alarms[i].scheduleOnce()
        // firing deletes a one-off with this set, so one that was something else would go unplayed with the next alarm
        if alarms[i].weekdays.isEmpty, !alarms[i].whileHere { alarms[i].lastFired = nil }
        alarmsChanged()
        // a part picked by hand is yours to undo; one the row moved on to by playing isn't
        let part = alarms[i].nextPart == old.nextPart ? nil : old.nextPart
        undo?.registerUndo(withTarget: self) { controller in
            controller.changeAlarm(id) {
                $0.setUserFields(from: old)
                if let part { $0.nextPart = part }
            }
        }
        did(action ?? "Change \(old.name)", "Changed \(old.name)", back: "Put \(old.name) back as it was")
    }

    public func removeAlarm(_ id: Alarm.ID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        let alarm = alarms.remove(at: i)
        alarmsChanged()
        undo?.registerUndo(withTarget: self) { $0.insertAlarm(alarm, at: i) }
        did("Delete \(alarm.name)", "Deleted \(alarm.name)", back: "Put back \(alarm.name)")
    }

    private func insertAlarm(_ alarm: Alarm, at i: Int) {
        var alarm = alarm
        alarm.scheduleOnce()
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
        let lastSaved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
        for i in alarms.indices { alarms[i].prune() }
        if let lastSaved {
            for i in alarms.indices {
                alarms[i].missed = alarms[i].missedWhileGone(lastSaved: lastSaved, booted: Self.bootTime(), now: .now, lateness: Self.alarmLateness) ?? alarms[i].missed
            }
        }
        if alarms != saved {
            alarmsChanged()
        } else {
            armAlarm()
        }
    }

    private static func bootTime() -> Date {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return Date(timeIntervalSince1970: Double(boot.tv_sec))
    }

    /// One timer for the soonest alarm, on the wall clock: it still fires on time after the Mac has slept, and
    /// `.strict` keeps App Nap from sliding it while the app sits idle in the menu bar.
    func armAlarm(now: Date = .now) {
        alarmTimer?.cancel()
        alarmTimer = nil
        let next = nextAlarm(after: now)
        // an alarm keeps the app awake to its timer and the Mac from sleeping when idle (the screen still turns off);
        // an hour only needs its checks on time, since it plays only while you're there
        let wanted: ProcessInfo.ActivityOptions? = next != nil ? .userInitiated
            : alarms.contains { $0.on && $0.whileHere } ? .userInitiatedAllowingIdleSystemSleep : nil
        if wanted != activityOptions {
            alarmActivity.map(ProcessInfo.processInfo.endActivity)
            alarmActivity = wanted.map { ProcessInfo.processInfo.beginActivity(options: $0, reason: next != nil ? "an alarm is set" : "an hour is set") }
            activityOptions = wanted
        }
        // a timer whose time has passed and hasn't run, as after a wake when the clock's notice comes first, still runs:
        // only that one, or a row saved for a minute ago would go off as it's saved
        let late = armed.flatMap { armed in
            armed.at <= now && alarms.contains { $0.id == armed.id && $0.on && !$0.whileHere && $0.lastFired != armed.at && $0.next(after: armed.at - 1) == armed.at } ? armed : nil
        }
        armed = late ?? next.map { ($0.alarm.id, $0.at) }
        guard let (id, at) = armed else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + max(at.timeIntervalSince(now), 0), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // not armed again by what fire does: it can leave the alarm unspent for catch-up
                self?.armed = nil
                self?.fire(id, due: at)
            }
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
        // the clock was set back past it, or the day was taken off after the timer was set: quiet, and not missed
        if alarms[index].lastFired == due || alarms[index].isOff(due) {
            armAlarm()
            return
        }
        alarms[index].lastFired = due
        let late = now.timeIntervalSince(due) > Self.alarmLateness
        alarms[index].missed = late ? Alarm.Missed(at: due, why: .asleep) : nil
        if late {
            // only the soonest had a timer; any others passed in the same sleep are too late to catch up
            for i in alarms.indices where i != index {
                if let passed = alarms[i].missedWhileGone(lastSaved: due, booted: .distantPast, now: now, lateness: Self.alarmLateness) {
                    alarms[i].missed = Alarm.Missed(at: passed.at, why: .asleep)
                }
            }
        }
        let alarm = alarms[index]
        var played = false
        if late {
            problem = "the \(alarm.name) alarm didn't play: the mac was asleep at \(due.formatted(date: .omitted, time: .shortened))"
        } else if alarm.heedsCalendar, calendarBusy() {
            problem = "\(alarm.name) didn't play at \(due.formatted(date: .omitted, time: .shortened)): your calendar had something on"
        } else if case let songs = rowSongs(alarm), !songs.isEmpty {
            played = true
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
        for (other, at) in played ? dueAlarms(now: now) : [] {
            problem = "\(other.name) didn't play at \(at.formatted(date: .omitted, time: .shortened)): \(alarm.name) was starting"
            if let i = alarms.firstIndex(where: { $0.id == other.id }) { alarms[i].lastFired = at }
        }
        alarms.removeAll { $0.weekdays.isEmpty && !$0.whileHere && $0.lastFired != nil }
        alarmsChanged()
        // this one stayed quiet, so one still in time gets its turn; each go spends one, so this ends
        if !played, let next = dueAlarms(now: now).max(by: { $0.at < $1.at }) { fire(next.alarm.id, due: next.at, now: now) }
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

    /// A row's parts by name, in turn, and the one it plays next.
    public func partChoices(for alarm: Alarm) -> (names: [String], next: Int) {
        let all = parts(for: alarm)
        let own = playlists.first { $0.id == alarm.source && !$0.breaks.isEmpty }.map(ownParts(of:))
        let names = all.indices.map { index in own.flatMap { index < $0.count ? $0[index].name : nil } ?? "part \(index + 1)" }
        return (names, partIndex(from: alarm.nextPart, in: all) ?? 0)
    }

    /// A row missed earlier, from what it would have played and at its volume. Not its firing: its time has gone, so
    /// nothing rises, and the part it's on stays next.
    public func playNow(_ alarm: Alarm) {
        // not rowSongs: the time this is for never played, so yesterday's spent part doesn't count
        var unspent = alarm
        unspent.partSpent = nil
        let songs = rowSongs(unspent)
        guard !songs.isEmpty else { return }
        play(alarm.shuffled ? songs.shuffled() : songs, source: playlists.contains { $0.id == alarm.source } ? alarm.source : nil, shuffled: alarm.shuffled)
        useRowVolume(alarm.volume)
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

    // MARK: What the screens say

    /// The row this music is for: an hour while it has the music, or the alarm that started it, by the time it went
    /// off, so it survives a relaunch. A one-off is gone once fired, so it has none.
    public var soundingRow: Alarm? {
        status == .idle ? nil : rowInCharge
    }

    private var rowInCharge: Alarm? {
        if let hourPlaying { return alarms.first { $0.id == hourPlaying } }
        guard fromAlarm, let alarmDue else { return nil }
        return alarms.first { !$0.whileHere && $0.lastFired == alarmDue }
    }

    /// In a gap, paused or not. Like the gain these change with the ticks and aren't observed, so views poll them.
    public var inSilence: Bool { machine.restRemaining != nil }
    /// An alarm is still coming up to its volume.
    public var rising: Bool { machine.rise != nil }
    /// The sleep timer has started bringing it down.
    public var easing: Bool {
        guard case .timer(let left, let fade)? = machine.sleep else { return false }
        return left < fade
    }
    /// A piece is held up by a device that won't start: the status says playing, the speakers say otherwise.
    public var waitingForDevice: Bool { retrying != nil }
    /// The album or playlist this piece came from; nil for the shuffler's pick or a mix of albums.
    public var playingFrom: String? { status == .idle ? nil : currentSource }

    public struct Played: Equatable, Sendable {
        public let at: Date
        public let path: String
        public let title: String
        /// The row it played for, by its name now.
        public let row: String?
        public let artwork: String?
    }

    /// What played today, soonest first, from the log and the piece that's on, which is only logged once it's over.
    public func playedToday(now: Date = .now, calendar: Calendar = .current) -> [Played] {
        let played = { (path: String, at: Date, row: Alarm.ID?) in
            Played(at: at, path: path, title: self.catalog.songsByID[path]?.title ?? URL(filePath: path).deletingPathExtension().lastPathComponent,
                   row: self.alarms.first { $0.id == row }?.name, artwork: self.catalog.songsByID[path]?.artwork)
        }
        var today = storage.map { PlayRecord.read($0.appending(path: "plays.jsonl"), last: 2000) }?
            .filter { calendar.isDate($0.startedAt, inSameDayAs: now) }.map { played($0.file, $0.startedAt, $0.row) } ?? []
        if status != .idle, !inSilence, let path = file?.url.path, calendar.isDate(startedAt, inSameDayAs: now) {
            today.append(played(path, startedAt, pieceRow))
        }
        return today
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
    @ObservationIgnored private var currentSource: String?
    /// The row in charge when this piece started, for the play log: it's written at the end, after a press may have changed that.
    @ObservationIgnored private var pieceRow: Alarm.ID?
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
        // paused counts as not playing: often it's only how a relaunch or a restart left things.
        // a pause you pressed since the window opened is still yours
        // not before there's a catalog, which it needs to find its songs
        if hourPlaying == nil, let current, let window = open,
           status == .idle || status == .paused && !alarmTrying && (pausedByHand ?? .distantPast) < window.start,
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
        let before = trims[path]
        guard trim != before else { return }
        trims[path] = trim
        undo?.registerUndo(withTarget: self) { $0.setTrim(before, for: path) }
        let name = called([path])
        did("Trim \(name)", trim == nil ? "\(name) plays whole again" : "Trimmed \(name)", back: "Put \(name) back as it was")
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
        let songs = album.songs.map(\.id)
        replaceCover(at: url, with: data, credit: credit, of: album.title) { controller in
            for song in songs {
                controller.library.entries[song]?.meta = nil
            }
            controller.analyzePending()
        }
    }

    /// Writes the picture beside the playlist's file, as "<name>.jpg".
    public func setCover(_ data: Data, credit: String?, forPlaylist id: String) {
        guard let name = playlists.first(where: { $0.id == id })?.name else { return }
        replaceCover(at: Self.coverURL(forPlaylist: id), with: data, credit: credit, of: name) { $0.loadPlaylistCovers() }
    }

    public static func coverURL(forPlaylist id: String) -> URL {
        URL(filePath: id).deletingPathExtension().appendingPathExtension("jpg")
    }

    private func replaceCover(at url: URL, with data: Data, credit: String?, of title: String, reread: @escaping (Controller) -> Void) {
        do {
            putCover(try CoverFile.jpeg(data, credit: credit), at: url, of: title, reread: reread)
        } catch {
            problem = "couldn't save the cover: \(error.localizedDescription)"
        }
    }

    /// Puts these bytes where the cover goes, or takes it away. The one there goes to the Trash, and its bytes stay here for undo.
    private func putCover(_ bytes: Data?, at url: URL, of title: String, reread: @escaping (Controller) -> Void) {
        // written beside it first, so a picture that can't be written leaves the old one where it is
        let fresh = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).new")
        defer { try? FileManager.default.removeItem(at: fresh) }
        let old: Data?
        do {
            try bytes?.write(to: fresh)
            old = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            if old != nil {
                try trash(url)
            }
            if bytes != nil {
                try FileManager.default.moveItem(at: fresh, to: url)
            }
        } catch {
            if let undo, undo.isUndoing || undo.isRedoing {
                notice = Notice("couldn't put \(title)'s cover back: \(error.localizedDescription)", undoable: false)
                // its redo would only say the cover changed
                if let noticeUndo { undo.removeAllActions(withTarget: noticeUndo) }
            } else {
                problem = "couldn't save the cover: \(error.localizedDescription)"
            }
            return
        }
        reread(self)
        undo?.registerUndo(withTarget: self) { $0.putCover(old, at: url, of: title, reread: reread) }
        did("Change cover", "Changed the cover of \(title)", back: "Put \(title)'s cover back as it was")
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
        /// Where the piece came from, gaps of its own or not. `source` is only for those that have them.
        var playingFrom: String?
        var upNext: [Entry]
        /// The hour this was playing for, if any.
        var hour: UUID?
        /// What it was started from, so that page's play button still knows.
        var origin: Origin?
        var fromAlarm: Bool?
        var alarmDue: Date?
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
        (state.sleep, state.rise, state.hourEnding, state.paused) = (machine.sleep, machine.rise, hourEnding, machine.paused && resuming == nil && !tryingOverSleep)
        state.alarmDue = alarmDue
        state.playingFrom = currentSource
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
        alarmDue = state.alarmDue
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
        currentSource = state.playingFrom ?? state.source
        self.file = file
        if let path = state.path, let fileURL {
            current = catalog.songsByID[path]
            title = current?.title ?? fileURL.deletingPathExtension().lastPathComponent
            trackGain = gain(of: path)
        }
        startedAt = Date()
        pieceRow = rowInCharge?.id
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

    /// A new playlist named `name`, or "name 2" when that's taken. Returns its id. Edit › Undo moves it to the
    /// Trash and Redo puts it back.
    @discardableResult
    public func newPlaylist(named name: String = "New collection", songs: [Song] = []) -> String? {
        guard let id = makePlaylist(named: name, songs: songs), let made = playlists.first(where: { $0.id == id })?.name else { return nil }
        undo?.registerUndo(withTarget: self) { $0.unmake(id) }
        did("New collection", "Made \(made)", back: "Moved \(made) to the Trash")
        return id
    }

    private func makePlaylist(named name: String, songs: [Song], fromAlbum: String? = nil) -> String? {
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
        let into = playlists.first { $0.id == id }?.name ?? ""
        let what = called(songs.map(\.id))
        editParts(id, "Add \(Self.songsTitle(songs.count))", "Added \(what) to \(into)", back: "Took \(what) out of \(into)") { update(id) { $0.insert(songs.map(\.id), at: index ?? $0.paths.count) } }
    }

    public func removeFromPlaylist(_ id: String, at offsets: IndexSet) {
        guard let before = playlists.first(where: { $0.id == id }) else { return }
        let removed = offsets.filter(before.paths.indices.contains).map { ($0, before.paths[$0]) }
        let next = Dictionary(uniqueKeysWithValues: alarms.filter { $0.source == id }.map { ($0.id, $0.nextPart) })
        var went: [Int] = []
        guard update(id, { went = $0.remove(at: offsets) }) else { return }
        // a part emptied: its rows' next part is the one after it, and the parts after it move up
        var moved = false
        for i in alarms.indices where alarms[i].source == id && went.indices.contains(alarms[i].nextPart) && went[alarms[i].nextPart] != alarms[i].nextPart {
            alarms[i].nextPart = went[alarms[i].nextPart]
            moved = true
        }
        if moved { alarmsChanged() }
        undo?.registerUndo(withTarget: self) { controller in
            controller.update(id) { playlist in
                for (i, path) in removed { playlist.insert([path], at: i) }
                // nothing else has changed since, so the parts can be just as they were
                if playlist.paths == before.paths { (playlist.breaks, playlist.partNames) = (before.breaks, before.partNames) }
            }
            if moved, controller.playlists.first(where: { $0.id == id })?.paths == before.paths {
                for i in controller.alarms.indices { if let part = next[controller.alarms[i].id] { controller.alarms[i].nextPart = part } }
                controller.alarmsChanged()
            }
            controller.undo?.registerUndo(withTarget: controller) { $0.removeFromPlaylist(id, at: IndexSet(removed.map(\.0))) }
        }
        let what = called(removed.map(\.1))
        did("Remove \(Self.songsTitle(removed.count))", removed.count == 1 ? "Removed \(what)" : "Removed \(what) from \(before.name)", back: "Put back \(what)")
    }

    /// A part of the collection starts at this song, or stops starting there. Each row's next part stays the same
    /// songs: the parts after a split move up one, and a joined part's rows go to the part it joined.
    public func setBreak(_ on: Bool, at index: Int, in id: String) {
        let name = playlists.first { $0.id == id }?.name ?? ""
        editParts(id, on ? "New part" : "Join parts", on ? "Made a new part in \(name)" : "Joined two parts in \(name)", back: "Put \(name)'s parts back") {
            var split: Int?, joined: Int?, parts = 0
            let saved = update(id) { playlist in
                guard index > 0, index < playlist.paths.count, playlist.breaks.contains(index) != on else { return }
                let part = playlist.breaks.filter { $0 < index }.count
                parts = playlist.breaks.count + 1
                if on {
                    playlist.breaks.insert(index)
                    split = part
                } else {
                    playlist.breaks.remove(index)
                    playlist.partNames[index] = nil
                    joined = part + 1
                }
            }
            guard saved else { return }
            for i in alarms.indices where alarms[i].source == id && alarms[i].nextPart < parts {
                if let split, alarms[i].nextPart > split { alarms[i].nextPart += 1 }
                if let joined, alarms[i].nextPart >= joined { alarms[i].nextPart -= 1 }
            }
            if split != nil || joined != nil { alarmsChanged() }
        }
    }

    /// The rows gather where the first of them is and become a part of their own. Each step registers its own
    /// undo, so one Undo walks them back in order.
    public func newPart(from rows: IndexSet, in id: String) {
        guard let first = rows.first else { return }
        movePlaylistSongs(id, fromOffsets: rows, toOffset: first)
        setBreak(true, at: first, in: id)
        setBreak(true, at: first + rows.count, in: id)
        undo?.setActionName("New part")
    }

    /// Calls the part starting at this song `name`; an empty name puts its number back.
    public func namePart(_ name: String, at index: Int, in id: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = playlists.first { $0.id == id }?.name ?? ""
        editParts(id, "Rename part", name.isEmpty ? "Numbered the part again" : "Named the part \(name)", back: "Put \(collection)'s parts back") { update(id) { $0.partNames[index] = name.isEmpty ? nil : name } }
    }

    /// The part keeps being the one its rows play next.
    public func movePart(_ part: Int, to destination: Int, in id: String) {
        let name = playlists.first { $0.id == id }?.name ?? ""
        editParts(id, "Move part", "Moved a part of \(name)", back: "Put \(name)'s parts back") {
            var moved: [Int] = []
            guard update(id, { moved = $0.movePart(part, to: destination) }) else { return }
            for i in alarms.indices where alarms[i].source == id && moved.indices.contains(alarms[i].nextPart) {
                alarms[i].nextPart = moved[alarms[i].nextPart]
            }
            alarmsChanged()
        }
    }

    private struct PartsState: Equatable {
        let paths: [String], breaks: Set<Int>, names: [Int: String]
        let next: [UUID: Int]
    }

    private func partsState(_ id: String) -> PartsState? {
        playlists.first { $0.id == id }.map {
            PartsState(paths: $0.paths, breaks: $0.breaks, names: $0.partNames,
                       next: Dictionary(uniqueKeysWithValues: alarms.filter { $0.source == id }.map { ($0.id, $0.nextPart) }))
        }
    }

    /// One Edit › Undo for a change to a collection's parts: its songs and parts, and the part its rows play next.
    private func editParts(_ id: String, _ action: String, _ text: String, back: String, _ change: () -> Void) {
        guard let before = partsState(id) else { return }
        change()
        guard partsState(id) != before else { return }
        undo?.registerUndo(withTarget: self) { $0.restoreParts(id, to: before, action, text, back: back) }
        did(action, text, back: back)
    }

    private func restoreParts(_ id: String, to state: PartsState, _ action: String, _ text: String, back: String) {
        editParts(id, action, text, back: back) {
            guard update(id, { ($0.paths, $0.breaks, $0.partNames) = (state.paths, state.breaks, state.names) }) else { return }
            for i in alarms.indices { if let next = state.next[alarms[i].id] { alarms[i].nextPart = next } }
            alarmsChanged()
        }
    }

    public func movePlaylistSongs(_ id: String, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let playlist = playlists.first { $0.id == id }
        let name = playlist?.name ?? "", paths = playlist?.paths ?? []
        let what = called(offsets.filter(paths.indices.contains).map { paths[$0] })
        editParts(id, "Move \(Self.songsTitle(offsets.count))", "Moved \(what)", back: "Put \(name) back in its order") {
            var went: [Int] = []
            guard update(id, { went = $0.move(offsets, to: destination) }) else { return }
            var moved = false
            for i in alarms.indices where alarms[i].source == id && went.indices.contains(alarms[i].nextPart) && went[alarms[i].nextPart] != alarms[i].nextPart {
                alarms[i].nextPart = went[alarms[i].nextPart]
                moved = true
            }
            if moved { alarmsChanged() }
        }
    }

    public func setGaps(_ gaps: Settings?, for id: String) {
        guard let before = playlists.first(where: { $0.id == id }) else { return }
        undo?.registerUndo(withTarget: self) { controller in
            controller.setGaps(before.gaps, for: id)
            // a line it couldn't read comes back as it was written
            controller.update(id) { $0.unreadGaps = before.unreadGaps }
        }
        did("Change silence", "Changed the silence in \(before.name)", back: "Put back \(before.name)'s silence")
        update(id) {
            $0.gaps = gaps
            $0.unreadGaps = nil
        }
        if playingAlbum == id {
            useAlbumSettings(for: id)
        }
    }

    public func setAlbumGaps(_ gaps: Settings?, for album: Album) {
        let before = albumSettings[album.id]
        undo?.registerUndo(withTarget: self) { $0.setAlbumGaps(before, for: album) }
        did("Change silence", "Changed the silence in \(album.title)", back: "Put back \(album.title)'s silence")
        albumSettings[album.id] = gaps
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
        let old = playlists[index].name
        playlists[index].id = url.path
        playlists[index].name = name
        save(playlists[index])
        repointAlarms(from: id, to: url.path)
        upNext = upNext.map { $0.source == id ? QueueEntry(path: $0.path, source: url.path) : $0 }
        if currentSource == id { currentSource = url.path }
        if playingAlbum == id {
            playingAlbum = url.path
        }
        // what's playing is still this collection, or a pick in it, so its Play and Shuffle still know it, and a
        // relaunch finds it
        if let origin, origin.key == id || origin.key.hasSuffix("\u{0}" + id) {
            self.origin = Origin(key: origin.key.dropLast(id.count) + url.path, shuffled: origin.shuffled)
        }
        if status != .idle { saveResume() }
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loadPlaylistCovers()
        if old != name {
            undo?.registerUndo(withTarget: self) { $0.rename(url.path, to: old) }
            did("Rename \(old)", "Renamed \(old) to \(name)", back: "Put back the name \(old)")
        }
        return url.path
    }

    /// Moves the file to the Trash; Edit › Undo puts it back, with the rows on Your day it took.
    public func trashPlaylist(_ id: String) {
        guard let name = playlists.first(where: { $0.id == id })?.name else { return }
        do {
            let gone = try moveToTrash(id)
            undo?.registerUndo(withTarget: self) { $0.putBack(gone) }
            did("Move \(name) to Trash", "Moved \(name) to the Trash", back: "Put back \(name)")
        } catch {
            problem = "couldn't move the collection to the Trash: \(error.localizedDescription)"
        }
    }

    /// Where a trashed collection went, and the rows it took with it, by where they stood.
    private struct Trashed {
        let playlist: Playlist, file: URL?, cover: URL?
        let rows: [(Int, Alarm)]
    }

    private func moveToTrash(_ id: String) throws -> Trashed {
        guard let playlist = playlists.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var file: NSURL?, cover: NSURL?
        try FileManager.default.trashItem(at: URL(filePath: id), resultingItemURL: &file)
        try? FileManager.default.trashItem(at: Self.coverURL(forPlaylist: id), resultingItemURL: &cover)
        // a copy of an album gives its rows back to the album instead
        let rows = playlist.fromAlbum != nil ? [] : alarms.enumerated().filter { $0.element.source == id }.map { ($0.offset, $0.element) }
        forget(id)
        // what's left pointing at it has nothing to play; the window asks before this happens
        if !rows.isEmpty {
            alarms.removeAll { $0.source == id }
            alarmsChanged()
        }
        return Trashed(playlist: playlist, file: file as URL?, cover: cover as URL?, rows: rows)
    }

    private func putBack(_ gone: Trashed) {
        let id = gone.playlist.id
        do {
            guard let file = gone.file else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.moveItem(at: file, to: URL(filePath: id))
        } catch {
            let rows = gone.rows.isEmpty ? "" : ", so \(ListFormatter.localizedString(byJoining: gone.rows.map(\.1.name))) stay off your day"
            notice = Notice("couldn't get \(gone.playlist.name) back from the Trash\(rows): \(error.localizedDescription)", undoable: false)
            // its redo would only say it was trashed again
            if let noticeUndo { undo?.removeAllActions(withTarget: noticeUndo) }
            return
        }
        if let cover = gone.cover { try? FileManager.default.moveItem(at: cover, to: Self.coverURL(forPlaylist: id)) }
        playlists.append(gone.playlist)
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loadPlaylistCovers()
        if let album = gone.playlist.fromAlbum {
            albumSettings[album] = nil
            repointAlarms(from: album, to: id)
        }
        for (i, row) in gone.rows {
            var row = row
            row.scheduleOnce()
            alarms.insert(row, at: min(i, alarms.count))
        }
        if !gone.rows.isEmpty { alarmsChanged() }
        undo?.registerUndo(withTarget: self) { $0.trashPlaylist(id) }
    }

    /// Undoing a new collection. One a row on Your day plays stays: trashing it by ⌘Z would take the row too.
    private func unmake(_ id: String) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        guard playlist.fromAlbum != nil || !alarms.contains(where: { $0.source == id }) else {
            notice = Notice("\(playlist.name) is on your day, so it stays", undoable: false)
            return
        }
        do {
            let gone = try moveToTrash(id)
            undo?.registerUndo(withTarget: self) { $0.putBack(gone) }
        } catch {
            notice = Notice("couldn't move \(playlist.name) to the Trash: \(error.localizedDescription)", undoable: false)
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
        guard let id = makePlaylist(named: album.title, songs: album.songs, fromAlbum: album.id) else { return nil }
        albumSettings[album.id] = nil
        if let first = album.songs.first {
            let cover = URL(filePath: first.id).deletingLastPathComponent().appending(path: "cover.jpg")
            if (try? FileManager.default.copyItem(at: cover, to: Self.coverURL(forPlaylist: id))) != nil {
                loadPlaylistCovers()
            }
        }
        repointAlarms(from: album.id, to: id)
        undo?.registerUndo(withTarget: self) { $0.unmake(id) }
        did("Make \(album.title) yours", "Made \(album.title) yours", back: "\(album.title) is an album again")
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

    /// On disk first: a collection that couldn't be saved stays as it was, and callers leave its rows alone too.
    @discardableResult
    private func update(_ id: String, _ change: (inout Playlist) -> Void) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return false }
        var changed = playlists[index]
        change(&changed)
        guard save(changed) else { return false }
        playlists[index] = changed
        return true
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
        let what = called(moving.map(\.path))
        setQueue(rest, "Move in queue", "Moved \(what) in the queue", back: "Put the queue back in its order")
    }

    public func removeQueued(_ ids: Set<QueueEntry.ID>) {
        let gone = upNext.filter { ids.contains($0.id) }
        let what = called(gone.map(\.path))
        setQueue(upNext.filter { !ids.contains($0.id) }, "Remove \(Self.songsTitle(gone.count)) from queue", "Removed \(what) from the queue", back: "Put back \(what)")
    }

    /// Undo puts back the whole queue as it was, so only while nothing has played from it or joined it since.
    private func setQueue(_ queue: [QueueEntry], _ action: String, _ text: String, back: String) {
        let before = upNext
        guard queue != before else { return }
        upNext = queue
        let taken = queueTaken
        undo?.registerUndo(withTarget: self) { controller in
            guard controller.upNext == queue, controller.queueTaken == taken else {
                if let target = controller.noticeUndo { controller.undo?.removeAllActions(withTarget: target) }
                controller.notice = Notice("the queue has moved on since, so undo leaves it", undoable: false)
                return
            }
            controller.setQueue(before, action, text, back: back)
        }
        did(action, text, back: back)
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
        let count = upNext.count == 1 ? "1 song" : "\(upNext.count) songs"
        setQueue([], "Clear queue", "Cleared the queue, \(count)", back: "Put back \(count)")
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
            currentSource = nil
            return nil
        }
        let entry = upNext.removeFirst()
        queueTaken += 1
        useAlbumSettings(for: entry.source)
        currentSource = entry.source
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
        did("Remove \(url.lastPathComponent)", "Removed \(url.lastPathComponent) from your folders", back: "Put back \(url.lastPathComponent)")
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
            // a held silence has had its quiet: Play means the next piece, not the rest of the countdown
            if case .resting = machine.phase { command(.skip) } else { command(.resume) }
        case .playing, .resting:
            command(.pause)
            pausedByHand = .now
        }
    }

    public func play() {
        if status == .idle || status == .paused { toggle() }
    }

    /// Play on a collection's page. If it's already going this brings the music back, out of a silence too.
    /// Whether these songs are what's going, and how: for a page's Play and Shuffle. nil when something else is.
    public func collectionState(_ songs: [Song], source: String? = nil) -> (paused: Bool, shuffled: Bool)? {
        state(of: Origin.key(of: songs, source: source))
    }

    private func state(of key: String) -> (paused: Bool, shuffled: Bool)? {
        guard status != .idle, let origin, origin.key == key else { return nil }
        return (status == .paused, origin.shuffled)
    }

    public func playCollection(_ songs: [Song], source: String? = nil) {
        playKnown(songs, source: source, as: Origin.key(of: songs, source: source))
    }

    private func playKnown(_ songs: [Song], source: String?, as key: String) {
        guard origin?.key == key, status != .idle else {
            play(songs, source: source, key: key)
            return
        }
        bringBack()
    }

    /// What's going already: out of a silence, or out of a pause.
    private func bringBack() {
        if inSilence {
            skip()
        } else if status == .paused {
            toggle()
        }
    }

    /// Return and Play on a pick, by place in `list`: one plays on from there, as a double-click does; several play
    /// just themselves.
    public func playPick(_ picked: [Int], of list: [Song], source: String? = nil) {
        let songs = picked.filter(list.indices.contains).map { list[$0] }
        guard songs.count == 1 else {
            playKnown(songs, source: source, as: pickKey(songs, source: source))
            return
        }
        if pickState(picked, of: list, source: source) == nil { play(list, from: picked[0], source: source) } else { bringBack() }
    }

    /// Whether a pick is what's going, as `playPick` plays it: for the pick bar's Play. One row is while its list
    /// goes and it's the song sounding.
    public func pickState(_ picked: [Int], of list: [Song], source: String? = nil) -> (paused: Bool, shuffled: Bool)? {
        let songs = picked.filter(list.indices.contains).map { list[$0] }
        guard songs.count == 1 else { return state(of: pickKey(songs, source: source)) }
        // ponytail: a collection holding the song twice counts either row as sounding
        return current?.id == songs[0].id ? collectionState(list, source: source) : nil
    }

    /// Several are known by their songs and the collection they're picked in: a collection alone is known by its id,
    /// and a pick from the one that's going isn't all of it. The id goes last, for a rename to swap.
    private func pickKey(_ songs: [Song], source: String?) -> String {
        Origin.key(of: songs, source: nil) + (source.map { "\u{0}" + $0 } ?? "")
    }

    public func pause() {
        endResuming()
        if status == .playing || status == .resting { toggle() }
    }

    /// A preview on a player of its own holds the music, a silence's countdown too. True when there's something to
    /// give back with `endPreview()`.
    public func holdForPreview() -> Bool {
        guard status == .playing || status == .resting else { return false }
        pause()
        return true
    }

    /// Not Play: that would end a held silence, and a preview isn't your quiet being over.
    public func endPreview() {
        if status == .paused { command(.resume) }
    }

    public func skip() {
        command(.skip)
    }

    /// Bumped on every seek, so views drawing the unobserved `track` know to start over.
    public private(set) var seeks = 0

    /// Bumped on every skip: a skip changes the unobserved `track`'s fade, with status and song as they were.
    public private(set) var skips = 0

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

    /// An alarm that hasn't got its sound yet, or has lost it, and is still after the device.
    private var alarmTrying: Bool {
        fromAlarm && (resuming != nil || retrying != nil || tryingOverSleep)
    }

    public func systemWillSleep(now: Date = .now) {
        tryingOverSleep = alarmTrying
        endResuming()
        if tryingOverSleep {
            command(.pause)
            return
        }
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
        if tryingOverSleep {
            tryingOverSleep = false
            guard fromAlarm, status == .paused else { return }
            if let alarmDue, now.timeIntervalSince(alarmDue) <= Self.alarmLateness {
                // failing again here starts the trying again
                command(.resume)
            } else {
                if case .loading = machine.phase { send(.stop) }
                problem = "the mac slept past the alarm's time while it waited for audio output, so it gave up"
                playbackProblem = problem
            }
            return
        }
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
            alarmDue = nil
            tryingOverSleep = false
            partDue = nil
            giveVolumeBack()
        }
        guard new != status else { return }
        if new != .paused { pausedByHand = nil }
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
            pieceRow = rowInCharge?.id
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
        // between pieces the status doesn't change, so nothing else writes this
        if engineFailures == 1 { publish() }
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
        // waiting for the device is playing to the UI, but it's silence, and the alarm backup believes this file
        var info: [String: Any] = ["status": retrying != nil ? "waiting" : "\(status)", "preset": settings.name]
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
        let record = PlayRecord(file: file.url.path, startedAt: startedAt, skipped: skipped, gapAfterSec: gap, heardSec: lastTrack?.elapsed, row: pieceRow)
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

#if SHOT
/// Seeds fake data and puts the real machine in a state. Time only moves by `advance`, so without `live` a picture of a
/// fade holds still; there's no Now Playing and no scan.
extension Controller {
    public var shotNow: Date? {
        get { ShotEnv.now }
        set { ShotEnv.now = newValue }
    }

    public static func shot() -> Controller {
        let engine = AVAudioEngine()
        do {
            try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        } catch {
            fatalError("no offline engine, so no sound-proof copy: \(error)")
        }
        return Controller(engine: engine, storage: ShotEnv.storage, playlistFolder: ShotEnv.music.appending(path: "Sottova Playlists"), artworkFolder: ShotEnv.artwork)
    }

    public func shotEnter(_ state: String, covers: URL?) async throws {
        guard ["mine", "empty", "idle", "playing", "paused", "fading", "rising", "silence", "live", "arriving", "pausedSilence", "noCover", "longTitle", "easing", "away", "call", "busy", "media", "noAudio", "reading", "missed", "complinePlaying", "dayDone", "nothingYet", "nothingDay", "preview", "liveSilence"].contains(state) else { fatalError("no such state: \(state)") }
        keepsMacAwake = false
        loadTrims()
        loadAlarms()
        if state == "empty" { return }
        if state == "mine" {
            folders = [ShotEnv.music]
            refreshTracks()
            while catalog.albums.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            lastTick = .now
            startTicker()
            return
        }
        if UserDefaults.standard.bool(forKey: "shotLibrary") {
            try await seedLibrary(covers: covers)
        } else {
            try await seed(covers: covers)
        }
        apply(Settings.presets.first { $0.name == "Sparse" }!)
        let overworld = catalog.albums.first { $0.title == "Overworld" }!
        let row = alarms.first { $0.name == "Overworld" }!.id
        shotNow = Self.shotMonday(hour: 16)
        switch state {
        case "playing", "paused", "fading", "silence", "live", "arriving", "pausedSilence", "away", "call", "busy", "media", "noAudio", "preview":
            play(overworld.songs, source: overworld.id)
            // the live ticker checks hours against the real clock, which would end this row
            if state != "live" && state != "preview" { hourPlaying = row }
            let track = track!
            switch state {
            case "fading": advance(track.outStart + track.fallLength * 0.5)
            case "silence", "pausedSilence", "away", "call", "busy", "media", "noAudio":
                advance(track.outStart)
                while status != .resting { advance(0.05) }
                advance(1)
            case "arriving": advance(track.riseLength * 0.4)
            default: advance(track.fadeIn + 60)
            }
            if state == "paused" || state == "pausedSilence" { toggle() }
            switch state {
            case "away": hold = .away
            case "call": hold = .call
            case "busy": hold = .busy
            case "media": hold = .media
            case "noAudio": retrying = "shot"
            default: break
            }
            if state == "live" {
                lastTick = .now
                startTicker()
            }
            if state == "preview" {
                // the real fall, silence and rise in under a minute, through the real machine and clock
                var quick = settings
                (quick.gapMin, quick.gapMax) = (12, 12)
                settings = quick
                advance(self.track!.outStart - 15 - self.track!.elapsed)
                lastTick = .now
                startTicker()
                // and again, each piece heading for its fall after ten seconds, so it can be watched as often as wanted
                Task { [weak self] in
                    while let self {
                        try? await Task.sleep(for: .seconds(1))
                        if let t = self.track, self.status == .playing, t.elapsed > 10, t.elapsed < t.outStart - 6 { self.advance(t.outStart - 6 - t.elapsed) }
                    }
                }
            }
        case "rising":
            fire(alarms.first { $0.name == "Lauds" }!.id, due: .now)
            advance(track!.fadeIn + 10)
            shotNow = Self.shotMonday(hour: 7, minute: 3)
        case "noCover":
            let shellac = catalog.albums.first { $0.title == "Shellac" }!
            play(shellac.songs, source: shellac.id)
            advance(track!.fadeIn + 60)
        case "longTitle":
            let chopin = catalog.albums.first { $0.title == "Perfect Chopin" }!
            play(chopin.songs, from: 2, source: chopin.id)
            advance(track!.fadeIn + 60)
        case "easing":
            let compline = catalog.albums.first { $0.title == "Compline" }!
            play(compline.songs, source: compline.id)
            advance(track!.fadeIn + 60)
            sleep(minutes: 1)
            advance(30)
        case "reading":
            catalog = Catalog()
            library.entries.keys.sorted().prefix(9).forEach { library.entries[$0]?.loudness = nil }
            tracks = library.playable.map { URL(filePath: $0) }
            pendingAnalysis = library.pending.count
        case "missed":
            changeAlarm(alarms.first { $0.name == "Lauds" }!.id) { $0.missed = Alarm.Missed(at: Self.shotMonday(hour: 7, minute: 2), why: .off) }
            shotNow = Self.shotMonday(hour: 9)
        case "complinePlaying":
            let compline = playlists.first { $0.name == "Compline" }!
            play(songs(of: compline), source: compline.id)
            advance(track!.fadeIn + 30)
        case "nothingDay": alarms.map(\.id).forEach(removeAlarm)
        case "liveSilence":
            var long = settings
            (long.gapMin, long.gapMax) = (3600, 3600)
            settings = long
            play(overworld.songs, source: overworld.id)
            advance(track!.outStart)
            while status != .resting { advance(0.05) }
            lastTick = .now
            startTicker()
        case "nothingYet": shotNow = Self.shotMonday(hour: 9)
        case "dayDone": shotNow = Self.shotMonday(hour: 22)
        default: break
        }
        shotDay()
    }

    /// The states Your day has that nothing else needs.
    private func shotDay() {
        let defaults = UserDefaults.standard
        if let clock = defaults.string(forKey: "shotClock")?.split(separator: ":").compactMap({ Int($0) }), clock.count == 2 {
            shotNow = Self.shotMonday(hour: clock[0], minute: clock[1])
        }
        if let name = defaults.string(forKey: "shotOff"), let row = alarms.first(where: { $0.name == name }) { changeAlarm(row.id) { $0.on = false } }
        // "Lauds=1;Compline=49-63": days off, counted from the picture's today
        for item in (defaults.string(forKey: "shotDaysOff") ?? "").split(separator: ";") {
            let parts = item.split(separator: "=")
            guard parts.count == 2, let row = alarms.first(where: { $0.name == parts[0] }) else { continue }
            let span = parts[1].split(separator: "-").compactMap { Int($0) }
            guard let first = span.first, let today = shotNow else { continue }
            let days = (first...(span.last ?? first)).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today).map { Alarm.day($0) } }
            changeAlarm(row.id) { $0.daysOff.formUnion(days) }
        }
        if defaults.bool(forKey: "shotOverlap"), let chopin = catalog.albums.first(where: { $0.title == "Perfect Chopin" }) {
            var row = Alarm(source: chopin.id, name: "Perfect Chopin", hour: 17, minute: 0, weekdays: Set(1...7))
            row.minutes = 60
            addAlarm(row)
        }
        // the rows as the mock has them
        if defaults.bool(forKey: "shotMock") {
            if let row = alarms.first(where: { $0.name == "Lauds" }) { changeAlarm(row.id) { ($0.rotates, $0.parts, $0.minutes) = (true, 2, 69) } }
            if let row = alarms.first(where: { $0.name == "Overworld" }) { changeAlarm(row.id) { $0.heedsCalendar = true } }
            if let row = alarms.first(where: { $0.name == "Compline" }) { changeAlarm(row.id) { $0.rotates = true } }
        }
        if defaults.bool(forKey: "shotPlayed"), let storage {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let songs = catalog.songs
            let row = alarms.first { $0.name == "Lauds" }?.id
            let times = [(7, 2), (7, 40), (15, 1), (15, 14), (15, 25), (15, 37)]
            let lines = zip(times, songs).compactMap { time, song -> String? in
                let record = PlayRecord(file: song.id, startedAt: Self.shotMonday(hour: time.0, minute: time.1), skipped: false, gapAfterSec: 0, row: time.0 == 7 ? row : nil)
                return (try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) }
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: storage.appending(path: "plays.jsonl"), atomically: true, encoding: .utf8)
        }
    }

    /// A Monday, so every seeded row is on.
    private static func shotMonday(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hour, minute: minute))!
    }

    /// The mock's library, for Songs and collections: real tags, Compline's parts, a collection of mixed covers, Shellac with none.
    private func seedLibrary(covers: URL?) async throws {
        typealias Row = (who: String?, title: String, artist: String, album: String, seconds: Int, cover: String?)
        let mixed = UserDefaults.standard.bool(forKey: "shotMixed")
        var rows: [Row] = [
            (nil, "The road we use to travel when we were kids", "Komiku", "Overworld", 140, "overworld"),
            (nil, "A forest for you and me", "Komiku", "Overworld", 192, "overworld"),
            (nil, "green world", "Komiku", "Overworld", 171, "overworld"),
            ("Bach", "Goldberg Variations: Aria", "Kimiko Ishizaka", "Compline", 300, "compline"),
            ("Chopin", "Nocturne in F-sharp minor Op. 48 No. 2", "Luke Faulkner", "Compline", 496, "compline"),
            ("Dowland", "Sorrow, stay", "In Stile Moderno", "Compline", 442, "compline"),
            ("Schubert", "Sonata in A major: II. Andantino D. 959", "Paul Pitman", "Compline", 546, "compline"),
            ("Chopin", "Nocturne in C minor B. 108", "Diana Hughes", "Compline", 193, "compline"),
            ("Borodin", "String Quartet No. 2: III. Notturno", "Musopen String Quartet", "Compline", 547, "compline"),
            ("Bach", "Well-Tempered Clavier: Prelude in C", "Kimiko Ishizaka", "Lauds", 134, "lauds"),
            ("Bach", "Cello Suite No. 1: Prelude", "Pieter Wispelwey", "Lauds", 151, "lauds"),
            ("Palestrina", "Missa Papae Marcelli: Kyrie", "Tallis Scholars", "Counterpoint", 258, "counterpoint"),
            ("Tallis", "If ye love me", "Tallis Scholars", "Counterpoint", 126, "counterpoint"),
            ("Louis Armstrong", "West End Blues", "Hot Five", "Shellac", 196, nil),
            ("Duke Ellington", "Mood Indigo", "His Orchestra", "Shellac", 180, nil),
            ("Bessie Smith", "St. Louis Blues", "with Louis Armstrong", "Shellac", 190, nil),
            ("Coleman Hawkins", "Body and Soul", "His Orchestra", "Shellac", 180, nil),
            ("Billie Holiday", "Strange Fruit", "Commodore", "Shellac", 192, nil),
        ]
        let chopin: String? = mixed ? nil : "Chopin"
        rows += [(chopin, "Nocturne in E-flat Op. 9 No. 2", "Luke Faulkner", "Perfect Chopin", 270, "perfectchopin")]
        if mixed { rows += [(nil, "Harbor Lights", "Mara Lind", "Perfect Chopin", 228, "neon")] }
        rows += [(chopin, "Etude Op. 10 No. 3", "Diana Hughes", "Perfect Chopin", 232, "perfectchopin")]
        if mixed { rows += [(nil, "Blue Hour", "Tomas Ek", "Perfect Chopin", 209, "pale")] }
        rows += [(chopin, "Ballade No. 1", "Musopen", "Perfect Chopin", 561, mixed ? "counterpoint" : "perfectchopin")]
        if mixed { rows += [(nil, "Last Train", "Ines Vale", "Perfect Chopin", 362, "tiny"), (nil, "Static Coast", "Ines Vale", "Perfect Chopin", 235, "flat")] }
        rows += [(chopin, "Prelude Op. 28 No. 4", "Diana Hughes", "Perfect Chopin", 135, "perfectchopin")]

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        let saved: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        var art: [String: String] = [:]
        var paths: [String: [String]] = [:]
        for row in rows {
            if let name = row.cover, art[name] == nil, let data = covers.flatMap({ try? Data(contentsOf: $0.appending(path: "\(name).jpg")) }) {
                art[name] = artwork?.save(data)
            }
            let folder = ShotEnv.music.appending(path: row.album)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(paths[row.album, default: []].count + 1).caf")
            paths[row.album, default: []].append(url.path)
            // only what plays needs its length on disk; the rest take the tag's word for it
            let plays = row.album == "Overworld" || row.title == "Goldberg Variations: Aria"
            let frames = AVAudioFrameCount((plays ? row.seconds : 1) * 8_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            buffer.floatChannelData![0].update(repeating: 0, count: Int(frames))
            try AVAudioFile(forWriting: url, settings: saved).write(from: buffer)
            var meta = TrackMeta(title: row.title, artist: row.artist, album: row.album, albumArtist: row.album == "Overworld" ? row.artist : "Various",
                                 trackNumber: paths[row.album]!.count, duration: Double(row.seconds), artwork: row.cover.flatMap { art[$0] })
            meta.composer = row.who
            library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10), meta: meta)
        }
        folders = [ShotEnv.music]
        refreshTracks()
        while catalog.songs.count < rows.count { try await Task.sleep(for: .milliseconds(10)) }
        let album = { (title: String) in self.catalog.albums.first { $0.title == title }! }
        let own = { (title: String) in self.makePlaylist(named: title, songs: album(title).songs, fromAlbum: album(title).id)! }
        let compline = own("Compline")
        for (index, name) in [(2, "Sorrow, stay"), (3, "Trembling shadow"), (5, "Candle out")] { setBreak(true, at: index, in: compline); namePart(name, at: index, in: compline) }
        namePart("Dusk", at: 0, in: compline)
        _ = own("Perfect Chopin")
        if UserDefaults.standard.bool(forKey: "shotNewCollection") { newPlaylist() }
        var lauds = Alarm(source: album("Lauds").id, name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6], shuffled: true)
        lauds.volume = 0.25
        var overworld = Alarm(source: album("Overworld").id, name: "Overworld", hour: 15, minute: 0, weekdays: Set(1...7), shuffled: true)
        (overworld.whileHere, overworld.minutes) = (true, 240)
        var evening = Alarm(source: compline, name: "Compline", hour: 20, minute: 0, weekdays: Set(1...7))
        (evening.volume, evening.minutes) = (0.15, 60)
        [lauds, overworld, evening].forEach(addAlarm)
    }

    private func seed(covers: URL?) async throws {
        let sets: [(album: String, artist: String, cover: String?, titles: [String])] = [
            ("Lauds", "Various", "lauds", ["Strings", "Morning Hymn", "Benedictus"]),
            ("Overworld", "Komiku", "overworld", ["The road we use to travel when we were kids", "A forest for you and me", "green world"]),
            ("Compline", "Various", "compline", ["Dusk", "Nunc dimittis", "Salve Regina"]),
            ("Counterpoint", "Kimiko Ishizaka", "counterpoint", ["Contrapunctus 1", "Contrapunctus 2"]),
            ("Perfect Chopin", "Musopen", "perfectchopin", ["Nocturne in E-flat", "Ballade No. 1", "Piano Sonata No. 2 in B-flat minor, Op. 35 \u{201C}Funeral March\u{201D}: III. Marche funèbre, Lento, live from the Warsaw Philharmonic"]),
            ("Shellac", "Various", nil, ["Blue Skies", "Paper Moon"]),
        ]
        // the lowest rate a file can have: 15 pieces of 3 to 5 minutes come to about 45 MB
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        let saved: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        for set in sets {
            let art = set.album == "Overworld" ? UserDefaults.standard.string(forKey: "shotArt") ?? set.cover : set.cover
            let cover = art.flatMap { name in covers.flatMap { try? Data(contentsOf: $0.appending(path: "\(name).jpg")) } }.flatMap { artwork?.save($0) }
            let folder = ShotEnv.music.appending(path: set.album)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, title) in set.titles.enumerated() {
                let url = folder.appending(path: "\(i + 1).caf")
                let duration = 190 + 47 * i
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 8_000))!
                buffer.frameLength = buffer.frameCapacity
                buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
                try AVAudioFile(forWriting: url, settings: saved).write(from: buffer)
                library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10),
                    meta: TrackMeta(title: title, artist: set.artist, album: set.album, albumArtist: set.artist, trackNumber: i + 1, duration: Double(duration), artwork: cover))
            }
        }
        folders = [ShotEnv.music]
        refreshTracks()
        while catalog.albums.count < sets.count { try await Task.sleep(for: .milliseconds(10)) }
        let id = { (title: String) in self.catalog.albums.first { $0.title == title }!.id }
        var lauds = Alarm(source: id("Lauds"), name: "Lauds", hour: 7, minute: 2, weekdays: [2, 3, 4, 5, 6], shuffled: true)
        lauds.volume = 0.25
        var overworld = Alarm(source: id("Overworld"), name: "Overworld", hour: 15, minute: 0, weekdays: Set(1...7), shuffled: true)
        (overworld.whileHere, overworld.minutes) = (true, 240)
        var compline = Alarm(source: id("Compline"), name: "Compline", hour: 20, minute: 0, weekdays: Set(1...7))
        (compline.volume, compline.minutes) = (0.15, 60)
        [lauds, overworld, compline].forEach(addAlarm)
    }
}
#endif
