#if SHOT
import AppKit
import SwiftUI
import SottovaCore

/// Enters the state from `-shotState`, opens `-shotRoute`, sizes the window, then writes its number to `ready`, which
/// is what scripts/harness.sh waits for.
struct ShotReady: ViewModifier {
    let controller: Controller
    let router: Router
    @State private var seeded = false
    @State private var mounted = false

    func body(content: Content) -> some View {
        ZStack {
            if seeded {
                content.onAppear { mounted = true }
            } else {
                Color.clear
            }
        }.task {
            guard !seeded else { return }
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "shotAppearance") == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            try? await controller.shotEnter(defaults.string(forKey: "shotState") ?? "idle",
                                            covers: defaults.string(forKey: "shotCovers").map { URL(filePath: $0) })
            // before the route: resized in the same turn as a withAnimation, SwiftUI's updateAnimatedWindowSize runs the
            // window's width away until AppKit throws. Nothing but this harness resizes from code
            let width = defaults.object(forKey: "shotWidth") != nil ? defaults.double(forKey: "shotWidth") : 1240
            let height = defaults.object(forKey: "shotHeight") != nil ? defaults.double(forKey: "shotHeight") : 800
            seeded = true
            for _ in 0..<120 {
                if mounted { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard mounted else { return }
            var window: NSWindow?
            for _ in 0..<120 {
                window = NSApp.windows.first { $0.isVisible && ($0.title == "Sottova" || $0.frameAutosaveName == "main") }
                if window != nil { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard window != nil else { return }
            window?.setContentSize(NSSize(width: width, height: height))
            let routes: [String: Route] = ["home": .home, "songs": .songs, "collections": .collections, "artists": .artists, "alarms": .alarms, "shelf": .shelf]
            if let name = defaults.string(forKey: "shotNewCollection") { _ = controller.newPlaylist(named: name) }
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
            router.droppingMusic = defaults.bool(forKey: "shotDragging")
            if let filter = defaults.string(forKey: "shotFilter") { router.songFilter = filter }
            controller.problem = defaults.string(forKey: "shotProblem")
            if let title = defaults.string(forKey: "shotTrim"), let song = controller.catalog.songs.first(where: { $0.title == title }) {
                router.trimming = song
            }
            if let name = defaults.string(forKey: "shotCover"), let playlist = controller.playlists.first(where: { $0.name == name }) {
                router.coverFor = .playlist(playlist.id)
            }
            if let picked = defaults.string(forKey: "shotPicked") {
                let titles = picked.components(separatedBy: "|")
                if case .playlist(let id) = router.route, let playlist = controller.playlists.first(where: { $0.id == id }) {
                    router.selected = Set(playlist.paths.indices.filter { titles.contains(controller.catalog.songsByID[playlist.paths[$0]]?.title ?? "") }
                        .map { Playlist.rowKey($0, playlist.paths[$0]) })
                } else {
                    router.selected = Set(controller.catalog.songs.filter { titles.contains($0.title) }.map(\.id))
                }
            }
            if let name = defaults.string(forKey: "shotRow") {
                router.alarm = controller.alarms.first { $0.name == name }.map { .edit($0) } ?? .new(nil)
            } else if defaults.bool(forKey: "shotSheet") {
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
            if let name = defaults.string(forKey: "shotCustom"), let playlist = controller.playlists.first(where: { $0.name == name }) {
                var own = controller.settings
                (own.name, own.crossfade) = ("Custom", false)
                router.presetEdit = PresetEdit(preset: own, collection: (name, { controller.setGaps($0, for: playlist.id) }))
            }
            if let name = defaults.string(forKey: "shotOwnSilence"), let playlist = controller.playlists.first(where: { $0.name == name }) {
                var own = controller.settings
                (own.name, own.gapMin, own.gapMax) = ("Custom", 300, 300)
                controller.setGaps(own, for: playlist.id)
            }
            if let name = defaults.string(forKey: "shotCredit"), let playlist = controller.playlists.first(where: { $0.name == name }),
               let cover = defaults.string(forKey: "shotCovers").flatMap({ try? Data(contentsOf: URL(filePath: $0).appending(path: "compline.jpg")) }) {
                controller.setCover(cover, credit: "Caspar David Friedrich, Moonrise over the Sea, 1822", forPlaylist: playlist.id)
            }
            router.showsQueue = defaults.bool(forKey: "shotQueue")
            if defaults.bool(forKey: "shotYours") {
                for name in ["Counterpoint", "Perfect Chopin", "Shellac"] {
                    _ = controller.newPlaylist(named: name, songs: controller.catalog.albums.first { $0.title == name }?.songs ?? [])
                }
                controller.volume = 0.62
                if router.showsQueue { controller.playNext(Array(controller.catalog.songs.prefix(4))) }
            }
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
            // setting up the state leaves notices of its own
            controller.notice = defaults.string(forKey: "shotNotice").map { .init($0, undoable: true, action: "") }  // an empty Edit › Undo is named ""
            try? await Task.sleep(for: .seconds(1))
            if defaults.bool(forKey: "shotUndo"), let playlist = controller.playlists.first(where: { $0.name == "Compline" }),
               let undo = controller.undo ?? window?.undoManager {
                undo.removeAllActions()
                while undo.groupingLevel > 0 { undo.endUndoGrouping() }
                undo.groupsByEvent = false
                controller.undo = undo
                undo.beginUndoGrouping()
                controller.removeFromPlaylist(playlist.id, at: [0])
                undo.endUndoGrouping()
                await Task.yield()
            }
            if let name = defaults.string(forKey: "shotTrash"), let playlist = controller.playlists.first(where: { $0.name == name }) {
                NSApp.activate()
                window?.makeKeyAndOrderFront(nil)
                router.trashing = playlist.id
                for _ in 0..<40 {
                    if NSApp.windows.contains(where: { $0.isVisible && String(describing: type(of: $0)).contains("AlertPanel") }) { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                await Task.yield()
            }
            // a covered window holds an animated change undrawn: a route with no resize to push it showed the old page
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            // from the window's top left, as the mocks measure
            if let at = defaults.string(forKey: "shotMenuAt")?.split(separator: ",").compactMap({ Double($0) }), let window, let height = window.contentView?.bounds.height {
                return shotMenu(at: NSPoint(x: at[0], y: height - at[1]), in: window)
            }
            if let name = defaults.string(forKey: "shotDaysOffPopover"), let row = controller.alarms.first(where: { $0.name == name }) {
                router.daysOffFromWord = true
                router.daysOff = row.id
                try? await Task.sleep(for: .seconds(1))
                let popover = NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                try? Data(String(popover?.windowNumber ?? 0).utf8).write(to: ShotEnv.root.appending(path: "ready"))
                return
            }
            if let kind = defaults.string(forKey: "shotContextMenu"), let window {
                window.makeKeyAndOrderFront(nil)
                let navigate = Navigate { router.open($0, in: controller) }
                var entries: [MenuEntry] = []
                if kind == "sleep" {
                    entries = StatusMenu.sleepChoices(controller)
                } else if kind == "collection", let playlist = controller.playlists.first(where: { $0.name == "Compline" }) {
                    entries = MenuEntry.yours(playlist, controller: controller, router: router, navigate: navigate,
                                             renaming: Binding(get: { router.renaming }, set: { router.renaming = $0 }))
                } else if kind == "album", let album = controller.catalog.albums.first(where: { $0.title == "Overworld" }) {
                    entries = MenuEntry.album(album, controller: controller, router: router, navigate: navigate)
                } else if kind == "song", let song = controller.catalog.songs.first(where: { $0.title == "Goldberg Variations: Aria" }) {
                    let titles = (defaults.string(forKey: "shotPicked") ?? song.title).components(separatedBy: "|")
                    let picked = controller.catalog.songs.filter { titles.contains($0.title) }
                    entries = MenuEntry.song(song, picked: picked, play: router.playPick, remove: nil, part: nil,
                                             controller: controller, router: router, navigate: navigate)
                }
                let menu = NSMenu(entries)
                let shown = defaults.string(forKey: "shotSubmenu").flatMap { title in menu.items.first { $0.title.hasPrefix(title) }?.submenu } ?? menu
                if shown.numberOfItems > 0 {
                    shotMenuReady()
                    shown.popUp(positioning: nil, at: NSPoint(x: window.frame.midX, y: window.frame.midY), in: nil)
                    return
                }
            }
            if let title = defaults.string(forKey: "shotMainMenu"), let window, let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu {
                window.makeKeyAndOrderFront(nil)
                shotMenuReady()
                menu.popUp(positioning: nil, at: NSPoint(x: window.frame.midX, y: window.frame.maxY - 80), in: nil)
                return
            }
            if defaults.bool(forKey: "shotStatusMenu"), let window {
                shotMenuReady()
                _ = AppDelegate.statusMenu?.item.menu?.popUp(positioning: nil, at: NSPoint(x: window.frame.midX, y: window.frame.midY), in: nil)
                return
            }
            if defaults.bool(forKey: "shotSettings") {
                AppDelegate.showSettings()
                try? await Task.sleep(for: .seconds(1))
                let settings = NSApp.windows.first { $0.isVisible && $0.title.contains("Settings") } ?? NSApp.windows.first { $0.isVisible && $0.contentView?.frame.width == 620 }
                try? Data(String(settings?.windowNumber ?? 0).utf8).write(to: ShotEnv.root.appending(path: "ready"))
                return
            }
            // a sheet is its own window: asking for one takes the picture of it alone
            let sheet = defaults.bool(forKey: "shotSheet") || defaults.string(forKey: "shotRow") != nil || router.trimming != nil || router.coverFor != nil || router.trashing != nil
            let dialog = router.trashing == nil ? nil : NSApp.windows.first { $0.isVisible && $0.windowNumber != window?.windowNumber && $0.frame.width > 100 && $0.frame.height > 60 }
            if let path = defaults.string(forKey: "shotNativePNG"), let view = dialog?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            }
            let number = (sheet ? window?.attachedSheet?.windowNumber : nil) ?? dialog?.windowNumber ?? window?.windowNumber ?? 0
            try? Data(String(number).utf8).write(to: ShotEnv.root.appending(path: "ready"))
        }
    }
}
#endif
