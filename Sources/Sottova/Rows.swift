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
                    Text(song.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsAlbum {
                Text(song.album)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
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
        .contextMenu {
            Button("Play", action: play)
            Button("Play next") { controller.playNext([song]) }
            AddToPlaylist(songs: [song], name: song.work)
            if let remove {
                Button("Remove from playlist", action: remove)
            }
            Divider()
            Button("Go to album") { navigate(.album(song.albumID)) }
            Button("Go to artist") { navigate(.artist(song.artist)) }
            if let composer = song.composer {
                Button("Go to composer") { navigate(.composer(composer)) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: song.id)]) }
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
                .lineLimit(lines, reservesSpace: lines > 1)
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
                Text("Album").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
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
                    PlayCircle(size: 44, action: play)
                        .padding(circle ? 4 : 8)
                        .opacity(hovering ? 1 : 0)
                        .offset(y: hovering || reduceMotion ? 0 : 8)
                        .animation(hovering ? Theme.settle : Theme.curve(0.12), value: hovering)
                }
            label
        }
        .padding(8)
        // 12 outside, 12 − 8 = 4 on the art inside, so the two corners stay concentric
        .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 12))
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
        Tile(artwork: album.artwork, coverTitle: album.title, coverSubtitle: album.artist, play: { controller.play(album.songs) }, open: { navigate(.album(album.id)) }) {
            VStack(alignment: .leading, spacing: 2) {
                NowPlayingTitle(text: album.title, playing: controller.sounding?.albumID == album.id, key: album.title)
                Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Play") { controller.play(album.songs) }
            Button("Play next") { controller.playNext(album.songs) }
            AddToPlaylist(songs: album.songs, name: album.title)
            Button("Go to artist") { navigate(.artist(album.artist)) }
            Button("Choose cover…") { router.coverFor = .album(album.id) }
            Picker("Gaps", selection: Binding(
                get: { controller.albumSettings[album.id]?.name ?? "" },
                set: { name in
                    // Custom is edited on the album page; picking it here keeps what's there
                    guard name != "Custom" else { return }
                    controller.albumSettings[album.id] = SottovaCore.Settings.presets.first { $0.name == name }
                })) {
                Text("Your setting").tag("")
                ForEach(SottovaCore.Settings.presets, id: \.name) { Text($0.name).tag($0.name) }
                if controller.albumSettings[album.id]?.name == "Custom" {
                    Text("Custom").tag("Custom")
                }
            }
        }
    }
}

struct ArtistTile: View {
    let artist: Artist
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        Tile(artwork: artist.artwork, circle: true, coverTitle: artist.name, play: { controller.play(artist.songs.shuffled()) }, open: { navigate(.artist(artist.name)) }) {
            VStack(spacing: 2) {
                NowPlayingTitle(text: artist.name, playing: controller.sounding.map { $0.artist == artist.name || $0.albumArtist == artist.name } ?? false,
                                key: controller.sounding?.album)
                Text(Format.count(artist.songs.count, "song"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .contextMenu {
            Button("Shuffle") { controller.play(artist.songs.shuffled()) }
            Button("Play next") { controller.playNext(artist.songs) }
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

/// "Add to Playlist ▸": every playlist, then a new one named after what's being added.
struct AddToPlaylist: View {
    let songs: [Song]
    let name: String
    @Environment(Controller.self) private var controller

    var body: some View {
        Menu("Add to playlist") {
            ForEach(controller.playlists) { playlist in
                Button(playlist.name) { controller.add(songs, to: playlist.id) }
            }
            if !controller.playlists.isEmpty {
                Divider()
            }
            Button("New playlist") { controller.newPlaylist(named: name, songs: songs) }
        }
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

    var body: some View {
        HStack(spacing: 16) {
            PlayCircle(size: 52) { controller.play(songs, source: source) }
            // labeled, not a bare icon: it's a one-shot "play these shuffled", and alone the icon read as a toggle
            // whose on and off looked the same
            Button { controller.play(songs.shuffled(), source: source) } label: {
                HStack(spacing: 8) {
                    Ph.shuffle.icon(size: 16)
                    Text("Shuffle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .hoverable(radius: 8)
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .help("play these in random order")
            if let more {
                more
            }
        }
    }
}

let albumGrid = [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 16, alignment: .top)]
