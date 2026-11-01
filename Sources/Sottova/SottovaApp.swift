import AppKit
import SwiftUI
import SottovaCore

@main
struct SottovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #if SHOT
    private let controller = Controller.shot()
    #else
    private let controller = Controller(playlistFolder: .musicDirectory.appending(path: "Sottova Playlists"))
    #endif
    /// Theme.palette is set before this changes, so re-keying the scenes below redraws them in the new colors.
    #if NEWLOOK
    @AppStorage("palette") private var paletteName = Palette.gruvbox.id
    /// Bumped when a theme file changed on disk.
    @State private var themeVersion = 0
    private var palette: String { "\(paletteName) \(themeVersion)" }
    #else
    @AppStorage("palette") private var palette = Palette.monochrome.id
    #endif
    @State private var router = Router()

    init() {
        #if NEWLOOK
        // a launch with saved state, even an old build's, presents only what was saved: no keepalive, so nothing reopens
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        #endif
        let controller = controller
        AppDelegate.controller = controller
        #if NEWLOOK
        let router = Router()
        _router = State(initialValue: router)
        AppDelegate.router = router
        #endif
        Artwork.store = controller.artwork
        // M1 kept a single folder path in defaults
        if let path = UserDefaults.standard.string(forKey: "folder") {
            controller.addFolders([URL(filePath: path)])
            UserDefaults.standard.removeObject(forKey: "folder")
        }
        #if !SHOT
        controller.run()
        #endif
        SystemWake.shared.renew(for: controller.alarms)
        // a Mac that never sleeps never gets a wake from sleep to top these up on
        Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { SystemWake.shared.renew(for: controller.alarms) }
        }
        // undoing an edit can bring back a time with no wake yet
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SystemWake.shared.renew(for: controller.alarms) }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        _ = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { controller.systemWillSleep() }
        }
        _ = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                controller.systemDidWake()
                SystemWake.shared.renew(for: controller.alarms)
            }
        }
    }

    var body: some Scene {
        Window("Sottova", id: "main") {
            MainWindow()
                .id(palette)
                .environment(controller)
                .environment(router)
                #if SHOT
                .modifier(ShotReady(controller: controller, router: router))
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        #if NEWLOOK
        // the keepalive opens it, as whether this is a login isn't known yet when scenes are read
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif
        // otherwise every sottova:// link opens another window
        .handlesExternalEvents(matching: [])
        .commands { SottovaCommands(controller: controller, router: router) }

        #if !NEWLOOK
        MenuBarExtra {
            Panel(controller: controller)
                .id(palette)
                .environment(controller)
        } label: {
            Image(systemName: controller.status.symbol)
        }
        .menuBarExtraStyle(.window)
        #endif

        Settings {
            SettingsView(controller: controller)
                // the rail runs up under the traffic lights, as the main window's sidebar does
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .containerBackground(Theme.background, for: .window)
                #if NEWLOOK
                .onAppear { if Theme.reloadThemes() { themeVersion += 1 } }
                #endif
        }
        .windowResizability(.contentSize)
        #if NEWLOOK
        .restorationBehavior(.disabled)
        #endif

        #if NEWLOOK
        // a suppressed launch runs no views in the main window, so something else has to hold what can reopen it
        Window("", id: "keepalive") { Keepalive() }
            .windowStyle(.plain)
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
            .commandsRemoved()
        #endif
    }
}

#if NEWLOOK
private struct Keepalive: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HidesWindow()
            .frame(width: 1, height: 1)
            .onAppear {
                AppDelegate.showMain = { openWindow(id: "main"); NSApp.activate() }
                AppDelegate.showSettings = { openSettings(); NSApp.activate() }
                // no activate: the guard's `open -g` stays in the background
                AppDelegate.openAtLaunch = { openWindow(id: "main") }
                AppDelegate.launchWindow()
            }
    }

    private struct HidesWindow: NSViewRepresentable {
        func makeNSView(context: Context) -> Hider { Hider() }
        func updateNSView(_ view: Hider, context: Context) {}
    }

    private final class Hider: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            DispatchQueue.main.async { window.orderOut(nil) }
        }
    }
}
#endif

/// sottova:// links arrive here; SwiftUI's onOpenURL needs a window scene, and the panel isn't one until opened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var controller: Controller?
    #if NEWLOOK
    /// Work from anywhere, with or without a window open, unlike SwiftUI's environment actions.
    @MainActor static var showMain: () -> Void = {}
    @MainActor static var showSettings: () -> Void = {}
    @MainActor static var router: Router?
    @MainActor static var openAtLaunch: (() -> Void)?
    /// Set once launching is done; the launch event isn't readable any sooner.
    @MainActor private static var atLogin: Bool?

    /// A login starts in the menu bar, as Settings says. Needs both the keepalive and the launch event, in either order.
    @MainActor static func launchWindow() {
        guard let atLogin, let open = openAtLaunch else { return }
        openAtLaunch = nil
        if !atLogin { open() }
    }

    @MainActor static var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        MainActor.assumeIsolated {
            Self.atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            Self.launchWindow()
            if let controller = Self.controller, let router = Self.router { Self.statusMenu = StatusMenu(controller: controller, router: router) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { Self.showMain() } }
        return false
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Self.controller?.open($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.controller?.quitting() }
    }
}

extension PlaybackStatus {
    var symbol: String {
        switch self {
        case .idle: "music.note"
        case .playing: "waveform"
        case .resting: "ellipsis"
        case .paused: "pause"
        }
    }
}
