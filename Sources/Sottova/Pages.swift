import AppKit
import SwiftUI
import SottovaCore

struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Router.self) private var router
    @State private var position = ScrollPosition(edge: .top)

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
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in router.offset = y }
        .onAppear {
            // Back and Forward land where the page was left; anything else opens at the top. No animation: the page
            // shouldn't be seen scrolling down to it
            guard let y = router.restore else { return }
            router.restore = nil
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { position.scrollTo(y: y) }
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
            if recent.count >= 3 {
                SectionTitle(title: "Recently played")
                    .padding(.bottom, 8)
                // one tile per album: the same cover five times reads as a pattern. With fewer than three albums the
                // titles are what differ, so it's a list
                var seen = Set<String>()
                let covers = recent.filter { seen.insert($0.albumID).inserted }
                Group {
                    if covers.count < 3 {
                        RecentList(songs: Array(recent.prefix(6)))
                    } else {
                        Shelf(items: covers) { RecentTile(song: $0) }
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
        // a seek starts the envelope over somewhere else; reading this rebuilds the schedules below from the new spot
        let _ = controller.seeks
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
                    if let line = eyebrow(at: context.date) {
                        Text(line)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
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
                        // the piece takes the first 70%; the rest is the gap and the next fade-in
                        .seeker(controller, span: 0.7)
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


    /// The line over the title. nil rather than "now playing" or "paused": the art, the title's weight and the player
    /// bar already say that.
    private func eyebrow(at date: Date) -> String? {
        switch controller.status {
        case .idle:
            guard !controller.tracks.isEmpty else { return "sottova plays your library with silence between songs" }
            let songs = controller.catalog.songs
            return "\(Format.count(songs.count, "song")) · \(Format.length(songs.reduce(0) { $0 + $1.duration })) · \(Format.range(controller.settings)) between"
        case .playing, .paused:
            // concert-program order: composer, work, performer. Without a composer tag, classical files carry the
            // composer as album artist
            guard let song = controller.current else { return nil }
            return song.composer ?? (song.albumArtist != song.artist ? song.albumArtist : nil)
        case .resting: return controller.subline(at: date)
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
                    let steady = track.steady(from: track.elapsed + next.timeIntervalSince(taken))
                    next += steady > 0 ? max(0.1, min(1, steady)) : 0.1
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
        // paintings, not type: four title covers in a square read as a placeholder
        let painted = albums.filter { $0.artwork != nil }
        if painted.count < 4 {
            let one = painted.first ?? albums.first
            Artwork(key: one?.artwork, size: side, radius: 12, outlined: true, title: one?.title, subtitle: one?.artist)
        } else {
            grid(painted)
        }
    }

    private func grid(_ albums: [Album]) -> some View {
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
        Tile(artwork: song.artwork, coverTitle: song.album, play: { controller.play([song]) }, open: { navigate(.album(song.albumID)) }) {
            VStack(alignment: .leading, spacing: 2) {
                NowPlayingTitle(text: song.work, playing: controller.sounding?.id == song.id, key: song.album, lines: 2)
                Text(song.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            // a shelf is a lazy row sized from its first tiles; equal heights keep a later cover from being squeezed,
            // and the spare line goes at the bottom instead of between a short title and its performer
            .frame(height: 52, alignment: .topLeading)
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
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 40)
            // disabled, it steps back into the surface instead of staying the heaviest thing on it at low opacity
            .foregroundStyle(enabled ? Theme.background : Theme.faint)
            .background(enabled ? Theme.text : Theme.hover, in: .rect(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// The quiet partner of InvertedButton, for Cancel: the whole 40 pt block is the target, not just the word.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(.rect)
            .hoverable(radius: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct SongsPage: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @AppStorage("songSort") private var sort = SongSort.title
    @State private var filter = ""
    @FocusState private var filtering: Bool

    var body: some View {
        let all = controller.catalog.songs
        if all.isEmpty {
            EmptyLibrary(what: "songs")
        } else {
            let needle = filter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let songs = sort.sorted(needle.isEmpty ? all : all.filter { $0.searchKey.contains(needle) })
            PageScroll {
                let art = songs.contains { $0.artwork != nil }
                let albums = Set(songs.map(\.albumID)).count > 1
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Songs")
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                        HStack(spacing: 8) {
                            Text((needle.isEmpty ? Format.count(all.count, "song") : "\(songs.count) of \(all.count) songs")
                                 + " · \(Format.length(songs.reduce(0) { $0 + $1.duration })) ·")
                                .foregroundStyle(Theme.muted)
                            sortMenu
                        }
                        .font(.system(size: 13))
                    }
                    HStack(spacing: 16) {
                        PlayRow(songs: songs)
                        Spacer(minLength: 0)
                        filterField
                    }
                }
                .padding(.bottom, 24)
                if songs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("no songs match “\(filter)”")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        LinkText(text: "clear filter") { filter = "" }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 24)
                } else {
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

    /// The order, read as part of the sentence above the list: "72 songs, 6 h 2 min · by title ⌄".
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SongSort.allCases, id: \.self) { Text($0.label.prefix(1).uppercased() + $0.label.dropFirst()).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(sort.label)
                Ph.caretDown.icon(.bold, size: 10)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Ph.magnifyingGlass.icon(size: 14)
                .foregroundStyle(Theme.faint)
            TextField("filter songs", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($filtering)
                .onExitCommand { filter = ""; filtering = false }
                .onChange(of: filtering) { _, focused in router.typing = focused }
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 32)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filtering ? Theme.muted : Theme.border))
        .animation(Theme.quick, value: filtering)
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

/// Beside Shuffle: the gaps an album or playlist plays with and how long they make it, opening the choice. Its border
/// darkens when it has gaps of its own, like a filter that's on.
struct GapsButton: View {
    let title: String
    let songs: [Song]
    @Binding var gaps: SottovaCore.Settings?
    @Environment(Controller.self) private var controller
    @State private var open = false

    var body: some View {
        let duration = songs.reduce(0) { $0 + $1.duration }
        let s = gaps?.gaps(over: controller.yourSettings) ?? controller.yourSettings
        let paced = s.lengthWithGaps(count: songs.count, music: duration)
        Button { open = true } label: {
            HStack(spacing: 8) {
                Text(s.crossfade ? "Crossfades" : "\(s.name) gaps")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if paced > duration {
                    Text(Format.length(paced))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Ph.caretDown.icon(.bold, size: 10)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(gaps == nil ? Theme.border : Theme.muted))
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .help(paced > duration ? "about \(Format.length(paced)) with the gaps" : "choose the gaps between these")
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
            Text("only for this one; everything else keeps yours")
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
                    preset(4, own)
                }
                GridRow {
                    card(named("Custom", own ?? yours), active: own?.name == "Custom", accent: 2 + 4 * SottovaCore.Settings.presets.count) {
                        var custom = own ?? yours
                        custom.name = "Custom"
                        custom.crossfade = false
                        gaps = custom
                    }
                    .gridCellColumns(3)
                }
            }

            if own?.name == "Custom" {
                caption("Silence between tracks")
                GapRange(low: field(\.gapMin), high: field(\.gapMax))
                    .padding(.horizontal, 12)
                caption("Fades")
                HStack(spacing: 12) {
                    ValueStepper(label: "In", value: field(\.fadeIn), range: 0...20, unit: "s")
                    ValueStepper(label: "Out", value: field(\.fadeOut), range: 0...20, unit: "s")
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        // its own ground so the edge shows against the page; the cards, score and steppers keep their borders on it
        .presentationBackground(Theme.raised)
        .animation(Theme.quick, value: own?.name)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.top, 16)
            .padding(.bottom, 8)
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
    @Environment(Router.self) private var router
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
                    Artwork(key: controller.playlistCovers[pid] ?? songs.first?.artwork, size: art, radius: 12, outlined: true,
                            title: playlist.name)
                    VStack(alignment: .leading, spacing: 12) {
                        title(playlist)
                        Text([Format.count(playlist.paths.count, "song"), Format.length(duration), missing > 0 ? "\(missing) missing" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                        CoverCredit(url: Controller.coverURL(forPlaylist: pid), key: controller.playlistCovers[pid])
                        AlarmLine(source: pid)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
                .background(alignment: .top) {
                    if let key = controller.playlistCovers[pid] ?? songs.first?.artwork {
                        ArtWash(key: key)
                            .frame(height: art + 200)
                            .padding(.horizontal, -32)
                            .padding(.top, -12)
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: songs, source: pid, more: AnyView(HStack(spacing: 16) {
                    if !songs.isEmpty {
                        GapsButton(title: playlist.name, songs: songs, gaps: Binding(
                            get: { playlist.gaps }, set: { controller.setGaps($0, for: pid) }))
                    }
                    menu(playlist)
                }))
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
                    router.typing = focused
                    if !focused { commitRename() }
                }
        } else {
            Text(playlist.name)
                .font(.system(size: 48, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .onTapGesture(count: 2) { startRename(playlist) }
                .help("double-click to rename")
        }
    }

    private func menu(_ playlist: Playlist) -> some View {
        Menu {
            Button("Rename") { startRename(playlist) }
            Button("Choose cover…") { router.coverFor = .playlist(pid) }
            Button("Start at…") { router.alarm = .new(.playlist(pid)) }
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
            .sottovaMenu {
                [.item("Remove from playlist") { withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: [index]) } }]
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
                        Text(album.title)
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        HStack(spacing: 0) {
                            LinkText(text: album.artist) { navigate(.artist(album.artist)) }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(" · " + [album.year.map(String.init), Format.count(album.songs.count, "song"), Format.length(album.duration)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                        }
                        CoverCredit(url: album.songs.first.map { URL(filePath: $0.id).deletingLastPathComponent().appending(path: "cover.jpg") },
                                    key: album.artwork)
                        AlarmLine(source: album.id)
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

                PlayRow(songs: album.songs, more: AnyView(
                    GapsButton(title: album.title, songs: album.songs, gaps: Binding(
                        get: { controller.albumSettings[album.id] }, set: { controller.albumSettings[album.id] = $0 }))))
                    .padding(.bottom, 24)

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
                // composers known only from tags; one with a page of its own links to its works from there
                let composers = controller.catalog.composers.filter { controller.catalog.artistsByName[$0] == nil }
                if !composers.isEmpty {
                    SectionTitle(title: "Composers")
                        .padding(.bottom, 8)
                    // a grid like the performers below: this is already the show-all page, and its columns line up
                    LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                        ForEach(composers, id: \.self) { ComposerTile(name: $0) }
                    }
                    .padding(.horizontal, -8)
                    .padding(.bottom, 32)
                    SectionTitle(title: "Performers")
                        .padding(.bottom, 8)
                }
                LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                    ForEach(artists) { ArtistTile(artist: $0) }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

private struct ComposerTile: View {
    let name: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        let works = controller.catalog.works(by: name)
        Tile(artwork: nil, circle: true, coverTitle: name, play: { controller.play(works.flatMap(\.recordings).shuffled(), shuffled: true) },
             open: { navigate(.composer(name)) }) {
            VStack(spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Format.count(works.count, "work"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// A composer's works set like a concert program: each work with its catalog number, then every recording of it.
struct ComposerPage: View {
    let name: String
    @Environment(Controller.self) private var controller

    var body: some View {
        let works = controller.catalog.works(by: name)
        if works.isEmpty {
            Missing(text: "nothing by \(name) in your library anymore")
        } else {
            let songs = works.flatMap(\.recordings)
            PageScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text(name)
                        .font(.system(size: 48, weight: .bold))
                        .tracking(-1.2)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text([Format.count(works.count, "work"), Format.count(songs.count, "recording"),
                          Format.length(songs.reduce(0) { $0 + $1.duration })].joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 24)
                .padding(.bottom, 32)

                PlayRow(songs: songs)
                    .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 24) {
                    ForEach(works) { work in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(work.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if let number = work.catalogNumber {
                                    Text(number)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.faint)
                                }
                            }
                            .padding(.horizontal, 12)
                            ForEach(Array(work.recordings.enumerated()), id: \.element.id) { index, song in
                                SongRow(song: song, number: index + 1, performerFirst: true) { controller.play(work.recordings, from: index) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ArtistPage: View {
    let name: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        if let artist = controller.catalog.artistsByName[name] {
            let songs = artist.songs
            let art = songs.contains { $0.artwork != nil }
            PageScroll {
                HStack(alignment: .bottom, spacing: 32) {
                    // initials on a 200 pt disc would be the loudest thing on the page; without a picture the name leads
                    if artist.artwork != nil {
                        Artwork(key: artist.artwork, size: 200, circle: true, outlined: true, title: artist.name)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(artist.name)
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        HStack(spacing: 0) {
                            Text("\(Format.count(artist.albums.count, "album")) · \(Format.count(songs.count, "song"))")
                                .foregroundStyle(Theme.muted)
                            let works = controller.catalog.works(by: name).count
                            if works > 0 {
                                Text(" · ").foregroundStyle(Theme.muted)
                                LinkText(text: "\(Format.count(works, "work")) by work") { navigate(.composer(name)) }
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        .font(.system(size: 13))
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: songs)
                    .padding(.bottom, 32)

                let albums = artist.albums.filter { !controller.albumsInPlaylists.contains($0.id) }
                if !albums.isEmpty {
                    SectionTitle(title: "Albums")
                        .padding(.bottom, 8)
                    Shelf(items: albums) { AlbumTile(album: $0) }
                        .padding(.bottom, 32)
                }

                SectionTitle(title: "Songs")
                    .padding(.bottom, 8)
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        // the artist's own name under every title would only repeat the page's
                        SongRow(song: song, number: index + 1, showsArt: art, albumArtist: name) { controller.play(songs, from: index) }
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
                // the few artists and albums first, then every matching song; eight songs used to push them out of view
                PageScroll {
                    if !artists.isEmpty {
                        SectionTitle(title: "Artists")
                            .padding(.bottom, 8)
                        Shelf(items: Array(artists.prefix(20))) { ArtistTile(artist: $0) }
                            .padding(.bottom, 32)
                    }
                    if !albums.isEmpty {
                        SectionTitle(title: "Albums")
                            .padding(.bottom, 8)
                        Shelf(items: Array(albums.prefix(20))) { AlbumTile(album: $0) }
                            .padding(.bottom, 32)
                    }
                    if !songs.isEmpty {
                        let art = songs.contains { $0.artwork != nil }
                        SectionTitle(title: "Songs")
                            .padding(.bottom, 8)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                SongRow(song: song, number: index + 1, showsArt: art) { controller.play(songs, from: index) }
                            }
                        }
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
    @Environment(Router.self) private var router

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
                HStack(spacing: 12) {
                    Button("Add a music folder", action: controller.chooseFolders)
                        .buttonStyle(InvertedButton())
                    // no music yet: something to hear in a minute or two, legally
                    Button("Get free music") { router.go(to: .shelf) }
                        .buttonStyle(QuietButton())
                }
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

