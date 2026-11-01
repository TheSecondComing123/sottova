import AppKit
import SwiftUI
import SottovaCore

/// Album art from the artwork cache, decoded off the main thread at the size it's drawn.
/// A cached image appears on the first frame with no fade, so scrolling back never re-fades tiles.
/// Without art, a cover large enough to read is set from its title instead; smaller ones stay an outlined square.
struct Artwork: View {
    @MainActor static var store: ArtworkStore?

    let key: String?
    /// nil fills the proposed width as a square.
    var size: CGFloat?
    var radius: CGFloat = 4
    var circle = false
    var outlined = false
    var title: String?
    var subtitle: String?
    @State private var image: CGImage?

    init(key: String?, size: CGFloat? = nil, radius: CGFloat = 4, circle: Bool = false, outlined: Bool = false, title: String? = nil, subtitle: String? = nil) {
        self.key = key
        self.size = size
        self.radius = radius
        self.circle = circle
        self.outlined = outlined
        self.title = title
        self.subtitle = subtitle
        _image = State(initialValue: key.flatMap { Self.store?.cached(for: $0, maxPixel: Self.pixels(for: size)) })
    }

    private static func pixels(for size: CGFloat?) -> Int {
        Int((size ?? 240) * 2)
    }

    var body: some View {
        let shape = circle ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: radius))
        Rectangle()
            // an artist without art is an outlined circle, lighter than an album's solid ground
            .fill(image == nil ? Theme.coverGround(for: title ?? "") : Theme.hover)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                        // a new image crossfades over the old one instead of flashing the placeholder
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                } else if let title, (size ?? .infinity) >= 56 {
                    TypeCover(title: title, subtitle: subtitle, circle: circle)
                }
            }
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(shape)
            .overlay {
                if outlined || image == nil {
                    // keeps a black cover from dissolving into the black page
                    shape.stroke(Theme.border, lineWidth: 1)
                }
            }
            // the size is part of the identity: header art that grows with the window decodes again, sharper
            .task(id: "\(key ?? "")@\(Self.pixels(for: size))") {
                guard let key, let store = Self.store else {
                    image = nil
                    return
                }
                let pixels = Self.pixels(for: size)
                if let hit = store.cached(for: key, maxPixel: pixels) {
                    image = hit
                    return
                }
                let decoded = await Self.decode(store, key, pixels)
                guard !Task.isCancelled else { return }
                withAnimation(Theme.curve(0.25)) { image = decoded }
            }
    }

    /// Runs off the main actor and is skipped once the cell scrolls away, so a fast fling doesn't queue hundreds of decodes.
    @concurrent
    nonisolated private static func decode(_ store: ArtworkStore, _ key: String, _ pixels: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return store.image(for: key, maxPixel: pixels)
    }
}

/// The cover blurred into a wash behind a page header, so the page's only color still comes from the art.
/// A 64 pt decode, blurred at that size and then scaled up: the same look as blurring the big layer, at a fraction of the pixels.
struct ArtWash: View {
    let key: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            Artwork(key: key, size: 64, radius: 0)
                .blur(radius: 60 * 64 / side, opaque: true)
                .scaleEffect(side / 64, anchor: .topLeading)
                .frame(width: side, height: side, alignment: .topLeading)
                .opacity(colorScheme == .dark ? 0.45 : 0.3)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
        }
        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

/// A cover set from type alone, low and to the left like a record sleeve with nothing to show but its name.
private struct TypeCover: View {
    let title: String
    let subtitle: String?
    let circle: Bool

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            if circle {
                // the name is already the caption under an artist's circle, so the circle carries initials
                // first and last name, so "Adolf von Henselt" is AH, and always capitals
                Text({ let words = title.split(separator: " "); return ([words.first] + (words.count > 1 ? [words.last] : []))
                    .compactMap { $0?.first.map { String($0).uppercased() } }.joined() }())
                    .font(.system(size: side * 0.17))
                    .foregroundStyle(Theme.accent(for: title, or: \.muted))
                    .frame(width: side, height: side)
            } else {
                cover(side: side)
            }
        }
    }

    private func cover(side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: side * 0.025) {
            Text(title)
                .font(.system(size: side * 0.105, weight: .semibold))
                .tracking(-0.2)
                // the item's color is in the type, on a quiet ground, so a wall of type covers isn't a wall of color
                .foregroundStyle(Theme.accent(for: title, or: \.coverInk))
                .lineLimit(3)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: side * 0.06))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(side * 0.08)
        // top left, where the hover play button in the opposite corner can't cover it
        .frame(width: side, height: side, alignment: .topLeading)
    }
}

/// Reports whether the hosting window is on screen, from AppKit's occlusion state.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        view.onChange = { visible = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            guard let window else { return }
            // restoration is off, and SwiftUI's frame saving goes with it
            window.setFrameAutosaveName("main")
            // otherwise a press on any control in the title bar's band moves the window, whatever the control says:
            // TitleDrag moves it from the blank parts instead
            window.isMovable = false
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.onChange(window.occlusionState.contains(.visible))
                }
            }
            onChange(window.occlusionState.contains(.visible))
        }
    }
}
