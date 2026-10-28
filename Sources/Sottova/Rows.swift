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
    let play: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Marker(song: song, number: number, hovering: hovering, play: play)
                .frame(width: 28)

            if showsArt {
                Artwork(key: song.artwork, size: 40, radius: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Title(song: song)
                if song.artist != albumArtist {
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
        .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .accessibilityAction(named: "Play", play)
        .draggable(URL(filePath: song.id))
        .contextMenu {
            Button("Play", action: play)
            Button("Play Next") { controller.playNext([song]) }
            Divider()
            Button("Go to Album") { navigate(.album(song.albumID)) }
            Button("Go to Artist") { navigate(.artist(song.artist)) }
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
    @Environment(\.windowVisible) private var visible

    var body: some View {
        let isCurrent = controller.current?.id == song.id && controller.status != .idle
        let running = controller.status == .playing || controller.status == .resting
        if hovering {
            Button(action: isCurrent ? controller.toggle : play) {
                Image(systemName: isCurrent && running ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(PressStyle())
            .help(isCurrent ? (running ? "pause" : "play") : "play from here")
        } else if isCurrent {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .symbolEffect(.variableColor.iterative, isActive: controller.status == .playing && visible)
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
            .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}

/// Column labels above a song list.
struct SongColumns: View {
    var showsArt = true
    var showsAlbum = true

    var body: some View {
        HStack(spacing: 14) {
            Text("#").frame(width: 28)
            if showsArt {
                Color.clear.frame(width: 40, height: 1)
            }
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text("Album").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "clock").frame(width: 48, alignment: .trailing)
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
        VStack(alignment: circle ? .center : .leading, spacing: 10) {
            Artwork(key: artwork, radius: 8, circle: circle, title: coverTitle, subtitle: coverSubtitle)
                .overlay(alignment: .bottomTrailing) {
                    PlayCircle(size: 44, action: play)
                        .padding(circle ? 4 : 10)
                        .opacity(hovering ? 1 : 0)
                        .offset(y: hovering || reduceMotion ? 0 : 8)
                        .animation(hovering ? Theme.settle : .easeOut(duration: 0.12), value: hovering)
                }
            label
        }
        .padding(10)
        .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 10))
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

    var body: some View {
        Tile(artwork: album.artwork, coverTitle: album.title, coverSubtitle: album.artist, play: { controller.play(album.songs) }, open: { navigate(.album(album.id)) }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Play") { controller.play(album.songs) }
            Button("Play Next") { controller.playNext(album.songs) }
            Button("Go to Artist") { navigate(.artist(album.artist)) }
        }
    }
}

struct ArtistTile: View {
    let artist: Artist
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        Tile(artwork: artist.artwork, circle: true, coverTitle: artist.name, play: { controller.play(artist.songs.shuffled()) }, open: { navigate(.artist(artist.name)) }) {
            VStack(spacing: 3) {
                Text(artist.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Format.count(artist.albums.count, "album"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .contextMenu {
            Button("Shuffle") { controller.play(artist.songs.shuffled()) }
            Button("Play Next") { controller.playNext(artist.songs) }
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 48, weight: .heavy))
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
        .padding(.bottom, 20)
    }
}

/// Play in order, or shuffled; gaps either way.
struct PlayRow: View {
    let songs: [Song]
    @Environment(Controller.self) private var controller

    var body: some View {
        HStack(spacing: 14) {
            PlayCircle(size: 52) { controller.play(songs) }
            IconButton(systemImage: "shuffle", help: "shuffle these", size: 40) {
                controller.play(songs.shuffled())
            }
        }
    }
}

let albumGrid = [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 14, alignment: .top)]
