import AppKit
import SwiftUI
import SottovaCore

/// Monochrome tokens for dark and light; album art is the only color. Dark values follow monochrome.st's CSS,
/// with text tokens raised to pass WCAG AA at 11–13 pt.
enum Theme {
    static let background = dynamic(0x0A0A0A, 0xF5F5F5)
    static let raised = dynamic(0x141414, 0xFFFFFF)
    static let hover = dynamic(0x1C1C1C, 0xEAEAEA)
    static let border = dynamic(0x262626, 0xE0E0E0)
    static let text = dynamic(0xF5F5F5, 0x0A0A0A)
    static let muted = dynamic(0xA0A0A0, 0x525252)
    static let faint = dynamic(0x7A7A7A, 0x6E6E6E)
    /// Not for text: timeline dots, unplayed bars, placeholders.
    static let decor = dynamic(0x5C5C5C, 0xA5A5A5)
    /// Grounds for covers drawn from type, picked per album so a shelf of them isn't one flat tone.
    static let covers = [dynamic(0x141414, 0xFFFFFF), dynamic(0x1A1A1A, 0xF0F0F0), dynamic(0x202020, 0xE6E6E6)]

    static let quick = Animation.easeOut(duration: 0.15)
    static let settle = Animation.spring(duration: 0.35, bounce: 0.12)
    static let page = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    /// System-driven changes (a track ending, a gap starting) ease slowly, like the audio does.
    static let ambient = Animation.easeInOut(duration: 0.6)

    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Route: Hashable {
    case home, songs, albums, artists
    case album(String)
    case artist(String)

    /// The sidebar section a page lives under.
    var section: Route {
        switch self {
        case .album: .albums
        case .artist: .artists
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
    /// False while the main window is minimized or covered, so nothing animates unseen.
    @Entry var windowVisible = true
}

/// A row or tile that lights up under the pointer, instantly, as in Finder and Music.
struct Hoverable: ViewModifier {
    var radius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(Theme.hover.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverable(radius: CGFloat = 6) -> some View {
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
        Text(text)
            .underline(hovering)
            .lineLimit(1)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
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
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Theme.background)
                // the play triangle reads off-center at its geometric center
                .offset(x: playing ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(Theme.text, in: .circle)
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
    let systemImage: String
    var help: String
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
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
