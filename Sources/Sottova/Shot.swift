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
            let asked = defaults.string(forKey: "shotRoute") ?? "home"
            if asked.hasPrefix("collection:") {
                let name = asked.dropFirst("collection:".count)
                if let playlist = controller.playlists.first(where: { $0.name == name }) {
                    router.go(to: .playlist(playlist.id))
                } else if let album = controller.catalog.albums.first(where: { $0.title == name }) {
                    router.go(to: .album(album.id))
                }
            } else {
                router.go(to: routes[asked]!)
            }
            #if NEWLOOK
            router.droppingMusic = defaults.bool(forKey: "shotDragging")
            if let filter = defaults.string(forKey: "shotFilter") { router.songFilter = filter }
            if let picked = defaults.string(forKey: "shotPicked") {
                let titles = picked.components(separatedBy: "|")
                router.selected = Set(controller.catalog.songs.filter { titles.contains($0.title) }.map(\.id))
            }
            if defaults.bool(forKey: "shotSheet") {
                var preset = controller.settings
                (preset.name, preset.gapMin, preset.gapMax, preset.fadeIn, preset.crossfade) = ("Long evening", 300, 720, 6, false)
                router.presetEdit = PresetEdit(preset: preset)
            }
            if let free = defaults.string(forKey: "shotFree") {
                let credit = { (title: String) in
                    let folder = Shelf.folder.appending(path: Shelf.sets.first { $0.title == title }!.folder)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? Data().write(to: folder.appending(path: "credits.txt"))
                }
                if free != "first" { credit("Open Goldberg Variations") }
                if free == "downloaded" { credit("Cloud Cover") }
                if free == "downloading" { ShelfDownload.shelf.shotRow("musopen-chopin", running: 0.4) }
                if free == "failed" { ShelfDownload.shelf.shotRow("ChrisZabriskieDirectToVideo", failure: "Didn't finish. The connection dropped.") }
            }
            if let hour = defaults.object(forKey: "shotDropHour") as? Int ?? Int(defaults.string(forKey: "shotDropHour") ?? "") {
                router.shotDrop = (hour, defaults.string(forKey: "shotDropName") ?? "")
            }
            router.showsQueue = defaults.bool(forKey: "shotQueue")
            if defaults.bool(forKey: "shotYours") {
                for name in ["Counterpoint", "Perfect Chopin", "Shellac"] {
                    _ = controller.newPlaylist(named: name, songs: controller.catalog.albums.first { $0.title == name }?.songs ?? [])
                }
                controller.volume = 0.62
                if router.showsQueue { controller.playNext(Array(controller.catalog.songs.prefix(4))) }
            }
            #endif
            let width = defaults.object(forKey: "shotWidth") != nil ? defaults.double(forKey: "shotWidth") : 1240
            let window = NSApp.windows.first { $0.title == "Sottova" }
            window?.setContentSize(NSSize(width: width, height: 800))
            // a covered window stops drawing, by design, so it can't be measured: on top in every space, but nearly
            // clear and letting clicks through, so whoever's at the Mac isn't interrupted
            if defaults.bool(forKey: "shotFront") {
                window?.level = .floating
                window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window?.ignoresMouseEvents = true
                window?.alphaValue = 0.02
                window?.orderFrontRegardless()
            }
            // for someone watching: in front, but still not activated
            if defaults.bool(forKey: "shotRaise") { window?.orderFrontRegardless() }
            try? await Task.sleep(for: .seconds(1))
            #if NEWLOOK
            // from the window's top left, as the mocks measure
            if let at = defaults.string(forKey: "shotMenuAt")?.split(separator: ",").compactMap({ Double($0) }), let window, let height = window.contentView?.bounds.height {
                return shotMenu(at: NSPoint(x: at[0], y: height - at[1]), in: window)
            }
            if defaults.bool(forKey: "shotStatusMenu"), let window {
                shotMenuReady()
                _ = AppDelegate.statusMenu?.item.menu?.popUp(positioning: nil, at: NSPoint(x: window.frame.midX, y: window.frame.midY), in: nil)
                return
            }
            #endif
            // a sheet is its own window: asking for one takes the picture of it alone
            try? Data(String((defaults.bool(forKey: "shotSheet") ? window?.attachedSheet?.windowNumber : nil) ?? window?.windowNumber ?? 0).utf8).write(to: ShotEnv.root.appending(path: "ready"))
        }
    }
}
#endif
