import AppKit
import SwiftUI
import SottovaCore

private struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
}

/// One row of tiles that scrolls sideways, so a shelf never wraps an orphan onto a second line.
private struct Shelf<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 4) {
                ForEach(items) { item in
                    cell(item).frame(width: 188)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -28)
    }

    /// Whether `count` tiles run past a page `width` wide, so "Show All" only appears when some are out of sight.
    /// 188 pt cells 4 apart, 18 pt insets, and the shelf bleeds 28 pt past the page on each side.
    static func overflows(_ count: Int, in width: CGFloat) -> Bool {
        36 + CGFloat(count) * 192 - 4 > width + 56
    }
}

struct HomePage: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @State private var width: CGFloat = 0

    var body: some View {
        // the hero already shows what's playing
        let playing = controller.status == .idle ? nil : controller.current?.id
        let recent = controller.recent.filter { $0.id != playing }
        let albums = controller.catalog.albums
        PageScroll {
            Hero()
                .padding(.bottom, 44)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if recent.count >= 3 {
                SectionTitle(title: "Recently Played")
                    .padding(.bottom, 8)
                Shelf(items: recent) { RecentTile(song: $0) }
                    .padding(.bottom, 32)
            }
            if !albums.isEmpty {
                SectionTitle(title: "Albums", action: Shelf<Album, AlbumTile>.overflows(albums.count, in: width) ? ("Show All", { navigate(.albums) }) : nil)
                    .padding(.bottom, 8)
                Shelf(items: Array(albums.prefix(24))) { AlbumTile(album: $0) }
            }
        }
    }
}

/// What's playing, as big as the page allows, with the fade timeline under it.
/// The art follows the audio: its color drains as a track fades out and returns as the next fades in.
private struct Hero: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.windowVisible) private var visible

    var body: some View {
        let idle = controller.status == .idle
        let resting = controller.status == .resting
        HStack(alignment: .bottom, spacing: 30) {
            Group {
                if idle {
                    Mosaic(albums: controller.catalog.albums)
                } else {
                    TimelineView(.periodic(from: .now, by: controller.status == .playing && visible ? 0.1 : 60)) { _ in
                        let gain = level
                        Artwork(key: controller.current?.artwork, size: 232, radius: 10, outlined: true,
                                title: controller.current?.album, subtitle: controller.current?.albumArtist)
                            .saturation(gain)
                            .opacity(0.5 + 0.5 * gain)
                            .animation(.linear(duration: 0.1), value: gain)
                    }
                }
            }
            .frame(width: 232, height: 232)

            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(eyebrow(at: context.date))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                // one size per title, the largest that fits on a line, instead of a scale factor that sizes every track differently
                ViewThatFits(in: .horizontal) {
                    ForEach([56, 44], id: \.self) { size in
                        headingText(size: size).lineLimit(1)
                    }
                    headingText(size: 36).lineLimit(2)
                }
                .foregroundStyle(resting ? Theme.faint : Theme.text)
                .contentTransition(.opacity)
                if let detail = controller.current?.detail, !idle, !resting {
                    Text(detail)
                        .font(.system(size: 20, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                if let song = controller.current, !idle {
                    Group {
                        if resting {
                            Text("after \(song.work)")
                        } else {
                            HStack(spacing: 6) {
                                LinkText(text: song.artist) { navigate(.artist(song.artist)) }
                                Text("·")
                                LinkText(text: song.album) { navigate(.album(song.albumID)) }
                            }
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(resting ? Theme.faint : Theme.muted)
                    .lineLimit(1)
                }
                if !idle {
                    Timeline(controller: controller, bars: 48, visible: visible)
                        .frame(height: 56)
                        .frame(maxWidth: 560)
                        .padding(.top, 8)
                        .transition(.opacity)
                } else if controller.tracks.isEmpty {
                    Button("Add a Music Folder", action: addFolders)
                        .buttonStyle(InvertedButton())
                        .padding(.top, 6)
                } else {
                    HStack(spacing: 14) {
                        PlayCircle(size: 52) { controller.toggle() }
                        Text("shuffle everything")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .animation(Theme.ambient, value: controller.status)
    }

    /// The envelope's gain right now: 0 in a gap, 1 while a track holds.
    private var level: Double {
        guard controller.status != .resting, let track = controller.track else { return 0 }
        return track.gain(at: track.elapsed, controller.settings.curve)
    }

    private var heading: String {
        switch controller.status {
        case .idle: controller.tracks.isEmpty ? "Your music, with room to breathe" : Format.count(controller.tracks.count, "song")
        case .resting: "Resting"
        case .playing, .paused: controller.current?.work ?? controller.title ?? "Starting"
        }
    }

    private func headingText(size: CGFloat) -> some View {
        Text(heading)
            .font(.system(size: size, weight: controller.status == .resting ? .semibold : .bold))
            .tracking(-size * 0.022)
    }

    private func eyebrow(at date: Date) -> String {
        switch controller.status {
        case .idle:
            guard !controller.tracks.isEmpty else { return "sottova plays your library with silence between songs" }
            let total = controller.catalog.songs.reduce(0) { $0 + $1.duration }
            return "\(Format.length(total)) of music, \(Format.gaps(controller.settings)) between"
        case .playing:
            // concert-program order: composer, work, performer
            guard let song = controller.current, song.albumArtist != song.artist else { return "now playing" }
            return song.albumArtist
        case .paused: return "paused"
        case .resting: return controller.subline(at: date)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.addFolders(panel.urls)
    }
}

/// Four covers from across the library, so the idle home shows your music instead of a placeholder.
private struct Mosaic: View {
    let albums: [Album]

    var body: some View {
        let picks = albums.isEmpty ? [] : (0..<4).map { albums[$0 * albums.count / 4] }
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                cover(picks, 0)
                cover(picks, 1)
            }
            GridRow {
                cover(picks, 2)
                cover(picks, 3)
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    private func cover(_ picks: [Album], _ i: Int) -> some View {
        let album = picks.indices.contains(i) ? picks[i] : nil
        return Artwork(key: album?.artwork, size: 115, radius: 0, title: album?.title)
    }
}

private struct RecentTile: View {
    let song: Song
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        Tile(artwork: song.artwork, coverTitle: song.album, coverSubtitle: song.albumArtist, play: { controller.play([song]) }, open: { navigate(.album(song.albumID)) }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.work)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(song.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }
}

struct InvertedButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Theme.text, in: .rect(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct SongsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let songs = controller.catalog.songs
        PageScroll {
            let art = songs.contains { $0.artwork != nil }
            let albums = Set(songs.map(\.albumID)).count > 1
            PageHeader(title: "Songs", detail: "\(Format.count(songs.count, "song")), \(Format.length(songs.reduce(0) { $0 + $1.duration }))", songs: songs)
            SongColumns(showsArt: art, showsAlbum: albums)
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, number: index + 1, showsArt: art, showsAlbum: albums) { controller.play(songs, from: index) }
                }
            }
        }
    }
}

struct AlbumsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let albums = controller.catalog.albums
        PageScroll {
            PageHeader(title: "Albums", detail: Format.count(albums.count, "album"), songs: [])
            LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 18) {
                ForEach(albums) { AlbumTile(album: $0) }
            }
            .padding(.horizontal, -10)
        }
    }
}

struct AlbumPage: View {
    let id: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        if let album = controller.catalog.albumsByID[id] {
            PageScroll {
                HStack(alignment: .bottom, spacing: 30) {
                    Artwork(key: album.artwork, size: 232, radius: 10, outlined: true, title: album.title, subtitle: album.artist)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("album")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(album.title)
                            .font(.system(size: 48, weight: .heavy))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                        HStack(spacing: 6) {
                            LinkText(text: album.artist) { navigate(.artist(album.artist)) }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text([album.year.map(String.init), Format.count(album.songs.count, "song"), Format.length(album.duration)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.bottom, 28)

                PlayRow(songs: album.songs)
                    .padding(.bottom, 24)

                SongColumns(showsArt: false, showsAlbum: false)
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, number: song.trackNumber ?? index + 1, showsArt: false, showsAlbum: false, albumArtist: album.artist) {
                            controller.play(album.songs, from: index)
                        }
                    }
                }
            }
        } else {
            Missing(text: "this album isn't in your library anymore")
        }
    }
}

struct ArtistsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let artists = controller.catalog.artists
        PageScroll {
            PageHeader(title: "Artists", detail: Format.count(artists.count, "artist"), songs: [])
            LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 18) {
                ForEach(artists) { ArtistTile(artist: $0) }
            }
            .padding(.horizontal, -10)
        }
    }
}

struct ArtistPage: View {
    let name: String
    @Environment(Controller.self) private var controller

    var body: some View {
        if let artist = controller.catalog.artistsByName[name] {
            let songs = artist.songs
            let art = songs.contains { $0.artwork != nil }
            PageScroll {
                HStack(alignment: .bottom, spacing: 30) {
                    Artwork(key: artist.artwork, size: 200, circle: true, outlined: true, title: artist.name)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("artist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(artist.name)
                            .font(.system(size: 48, weight: .heavy))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("\(Format.count(artist.albums.count, "album")) · \(Format.count(songs.count, "song"))")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.bottom, 28)

                PlayRow(songs: songs)
                    .padding(.bottom, 32)

                SectionTitle(title: "Albums")
                    .padding(.bottom, 8)
                Shelf(items: artist.albums) { AlbumTile(album: $0) }
                    .padding(.bottom, 32)

                SectionTitle(title: "Songs")
                    .padding(.bottom, 8)
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, number: index + 1, showsArt: art) { controller.play(songs, from: index) }
                    }
                }
            }
        } else {
            Missing(text: "this artist isn't in your library anymore")
        }
    }
}

/// Filters after a short pause in typing, against keys folded once per song.
struct SearchPage: View {
    let query: String
    @Environment(Controller.self) private var controller
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var searched = false

    var body: some View {
        Group {
            if searched, songs.isEmpty, albums.isEmpty, artists.isEmpty {
                Missing(text: "nothing in your library matches “\(query)”")
            } else {
                PageScroll {
                    if !songs.isEmpty {
                        let art = songs.prefix(8).contains { $0.artwork != nil }
                        SectionTitle(title: "Songs")
                            .padding(.bottom, 8)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.prefix(8).enumerated()), id: \.element.id) { index, song in
                                SongRow(song: song, number: index + 1, showsArt: art) { controller.play(songs, from: index) }
                            }
                        }
                        .padding(.bottom, 32)
                    }
                    if !albums.isEmpty {
                        SectionTitle(title: "Albums")
                            .padding(.bottom, 8)
                        Shelf(items: Array(albums.prefix(20))) { AlbumTile(album: $0) }
                            .padding(.bottom, 32)
                    }
                    if !artists.isEmpty {
                        SectionTitle(title: "Artists")
                            .padding(.bottom, 8)
                        Shelf(items: Array(artists.prefix(20))) { ArtistTile(artist: $0) }
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(searched ? 120 : 0))
            guard !Task.isCancelled else { return }
            let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let catalog = controller.catalog
            songs = catalog.songs.filter { $0.searchKey.contains(needle) }
            albums = catalog.albums.filter { $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }
            artists = catalog.artists.filter { $0.name.localizedStandardContains(query) }
            searched = true
        }
    }
}

private struct Missing: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
