import AppKit
import SwiftUI
import SottovaCore

/// Album art from the artwork cache, decoded off the main thread at the size it's drawn.
/// A cached image appears on the first frame with no fade, so scrolling back never re-fades tiles.
struct Artwork: View {
    @MainActor static var store: ArtworkStore?

    let key: String?
    /// nil fills the proposed width as a square.
    var size: CGFloat?
    var radius: CGFloat = 6
    var circle = false
    var outlined = false
    @State private var image: CGImage?

    init(key: String?, size: CGFloat? = nil, radius: CGFloat = 6, circle: Bool = false, outlined: Bool = false) {
        self.key = key
        self.size = size
        self.radius = radius
        self.circle = circle
        self.outlined = outlined
        _image = State(initialValue: key.flatMap { Self.store?.cached(for: $0, maxPixel: Self.pixels(for: size)) })
    }

    private static func pixels(for size: CGFloat?) -> Int {
        Int((size ?? 240) * 2)
    }

    var body: some View {
        let shape = circle ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: radius))
        Rectangle()
            .fill(Theme.hover)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                        // a new image crossfades over the old one instead of flashing the placeholder
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: (size ?? 120) * 0.3, weight: .light))
                        .foregroundStyle(Theme.decor)
                }
            }
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(shape)
            .overlay {
                if outlined {
                    // keeps a black cover from dissolving into the black page
                    shape.stroke(Theme.border, lineWidth: 1)
                }
            }
            .task(id: key) {
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
                withAnimation(.easeOut(duration: 0.25)) { image = decoded }
            }
    }

    /// Runs off the main actor and is skipped once the cell scrolls away, so a fast fling doesn't queue hundreds of decodes.
    @concurrent
    nonisolated private static func decode(_ store: ArtworkStore, _ key: String, _ pixels: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return store.image(for: key, maxPixel: pixels)
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
