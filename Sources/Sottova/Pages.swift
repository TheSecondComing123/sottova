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
        // rows fade out under the floating player bar instead of showing through the strip beneath it
        .scrollEdgeEffectStyle(.soft, for: .bottom)
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
            if !controller.today.isEmpty {
                SectionTitle(title: "Today")
                    .padding(.bottom, 10)
                TodayScore(plays: controller.today)
                    .padding(.bottom, 36)
            }
            if recent.count >= 3 {
                SectionTitle(title: "Recently Played")
                    .padding(.bottom, 8)
                Group {
                    // one album's cover five times reads as a pattern; the titles are what differ
                    if Set(recent.map(\.albumID)).count == 1 {
                        RecentList(songs: Array(recent.prefix(6)))
                    } else {
                        Shelf(items: recent) { RecentTile(song: $0) }
                    }
                }
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
    @State private var art: CGFloat = 232
    @State private var column: CGFloat = 0

    var body: some View {
        let idle = controller.status == .idle
        let resting = controller.status == .resting
        HStack(alignment: .bottom, spacing: 30) {
            Group {
                if idle {
                    Mosaic(albums: controller.catalog.albums, side: art)
                } else {
                    TimelineView(FadeSchedule(track: controller.track, taken: .now, active: controller.status == .playing && visible)) { _ in
                        let gain = level
                        Artwork(key: controller.current?.artwork, size: art, radius: 10, outlined: true,
                                title: controller.current?.album, subtitle: controller.current?.albumArtist)
                            .saturation(gain)
                            .opacity(0.5 + 0.5 * gain)
                            .animation(.linear(duration: 0.1), value: gain)
                    }
                }
            }
            .frame(width: art, height: art)

            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(eyebrow(at: context.date))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                // the title thins with the sound: it fades out to a light weight, rests there, and fills in with the next track
                TimelineView(FadeSchedule(track: controller.track, taken: .now, active: controller.status == .playing && visible)) { _ in
                    let gain = idle ? 1 : level
                    // rounded to steps of 10 so a held track, at gain 1, skips the title's body on every tick
                    HeroTitle(text: heading, weight: (20 + 50 * gain).rounded() * 10, size: HeroTitle.size(for: heading, in: column))
                        .equatable()
                        .opacity(resting ? 0.5 : 1)
                }
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
                    Timeline(controller: controller, visible: visible)
                        .frame(height: 44)
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
            // the column takes all the width beside the art, so its width never depends on the title it sizes
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
        }
        .animation(Theme.ambient, value: controller.status)
        // measured at the page's width, not the header's, which would depend on the art it sizes
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
    }

    /// The envelope's gain right now: 0 in a gap, 1 while a track holds.
    private var level: Double {
        guard controller.status != .resting, let track = controller.track else { return 0 }
        return track.gain(at: track.elapsed, controller.settings.curve)
    }

    private var heading: String {
        switch controller.status {
        // idle, the headline is how you'll listen; the library's size is a detail
        case .idle: controller.tracks.isEmpty ? "Your music, with room to breathe" : controller.settings.name
        case .resting: "Resting"
        case .playing, .paused: controller.current?.work ?? controller.title ?? "Starting"
        }
    }


    private func eyebrow(at date: Date) -> String {
        switch controller.status {
        case .idle:
            guard !controller.tracks.isEmpty else { return "sottova plays your library with silence between songs" }
            let songs = controller.catalog.songs
            return "\(Format.count(songs.count, "song")) · \(Format.length(songs.reduce(0) { $0 + $1.duration })) · \(Format.range(controller.settings)) between"
        case .playing:
            // concert-program order: composer, work, performer. Without a composer tag, classical files carry the
            // composer as album artist
            guard let song = controller.current else { return "now playing" }
            return song.composer ?? (song.albumArtist != song.artist ? song.albumArtist : "now playing")
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

/// The day as a score: each piece at its true length with its fades, and the quiet after it as bare line.
/// Only finished plays are drawn, so a gap still running is never measured out.
private struct TodayScore: View {
    let plays: [Play]
    @Environment(Controller.self) private var controller
    /// Ten points a minute: an hour of listening is 600 pt, so the latest pieces sit at the right and older ones scroll.
    private let scale: CGFloat = 1 / 6

    var body: some View {
        let music = plays.reduce(0) { $0 + $1.played }
        let quiet = plays.reduce(0) { $0 + $1.gapAfter }
        let width = CGFloat(music + quiet) * scale + 1
        HStack(alignment: .bottom, spacing: 20) {
            // as wide as the day so far, and scrolling, latest at the right, once the day outgrows the page
            ScrollView(.horizontal) {
                Canvas { gc, size in draw(in: gc, size: size) }
                    .frame(width: width, height: 32)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: width)
            Text("\(Format.count(plays.count, "piece")), \(Format.length(music)) of music, \(Format.length(quiet)) of quiet")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize()
        }
    }

    private func draw(in gc: GraphicsContext, size: CGSize) {
        let height = size.height - 1
        let curve = controller.settings.curve
        let fadeIn = max(controller.settings.fadeIn, 0.1), fadeOut = max(controller.settings.fadeOut, 0.1)
        gc.fill(Path(CGRect(x: 0, y: height, width: size.width, height: 1)), with: .color(Theme.border))
        var x: CGFloat = 0
        for play in plays {
            let width = CGFloat(play.played) * scale
            var shape = Path()
            shape.move(to: CGPoint(x: x, y: height))
            for dx in stride(from: 0, through: width, by: 1) {
                let t = Double(dx / scale)
                let gain = min(curve.fadeIn(t / fadeIn), curve.fadeIn((play.played - t) / fadeOut))
                shape.addLine(to: CGPoint(x: x + dx, y: height - CGFloat(gain) * height))
            }
            shape.addLine(to: CGPoint(x: x + width, y: height))
            shape.closeSubpath()
            gc.fill(shape, with: .color(Theme.text.opacity(0.25)))
            x += width + CGFloat(play.gapAfter) * scale
        }
    }
}

/// Every 0.1 s while a fade moves the gain, at most once a second through the hold: at 10 Hz a held track re-laid
/// out the hero for nothing, about 8% CPU. The second-long steps still catch a skip's early fade-out.
private struct FadeSchedule: TimelineSchedule {
    let track: Track?
    /// When `track` was read; its elapsed time runs on from there while playing.
    let taken: Date
    let active: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        return AnyIterator {
            defer {
                if active, let track {
                    let t = track.elapsed + next.timeIntervalSince(taken)
                    let holding = t >= track.fadeIn && t < track.outStart
                    next += holding ? max(0.1, min(1, track.outStart - t)) : 0.1
                } else {
                    next += 60
                }
            }
            return next
        }
    }
}

/// The title thins with the sound: it fades out to a light weight, rests there, and fills in with the next track.
/// One size per title, the largest that fits on a line, instead of a scale factor that sizes every track differently.
private struct HeroTitle: View, Equatable {
    let text: String
    let weight: Double
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, axisWeight: weight))
            .tracking(-size * 0.022)
            .lineLimit(size < 44 ? 2 : 1)
            .foregroundStyle(Theme.text)
    }

    /// The largest of 56 and 44 pt whose bold cut fits `width` on one line, else 36 on two. Measured here rather than
    /// with ViewThatFits, which answered the stacks' 0 and ∞ width probes with different heights and kept the window
    /// re-laying out about 1,700 times a second. Bold is the widest the title gets, so the size holds while the weight moves.
    static func size(for text: String, in width: CGFloat) -> CGFloat {
        for size: CGFloat in [56, 44] {
            let bold = NSFont.systemFont(ofSize: size, weight: .bold)
            if (text as NSString).size(withAttributes: [.font: bold, .kern: -size * 0.022]).width <= width { return size }
        }
        return 36
    }
}

/// Four covers from across the library, so the idle home shows your music instead of a placeholder.
private struct Mosaic: View {
    let albums: [Album]
    let side: CGFloat

    var body: some View {
        if albums.count < 4 {
            // four of the same cover would read as a pattern, not a library
            Artwork(key: albums.first?.artwork, size: side, radius: 10, outlined: true, title: albums.first?.title, subtitle: albums.first?.artist)
        } else {
            grid
        }
    }

    private var grid: some View {
        let picks = (0..<4).map { albums[$0 * albums.count / 4] }
        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
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
        Artwork(key: picks[i].artwork, size: (side - 2) / 2, radius: 0, title: picks[i].title)
    }
}

private struct RecentTile: View {
    let song: Song
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        Tile(artwork: song.artwork, coverTitle: song.album, coverSubtitle: song.albumArtist, play: { controller.play([song]) }, open: { navigate(.album(song.albumID)) }) {
            VStack(alignment: .leading, spacing: 3) {
                // a shelf is a lazy row sized from its first tiles; equal heights keep a later cover from being squeezed
                Text(song.work)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2, reservesSpace: true)
                Text(song.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }
}

private struct RecentList: View {
    let songs: [Song]
    @Environment(Controller.self) private var controller

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 2) {
            ForEach(songs) { song in
                Button { controller.play([song]) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.work)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text([song.detail, song.artist].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverable()
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
        }
        .padding(.horizontal, -10)
        .frame(maxWidth: 900, alignment: .leading)
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
    @State private var art: CGFloat = 232

    var body: some View {
        if let album = controller.catalog.albumsByID[id] {
            PageScroll {
                HStack(alignment: .bottom, spacing: 30) {
                    Artwork(key: album.artwork, size: art, radius: 10, outlined: true, title: album.title, subtitle: album.artist)
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
                            let paced = controller.settings.lengthWithGaps(count: album.songs.count, music: album.duration)
                            Text([album.year.map(String.init), Format.count(album.songs.count, "song"), Format.length(album.duration),
                                  paced > album.duration ? "about \(Format.length(paced)) with \(controller.settings.name) gaps" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
                .background(alignment: .top) {
                    if let key = album.artwork {
                        ArtWash(key: key)
                            .frame(height: art + 200)
                            .padding(.horizontal, -28)
                            .padding(.top, -12)
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

