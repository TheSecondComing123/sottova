import AppKit
import SwiftUI
import SottovaCore

/// A set of songs you press play on: an album that came with your files, or one of yours.
enum MusicCollection: Identifiable {
    case album(Album)
    case yours(Playlist)

    var id: String {
        switch self {
        case .album(let album): album.id
        case .yours(let playlist): playlist.id
        }
    }

    var title: String {
        switch self {
        case .album(let album): album.title
        case .yours(let playlist): playlist.name
        }
    }
}

extension MenuEntry {
    /// A song's row; several picked get what can be done to all of them.
    @MainActor static func song(_ song: Song, picked songs: [Song], play: @escaping () -> Void, remove: ((Set<String>) -> Void)?,
                                part: (starts: Bool, flip: () -> Void)?, naming: @escaping () -> Void,
                                controller: Controller, router: Router, navigate: Navigate) -> [MenuEntry] {
        if songs.count > 1 {
            var entries: [MenuEntry] = [
                // from the first picked, as Return does
                .item("Play", action: router.playPick),
                .item("Play \(songs.count) next") { controller.playNext(songs) },
                .item("Add \(songs.count) to queue") { controller.playNext(songs, at: controller.upNext.count) },
                .addToCollection(songs, name: "", controller: controller, naming: naming),
            ]
            if let remove {
                entries.append(.item("Remove \(songs.count) from this collection") { remove(Set(songs.map(\.id))) })
            }
            return entries
        }
        var entries: [MenuEntry] = [
            .item("Play", action: play),
            .item("Play next") { controller.playNext([song]) },
            .item("Add to queue") { controller.playNext([song], at: controller.upNext.count) },
            .addToCollection([song], name: "", controller: controller, naming: naming),
        ]
        entries.append(.item(controller.trims[song.id] == nil ? "Trim…" : "Change trim…") { router.trimming = song })
        if let remove {
            entries.append(.item("Remove from this collection") { remove([song.id]) })
        }
        if let part {
            entries.append(.item(part.starts ? "Join the part before" : "Start a new part here", action: part.flip))
        }
        entries += [
            .divider,
            .item("Go to \(controller.copy(ofAlbum: song.albumID)?.name ?? song.album)") { navigate(.album(song.albumID)) },
            .item("Go to artist") { navigate(.artist(song.artist)) },
        ]
        if let composer = song.composer {
            entries.append(.item("Go to composer") { navigate(.composer(composer)) })
        }
        entries.append(.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: song.id)]) })
        return entries
    }

    @MainActor static func album(_ album: Album, controller: Controller, router: Router, navigate: Navigate) -> [MenuEntry] {
        let gaps = controller.albumSettings[album.id]?.name
        var choices: [MenuEntry] = [.item("Your setting", checked: gaps == nil) { controller.albumSettings[album.id] = nil }]
        choices += controller.allPresets.map { preset in
            .item(preset.name, checked: gaps == preset.name) { controller.albumSettings[album.id] = preset }
        }
        // Custom is edited on the album page; here it only shows that it's the one in use
        if gaps == "Custom" {
            choices.append(.item("Custom", checked: true, enabled: false) {})
        }
        let choicesName = "Silence"
        var goToArtist: [MenuEntry] = [.item("Go to artist") { navigate(.artist(album.artist)) }]
        // a name opens Songs filtered, and no song is tagged with Catalog's word for a compilation
        if album.artist == "Various Artists" { goToArtist = [] }
        return [
            .item("Play") { controller.play(album.songs) },
            .item("Play next") { controller.playNext(album.songs) },
            .addToCollection(album.songs, name: album.title, controller: controller),
        ] + goToArtist + [
            .divider,
            .item("Choose cover…") { router.coverFor = .album(album.id) },
            .item("Start at…") { router.alarm = .new(.album(album.id)) },
            .item("Make it yours") { controller.makeYours(album).map { navigate(.playlist($0)) } },
            .submenu(choicesName, choices),
        ]
    }

    /// "Add to collection ▸": every one of yours, then a new one named after what's being added, or, with `naming`,
    /// one you're asked to name.
    @MainActor static func addToCollection(_ songs: [Song], name: String, controller: Controller, naming: (() -> Void)? = nil) -> MenuEntry {
        .submenu("Add to collection", collections(songs, name: name, controller: controller, naming: naming))
    }

    /// The same list for Songs' Add to button.
    @MainActor static func collections(_ songs: [Song], name: String, controller: Controller, naming: (() -> Void)? = nil) -> [MenuEntry] {
        var entries = controller.playlists.map { playlist in MenuEntry.item(playlist.name) { controller.add(songs, to: playlist.id) } }
        if !entries.isEmpty {
            entries.append(.divider)
        }
        if let naming {
            entries.append(.item("New collection…", action: naming))
        } else {
            entries.append(.item("New collection") { controller.newPlaylist(named: name, songs: songs) })
        }
        return entries
    }

    /// What a new collection of these is called until you say otherwise: the piece or folder they share.
    @MainActor static func name(for songs: [Song], controller: Controller) -> String {
        guard let first = songs.first else { return "New collection" }
        if songs.allSatisfy({ $0.work == first.work }) { return first.work }
        if songs.allSatisfy({ $0.albumID == first.albumID }) { return controller.copy(ofAlbum: first.albumID)?.name ?? first.album }
        return "New collection"
    }

    /// One of yours, from the sidebar or a tile. Rename opens its page with the name selected.
    @MainActor static func yours(_ playlist: Playlist, controller: Controller, router: Router, navigate: Navigate,
                                 renaming: Binding<String?>) -> [MenuEntry] {
        [
            .item("Play") { controller.play(controller.songs(of: playlist), source: playlist.id) },
            .item("Shuffle") { controller.play(controller.songs(of: playlist).shuffled(), source: playlist.id, shuffled: true) },
            .divider,
            .item("Rename") {
                renaming.wrappedValue = playlist.id
                navigate(.playlist(playlist.id))
            },
            .item("Choose cover…") { router.coverFor = .playlist(playlist.id) },
            .item("Start at…") { router.alarm = .new(.playlist(playlist.id)) },
            .item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: playlist.id)]) },
            .divider,
            .item("Move to Trash") {
                if !controller.alarmsLost(trashing: playlist).isEmpty {
                    router.trashing = playlist.id
                    return
                }
                if router.route == .playlist(playlist.id) { navigate(.home) }
                controller.trashPlaylist(playlist.id)
            },
        ]
    }
}
