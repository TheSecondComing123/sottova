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
    public private(set) var catalog = Catalog()
    public private(set) var current: Song?
    public private(set) var recent: [Song] = []
    /// What played today, oldest first, for drawing the day as a score.
    public private(set) var today: [Play] = []
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
            keepAwake(keepsMacAwake && (status == .playing || status == .resting))
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
    @ObservationIgnored private var machine: Machine
    @ObservationIgnored private var shuffler = Shuffler()
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var trackGain = 1.0
    @ObservationIgnored private var outgoingGain = 1.0
    @ObservationIgnored private var lastTrack: Track?
    /// plays.jsonl, read once at launch and appended to after, so drawing today never rereads the file.
    @ObservationIgnored private var playLog: [PlayRecord] = []
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var failures = 0
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
        let file = Self.loadProfile(from: storage)
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
            playLog = PlayRecord.read(storage.appending(path: "plays.jsonl"))
            // avoid-last-N survives a relaunch
            shuffler.recent = playLog.suffix(20).map(\.file)
        }
        loadLibrary()
        loadPlaylists()
    }

    /// Starts the envelope clock, media keys and the first scan. Tests skip this and call `advance` themselves.
    public func run() {
        guard ticker == nil else { return }
        lastTick = .now
        startTicker()
        nowPlaying = NowPlaying(controller: self)
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
            }
        }
    }

    private var tickInterval: Duration {
        let envelope = envelopeInterval
        // the sleep timer's ease-down moves the gain too: at 10 Hz its steps are 0.03 dB
        guard status == .playing, case .timer(let left, let fade)? = machine.sleep else { return envelope }
        return min(envelope, .milliseconds(Int(max(0.1, left - fade) * 1000)))
    }

    private var envelopeInterval: Duration {
        guard status == .playing, machine.outgoing == nil, case .track(let track) = machine.phase else {
            return status == .playing ? .milliseconds(10) : .milliseconds(500)
        }
        let holdLeft = track.outStart - 0.5 - track.elapsed
        guard track.elapsed >= track.fadeIn, holdLeft > 0.01 else { return .milliseconds(10) }
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

    public func apply(_ preset: Settings) {
        settings = preset
    }

    /// Plays these songs in order from `index`, with the usual fades and gaps, then goes back to shuffling everything.
    /// `source` is a playlist id, whose gaps the songs play with; without one, songs from one album play with its gaps.
    public func play(_ songs: [Song], from index: Int = 0, source: String? = nil) {
        guard songs.indices.contains(index) else { return }
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
    public func newPlaylist(named name: String = "New playlist", songs: [Song] = [], fromAlbum: String? = nil) -> String? {
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
        update(id) { $0.paths = $0.paths.enumerated().filter { !offsets.contains($0.offset) }.map(\.element) }
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
            problem = "there's already a playlist called \(name)"
            return nil
        }
        do {
            try FileManager.default.moveItem(at: URL(filePath: id), to: url)
        } catch {
            problem = "couldn't rename \(playlists[index].name): \(error.localizedDescription)"
            return nil
        }
        playlists[index].id = url.path
        playlists[index].name = name
        save(playlists[index])
        upNext = upNext.map { $0.source == id ? QueueEntry(path: $0.path, source: url.path) : $0 }
        if playingAlbum == id {
            playingAlbum = url.path
        }
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return url.path
    }

    /// Moves the file to the Trash, where it can be put back.
    public func trashPlaylist(_ id: String) {
        do {
            try FileManager.default.trashItem(at: URL(filePath: id), resultingItemURL: nil)
            playlists.removeAll { $0.id == id }
        } catch {
            problem = "couldn't move the playlist to the Trash: \(error.localizedDescription)"
        }
    }

    /// Turns albums (folders tagged as one album) into playlists, keeping their gaps; the files stay where they are.
    /// Backs up library.json and profile.json first.
    public func makePlaylists(from albums: [Album]) {
        backUpData()
        for album in albums where !albumsInPlaylists.contains(album.id) {
            // the playlist file is written before the album's gaps move into it
            guard newPlaylist(named: album.title, songs: album.songs, fromAlbum: album.id) != nil else { return }
            albumSettings[album.id] = nil
        }
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
        upNext.removeAll()
    }

    /// Songs from one album play with that album's gaps, wherever they were queued from.
    private static func source(of songs: [Song]) -> String? {
        let albums = Set(songs.map(\.albumID))
        return albums.count == 1 ? albums.first : nil
    }

    /// The next path to play, putting its source's gaps in place, or nil when the shuffler should pick.
    func dequeue() -> String? {
        guard !upNext.isEmpty else {
            useAlbumSettings(for: nil)
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
            }
            refreshRecent()
            // today's plays take their lengths from the tags, which may only just have been read
            refreshToday()
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
        nextTrackAt = machine.restRemaining.map { Date(timeIntervalSinceNow: $0) }
        keepAwake(keepsMacAwake && (new == .playing || new == .resting))
        refreshSleep()
        publish()
    }

    private func perform(_ effect: Machine.Effect) {
        let deck = players[active]
        switch effect {
        case .startNextTrack:
            startNextTrack()
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
            deck.scheduleFile(file, at: nil, completionHandler: nil)
            deck.prepare(withFrameCount: 8192)
            deck.play()
            self.file = file
            // tracks not analyzed yet play at a provisional −6 dB
            let gainDb = library.entries[path]?.loudness?.gainDb(target: settings.targetLufs, ceiling: settings.ceilingDbtp) ?? -6
            trackGain = pow(10, gainDb / 20)
            current = catalog.songsByID[path]
            title = current?.title ?? url.deletingPathExtension().lastPathComponent
            refreshRecent()
            startedAt = Date()
            failures = 0
            problem = nil
            send(.trackStarted(duration: Double(file.length) / file.processingFormat.sampleRate))
            publish()
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

    private static func loadProfile(from storage: URL?) -> ProfileFile? {
        guard let url = storage?.appending(path: "profile.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProfileFile.self, from: data)
    }

    private func saveProfile() {
        guard let url = storage?.appending(path: "profile.json") else { return }
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
        let start = AVAudioFramePosition(track.elapsed * file.processingFormat.sampleRate)
        guard start < file.length else { return }
        deck.stop()
        deck.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil, completionHandler: nil)
    }

    private func log(skipped: Bool, gap: Double) {
        guard let url = storage?.appending(path: "plays.jsonl"), let file else { return }
        let record = PlayRecord(file: file.url.path, startedAt: startedAt, skipped: skipped, gapAfterSec: gap, heardSec: lastTrack?.elapsed)
        do {
            try record.append(to: url)
        } catch {
            problem = "couldn't write the play log: \(error.localizedDescription)"
        }
        playLog.append(record)
        refreshToday()
    }

    private func refreshToday() {
        let songs = catalog.songsByID
        today = PlayRecord.plays(playLog, on: .now) { songs[$0]?.duration }
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
