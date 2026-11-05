import AppKit
import SwiftUI
import SottovaCore

/// Where the main window is and how it got there. The app owns it, so menu commands can navigate, and a palette
/// switch, which rebuilds the window, doesn't send it back Home.
@Observable @MainActor
final class Router {
    private(set) var route = Route.home
    /// Something's being dragged over the window, for the first run's frame.
    var droppingMusic = false
    /// A missed line put away at the foot of Now; it stays on its row.
    var dismissedFoot: String?
    /// The filter on Songs, here so a name anywhere can open Songs filtered to it.
    var songFilter = ""
    /// The collection the open page shows: renaming it there moves the file to a new id under the same route, which
    /// stays put so the page isn't rebuilt and ⌘Z can take the name back.
    var shownCollection: String?
    /// A collection on its way from the sidebar onto an hour; the drop itself can't be read until it lands.
    var draggingCollection: String?
    #if SHOT
    var shotDrop: (hour: Int, name: String)?
    #endif
    /// Where each page in the history was scrolled to, so Back lands where you were.
    private(set) var back: [(route: Route, offset: CGFloat)] = []
    private(set) var forward: [(route: Route, offset: CGFloat)] = []
    /// How far the page on screen is scrolled. Changes every frame of a scroll, so nothing observes it.
    @ObservationIgnored var offset: CGFloat = 0
    /// Where the next page should open: set by Back and Forward, taken once by the page.
    @ObservationIgnored var restore: CGFloat?
    /// Bumped by ⌘F; Songs focuses its filter when it changes.
    private(set) var searchRequests = 0
    /// A text field has focus: ⌘→ moves its cursor there, so playback commands step aside.
    var typing = false
    /// The album or playlist whose cover is being chosen, shown as a sheet.
    var coverFor: CoverTarget?
    /// The song whose start and end are being trimmed, shown as a sheet.
    var trimming: Song?
    /// The preset being made or changed, shown as a sheet.
    var presetEdit: PresetEdit?
    /// The alarm being set or changed, shown as a sheet.
    var alarm: AlarmRequest?
    /// The row whose days off are being picked, in a popover on it.
    var daysOff: Alarm.ID?
    /// It came from the row's "Off…" word, so the popover points there.
    var daysOffFromWord = false
    /// Songs picked in a list: a click picks one, ⌘-click adds or takes one away, ⇧-click picks the run from the
    /// last one picked. Gone when the page changes.
    var selected: Set<String> = []
    @ObservationIgnored private var anchor: String?
    /// Where the arrows are: a song in a collection twice has one id and two places.
    @ObservationIgnored private var stepped: Int?
    /// The list on the page, for the keys, Select All and the Song menu, which has to see it arrive.
    var run: SongRun?
    /// The song the arrows moved to, for the page to bring into view.
    private(set) var scrollTo: String?
    /// The click under way brings the window forward: read at the press, because a tap ends after the window has come.
    @ObservationIgnored var pressActivates = false

    var currentRun: SongRun? { run?.route == route ? run : nil }
    var canSelectAll: Bool { currentRun != nil }

    func select(_ id: String, in order: [String]) {
        // the click that brings the window forward leaves the pick as it was
        guard !pressActivates else { return }
        let keys = NSEvent.modifierFlags
        if keys.contains(.shift), let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            selected = Set(order[min(a, b)...max(a, b)])
            return
        }
        if keys.contains(.command) {
            if selected.remove(id) == nil { selected.insert(id) }
        } else {
            selected = [id]
        }
        anchor = id
        stepped = nil
    }

    func clearPick() {
        guard !pressActivates else { return }
        selected = []
    }

    func selectAll() {
        guard let currentRun else { return }
        selected = Set(currentRun.order)
    }

    /// True when the key was for the list.
    func key(_ event: NSEvent) -> Bool {
        guard let run = currentRun, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else { return false }
        switch event.keyCode {
        case 125: step(1, in: run.order)
        case 126: step(-1, in: run.order)
        case 36, 76:
            guard run.order.contains(where: selected.contains) else { return false }
            playPick()
        case 51, 117:
            guard let removePick, !selected.isEmpty else { return false }
            removePick()
        case 53:
            guard !selected.isEmpty else { return false }
            selected = []
        default: return false
        }
        return true
    }

    /// Delete on the pick, and the Song menu's Remove: nil where the list isn't yours to take songs out of.
    var removePick: (() -> Void)? {
        guard let remove = currentRun?.remove else { return nil }
        return { [self] in
            remove(selected)
            selected = []
        }
    }

    private func step(_ by: Int, in order: [String]) {
        guard !order.isEmpty else { return }
        let here = stepped.flatMap { order.indices.contains($0) && order[$0] == anchor ? $0 : nil } ?? anchor.flatMap(order.firstIndex(of:))
        let next = here.map { min(max($0 + by, 0), order.count - 1) } ?? (by > 0 ? 0 : order.count - 1)
        selected = [order[next]]
        anchor = order[next]
        stepped = next
        scrollTo = order[next]
    }

    /// The queue's slide-over, so the Controls menu can open it too.
    var showsQueue = false
    /// A collection about to go to the Trash with alarms that would go with it, asked about first.
    var trashing: String?
    /// The playlist whose name is being typed, right after it's made or picked Rename.
    var renaming: String?
    /// Bumped by the menu bar; the open collection does each itself, as its own buttons and right-click do.
    var addSongsRequests = 0
    var newPartRequests = 0

    /// Where a click on a name goes.
    func open(_ route: Route, in controller: Controller) {
        // a name opens Songs filtered to it
        if case .artist(let name) = route {
            go(to: .songs)
            songFilter = name
            return
        }
        if case .composer(let name) = route {
            go(to: .songs)
            songFilter = name
            return
        }
        // an album made yours opens as its copy
        if case .album(let id) = route, let copy = controller.copy(ofAlbum: id) {
            go(to: .playlist(copy.id))
        } else {
            go(to: route)
        }
    }

    /// The picked songs on the page, in the list's order.
    var pickedPaths: [String] {
        currentRun.map { $0.order.filter(selected.contains).map(Playlist.path(ofRow:)) } ?? []
    }

    /// Return, and Play in the pick's right-click and the Song menu: see `Controller.playPick`.
    func playPick() {
        guard let run = currentRun else { return }
        let picked = run.order.filter(selected.contains)
        if !picked.isEmpty { run.play(picked) }
    }

    /// One row's right-click Play: as Return plays it picked. A double-click starts it over instead.
    func playRow(_ id: String) {
        currentRun?.play([id])
    }

    func go(to destination: Route) {
        selected = []
        if destination == .songs { songFilter = "" }
        guard destination != route else { return }
        restore = nil
        navigate {
            back.append((route, offset))
            forward.removeAll()
            route = destination
        }
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        selected = []
        restore = previous.offset
        navigate {
            forward.append((route, offset))
            route = previous.route
        }
    }

    /// Off a page that's going away, as a trashed collection's: back to where you came from, or Now.
    func leave(_ gone: Route) {
        guard route == gone else { return }
        if back.isEmpty { go(to: .home) } else { goBack() }
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        selected = []
        restore = next.offset
        navigate {
            back.append((route, offset))
            route = next.route
        }
    }

    private func navigate(_ change: () -> Void) {
        if NSApp.currentEvent?.type == .keyDown || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            change()
        } else {
            withAnimation(Theme.page, change)
        }
    }

    func search() {
        // the filter on Songs is the search; asking from elsewhere goes there, so it never waits to take focus later
        if route != .songs { go(to: .songs) }
        searchRequests += 1
    }

    func toggleQueue() {
        // in on a spring with no overshoot, a 340 pt edge mustn't wobble; out on the quick curve
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? nil : showsQueue ? Theme.quick : .spring(duration: 0.3, bounce: 0)) { showsQueue.toggle() }
    }
}

/// A list of songs the keys can act on.
struct SongRun {
    let route: Route
    let order: [String]
    /// The picked, in the list's order.
    let play: ([String]) -> Void
    var remove: ((Set<String>) -> Void)?
    var source: String?
}

/// The menu bar's Controls and Go menus: everything here is also a click away in the window.
struct SottovaCommands: Commands {
    let controller: Controller
    let router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Controls") {
            let running = controller.status == .playing || controller.status == .resting
            // bare Space: a focused text field takes it first, so typing a space still types one
            Button(running ? "Pause" : "Play") { controller.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(controller.tracks.isEmpty)
            Button("Skip") { controller.skip() }
                .keyboardShortcut(.rightArrow)
                .disabled(controller.status == .idle || router.typing)
            Divider()
            Button("Go to \(playingCollection)") {
                guard let song = controller.current else { return }
                openWindow(id: "main")
                router.go(to: controller.copy(ofAlbum: song.albumID).map { .playlist($0.id) } ?? .album(song.albumID))
            }
            .keyboardShortcut("l")
            .disabled(controller.status == .idle || controller.current == nil)
            Button(router.showsQueue ? "Hide queue" : "Show queue") {
                openWindow(id: "main")
                router.toggleQueue()
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(controller.tracks.isEmpty)
            Divider()
            // ⌘↑ and ⌘↓ move a text field's cursor, so they step aside while typing
            Button("Volume up") { controller.volume = min(controller.volume + 0.1, 1) }
                .keyboardShortcut(.upArrow)
                .disabled(router.typing)
            Button("Volume down") { controller.volume = max(controller.volume - 0.1, 0) }
                .keyboardShortcut(.downArrow)
                .disabled(router.typing)
            Menu("Sleep timer") { SleepChoices(controller: controller) }
                .disabled(controller.status == .idle)
        }
        CommandGroup(after: .newItem) {
            Button("Add folder…") { controller.chooseFolders() }
                .keyboardShortcut("o")
        }
        CommandMenu("Go") {
            goItems.disabled(router.presetEdit != nil)
        }
        // the right-click's own lists, so the two can't drift apart
        CommandMenu("Collection") {
            MenuEntries(entries: collectionEntries)
        }
        CommandMenu("Song") {
            MenuEntries(entries: songEntries)
        }
        CommandMenu("Day") {
            Button("Schedule music…") {
                openWindow(id: "main")
                router.alarm = .new(nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }

    private var navigate: Navigate { Navigate { router.open($0, in: controller) } }

    /// One of yours, open: what its page and its right-click do. An album: Play and Shuffle. Anything else: the same
    /// items, off. New ones first, always there.
    private var collectionEntries: [MenuEntry] {
        let songs = router.presetEdit == nil ? router.pickedPaths.compactMap { controller.catalog.songsByID[$0] } : []
        let new: [MenuEntry] = [
            .item("New collection", enabled: router.presetEdit == nil, shortcut: KeyboardShortcut("n")) {
                openWindow(id: "main")
                guard let id = controller.newPlaylist() else { return }
                router.renaming = id
                router.go(to: .playlist(id))
            },
            .item("New collection from selection", enabled: !songs.isEmpty, shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])) {
                MenuEntry.newCollection(songs, controller: controller, router: router)
            },
            .divider,
        ]
        let off = ["Play", "Shuffle", "Play next", "Add to collection", "Add songs", "New part from selection", "Rename", "Choose cover…", "Schedule music…",
                   "Silence between songs", "Show in Finder", "Move to Trash"]
            .map { MenuEntry.item($0, enabled: false) {} }
        guard router.presetEdit == nil else { return new + off }
        if case .album(let id) = router.route, let album = controller.catalog.albums.first(where: { $0.id == id }) {
            var entries = off
            entries[0] = .item("Play") { controller.playCollection(album.songs) }
            entries[1] = .item("Shuffle") { controller.play(album.songs.shuffled(), shuffled: true) }
            return new + entries
        }
        guard case .playlist = router.route, let playlist = controller.playlists.first(where: { $0.id == router.shownCollection }) else {
            return new + off
        }
        var entries = MenuEntry.yours(playlist, controller: controller, router: router, navigate: navigate,
                                      renaming: Binding(get: { router.renaming }, set: { router.renaming = $0 }))
        entries.insert(contentsOf: [
            .item("Add songs") { router.addSongsRequests += 1 },
            .item("New part from selection", enabled: router.selected.count > 1) { router.newPartRequests += 1 },
        ], at: 4)
        return new + entries
    }

    /// What the pick's right-click offers, less what only makes sense on the row itself.
    private var songEntries: [MenuEntry] {
        let songs = router.pickedPaths.compactMap { controller.catalog.songsByID[$0] }
        guard router.presetEdit == nil, let first = songs.first else {
            return ["Play", "Play next", "Add to queue", "Add to collection", "Trim…", "Show in Finder"].map { .item($0, enabled: false) {} }
        }
        return MenuEntry.song(first, picked: songs, source: router.currentRun?.source, play: router.playPick, remove: router.removePick.map { remove in { _ in remove() } }, part: nil,
                              controller: controller, router: router, navigate: navigate)
    }

    private var playingCollection: String {
        guard let song = controller.current else { return "collection" }
        return controller.copy(ofAlbum: song.albumID)?.name ?? song.album
    }

    private func inWindow(_ go: () -> Void) {
        openWindow(id: "main")
        go()
    }

    @ViewBuilder
    private var goItems: some View {
        Group {
            Button("Back") { inWindow(router.goBack) }
                .keyboardShortcut("[")
                .disabled(router.back.isEmpty)
            Button("Forward") { inWindow(router.goForward) }
                .keyboardShortcut("]")
                .disabled(router.forward.isEmpty)
            Divider()
            Button("Now") { inWindow { router.go(to: .home) } }.keyboardShortcut("1")
            Button("Your day") { inWindow { router.go(to: .alarms) } }.keyboardShortcut("2")
            Button("Songs") { inWindow { router.go(to: .songs) } }.keyboardShortcut("3")
            Button("Free music") { inWindow { router.go(to: .shelf) } }.keyboardShortcut("4")
            Button("Collections") { inWindow { router.go(to: .collections) } }.keyboardShortcut("5")
            Button("Artists") { inWindow { router.go(to: .artists) } }.keyboardShortcut("6")
            Divider()
            Button("Filter songs") {
                openWindow(id: "main")
                router.search()
            }
            .keyboardShortcut("f")
        }
    }
}
