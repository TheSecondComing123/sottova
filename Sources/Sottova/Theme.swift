import AppKit
import SwiftUI
import SottovaCore

/// Color tokens from the active theme files, for dark and light.
enum Theme {
    /// Read every time a color draws; the scenes re-key on the palette's id, so a change rebuilds them and shows at once.
    nonisolated(unsafe) static var palette = slotPalette()

    static let background = token(\.background)
    static let raised = token(\.raised)
    static let hover = token(\.hover)
    static let border = token(\.border)
    static let text = token(\.text)
    static let muted = token(\.muted)
    static let faint = token(\.faint)
    /// Not for text: timeline dots, unplayed bars, placeholders.
    static let decor = token(\.decor)
    static let primary = token(\.primary)
    static let onPrimary = token(\.onPrimary)
    static let coverInk = token(\.coverInk)

    /// An item's own color, by its place in a fixed list. A theme without accents falls back to a gray token.
    static func accent(_ index: Int, or fallback: KeyPath<Palette.Tokens, UInt32> = \.text) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let tokens = tokens(appearance)
            return rgb(tokens.accents.isEmpty ? tokens[keyPath: fallback] : tokens.accents[index % tokens.accents.count])
        })
    }

    /// An album's own color, stable across launches. Keyed by the album's title, as covers drawn from type are, so an
    /// album's cover and its marks agree.
    static func accent(for key: String?, or fallback: KeyPath<Palette.Tokens, UInt32> = \.text) -> Color {
        accent(Int(stableHash(key ?? "")), or: fallback)
    }

    /// The ground for a cover drawn from type.
    static func coverGround(for key: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let covers = tokens(appearance).covers
            return rgb(covers[Int(stableHash(key) % UInt32(covers.count))])
        })
    }

    /// FNV-1a: String.hashValue changes every launch.
    static func stableHash(_ text: String) -> UInt32 {
        text.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
    }

    static let quick = curve(0.2)
    static let settle = Animation.spring(duration: 0.35, bounce: 0.12)
    static let page = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)

    /// A press goes down fast and lets go slower, so a quick click still shows.
    static func press(_ down: Bool) -> Animation { curve(down ? 0.08 : 0.2) }

    /// Every control that shows only under the pointer: in over 120 ms, out over 80.
    static func reveal(_ shown: Bool) -> Animation { curve(shown ? 0.12 : 0.08) }

    /// One deceleration curve for everything that isn't a spring: quick to start, long to settle.
    static func curve(_ duration: Double) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    private static func token(_ path: KeyPath<Palette.Tokens, UInt32>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in rgb(tokens(appearance)[keyPath: path]) })
    }

    private static func tokens(_ appearance: NSAppearance) -> Palette.Tokens {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? palette.dark : palette.light
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Phosphor icons (MIT), vendored as SVGs in Support/Icons and copied into the app's Resources: the PhosphorSwift
/// package ships an asset catalog, which `swift build` can't compile. Only the name-weight pairs in use are vendored.
enum Ph: String {
    case clock, alarm, check, x, play, pause
    case magnifyingGlass = "magnifying-glass", speakerHigh = "speaker-high", caretDown = "caret-down", caretLeft = "caret-left", caretRight = "caret-right"
    case folder, plus, minus, palette, shuffle, dotsThree = "dots-three", dotsSixVertical = "dots-six-vertical"
    case sunHorizon = "sun-horizon", musicNotes = "music-notes", trayArrowDown = "tray-arrow-down", caretUpDown = "caret-up-down"
    case stack, microphoneStage = "microphone-stage", timer
    case barPause = "bar-pause", barPlay = "bar-play", barSkip = "bar-skip", barQueue = "bar-queue"

    enum IconWeight: String {
        case duotone, bold, fill
        case line
    }

    /// Drawn as a template image, so it takes foregroundStyle like text; the duotone layer keeps its 20% alpha,
    /// so the icon stays two grays of whatever color it's given.
    /// Hidden from VoiceOver, which can't name it: a control that's only an icon carries its own label.
    @MainActor func icon(_ weight: IconWeight = .duotone, size: CGFloat) -> some View {
        Image(nsImage: image(weight)).renderingMode(.template).resizable().frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor func image(_ weight: IconWeight) -> NSImage {
        let name = "\(rawValue)-\(weight.rawValue)"
        if let cached = Self.images[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else {
            fatalError("\(name).svg is missing from the app's Resources/Icons; scripts/bundle.sh copies Support/Icons")
        }
        Self.images[name] = image
        return image
    }

    @MainActor private static var images: [String: NSImage] = [:]
}

enum Route: Hashable {
    case home, songs, collections, artists, alarms, shelf
    case album(String)
    case artist(String)
    /// By the playlist's file path.
    case playlist(String)
    case composer(String)

    /// The sidebar section a page lives under.
    var section: Route {
        switch self {
        case .album: .collections
        case .artist, .composer: .artists
        default: self
        }
    }
}

/// Equal to every other instance, so a new closure each time MainWindow re-renders doesn't invalidate every row.
struct Navigate: Equatable {
    let go: @MainActor (Route) -> Void

    @MainActor func callAsFunction(_ route: Route) {
        go(route)
    }

    static func == (lhs: Navigate, rhs: Navigate) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var navigate = Navigate { _ in }
    /// The playlist whose name is being typed, right after it's made or picked Rename.
    @Entry var renaming: Binding<String?> = .constant(nil)
    /// False while the main window is minimized or covered, so nothing animates unseen.
    @Entry var windowVisible = true
    /// Read once, at the window. Each page reads what it needs, so a list isn't redrawn for every point of a resize.
    @Entry var pageLayout = PageLayout(windowWidth: 1240, pageHeight: 748)
    @Entry var listLayout = ListLayout(width: 1024)
    /// The songs of the list a row sits in, in order, so ⇧-click can pick the run between two.
    @Entry var songOrder: [String] = []
    @Entry var songDrag: Namespace.ID?
    /// The rows of a pick on its way somewhere, drawn dimmed until it lands.
    @Entry var songsLifted: Set<String> = []
}

/// A row or tile that lights up under the pointer, instantly, as in Finder and Music.
struct Hoverable: ViewModifier {
    var radius: CGFloat = Radius.medium
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverable(radius: CGFloat = Radius.medium) -> some View {
        modifier(Hoverable(radius: radius))
    }

    /// A hover-only control: fades with `Theme.reveal`, takes no clicks while hidden, and keeps its place.
    func revealed(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(Theme.reveal(shown), value: shown)
    }
}

/// Presses down a little, like a real button. Wide targets get a smaller scale so they don't visibly shrink.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(Press(pressed: configuration.isPressed, scale: scale))
    }
}

/// PressStyle's press, for a style that draws its own button.
struct Press: ViewModifier {
    let pressed: Bool
    let scale: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(enabled ? (reduceMotion && pressed ? 0.75 : 1) : 0.4)
            .contentShape(.rect)
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .animation(Theme.press(pressed), value: pressed)
    }
}

struct IconButton: View {
    let icon: Ph
    var weight: Ph.IconWeight = .duotone
    var help: String
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.icon(weight, size: size * 0.5)
                .foregroundStyle(Theme.muted)
                .frame(width: size, height: size)
                .hoverable(radius: size / 2)
        }
        .buttonStyle(PressStyle())
        .help(help)
        // .help is only the tooltip; without a label VoiceOver reads an unnamed button
        .accessibilityLabel(help)
    }
}

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Whole minutes, rounded up: "45 min", "1 h", "1 h 30 min".
    static func minutes(_ seconds: Double) -> String {
        DayPlan.length(minutes: max(1, Int((seconds / 60).rounded(.up))))
    }

    /// What the sleep timer has left, for the moon's label, or after "stops" in a sentence.
    static func sleep(_ timer: Controller.SleepTimer, resting: Bool, at now: Date, sentence: Bool = false) -> String {
        let left: Double
        switch timer {
        case .afterCurrent: return resting ? "after the next song" : "after this song"
        case .paused(let seconds): left = seconds
        case .at(let date): left = date.timeIntervalSince(now)
        }
        if left < 60 { return sentence ? "in under a minute" : "stopping" }
        return sentence ? "in \(minutes(left))" : minutes(left)
    }

    static func length(_ seconds: Double) -> String { DayPlan.length(minutes: Int((seconds / 60).rounded())) }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    /// The gap range alone, with the unit written once: "10 to 20 min", or "6 s crossfade".
    static func range(_ s: SottovaCore.Settings) -> String {
        if s.crossfade { return "\(TypedDuration.format(s.crossfadeSec)) crossfade" }
        let low = s.gapRange.lowerBound, high = s.gapRange.upperBound
        if high < 60 { return "\(Int(low)) to \(Int(high)) s" }
        if low >= 60 { return "\(String(format: "%g", low / 60)) to \(String(format: "%g", high / 60)) min" }
        return "\(Int(low)) s to \(String(format: "%g", high / 60)) min"
    }

    /// Silence between songs, wherever it's summed up: "Sparse, 3 to 8 min".
    static func silence(_ s: SottovaCore.Settings) -> String { "\(s.name), \(range(s))" }
}

/// With a mouse plugged in, AppKit gives every scroll view a wide gray scroller that never goes away; on these
/// grounds it reads as a stray bar. This asks the enclosing scroll view for the thin one that shows while scrolling,
/// and asks again when the system preference changes, since AppKit resets it then.
private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private var observer: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            observer = observer ?? NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            enclosingScrollView?.scrollerStyle = .overlay
        }
    }
}

extension View {
    /// Put on content inside a ScrollView or List.
    func overlayScrollers() -> some View {
        background(OverlayScroller())
    }
}
