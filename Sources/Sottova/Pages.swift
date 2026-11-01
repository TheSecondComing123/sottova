import AppKit
import SwiftUI
import SottovaCore

struct PageScroll<Content: View>: View {
    var insets = EdgeInsets(top: 12, leading: 32, bottom: 24, trailing: 32)
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
            .padding(insets)
            .overlayScrollers()
        }
        // rows fade out at the page's foot
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

/// What's left on the old names until the switch renames them: `.btn.def`, the single next action.
struct InvertedButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .role(.body)
            .foregroundStyle(enabled ? Theme.onPrimary : Theme.disabled)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(enabled ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.selection), in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// `.btn`.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .role(.body)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Theme.selection, in: .rect(cornerRadius: Radius.small))
            .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.stroke, lineWidth: 0.5) }
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A list page with nothing in it yet: what will appear, and the one way to get it there.
struct EmptyLibrary: View {
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

struct Missing: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
