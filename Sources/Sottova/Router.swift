import AppKit
import SwiftUI
import SottovaCore

/// Where the main window is and how it got there. The app owns it, so menu commands can navigate, and a palette
/// switch, which rebuilds the window, doesn't send it back Home.
@Observable @MainActor
final class Router {
    private(set) var route = Route.home
    #if NEWLOOK
    /// Something's being dragged over the window, for the first run's frame.
    var droppingMusic = false
    /// A missed line put away at the foot of Now; it stays on its row.
    var dismissedFoot: String?
    /// The filter on Songs, here so a name anywhere can open Songs filtered to it.
    var songFilter = ""
    /// A collection on its way from the sidebar onto an hour; the drop itself can't be read until it lands.
    var draggingCollection: String?
    #if SHOT
    var shotDrop: (hour: Int, name: String)?
    #endif
    #endif
    /// Where each page in the history was scrolled to, so Back lands where you were.
    private(set) var back: [(route: Route, offset: CGFloat)] = []
    private(set) var forward: [(route: Route, offset: CGFloat)] = []
    /// How far the page on screen is scrolled. Changes every frame of a scroll, so nothing observes it.
    @ObservationIgnored var offset: CGFloat = 0
    /// Where the next page should open: set by Back and Forward, taken once by the page.
    @ObservationIgnored var restore: CGFloat?
    var query = ""
    /// Bumped by ⌘F; the top bar focuses the search field when it changes.
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
    /// Songs picked in a list: a click picks one, ⌘-click adds or takes one away, ⇧-click picks the run from the
    /// last one picked. Gone when the page changes.
    var selected: Set<String> = []
    @ObservationIgnored private var anchor: String?

    func select(_ id: String, in order: [String]) {
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
    }

    /// The queue's slide-over, so the Controls menu can open it too.
    var showsQueue = false
    /// A collection about to go to the Trash with alarms that would go with it, asked about first.
    var trashing: String?

    func go(to destination: Route) {
        query = ""
        selected = []
        #if NEWLOOK
        if destination == .songs { songFilter = "" }
        #endif
        guard destination != route else { return }
        restore = nil
        withAnimation(Theme.page) {
            back.append((route, offset))
            forward.removeAll()
            route = destination
        }
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        restore = previous.offset
        withAnimation(Theme.page) {
            forward.append((route, offset))
            route = previous.route
        }
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        restore = next.offset
        withAnimation(Theme.page) {
            back.append((route, offset))
            route = next.route
        }
    }

    func search() {
        #if NEWLOOK
        // the filter on Songs is the search; asking from elsewhere goes there, so it never waits to take focus later
        if route != .songs || !query.isEmpty { go(to: .songs) }
        #endif
        searchRequests += 1
    }

    func toggleQueue() {
        // in on a spring with no overshoot, a 340 pt edge mustn't wobble; out on the quick curve
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? nil : showsQueue ? Theme.quick : .spring(duration: 0.3, bounce: 0)) { showsQueue.toggle() }
    }
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
            Button("Next") { controller.skip() }
                .keyboardShortcut(.rightArrow)
                .disabled(controller.status == .idle || router.typing)
            Divider()
            Button("Show playing") {
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
            Divider()
            // ⌘↑ and ⌘↓ move a text field's cursor, so they step aside while typing
            Button("Volume up") { controller.volume = min(controller.volume + 0.1, 1) }
                .keyboardShortcut(.upArrow)
                .disabled(router.typing)
            Button("Volume down") { controller.volume = max(controller.volume - 0.1, 0) }
                .keyboardShortcut(.downArrow)
                .disabled(router.typing)
            Menu("Sleep") { SleepChoices(controller: controller) }
                .disabled(controller.status == .idle)
        }
        CommandGroup(after: .newItem) {
            Button("Add folder…") { controller.chooseFolders() }
                .keyboardShortcut("o")
        }
        CommandMenu("Go") {
            #if NEWLOOK
            goItems.disabled(router.presetEdit != nil)
            #else
            goItems
            #endif
        }
    }

    @ViewBuilder
    private var goItems: some View {
        Group {
            Button("Back") { router.goBack() }
                .keyboardShortcut("[")
                .disabled(router.back.isEmpty)
            Button("Forward") { router.goForward() }
                .keyboardShortcut("]")
                .disabled(router.forward.isEmpty)
            Divider()
            Button("Home") { router.go(to: .home) }.keyboardShortcut("1")
            Button("Songs") { router.go(to: .songs) }.keyboardShortcut("2")
            Button("Collections") { router.go(to: .collections) }.keyboardShortcut("3")
            Button("Artists") { router.go(to: .artists) }.keyboardShortcut("4")
            Button("Your day") { router.go(to: .alarms) }.keyboardShortcut("5")
            Button("Free music") { router.go(to: .shelf) }.keyboardShortcut("6")
            Divider()
            Button("Search") {
                openWindow(id: "main")
                router.search()
            }
            .keyboardShortcut("f")
        }
    }
}
