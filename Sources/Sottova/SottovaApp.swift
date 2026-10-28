import AppKit
import SwiftUI
import SottovaCore

@main
struct SottovaApp: App {
    private let controller = Controller()

    init() {
        let controller = controller
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
