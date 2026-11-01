#if SHOT
import AppKit
import SwiftUI
import SottovaCore

/// Enters the state from `-shotState`, opens `-shotRoute`, sizes the window, then writes its number to `ready`, which
/// is what scripts/harness.sh waits for.
struct ShotReady: ViewModifier {
    let controller: Controller
    let router: Router

    func body(content: Content) -> some View {
        content.task {
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "shotAppearance") == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            try? await controller.shotEnter(defaults.string(forKey: "shotState") ?? "idle",
                                            covers: defaults.string(forKey: "shotCovers").map { URL(filePath: $0) })
            let routes: [String: Route] = ["home": .home, "songs": .songs, "collections": .collections, "artists": .artists, "alarms": .alarms, "shelf": .shelf]
            router.go(to: routes[defaults.string(forKey: "shotRoute") ?? "home"]!)
            #if NEWLOOK
            router.droppingMusic = defaults.bool(forKey: "shotDragging")
            #endif
            let width = defaults.object(forKey: "shotWidth") != nil ? defaults.double(forKey: "shotWidth") : 1240
            let window = NSApp.windows.first { $0.title == "Sottova" }
            window?.setContentSize(NSSize(width: width, height: 800))
            try? await Task.sleep(for: .seconds(1))
            try? Data(String(window?.windowNumber ?? 0).utf8).write(to: ShotEnv.root.appending(path: "ready"))
        }
    }
}
#endif
