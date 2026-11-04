import AppKit
import SwiftUI
import SottovaCore

struct PageScroll<Content: View>: View {
    var insets = EdgeInsets(top: 12, leading: 32, bottom: 24, trailing: 32)
    var maxWidth: CGFloat = 1440
    @ViewBuilder let content: Content
    @Environment(Router.self) private var router
    @Environment(\.pageLayout) private var layout
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                // capped so a wide window doesn't spread a song's columns a screen apart
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(insets)
                // the toast's height and its gap above the foot, so it never sits over the last row
                .padding(.bottom, 48)
                // to the page's foot and edges, under the rows, so a click on nothing lets go of the pick
                .frame(maxWidth: .infinity, minHeight: layout.height, alignment: .top)
                .background { Color.clear.contentShape(.rect).onTapGesture { router.clearPick() } }
                .overlayScrollers()
            }
            .onChange(of: router.scrollTo) { _, id in
                if let id { reader.scrollTo(id) }
            }
            #if SHOT
            .task {
                let free = UserDefaults.standard.string(forKey: "shotFree")
                let id = free == "downloading" ? "musopen-chopin" : free == "failed" ? "ChrisZabriskieDirectToVideo" :
                    free == "downloaded" ? Shelf.sets.first { $0.title == "Cloud Cover" }?.id : nil
                if let id {
                    await Task.yield()
                    reader.scrollTo(id, anchor: .center)
                }
            }
            #endif
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

/// The first painting belongs to the app, before the listener has supplied their own music.
struct MusicWelcome: View {
    var title = "Start with your music"
    var detail = ""
    var reading = false
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router

    @MainActor private static let painting: NSImage? = Bundle.main.url(forResource: "Welcome", withExtension: "jpg", subdirectory: "Covers").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            let height = wide ? min(680, max(440, geometry.size.height - 128)) : min(480, max(360, geometry.size.height * 0.58))
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .center, spacing: 48) {
                            painting(height: height)
                            words.frame(width: 340, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            painting(height: height)
                            words.frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, wide ? 40 : 24)
                .padding(.vertical, wide ? 32 : 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
            .overlayScrollers()
        }
    }

    private func painting(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = Self.painting {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: height * image.size.width / image.size.height, height: height)
                    .accessibilityLabel("The Music Room, a painting by Vilhelm Hammershøi")
                Text("Vilhelm Hammershøi, The Music Room")
                    .role(.small).foregroundStyle(Theme.muted)
            }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reading ? "Reading your music" : title)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if reading {
                let total = controller.tracks.count
                let done = max(0, total - controller.pendingAnalysis)
                Text("\(done) of \(total) songs")
                    .role(.body).foregroundStyle(Theme.muted)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.primary)
            } else {
                if !detail.isEmpty {
                    Text(detail)
                        .role(.body).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    ThemeButton(title: "Add folder…", action: controller.chooseFolders)
                    ThemeLink(text: "Get free music", color: Theme.muted) { router.go(to: .shelf) }
                        .role(.body)
                }
            }
        }
    }
}

/// Empty list pages keep their identity while explaining where their content comes from.
struct EmptyLibrary: View {
    let what: String
    @Environment(Controller.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(what.capitalized).role(.title).foregroundStyle(Theme.text)
                .padding(.horizontal, 40).padding(.top, 16)
            MusicWelcome(title: what == "artists" ? "Artists from your music" : "Songs from your folders",
                         reading: controller.pendingAnalysis > 0)
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
