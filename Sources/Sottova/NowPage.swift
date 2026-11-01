#if NEWLOOK
import AppKit
import SwiftUI
import SottovaCore

/// What Now draws from moment to moment, as separate properties so each small view redraws only for its own.
@MainActor @Observable
private final class NowMotion {
    var over: CGImage?
    var under: CGImage?
    var cover = 1.0
    var underLevel = 0.0
    var scale = 1.0
    var text = 1.0
    var hairline = 0.0
    var fill = 0.0
    var silent = false
    var screen = NowScreen(kind: .quiet, title: "")
    var foot: String?
}

/// Where things sit, from the mock: 400 pt cover at 64 in a 1024 pane, 280 at 32 in a 679 one, with the cover's foot
/// 70% of the way down.
private struct NowLayout {
    let width, height, side, left, gap: CGFloat

    init(_ size: CGSize) {
        (width, height) = (size.width, size.height)
        let p = min(1, max(0, (size.width - 679) / (1024 - 679)))
        side = (280 + 120 * p).rounded()
        left = (32 + 32 * p).rounded()
        gap = (32 + 8 * p).rounded()
    }

    var coverBottom: CGFloat { max(side + 24, height * 524 / 748) }
    func textLeft(_ shown: CGFloat) -> CGFloat { left + shown + gap }
    func textWidth(_ shown: CGFloat) -> CGFloat { min(456, width - textLeft(shown) - left) }
}

struct NowPage: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.windowVisible) private var visible
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
        GeometryReader { geo in
            let layout = NowLayout(geo.size)
            let shown = motion.over.map { min(layout.side, CGFloat($0.width)) } ?? layout.side
            ZStack(alignment: .topLeading) {
                NowHairline(motion: motion, width: geo.size.width, paused: controller.status == .paused)
                NowCover(motion: motion, layout: layout, album: controller.current?.album, dragging: router.droppingMusic)
                NowText(motion: motion, width: layout.textWidth(shown), dragging: router.droppingMusic, act: act,
                        choose: controller.chooseFolders, freeMusic: { navigate(.shelf) })
                    .frame(height: layout.coverBottom + 5, alignment: .bottomLeading)
                    .offset(x: layout.textLeft(shown))
                foot
                    .frame(height: geo.size.height - 14, alignment: .bottomLeading)
                    .offset(x: layout.textLeft(shown))
            }
        }
        .task(id: key) { await follow() }
    }

    @ViewBuilder
    private var foot: some View {
        if let line = motion.foot, line != router.dismissedFoot {
            HStack(spacing: 8) {
                let missed = line.hasPrefix("Missed")
                Text(line).role(.body).foregroundStyle(missed ? Theme.text : Theme.muted)
                if missed {
                    Button { router.dismissedFoot = line } label: {
                        Ph.x.icon(.bold, size: 12).foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("dismiss")
                }
            }
        }
    }

    private func act(_ action: NowScreen.Action) {
        switch action {
        case .skip: controller.skip()
        case .play: controller.play()
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
            var seen = Track.Visual.full
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
            apply(seen, fill: track.map { $0.duration > 0 ? min($0.elapsed / $0.duration, 1) : 0 } ?? 0, idle: status == .idle)
            let now = Date.now
            if now.timeIntervalSince(lastWords) >= 1 || seen.silent != wasSilent {
                words(silent: seen.silent)
                (lastWords, wasSilent) = (now, seen.silent)
            }
            if now.timeIntervalSince(lastFoot) >= 30 {
                let wake = SystemWake.shared.missing(for: controller.alarms).isEmpty
                motion.foot = controller.nowFoot(now: clock, wakeScheduled: wake)
                lastFoot = now
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

    private func apply(_ seen: Track.Visual, fill: Double, idle: Bool) {
        if motion.cover != seen.cover { motion.cover = seen.cover }
        if motion.underLevel != seen.under { motion.underLevel = seen.under }
        if motion.scale != seen.scale { motion.scale = seen.scale }
        if motion.text != seen.text { motion.text = seen.text }
        let line = idle ? 0 : seen.hairline
        if motion.hairline != line { motion.hairline = line }
        if motion.fill != fill { motion.fill = fill }
        if motion.silent != seen.silent { motion.silent = seen.silent }
    }

    /// The new piece's cover goes on top and the last one under it, to be risen through. Nothing playing, nothing shown.
    private func showArt() async {
        let idle = controller.status == .idle
        let key = idle ? nil : controller.current?.artwork
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
        motion.under = controller.status == .idle ? nil : motion.over
        motion.over = image
        (shownKey, shownPiece) = (key, piece)
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

    private final class ShownKey { var value, piece: String? }

    @concurrent
    nonisolated private static func decode(_ store: ArtworkStore, _ key: String) async -> CGImage? {
        store.image(for: key, maxPixel: 800)
    }
}

private struct NowHairline: View {
    let motion: NowMotion
    let width: CGFloat
    let paused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: -1)
            Rectangle().fill(paused ? Theme.faint : Theme.primary)
                .frame(width: width * motion.fill, height: 2)
                .opacity(motion.hairline)
                .offset(y: -2)
        }
    }
}

private struct NowCover: View {
    let motion: NowMotion
    let layout: NowLayout
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
        .offset(x: layout.left, y: layout.coverBottom - layout.side)
    }

    /// No art while a piece plays: its album's name, low in an outline. Nothing at all once it's gone.
    private var tile: some View {
        RoundedRectangle(cornerRadius: Radius.small)
            .strokeBorder(Theme.frame, lineWidth: 1)
            .overlay(alignment: .bottomLeading) {
                Text(album ?? "").role(.name).foregroundStyle(Theme.muted).padding(20)
            }
            .frame(width: layout.side, height: layout.side)
    }

    private func art(_ image: CGImage, level: Double, scale: Double) -> some View {
        let light = scheme == .light
        let side = min(layout.side, CGFloat(image.width))
        return Image(decorative: image, scale: CGFloat(image.width) / side)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color(white: 0.5, opacity: 0.28), lineWidth: 1))
            .scaleEffect(reduceMotion ? 1 : scale)
            // or multiply takes the image and its outline separately
            .compositingGroup()
            // on a light ground plain opacity reads as fog; multiply keeps the painting's darks
            .opacity(light ? Track.multiplied(level) : level)
            .blendMode(light ? .multiply : .normal)
            .accessibilityHidden(true)
    }
}

private struct NowText: View {
    let motion: NowMotion
    let width: CGFloat
    let dragging: Bool
    let act: (NowScreen.Action) -> Void
    let choose: () -> Void
    let freeMusic: () -> Void

    var body: some View {
        let screen = motion.screen
        let firstRun = screen.kind == .firstRun
        VStack(alignment: .leading, spacing: 0) {
            let title = firstRun && dragging ? "Let go to add it" : screen.title
            Text(title)
                .role(.title)
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .frame(width: min(width, Balance.width(title, in: width)), alignment: .leading)
            ZStack(alignment: .topLeading) {
                if firstRun {
                    if !dragging {
                        HStack(spacing: 0) {
                            Text("or ")
                            ThemeLink(text: "choose a folder", underlined: true, action: choose)
                            Text(", or ")
                            ThemeLink(text: "get free music", underlined: true, action: freeMusic)
                        }
                    }
                } else {
                    Text(screen.sub).lineLimit(2)
                }
            }
            .role(.body)
            .foregroundStyle(Theme.muted)
            .frame(minHeight: 18, alignment: .topLeading)
            // 8 in the mock; an exact line height sits 2 pt lower here than in a browser
            .padding(.top, 10)
            ZStack(alignment: .topLeading) {
                if let action = screen.action, let label = screen.actionTitle {
                    ThemeLink(text: label) { act(action) }
                } else if let third = screen.third {
                    Text(third).monospacedDigit().foregroundStyle(Theme.faint)
                }
            }
            .role(.body)
            .frame(minHeight: 18, alignment: .topLeading)
            .padding(.top, 2)
        }
        .frame(width: width, alignment: .leading)
        .opacity(motion.text)
    }
}

/// CSS's text-wrap: balance, which SwiftUI lacks: the narrowest width that keeps the title's line count.
@MainActor
private enum Balance {
    private static var cache: [String: CGFloat] = [:]

    static func width(_ text: String, in width: CGFloat) -> CGFloat {
        let key = "\(width) \(text)"
        if let hit = cache[key] { return hit }
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: Role.title.size, weight: .medium), .kern: -0.352])
        let height = { (w: CGFloat) in attributed.boundingRect(with: CGSize(width: w, height: 10_000), options: .usesLineFragmentOrigin).height }
        let lines = height(width)
        var (low, high) = (CGFloat(1), width)
        while high - low > 1 {
            let middle = (low + high) / 2
            if height(middle) > lines { low = middle } else { high = middle }
        }
        cache[key] = high.rounded(.up) + 1
        return high.rounded(.up) + 1
    }
}
#endif
