import AppKit

/// The Dock icon shows only while a real window (Settings, the now window) is open; the menu bar stays home.
/// An accessory app's windows otherwise open behind whatever app is in front.
@MainActor
enum Dock {
    private static var openWindows = 0

    static func windowOpened(identifier: String) {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        // the policy switch needs a beat before activation takes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.contains(identifier) == true }?.orderFrontRegardless()
        }
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
