import AppKit
import SwiftUI
import SottovaCore

/// Color tokens from the active palette, for dark and light. Monochrome's dark values follow monochrome.st's CSS,
/// with text tokens raised to pass WCAG AA at 11–13 pt.
enum Theme {
    /// Read every time a color draws; the scenes re-key on the palette's id, so a change rebuilds them and shows at once.
    nonisolated(unsafe) static var palette = Palette.named(UserDefaults.standard.string(forKey: "palette"))

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

    /// An item's own color, by its place in a fixed list (sections, presets). Monochrome has no accents, so it falls
    /// back to the gray token the item used before.
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

    /// The ground for a cover drawn from type: grays in monochrome, the accents in a color palette.
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

    static func select(_ id: String) {
        palette = Palette.named(id)
    }

    static let quick = curve(0.2)
    static let settle = Animation.spring(duration: 0.35, bounce: 0.12)
    static let page = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    /// System-driven changes (a track ending, a gap starting) ease slowly, like the audio does.
    static let ambient = curve(0.6)

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

extension Font {
    /// SF Pro anywhere on its weight axis (1–1000, bold is 700), so a title can thin continuously with the sound
    /// instead of stepping between named weights. Optical size follows the point size, as the named weights do.
    @MainActor static func system(size: CGFloat, axisWeight: Double) -> Font {
        let key = "\(size) \(axisWeight)"
        if let font = axisFonts[key] { return font }
        let weight = 0x7767_6874, opticalSize = 0x6F70_737A
        let base = NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [weight: axisWeight, opticalSize: Double(size)],
        ])
        let font = Font(NSFont(descriptor: descriptor, size: size) ?? base)
        axisFonts[key] = font
        return font
    }

    /// At most 3 sizes × 51 weights: the hero rounds its weight to steps of 10.
    @MainActor private static var axisFonts: [String: Font] = [:]
}

/// Phosphor icons (MIT), vendored as SVGs in Support/Icons and copied into the app's Resources: the PhosphorSwift
/// package ships an asset catalog, which `swift build` can't compile. Only the name-weight pairs in use are vendored.
enum Ph: String {
    case house, clock, alarm, check, trash, image, shuffle, x, waveform, play, pause
    case musicNote = "music-note", vinylRecord = "vinyl-record", microphoneStage = "microphone-stage"
    case folderPlus = "folder-plus", gearSix = "gear-six", magnifyingGlass = "magnifying-glass"
    case speakerHigh = "speaker-high", speakerSlash = "speaker-slash"
    case caretLeft = "caret-left", caretRight = "caret-right", caretDown = "caret-down", skipForward = "skip-forward"
    case pencil = "pencil-simple"
    case folder, plus, minus, palette, moon, queue, dotsThree = "dots-three", arrowsClockwise = "arrows-clockwise"

    enum IconWeight: String {
        case duotone, bold, fill
    }

    /// Drawn as a template image, so it takes foregroundStyle like text; the duotone layer keeps its 20% alpha,
    /// so the icon stays two grays of whatever color it's given.
    @MainActor func icon(_ weight: IconWeight = .duotone, size: CGFloat) -> some View {
        Image(nsImage: image(weight)).renderingMode(.template).resizable().frame(width: size, height: size)
    }

    @MainActor private func image(_ weight: IconWeight) -> NSImage {
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
    case home, songs, albums, artists, alarms
    case album(String)
    case artist(String)
    /// By the playlist's file path.
    case playlist(String)
    case composer(String)

    /// The sidebar section a page lives under.
    var section: Route {
        switch self {
        case .album: .albums
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
}

/// A row or tile that lights up under the pointer, instantly, as in Finder and Music.
struct Hoverable: ViewModifier {
    var radius: CGFloat = 8
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverable(radius: CGFloat = 8) -> some View {
        modifier(Hoverable(radius: radius))
    }
}

/// Presses down a little, like a real button. Wide targets get a smaller scale so they don't visibly shrink.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// Text that navigates, underlined under the pointer.
struct LinkText: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // a button rather than a tap gesture, so VoiceOver can follow the link
        Button(action: action) {
            Text(text)
                .underline(hovering)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The white (or black) circle play button.
struct PlayCircle: View {
    var size: CGFloat = 52
    var playing = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            (playing ? Ph.pause : Ph.play).icon(.fill, size: size * 0.4)
                // no nudge: Phosphor's triangle is already drawn right of its box's center, so it reads centered as is
                .foregroundStyle(Theme.onPrimary)
                .frame(width: size, height: size)
                .background(Theme.primary, in: .circle)
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering in
            withAnimation(Theme.settle) { self.hovering = hovering }
        }
        .help(playing ? "pause" : "play")
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
        let m = max(1, Int((seconds / 60).rounded(.up)))
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// What the sleep timer has left, for the moon's label, or after "stops" in a sentence.
    static func sleep(_ timer: Controller.SleepTimer, resting: Bool, at now: Date, sentence: Bool = false) -> String {
        let left: Double
        switch timer {
        case .afterCurrent: return resting ? "after the next piece" : "after this piece"
        case .paused(let seconds): left = seconds
        case .at(let date): left = date.timeIntervalSince(now)
        }
        if left < 60 { return sentence ? "in under a minute" : "stopping" }
        return sentence ? "in \(minutes(left))" : minutes(left)
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Header art grows with the window, from 232 pt up to 320, so a wide window isn't a small square and a long gap.
    static func heroArt(for width: CGFloat) -> CGFloat {
        min(max(width * 0.2, 232), 320).rounded()
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    static func gaps(_ s: SottovaCore.Settings) -> String {
        s.crossfade ? "crossfades, no gaps" : "\(range(s)) gaps"
    }

    /// The gap range alone, with the unit written once: "10–20 min".
    static func range(_ s: SottovaCore.Settings) -> String {
        if s.crossfade { return "crossfade" }
        let low = s.gapRange.lowerBound, high = s.gapRange.upperBound
        if high < 60 { return "\(Int(low))–\(Int(high)) s" }
        if low >= 60 { return "\(String(format: "%g", low / 60))–\(String(format: "%g", high / 60)) min" }
        return "\(Int(low)) s–\(String(format: "%g", high / 60)) min"
    }
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
