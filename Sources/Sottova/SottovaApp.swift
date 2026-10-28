import AppKit
import SwiftUI
import SottovaCore

@main
struct SottovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let controller = Controller()
    /// Theme.palette is set before this changes, so re-keying the scenes below redraws them in the new colors.
    @AppStorage("palette") private var palette = Palette.monochrome.id

    init() {
        let controller = controller
        AppDelegate.controller = controller
        Artwork.store = controller.artwork
        // M1 kept a single folder path in defaults
        if let path = UserDefaults.standard.string(forKey: "folder") {
            controller.addFolders([URL(filePath: path)])
            UserDefaults.standard.removeObject(forKey: "folder")
        }
        controller.run()
        let center = NSWorkspace.shared.notificationCenter
        _ = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { controller.systemWillSleep() }
        }
        _ = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { controller.systemDidWake() }
        }
    }

    var body: some Scene {
        Window("Sottova", id: "main") {
            MainWindow()
                .id(palette)
                .environment(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        // otherwise every sottova:// link opens another window
        .handlesExternalEvents(matching: [])

        MenuBarExtra {
            Panel(controller: controller)
                .id(palette)
                .environment(controller)
        } label: {
            Image(systemName: controller.status.symbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
                // the rail runs up under the traffic lights, as the main window's sidebar does
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .containerBackground(Theme.background, for: .window)
        }
        .windowResizability(.contentSize)
    }
}

/// sottova:// links arrive here; SwiftUI's onOpenURL needs a window scene, and the panel isn't one until opened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var controller: Controller?

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Self.controller?.open($0) }
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
