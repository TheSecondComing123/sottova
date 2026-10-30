import AppKit
import SwiftUI
import SottovaCore

/// One song: number (or play on hover), art, title over artist, album, length.
struct SongRow: View {
    let song: Song
    let number: Int
    var showsArt = true
    var showsAlbum = true
    /// On an album page the artist line only shows when a track's artist differs from the album's.
    var albumArtist: String?
    /// On a playlist page: takes the song out of the playlist.
    var remove: (() -> Void)?
    /// Under a work's heading the title would repeat it, so the performer leads.
    var performerFirst = false
    let play: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Marker(song: song, number: number, hovering: hovering, play: play)
                .frame(width: 28)

            if showsArt {
                Artwork(key: song.artwork, size: 40, radius: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                if performerFirst {
                    Text(song.artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                } else {
                    Title(song: song)
                }
                if song.artist != albumArtist, !performerFirst {
                    LinkText(text: song.artist) { navigate(.artist(song.artist)) }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsAlbum {
                LinkText(text: controller.copy(ofAlbum: song.albumID)?.name ?? song.album) { navigate(.album(song.albumID)) }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            }

            Text(Format.time(song.duration))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: showsArt ? 60 : 48)
        .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .accessibilityAction(named: "Play", play)
        .draggable(URL(filePath: song.id))
        .sottovaMenu {
            var entries: [MenuEntry] = [
                .item("Play", action: play),
                .item("Play next") { controller.playNext([song]) },
                .addToCollection([song], name: song.work, controller: controller),
            ]
            entries.append(.item(controller.trims[song.id] == nil ? "Trim…" : "Change trim…") { router.trimming = song })
            if let remove {
                entries.append(.item("Remove from this collection", action: remove))
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
    }
}

/// The number column. Its own view so only it, not the whole row, re-renders when the track changes.
private struct Marker: View {
    let song: Song
    let number: Int
    let hovering: Bool
    let play: () -> Void
    @Environment(Controller.self) private var controller

    var body: some View {
        let isCurrent = controller.current?.id == song.id && controller.status != .idle
        let running = controller.status == .playing || controller.status == .resting
        if hovering {
            Button(action: isCurrent ? controller.toggle : play) {
                (isCurrent && running ? Ph.pause : Ph.play).icon(.fill, size: 13)
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(PressStyle())
            .help(isCurrent ? (running ? "pause" : "play") : "play from here")
        } else if isCurrent {
            // still, on purpose: the animated .variableColor effect redrew at display rate and cost about 20% CPU
            Ph.waveform.icon(.bold, size: 15)
                .foregroundStyle(Theme.accent(for: song.album))
        } else {
            Text("\(number)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
        }
    }
}

private struct Title: View {
    let song: Song
    @Environment(Controller.self) private var controller

    var body: some View {
        let isCurrent = controller.current?.id == song.id && controller.status != .idle
        // the catalog number trails the work in a quieter voice, as on a concert program
        Text("\(song.work)\(Text(song.detail.map { "  \($0)" } ?? "").font(.system(size: 13)).foregroundStyle(Theme.faint))")
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}

/// A tile's title, led by a still waveform while something of it is playing. Still on purpose: the animated symbol
/// effect redrew at display rate.
struct NowPlayingTitle: View {
    let text: String
    let playing: Bool
    /// Whose accent the mark takes.
    var key: String?
    var lines = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if playing {
                Ph.waveform.icon(.bold, size: 12)
                    .foregroundStyle(Theme.accent(for: key))
                    .accessibilityLabel("playing")
            }
            Text(text)
                .lineLimit(lines)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.text)
    }
}

/// Column labels above a song list.
struct SongColumns: View {
    var showsArt = true
    var showsAlbum = true

    var body: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 28)
            if showsArt {
                Color.clear.frame(width: 40, height: 1)
            }
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text("Collection").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            }
            Ph.clock.icon(size: 14).frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.faint)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.bottom, 8)
    }
}

/// Square art that lifts a play button into its corner on hover: springs in, snaps out.
struct Tile<Label: View>: View {
    let artwork: String?
    var circle = false
    var coverTitle: String?
    var coverSubtitle: String?
    let play: () -> Void
    let open: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        VStack(alignment: circle ? .center : .leading, spacing: 12) {
            Artwork(key: artwork, radius: 4, circle: circle, title: coverTitle, subtitle: coverSubtitle)
                // a type cover repeats the label below it
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    // lifted off the art: the button's color can be the cover's own
                    PlayCircle(size: 44, action: play)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .padding(circle ? 4 : 8)
                        .opacity(hovering ? 1 : 0)
                        .offset(y: hovering || reduceMotion ? 0 : 8)
                        .animation(hovering ? Theme.settle : Theme.curve(0.12), value: hovering)
                }
            label
        }
        .padding(8)
        // 12 outside, 12 − 8 = 4 on the art inside, so the two corners stay concentric
        // a square plate behind a circle reads as a frame around it; circles lift the play button and nothing else
        .background(Theme.hover.opacity(hovering && !circle ? 1 : 0), in: .rect(cornerRadius: 12))
        .animation(Theme.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        // a tap gesture and a hover-only play button are invisible to VoiceOver: one labeled element with both actions
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Play", play)
    }
}

struct AlbumTile: View {
    let album: Album
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(Router.self) private var router

    var body: some View {
        Tile(artwork: album.artwork, coverTitle: album.title, play: { controller.play(album.songs) }, open: { navigate(.album(album.id)) }) {
            VStack(alignment: .leading, spacing: 2) {
                NowPlayingTitle(text: album.title, playing: controller.sounding?.albumID == album.id, key: album.title)
                Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .sottovaMenu {
            let gaps = controller.albumSettings[album.id]?.name
            var choices: [MenuEntry] = [.item("Your setting", checked: gaps == nil) { controller.albumSettings[album.id] = nil }]
            choices += SottovaCore.Settings.presets.map { preset in
                .item(preset.name, checked: gaps == preset.name) { controller.albumSettings[album.id] = preset }
            }
            // Custom is edited on the album page; here it only shows that it's the one in use
            if gaps == "Custom" {
                choices.append(.item("Custom", checked: true) {})
            }
            return [
                .item("Play") { controller.play(album.songs) },
                .item("Play next") { controller.playNext(album.songs) },
                .addToCollection(album.songs, name: album.title, controller: controller),
                .item("Go to artist") { navigate(.artist(album.artist)) },
                .divider,
                .item("Choose cover…") { router.coverFor = .album(album.id) },
                .item("Start at…") { router.alarm = .new(.album(album.id)) },
                .item("Make it yours") { controller.makeYours(album).map { navigate(.playlist($0)) } },
                .submenu("Gaps", choices),
            ]
        }
    }
}

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

struct CollectionTile: View {
    let collection: MusicCollection

    var body: some View {
        switch collection {
        case .album(let album): AlbumTile(album: album)
        case .yours(let playlist): PlaylistTile(playlist: playlist)
        }
    }
}

/// One of yours: its cover, or its first song's, over its name and how many songs it holds.
struct PlaylistTile: View {
    let playlist: Playlist
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(Router.self) private var router
    @Environment(\.renaming) private var renaming

    var body: some View {
        let songs = controller.songs(of: playlist)
        Tile(artwork: controller.playlistCovers[playlist.id] ?? songs.first?.artwork, coverTitle: playlist.name,
             play: { controller.play(songs, source: playlist.id) }, open: { navigate(.playlist(playlist.id)) }) {
            VStack(alignment: .leading, spacing: 2) {
                NowPlayingTitle(text: playlist.name, playing: controller.sounding != nil && controller.origin?.key == playlist.id, key: playlist.name)
                Text(Format.count(playlist.paths.count, "song"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .sottovaMenu { MenuEntry.yours(playlist, controller: controller, router: router, navigate: navigate, renaming: renaming) }
    }
}

struct ArtistTile: View {
    let artist: Artist
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        Tile(artwork: artist.artwork, circle: true, coverTitle: artist.name, play: { controller.play(artist.songs.shuffled(), shuffled: true) }, open: { navigate(.artist(artist.name)) }) {
            VStack(spacing: 2) {
                NowPlayingTitle(text: artist.name, playing: controller.sounding.map { $0.artist == artist.name || $0.albumArtist == artist.name } ?? false,
                                key: controller.sounding?.album)
                Text(Format.count(artist.songs.count, "song"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .sottovaMenu {
            [
                .item("Shuffle") { controller.play(artist.songs.shuffled(), shuffled: true) },
                .item("Play next") { controller.playNext(artist.songs) },
            ]
        }
    }
}

struct SectionTitle: View {
    let title: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.text)
            Spacer()
            if let action {
                LinkText(text: action.label, action: action.run)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Big page title with a count line and the play and shuffle buttons.
struct PageHeader: View {
    let title: String
    let detail: String
    let songs: [Song]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 48, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            if !songs.isEmpty {
                PlayRow(songs: songs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
    }
}

extension MenuEntry {
    /// "Add to collection ▸": every one of yours, then a new one named after what's being added.
    @MainActor static func addToCollection(_ songs: [Song], name: String, controller: Controller) -> MenuEntry {
        var entries = controller.playlists.map { playlist in MenuEntry.item(playlist.name) { controller.add(songs, to: playlist.id) } }
        if !entries.isEmpty {
            entries.append(.divider)
        }
        entries.append(.item("New collection") { controller.newPlaylist(named: name, songs: songs) })
        return .submenu("Add to collection", entries)
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
                if router.route == .playlist(playlist.id) { navigate(.home) }
                controller.trashPlaylist(playlist.id)
            },
        ]
    }
}

/// Play in order, or shuffled; gaps either way.
struct PlayRow: View {
    let songs: [Song]
    /// A playlist's id, whose gaps these play with.
    var source: String?
    /// Extra header actions after Shuffle.
    var more: AnyView?
    @Environment(Controller.self) private var controller

    /// Which songs these are, however they're ordered: the same set from the same page is the same origin.
    private var key: String {
        Controller.Origin.key(of: songs, source: source)
    }

    /// These songs are what's playing (or paused, or resting between them).
    private var current: Controller.Origin? {
        guard let origin = controller.origin, origin.key == key, controller.status != .idle else { return nil }
        return origin
    }

    var body: some View {
        let running = current != nil && (controller.status == .playing || controller.status == .resting)
        HStack(spacing: 16) {
            // nothing to play: no live play button, only the extra actions
            if !songs.isEmpty {
                // while these play it's their pause button; paused, it picks them up again instead of starting over
                PlayCircle(size: 52, playing: running) {
                    if current != nil {
                        controller.toggle()
                    } else {
                        controller.play(songs, source: source)
                    }
                }
                // labeled, not a bare icon: it's a one-shot "play these shuffled", and alone the icon read as a toggle
                // whose on and off looked the same
                let shuffling = current?.shuffled == true
                // lit while these play shuffled; pressed again it deals a new order
                Button { controller.play(songs.shuffled(), source: source, shuffled: true) } label: {
                    HStack(spacing: 8) {
                        Ph.shuffle.icon(shuffling ? .bold : .duotone, size: 16)
                            .foregroundStyle(shuffling ? Theme.accent(for: key) : Theme.text)
                        Text(shuffling ? "Shuffling" : "Shuffle")
                            .font(.system(size: 13, weight: .semibold))
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(shuffling ? Theme.hover : .clear, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(shuffling ? Theme.accent(for: key) : Theme.border, lineWidth: shuffling ? 1.5 : 1))
                    .hoverable(radius: 8)
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .animation(Theme.quick, value: shuffling)
                .help(shuffling ? "shuffle again" : "play these in random order")
            }
            if let more {
                more
            }
        }
    }
}

let albumGrid = [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 16, alignment: .top)]
