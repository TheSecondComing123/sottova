import AppKit
import SwiftUI
import SottovaCore

/// What Now draws from moment to moment, as separate properties so each small view redraws only for its own.
@MainActor @Observable
private final class NowMotion {
    var over: CGImage?
    var under: CGImage?
    var cover = Track.afterimage
    var underLevel = 0.0
    var scale = 1.0
    var text = 1.0
    var silent = false
    var screen = NowScreen(kind: .quiet, title: "")
    var foot: NowFoot?

    /// Nothing in the cover's place, so the words have the page.
    var bare: Bool { over == nil && (screen.kind == .quiet || screen.kind == .silence) }
}

struct NowPage: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.windowVisible) private var visible
    @Environment(\.pageLayout) private var page
    @State private var motion = NowMotion()

    private struct Key: Equatable {
        let status: PlaybackStatus, song, art: String?, seeks, skips: Int, visible: Bool, pending: Int, albums: Int, hold: Hold?, alarms: [Alarm]
    }

    private var key: Key {
        Key(status: controller.status, song: controller.current?.id, art: controller.current?.artwork, seeks: controller.seeks, skips: controller.skips, visible: visible,
            pending: controller.pendingAnalysis, albums: controller.catalog.albums.count, hold: controller.hold, alarms: controller.alarms)
    }

    private var clock: Date {
        #if SHOT
        controller.shotNow ?? .now
        #else
        .now
        #endif
    }

    var body: some View {
        Group {
            if controller.catalog.albums.isEmpty, controller.status == .idle {
                MusicWelcome(reading: controller.pendingAnalysis > 0)
            } else if controller.status == .idle, controller.dayPlan(now: clock).quietSource == nil {
                PageScroll(insets: EdgeInsets(top: 32, leading: 40, bottom: 24, trailing: 40), maxWidth: 1100) {
                    MusicChoices(title: "Choose a collection", showPlay: true)
                }
            } else {
                stage
            }
        }
        .task(id: key) { await follow() }
    }

    private var stage: some View {
        // for its proposal only: the cover and words run past a short page, and mustn't push the window's content
        GeometryReader { _ in
            let layout = page.now
            let shown = motion.over.map { min(layout.side, CGFloat($0.width)) } ?? layout.side
            let bare = motion.bare
            let width = bare ? layout.bareTextWidth : layout.textWidth(shown)
            let under = layout.stacked && !bare
            let titleSize = motion.screen.kind == .piece ? layout.titleSize(motion.screen.title, shown: shown) : 28
            let detail = bare ? Role.body.size : layout.detailSize(title: titleSize)
            let bottom = layout.coverBottom(shown)
            ZStack(alignment: .topLeading) {
                NowCover(motion: motion, layout: layout, shown: shown, album: controller.current?.album, dragging: router.droppingMusic)
                    .onTapGesture { if let route = shownRoute { navigate(route) } }
                    .pointerStyle(shownRoute == nil ? nil : .link)
                    .help(shownRoute == nil ? "" : "open the collection")
                VStack(alignment: bare ? .center : .leading, spacing: 12) {
                    NowText(motion: motion, width: width, size: titleSize, detail: detail, lines: under ? 4 : 6, centered: bare, dragging: router.droppingMusic, act: act,
                            choose: controller.chooseFolders, freeMusic: { navigate(.shelf) })
                    foot(detail)
                }
                .multilineTextAlignment(bare ? .center : .leading)
                .frame(width: width, height: bare ? layout.height : under ? layout.height - bottom - 16 : shown,
                       alignment: bare ? .center : under ? .topLeading : .leading)
                .offset(x: bare ? (layout.width - width) / 2 : layout.textLeft(shown), y: under ? bottom + 16 : bare ? 0 : bottom - shown)
            }
        }
    }

    @ViewBuilder
    private func foot(_ size: CGFloat) -> some View {
        if let next = motion.foot?.next {
            ThemeLink(text: next, style: .inline, color: Theme.muted) { navigate(.alarms) }.detail(size)
        }
        if let line = motion.foot?.note, line != router.dismissedFoot {
            HStack(spacing: 8) {
                let missed = line.hasPrefix("Missed")
                Text(line).detail(size).foregroundStyle(missed ? Theme.text : Theme.muted)
                if missed {
                    IconButton(icon: .x, weight: .bold, help: "dismiss", size: 24) { router.dismissedFoot = line }
                }
            }
        }
        // nothing sounding: what the words name, a click from playing; while it plays, the title bar has the controls
        if controller.status == .idle, let source = controller.dayPlan(now: clock).quietSource, let route = route(of: source) {
            HStack(spacing: 6) {
                if case .playlist(let id) = route {
                    PlayButton(songs: songs(of: route), source: id)
                } else {
                    PlayButton(songs: songs(of: route))
                }
                ThemeButton(title: "Open collection") { navigate(route) }
            }
            .controlSize(.large)
            .padding(.top, 4)
        } else if let route = shownRoute {
            ThemeLink(text: "Open collection") { navigate(route) }
                .role(.body)
                .padding(.top, 4)
        }
    }

    /// The collection whose painting is up: the playing piece's, or the one the words name.
    private var shownRoute: Route? {
        if controller.status == .idle { return controller.dayPlan(now: clock).quietSource.flatMap(route) }
        guard let song = controller.current else { return nil }
        return controller.copy(ofAlbum: song.albumID).map { .playlist($0.id) } ?? .album(song.albumID)
    }

    /// A made-yours folder opens as yours.
    private func route(of source: String) -> Route? {
        if controller.playlists.contains(where: { $0.id == source }) { return .playlist(source) }
        if let copy = controller.copy(ofAlbum: source) { return .playlist(copy.id) }
        return controller.catalog.albums.contains { $0.id == source } ? .album(source) : nil
    }

    private func songs(of route: Route) -> [Song] {
        switch route {
        case .playlist(let id): controller.playlists.first { $0.id == id }.map(controller.songs) ?? []
        case .album(let id): controller.catalog.albums.first { $0.id == id }?.songs ?? []
        default: []
        }
    }

    private func act(_ action: NowScreen.Action) {
        switch action {
        case .openDay: navigate(.alarms)
        case .openSound: NSWorkspace.shared.open(.soundSettings)
        }
    }

    /// Runs again whenever something observed changes. Reads the unobserved track on its own clock: 30 times a second while
    /// a cover moves, once a second in a hold for the time left, and hardly at all in a settled silence.
    private func follow() async {
        await showArt()
        let start = Date.now
        var lastWords = Date.distantPast, lastFoot = Date.distantPast
        var wasSilent = motion.silent
        while !Task.isCancelled {
            let status = controller.status, track = controller.track
            let rested = status == .resting ? Date.now.timeIntervalSince(start) : 0
            let at = (track?.elapsed ?? 0) + rested
            var seen = Track.Visual.resting
            var still = Double.infinity
            if status != .idle {
                if let track, !(controller.inSilence && !track.visual(at: at).silent) {
                    seen = track.visual(at: at)
                    still = track.stillFor(at: at)
                } else {
                    seen = .resting
                }
            }
            if status == .paused { seen = seen.paused }
            apply(seen)
            let now = Date.now
            if now.timeIntervalSince(lastWords) >= 1 || seen.silent != wasSilent {
                words(silent: seen.silent)
                (lastWords, wasSilent) = (now, seen.silent)
            }
            if now.timeIntervalSince(lastFoot) >= 30 {
                let wake = SystemWake.shared.missing(for: controller.alarms).isEmpty
                motion.foot = controller.nowFoot(now: clock, wakeScheduled: wake)
                lastFoot = now
                // the row named moves on with the clock, which the key doesn't have
                await showArt()
            }
            guard visible else { return }
            let holding = status == .playing && still.isFinite
            // `elapsed` is up to half a second stale in a hold, so the fall's first frame has to be looked for
            let wait = status != .paused && still < 1 ? 1.0 / 30 : holding ? 1 : 30
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func words(silent: Bool) {
        let next = controller.nowScreen(now: clock, silent: silent)
        guard next != motion.screen else { return }
        if motion.screen.kind == .firstRun {
            withAnimation(Theme.curve(0.3)) { motion.screen = next }
        } else {
            motion.screen = next
        }
    }

    private func apply(_ seen: Track.Visual) {
        if motion.cover != seen.cover { motion.cover = seen.cover }
        if motion.underLevel != seen.under { motion.underLevel = seen.under }
        if motion.scale != seen.scale { motion.scale = seen.scale }
        if motion.text != seen.text { motion.text = seen.text }
        if motion.silent != seen.silent { motion.silent = seen.silent }
    }

    /// The new piece's cover goes on top and the last one under it, to be risen through. Nothing playing, the painting
    /// of the row it names, at the afterimage's level.
    private func showArt() async {
        let idle = controller.status == .idle
        let key = idle ? idleArt : controller.current?.artwork
        let piece = idle ? nil : controller.current?.id
        // the song too: the next piece of an album has the same art, and the old layer under it has to be this one
        guard piece != shownPiece || key != shownKey else { return }
        let image: CGImage?
        if let key, let store = Artwork.store {
            image = await Self.decode(store, key)
            guard !Task.isCancelled else { return }
        } else {
            image = nil
        }
        // the row's painting was never a piece's, so nothing rises through it
        motion.under = controller.status == .idle || shownKeyBox.idle ? nil : motion.over
        shownKeyBox.idle = controller.status == .idle
        motion.over = image
        (shownKey, shownPiece) = (key, piece)
    }

    private var idleArt: String? {
        guard !controller.catalog.albums.isEmpty else { return nil }
        return controller.dayPlan(now: clock).quietSource.flatMap(controller.alarmArtwork)
    }

    @State private var shownKeyBox = ShownKey()
    private var shownKey: String? {
        get { shownKeyBox.value }
        nonmutating set { shownKeyBox.value = newValue }
    }

    private var shownPiece: String? {
        get { shownKeyBox.piece }
        nonmutating set { shownKeyBox.piece = newValue }
    }

    private final class ShownKey {
        var value, piece: String?
        var idle = false
    }

    @concurrent
    nonisolated private static func decode(_ store: ArtworkStore, _ key: String) async -> CGImage? {
        store.image(for: key, maxPixel: 2000)
    }
}

private struct NowCover: View {
    let motion: NowMotion
    let layout: NowLayout
    let shown: CGFloat
    let album: String?
    let dragging: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let kind = motion.screen.kind
        ZStack(alignment: .bottomLeading) {
            if let under = motion.under, motion.underLevel > 0 {
                art(under, level: motion.underLevel, scale: 1)
            }
            if let over = motion.over {
                art(over, level: motion.cover, scale: motion.scale)
            } else if kind == .piece, !motion.silent {
                // it goes with the words: no afterimage without art
                tile.opacity(motion.text)
            } else if kind == .firstRun || kind == .reading {
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(dragging ? Theme.primary.opacity(0.1) : .clear)
                    .strokeBorder(dragging ? Theme.primary : Theme.frame, lineWidth: 1)
                    .frame(width: layout.side, height: layout.side)
                    .transition(.opacity)
            }
        }
        .frame(height: layout.side, alignment: .bottomLeading)
        .offset(x: layout.left(shown), y: layout.coverBottom(shown) - layout.side)
    }

    /// No art while a piece plays: a cover set from its album's name. Nothing at all once it's gone.
    private var tile: some View {
        Artwork(key: nil, size: layout.side, radius: Radius.small, title: album ?? "")
    }

    private func art(_ image: CGImage, level: Double, scale: Double) -> some View {
        let light = scheme == .light
        let side = min(layout.side, CGFloat(image.width))
        return Image(decorative: image, scale: CGFloat(image.width) / side)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.artEdge, lineWidth: 1))
            .scaleEffect(reduceMotion ? 1 : scale)
            // multiply over a cream ground turned a dim painting into a khaki stain; plain opacity keeps its colors,
            // a little stronger than on dark so it still reads as a painting
            .compositingGroup()
            .opacity(light ? Track.multiplied(level) : level)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// The lines under Now's title: body type, larger beside a large title.
    func detail(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: Role.body.weight))
            .lineHeight(.exact(points: (size * Role.body.line / Role.body.size).rounded()))
    }
}

private struct NowText: View {
    let motion: NowMotion
    let width: CGFloat
    let size: CGFloat
    let detail: CGFloat
    let lines: Int
    let centered: Bool
    let dragging: Bool
    let act: (NowScreen.Action) -> Void
    let choose: () -> Void
    let freeMusic: () -> Void

    var body: some View {
        let screen = motion.screen
        let firstRun = screen.kind == .firstRun
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            let title = firstRun && dragging ? "Let go to add it" : screen.title
            Text(title)
                .font(.system(size: size, weight: Role.title.weight))
                .lineHeight(.exact(points: (size * Role.title.line / Role.title.size).rounded()))
                .kerning(-0.011 * size)
                .foregroundStyle(Theme.text)
                .lineLimit(lines)
                .frame(width: min(width, Balance.width(title, in: width, size: size, lines: lines)), alignment: centered ? .center : .leading)
            if firstRun || !screen.sub.isEmpty {
                ZStack(alignment: .topLeading) {
                    if firstRun {
                        if !dragging {
                            HStack(spacing: 0) {
                                Text("or ")
                                ThemeLink(text: "choose a folder", style: .inline, action: choose)
                                Text(", or ")
                                ThemeLink(text: "get free music", style: .inline, action: freeMusic)
                            }
                        }
                    } else {
                        Text(screen.sub).lineLimit(2)
                    }
                }
                // its links must stay on one line in a narrow column
                .detail(firstRun ? min(detail, 15) : detail)
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 18, alignment: .topLeading)
                // 8 in the mock; an exact line height sits 2 pt lower here than in a browser
                .padding(.top, 10)
            }
            if screen.action != nil || screen.third != nil {
                ZStack(alignment: .topLeading) {
                    if let action = screen.action, let label = screen.actionTitle {
                        ThemeLink(text: label, style: .inline) { act(action) }
                    } else if let third = screen.third {
                        Text(third).monospacedDigit().foregroundStyle(Theme.faint)
                    }
                }
                .detail(detail)
                .frame(minHeight: 18, alignment: .topLeading)
                .padding(.top, screen.sub.isEmpty ? 10 : 2)
            }
        }
        .frame(width: width, alignment: centered ? .center : .leading)
        .opacity(motion.text)
    }
}

/// CSS's text-wrap: balance, which SwiftUI lacks: the narrowest width that keeps the title's line count.
@MainActor
private enum Balance {
    private static var cache: [String: CGFloat] = [:]

    static func width(_ text: String, in width: CGFloat, size: CGFloat, lines limit: Int) -> CGFloat {
        let key = "\(width) \(size) \(limit) \(text)"
        if let hit = cache[key] { return hit }
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .kern: -0.011 * size])
        let height = { (w: CGFloat) in attributed.boundingRect(with: CGSize(width: w, height: 10_000), options: .usesLineFragmentOrigin).height }
        let lines = height(width)
        // past the limit it truncates anyway: narrowing would only truncate sooner
        if lines > height(10_000) * CGFloat(limit) + 1 { return width }
        var (low, high) = (CGFloat(1), width)
        while high - low > 1 {
            let middle = (low + high) / 2
            if height(middle) > lines { low = middle } else { high = middle }
        }
        cache[key] = high.rounded(.up) + 1
        return high.rounded(.up) + 1
    }
}
