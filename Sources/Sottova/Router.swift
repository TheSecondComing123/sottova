import SwiftUI
import SottovaCore

/// Where the main window is and how it got there. The app owns it, so menu commands can navigate, and a palette
/// switch, which rebuilds the window, doesn't send it back Home.
@Observable @MainActor
final class Router {
    private(set) var route = Route.home
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

    func go(to destination: Route) {
        query = ""
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
        searchRequests += 1
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
            Button("Show Playing") {
                guard let song = controller.current else { return }
                openWindow(id: "main")
                router.go(to: .album(song.albumID))
            }
            .keyboardShortcut("l")
            .disabled(controller.status == .idle || controller.current == nil)
        }
        CommandMenu("Go") {
            Button("Back") { router.goBack() }
                .keyboardShortcut("[")
                .disabled(router.back.isEmpty)
            Button("Forward") { router.goForward() }
                .keyboardShortcut("]")
                .disabled(router.forward.isEmpty)
            Divider()
            Button("Home") { router.go(to: .home) }.keyboardShortcut("1")
            Button("Songs") { router.go(to: .songs) }.keyboardShortcut("2")
            Button("Albums") { router.go(to: .albums) }.keyboardShortcut("3")
            Button("Artists") { router.go(to: .artists) }.keyboardShortcut("4")
            Divider()
            Button("Search") {
                openWindow(id: "main")
                router.search()
            }
            .keyboardShortcut("f")
        }
    }
}
