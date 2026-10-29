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
            // capped so a wide window doesn't spread a song's columns a screen apart
            .frame(maxWidth: 1440, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .overlayScrollers()
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
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -32)
    }

    /// Whether `count` tiles run past a page `width` wide, so "Show all" only appears when some are out of sight.
    /// 188 pt cells 4 apart, 24 pt insets, and the shelf bleeds 32 pt past the page on each side.
    static func overflows(_ count: Int, in width: CGFloat) -> Bool {
        48 + CGFloat(count) * 192 - 4 > width + 64
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
        let albums = controller.shownAlbums
        PageScroll {
            Hero()
                .padding(.bottom, 48)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if !controller.today.isEmpty {
                TodayScore(plays: controller.today)
                    .padding(.bottom, 40)
            }
            if recent.count >= 3 {
                SectionTitle(title: "Recently played")
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
                SectionTitle(title: "Albums", action: Shelf<Album, AlbumTile>.overflows(albums.count, in: width) ? ("Show all", { navigate(.albums) }) : nil)
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
        HStack(alignment: .bottom, spacing: 32) {
            Group {
                if idle {
                    Mosaic(albums: controller.shownAlbums, side: art)
                } else {
                    TimelineView(FadeSchedule(track: controller.track, taken: .now, active: controller.status == .playing && visible)) { _ in
                        let gain = level
                        Artwork(key: controller.current?.artwork, size: art, radius: 12, outlined: true,
                                title: controller.current?.album, subtitle: controller.current?.albumArtist)
                            .saturation(gain)
                            .opacity(0.5 + 0.5 * gain)
                            .animation(.linear(duration: 0.1), value: gain)
                    }
                }
            }
            .frame(width: art, height: art)

            VStack(alignment: .leading, spacing: 12) {
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
                        .font(.system(size: 22, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                if let song = controller.current, !idle {
                    Group {
                        if resting {
                            Text("after \(song.work)")
                        } else {
                            HStack(spacing: 8) {
                                LinkText(text: song.artist) { navigate(.artist(song.artist)) }
                                Text("·")
                                LinkText(text: song.album) { navigate(.album(song.albumID)) }
                            }
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(resting ? Theme.faint : Theme.muted)
                    .lineLimit(1)
                }
                if !idle {
                    Timeline(controller: controller, visible: visible)
                        .frame(height: 44)
                        .padding(.top, 8)
                        .transition(.opacity)
                } else if controller.tracks.isEmpty {
                    Button("Add a music folder", action: controller.chooseFolders)
                        .buttonStyle(InvertedButton())
                        .padding(.top, 8)
                } else {
                    HStack(spacing: 16) {
                        PlayCircle(size: 52) { controller.toggle() }
                        Text("shuffle everything")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 8)
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

    /// The envelope's gain right now: 0 in a gap, 1 while a track holds, lower as the sleep timer eases it down.
    private var level: Double {
        guard controller.status != .resting, let track = controller.track else { return 0 }
        return track.gain(at: track.elapsed, controller.settings.curve) * controller.sleepLevel
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
}

/// The day as a score on a clock: each piece where it started, at its length, with its fades; the quiet Sottova
/// left after it as dots on the line; time it wasn't listening as bare line. Hover names a piece.
private struct TodayScore: View {
    let plays: [Play]
    @Environment(Controller.self) private var controller
    @State private var hovered: Int?
    /// Eight points a minute: an hour is 480 pt, so the latest hours sit at the right and earlier ones scroll.
    private let perMinute: CGFloat = 8
    private let band: CGFloat = 28

    var body: some View {
        let music = plays.reduce(0) { $0 + $1.played }
        let quiet = plays.reduce(0) { $0 + $1.gapAfter }
        // the clock moves even when nothing ends, so the right edge stays now
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let start = Calendar.current.dateInterval(of: .hour, for: plays.first?.startedAt ?? context.date)?.start ?? context.date
            let width = x(context.date, from: start) + 1
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: "Today")
                    Spacer()
                    Group {
                        if let hovered, plays.indices.contains(hovered), let song = controller.catalog.songsByID[plays[hovered].file] {
                            Text("\(song.work) · \(song.artist) · \(plays[hovered].startedAt.formatted(date: .omitted, time: .shortened))")
                        } else {
                            Text("\(Format.count(plays.count, "piece")) · \(Format.length(music)) of music · \(Format.length(quiet)) of quiet")
                        }
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                }
                ScrollView(.horizontal) {
                    Canvas { gc, size in draw(in: gc, size: size, start: start, now: context.date) }
                        .frame(width: width, height: band + 18)
                        .overlayScrollers()
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase else { hovered = nil; return }
                            hovered = plays.firstIndex {
                                let x0 = x($0.startedAt, from: start)
                                return (x0...x0 + max(CGFloat($0.played) / 60 * perMinute, 2)).contains(point.x)
                            }
                        }
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.trailing)
                .frame(maxWidth: width, alignment: .leading)
            }
        }
    }

    private func x(_ date: Date, from start: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start)) / 60 * perMinute
    }

    private func draw(in gc: GraphicsContext, size: CGSize, start: Date, now: Date) {
        let base = band
        gc.fill(Path(CGRect(x: 0, y: base, width: size.width, height: 1)), with: .color(Theme.border))

        // hours: a tick and a label under the line
        var hour = start
        while hour <= now {
            let hx = x(hour, from: start)
            gc.fill(Path(CGRect(x: hx, y: base + 1, width: 1, height: 4)), with: .color(Theme.border))
            gc.draw(Text(hour.formatted(.dateTime.hour()).lowercased()).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint),
                    at: CGPoint(x: hx + 3, y: base + 4), anchor: .topLeading)
            hour += 3600
        }

        for (i, play) in plays.enumerated() {
            let x0 = x(play.startedAt, from: start)
            let x1 = x0 + CGFloat(play.played) / 60 * perMinute
            piece(in: gc, from: x0, to: x1, base: base, emphasis: hovered == i, album: controller.catalog.songsByID[play.file]?.album)
            quiet(in: gc, from: x1, to: x1 + CGFloat(play.gapAfter) / 60 * perMinute, base: base)
        }

        // what's happening right now: the piece still playing, or the quiet after the last one
        guard let last = plays.last else { return }
        let lastEnd = x(last.startedAt, from: start) + CGFloat(last.played) / 60 * perMinute
        let nowX = x(now, from: start)
        switch controller.status {
        case .playing, .paused:
            if let track = controller.track {
                piece(in: gc, from: max(nowX - CGFloat(track.elapsed) / 60 * perMinute, lastEnd), to: nowX, base: base, emphasis: true,
                      album: controller.current?.album, open: true)
            }
        case .resting:
            quiet(in: gc, from: lastEnd, to: nowX, base: base)
        case .idle:
            break
        }
    }

    /// The fades at their true length, but at least 2 pt so a piece never reads as a slab. `open` leaves the end
    /// unfaded: a piece still playing hasn't faded out yet.
    private func piece(in gc: GraphicsContext, from x0: CGFloat, to x1: CGFloat, base: CGFloat, emphasis: Bool, album: String?, open: Bool = false) {
        guard x1 > x0 else { return }
        let rampIn = min(max(CGFloat(controller.settings.fadeIn) / 60 * perMinute, 2), (x1 - x0) / 2)
        let rampOut = open ? 0 : min(max(CGFloat(controller.settings.fadeOut) / 60 * perMinute, 2), (x1 - x0) / 2)
        let top = base - band + 4
        var outline = Path()
        outline.addLines([CGPoint(x: x0, y: base), CGPoint(x: x0 + rampIn, y: top), CGPoint(x: x1 - rampOut, y: top), CGPoint(x: x1, y: open ? top : base)])
        var shape = outline
        shape.addLine(to: CGPoint(x: x1, y: base))
        shape.closeSubpath()
        // each piece in its album's accent; monochrome keeps the gray outline
        let ink = Theme.accent(for: album, or: emphasis ? \.text : \.muted)
        gc.fill(shape, with: .color(Theme.accent(for: album).opacity(emphasis ? 0.22 : 0.08)))
        gc.stroke(outline, with: .color(ink), lineWidth: 1)
    }

    /// Sottova's silence, drawn the way the gaps are everywhere else: dots on the line.
    private func quiet(in gc: GraphicsContext, from x0: CGFloat, to x1: CGFloat, base: CGFloat) {
        var x = x0 + 4
        while x < x1 - 2 {
            gc.fill(Path(ellipseIn: CGRect(x: x - 1, y: base - 1.5, width: 2, height: 2)), with: .color(Theme.faint))
            x += 6
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
            .lineLimit(size < 36 ? 2 : 1)
            .foregroundStyle(Theme.text)
    }

    /// The largest of 48 and 36 pt whose bold cut fits `width` on one line, else 28 on two. Measured here rather than
    /// with ViewThatFits, which answered the stacks' 0 and ∞ width probes with different heights and kept the window
    /// re-laying out about 1,700 times a second. Bold is the widest the title gets, so the size holds while the weight moves.
    static func size(for text: String, in width: CGFloat) -> CGFloat {
        for size: CGFloat in [48, 36] {
            let bold = NSFont.systemFont(ofSize: size, weight: .bold)
            if (text as NSString).size(withAttributes: [.font: bold, .kern: -size * 0.022]).width <= width { return size }
        }
        return 28
    }
}

/// Four covers from across the library, so the idle home shows your music instead of a placeholder.
private struct Mosaic: View {
    let albums: [Album]
    let side: CGFloat

    var body: some View {
        if albums.count < 4 {
            // four of the same cover would read as a pattern, not a library
            Artwork(key: albums.first?.artwork, size: side, radius: 12, outlined: true, title: albums.first?.title, subtitle: albums.first?.artist)
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
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
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
            VStack(alignment: .leading, spacing: 2) {
                // a shelf is a lazy row sized from its first tiles; equal heights keep a later cover from being squeezed
                NowPlayingTitle(text: song.work, playing: controller.sounding?.id == song.id, key: song.album, lines: 2)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverable()
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
        }
        .padding(.horizontal, -12)
        .frame(maxWidth: 900, alignment: .leading)
    }
}

struct InvertedButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Theme.text, in: .rect(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct SongsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let songs = controller.catalog.songs
        if songs.isEmpty {
            EmptyLibrary(what: "songs")
        } else {
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
}

struct AlbumsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let albums = controller.shownAlbums
        if albums.isEmpty, !controller.catalog.albums.isEmpty {
            Missing(text: "no albums. your folders are playlists now")
        } else if albums.isEmpty {
            EmptyLibrary(what: "albums")
        } else {
            PageScroll {
                PageHeader(title: "Albums", detail: Format.count(albums.count, "album"), songs: [])
                LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                    ForEach(albums) { AlbumTile(album: $0) }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

/// "about 9 h with Minecraft gaps", which opens the choice of gaps this album plays with.
struct GapsButton: View {
    let title: String
    let songs: [Song]
    @Binding var gaps: SottovaCore.Settings?
    @Environment(Controller.self) private var controller
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let duration = songs.reduce(0) { $0 + $1.duration }
        let s = gaps?.gaps(over: controller.yourSettings) ?? controller.yourSettings
        let paced = s.lengthWithGaps(count: songs.count, music: duration)
        Button { open = true } label: {
            HStack(spacing: 4) {
                Text(s.crossfade ? "crossfades, no gaps" : paced > duration ? "about \(Format.length(paced)) with \(s.name) gaps" : "\(s.name) gaps")
                    .underline(hovering)
                Ph.caretDown.icon(.bold, size: 10)
            }
            .font(.system(size: 13, weight: gaps == nil ? .regular : .medium))
            .foregroundStyle(gaps == nil ? Theme.muted : Theme.text)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // pinned to the label's start, which stays put while the label's length changes with each choice
        .popover(isPresented: $open, attachmentAnchor: .point(.bottomLeading), arrowEdge: .bottom) {
            AlbumGaps(title: title, gaps: $gaps)
        }
    }
}

/// Which gaps an album plays with, laid out like Settings > Playback: the score of what it'll sound like, then the
/// choices as cards, then the range and fades when it has its own.
private struct AlbumGaps: View {
    let title: String
    @Binding var gaps: SottovaCore.Settings?
    @Environment(Controller.self) private var controller

    var body: some View {
        let own = gaps
        let yours = controller.yourSettings
        VStack(alignment: .leading, spacing: 0) {
            Text("Gaps for \(title)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("it plays with these, then goes back to yours")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)
                .padding(.bottom, 16)

            ScoreDiagram(settings: own?.gaps(over: yours) ?? yours, height: 112)
                .padding(.bottom, 12)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    card(named("Yours", yours), active: own == nil, accent: nil) { gaps = nil }
                    preset(0, own)
                    preset(1, own)
                }
                GridRow {
                    preset(2, own)
                    preset(3, own)
                    card(named("Custom", own ?? yours), active: own?.name == "Custom", accent: 2 + 4 * 4) {
                        var custom = own ?? yours
                        custom.name = "Custom"
                        custom.crossfade = false
                        gaps = custom
                    }
                }
            }

            if own?.name == "Custom" {
                GapRange(low: field(\.gapMin), high: field(\.gapMax))
                    .padding(.horizontal, 12)
                    .padding(.top, 20)
                HStack(spacing: 12) {
                    ValueStepper(label: "In", value: field(\.fadeIn), range: 0...20, unit: "s")
                    ValueStepper(label: "Out", value: field(\.fadeOut), range: 0...20, unit: "s")
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(width: 380)
        // its own ground so the edge shows against the page; the cards, score and steppers keep their borders on it
        .presentationBackground(Theme.raised)
        .animation(Theme.quick, value: own?.name)
    }

    private func preset(_ index: Int, _ own: SottovaCore.Settings?) -> some View {
        let preset = SottovaCore.Settings.presets[index]
        return card(preset, active: own?.name == preset.name, accent: 2 + 4 * index) { gaps = preset }
    }

    private func named(_ name: String, _ settings: SottovaCore.Settings) -> SottovaCore.Settings {
        var s = settings
        s.name = name
        return s
    }

    private func card(_ settings: SottovaCore.Settings, active: Bool, accent: Int?, action: @escaping () -> Void) -> some View {
        PresetCard(preset: settings, active: active, accent: accent, action: action)
    }

    private func field(_ path: WritableKeyPath<SottovaCore.Settings, Double>) -> Binding<Double> {
        Binding(get: { gaps?[keyPath: path] ?? 0 },
                set: { gaps?[keyPath: path] = $0 })
    }
}

/// A playlist laid out like an album: its cover, name and gaps, then its songs. Drop songs on a row to put them
/// there; drag a row onto another to move it.
struct PlaylistPage: View {
    let id: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    @State private var art: CGFloat = 232
    /// Renaming moves the file, so the id changes under the page.
    @State private var renamedTo: String?
    @State private var editing = false
    @State private var name = ""
    @State private var target: Int?
    @FocusState private var typing: Bool

    private var pid: String { renamedTo ?? id }

    var body: some View {
        if let playlist = controller.playlists.first(where: { $0.id == pid }) {
            let songs = controller.songs(of: playlist)
            let duration = songs.reduce(0) { $0 + $1.duration }
            let missing = playlist.paths.count - songs.count
            PageScroll {
                HStack(alignment: .bottom, spacing: 32) {
                    Artwork(key: songs.first?.artwork, size: art, radius: 12, outlined: true, title: playlist.name, subtitle: "playlist")
                    VStack(alignment: .leading, spacing: 12) {
                        Text("playlist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        title(playlist)
                        HStack(spacing: 8) {
                            Text([Format.count(playlist.paths.count, "song"), Format.length(duration), missing > 0 ? "\(missing) missing" : nil]
                                .compactMap { $0 }.joined(separator: " · ") + " ·")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                            GapsButton(title: playlist.name, songs: songs, gaps: Binding(
                                get: { playlist.gaps }, set: { controller.setGaps($0, for: pid) }))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
                .background(alignment: .top) {
                    if let key = songs.first?.artwork {
                        ArtWash(key: key)
                            .frame(height: art + 200)
                            .padding(.horizontal, -32)
                            .padding(.top, -12)
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: songs, source: pid, more: AnyView(menu(playlist)))
                    .padding(.bottom, 24)

                if playlist.paths.isEmpty {
                    Text("drag songs here from any page")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Theme.accent(for: playlist.name).opacity(target == 0 ? 0.14 : 0), in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(target == 0 ? Theme.accent(for: playlist.name) : Theme.border,
                                                                                 style: StrokeStyle(lineWidth: target == 0 ? 1.5 : 1, dash: [4, 4])))
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, at: 0, in: playlist) } isTargeted: { target = $0 ? 0 : nil }
                } else {
                    SongColumns()
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playlist.paths.enumerated()), id: \.offset) { index, path in
                            row(path, at: index, in: playlist, songs: songs)
                                .overlay(alignment: .top) { insertionLine(playlist, at: index) }
                                .dropDestination(for: URL.self) { urls, _ in drop(urls, at: index, in: playlist) } isTargeted: { on in
                                    if on { target = index } else if target == index { target = nil }
                                }
                        }
                        // below the last row: drop to add at the end
                        Color.clear
                            .frame(height: 48)
                            .overlay(alignment: .top) { insertionLine(playlist, at: playlist.paths.count) }
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, at: playlist.paths.count, in: playlist) } isTargeted: { on in
                                if on { target = playlist.paths.count } else if target == playlist.paths.count { target = nil }
                            }
                    }
                }
            }
            .onAppear {
                if renaming.wrappedValue == pid { startRename(playlist) }
            }
            .onChange(of: renaming.wrappedValue) { _, new in
                if new == pid { startRename(playlist) }
            }
        } else {
            Missing(text: "this playlist isn't in your library anymore")
        }
    }

    @ViewBuilder
    private func title(_ playlist: Playlist) -> some View {
        if editing {
            // the same type as the title, so nothing moves when it turns into a field
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 48, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.text)
                .focused($typing)
                .onSubmit { commitRename() }
                .onExitCommand { endRename() }
                .onChange(of: typing) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            Text(playlist.name)
                .font(.system(size: 48, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .onTapGesture(count: 2) { startRename(playlist) }
                .help("double-click to rename")
        }
    }

    private func menu(_ playlist: Playlist) -> some View {
        Menu {
            Button("Rename") { startRename(playlist) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: pid)]) }
            Divider()
            Button("Move to Trash") {
                navigate(.home)
                controller.trashPlaylist(pid)
            }
        } label: {
            Ph.dotsThree.icon(.bold, size: 16)
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .hoverable(radius: 8)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("more")
    }

    @ViewBuilder
    private func row(_ path: String, at index: Int, in playlist: Playlist, songs: [Song]) -> some View {
        if let song = controller.catalog.songsByID[path] {
            // where this row sits among the songs that can play
            let playable = playlist.paths[..<index].count { controller.catalog.songsByID[$0] != nil }
            SongRow(song: song, number: index + 1, remove: {
                withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: [index]) }
            }) {
                controller.play(songs, from: playable, source: pid)
            }
            .draggable(URL(filePath: path))
        } else {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .frame(width: 28)
                Color.clear.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(filePath: path).deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                    Text("file not found")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                Spacer()
                Text("–")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 60)
            .help(path)
            .contextMenu {
                Button("Remove from Playlist") { withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: [index]) } }
            }
        }
    }

    /// Where a drop will land: a 2 pt line in the playlist's color at the title's left edge.
    private func insertionLine(_ playlist: Playlist, at index: Int) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent(for: playlist.name))
            .frame(height: 2)
            .padding(.leading, 52)
            .offset(y: -1)
            .opacity(target == index ? 1 : 0)
    }

    /// A song already in the playlist moves to `index`; anything else is added there.
    private func drop(_ urls: [URL], at index: Int, in playlist: Playlist) -> Bool {
        target = nil
        let paths = urls.map { $0.standardizedFileURL.path }
        withAnimation(Theme.quick) {
            // ponytail: a song already here moves rather than being added twice; add a copy from the context menu
            if paths.count == 1, let from = playlist.paths.firstIndex(of: paths[0]) {
                controller.movePlaylistSongs(pid, fromOffsets: [from], toOffset: index)
            } else {
                let songs = paths.compactMap { controller.catalog.songsByID[$0] }
                controller.add(songs, to: pid, at: index)
            }
        }
        return true
    }

    private func startRename(_ playlist: Playlist) {
        name = playlist.name
        editing = true
        renaming.wrappedValue = nil
        DispatchQueue.main.async {
            typing = true
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commitRename() {
        guard editing else { return }
        if let renamed = controller.rename(pid, to: name), renamed != pid {
            renamedTo = renamed
        }
        endRename()
    }

    private func endRename() {
        editing = false
        typing = false
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
                HStack(alignment: .bottom, spacing: 32) {
                    Artwork(key: album.artwork, size: art, radius: 12, outlined: true, title: album.title, subtitle: album.artist)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("album")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(album.title)
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                        HStack(spacing: 8) {
                            LinkText(text: album.artist) { navigate(.artist(album.artist)) }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text([album.year.map(String.init), Format.count(album.songs.count, "song"), Format.length(album.duration)]
                                .compactMap { $0 }.joined(separator: " · ") + " ·")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                            GapsButton(title: album.title, songs: album.songs, gaps: Binding(
                                get: { controller.albumSettings[album.id] }, set: { controller.albumSettings[album.id] = $0 }))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
                .background(alignment: .top) {
                    if let key = album.artwork {
                        ArtWash(key: key)
                            .frame(height: art + 200)
                            .padding(.horizontal, -32)
                            .padding(.top, -12)
                    }
                }
                .padding(.bottom, 32)

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
        if artists.isEmpty {
            EmptyLibrary(what: "artists")
        } else {
            PageScroll {
                PageHeader(title: "Artists", detail: Format.count(artists.count, "artist"), songs: [])
                LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                    ForEach(artists) { ArtistTile(artist: $0) }
                }
                .padding(.horizontal, -8)
            }
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
                HStack(alignment: .bottom, spacing: 32) {
                    Artwork(key: artist.artwork, size: 200, circle: true, outlined: true, title: artist.name)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("artist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(artist.name)
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("\(Format.count(artist.albums.count, "album")) · \(Format.count(songs.count, "song"))")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: songs)
                    .padding(.bottom, 32)

                SectionTitle(title: "Albums")
                    .padding(.bottom, 8)
                Shelf(items: artist.albums.filter { !controller.albumsInPlaylists.contains($0.id) }) { AlbumTile(album: $0) }
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
            albums = controller.shownAlbums.filter { $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }
            artists = catalog.artists.filter { $0.name.localizedStandardContains(query) }
            searched = true
        }
    }
}

/// A list page with nothing in it yet: what will appear, and the one way to get it there.
private struct EmptyLibrary: View {
    let what: String
    @Environment(Controller.self) private var controller

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if controller.folders.isEmpty {
                    Text("your \(what) show up here once you add a folder of music")
                } else if controller.pendingAnalysis > 0 {
                    Text("reading your folders; \(what) appear as each file is read")
                } else {
                    Text("nothing in your folders plays yet")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            if controller.pendingAnalysis == 0 {
                Button("Add a music folder", action: controller.chooseFolders)
                    .buttonStyle(InvertedButton())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Missing: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

