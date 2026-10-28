import AppKit
import SwiftUI
import SottovaCore

@main
struct SottovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let controller = Controller()

    init() {
        let controller = controller
        AppDelegate.controller = controller
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
        MenuBarExtra {
            Panel(controller: controller)
        } label: {
            Image(systemName: controller.status.symbol)
        }
        .menuBarExtraStyle(.window)

        Window("sottova", id: "now") {
            NowWindow(controller: controller)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 380)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // otherwise every sottova:// link opens this window
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView(controller: controller)
        }
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
