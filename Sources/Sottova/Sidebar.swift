#if NEWLOOK
import AppKit
import SwiftUI
import SottovaCore

struct Sidebar: View {
    let section: Route
    @Environment(Router.self) private var router
    @Environment(Controller.self) private var controller
    @Environment(\.renaming) private var renaming

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                nav(.home, "Now", .speakerHigh)
                nav(.alarms, "Your day", .sunHorizon)
                nav(.songs, "Songs", .musicNotes)
                nav(.shelf, "Free music", .trayArrowDown)
            }
            head
                .padding(.top, 20)
                .padding(.bottom, 4)
            ScrollView {
                // "till 7" turns into the next thing by itself
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    #if SHOT
                    let plan = controller.dayPlan(now: controller.shotNow ?? context.date)
                    #else
                    let plan = controller.dayPlan(now: context.date)
                    #endif
                    VStack(spacing: 0) {
                        ForEach(plan.inDayOrder(sources(plan)), id: \.self) { id in
                            CollectionRow(source: id, hours: plan.label(of: id))
                        }
                    }
                }
                .overlayScrollers()
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            news
            SilenceFoot()
        }
        .padding(.horizontal, 10)
        .padding(.top, 52)
        .padding(.bottom, 10)
    }

    /// Yours, and any album a row of the day plays; a whole library of albums belongs on the heading's grid.
    private func sources(_ plan: DayPlan) -> [String] {
        let albums = Set(controller.catalog.albums.map(\.id))
        var seen = Set<String>()
        return (controller.playlists.map(\.id) + controller.alarms.map(\.source).filter(albums.contains)).filter { seen.insert($0).inserted }
    }

    private func nav(_ route: Route, _ label: String, _ icon: Ph) -> some View {
        let on = section == route
        return Button { router.go(to: route) } label: {
            HStack(spacing: 8) {
                icon.icon(size: 18).foregroundStyle(on ? Theme.primary : Theme.icon)
                Text(label).role(.body).fontWeight(on ? .medium : .regular).foregroundStyle(Theme.text).padding(.top, 1)
                Spacer(minLength: 0)
            }
            .sidebarRow(selected: on)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var head: some View {
        SectionHead(title: "") {
            Button(action: newCollection) {
                Ph.plus.icon(.line, size: 12).foregroundStyle(Theme.faint).frame(height: 14).padding(.leading, 6).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("new collection")
            .accessibilityLabel("new collection")
        }
        .overlay(alignment: .leading) {
            Button { router.go(to: .collections) } label: {
                Text("Collections").role(.label).foregroundStyle(router.route == .collections ? Theme.text : Theme.faint)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help("all collections")
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func newCollection() {
        guard let id = controller.newPlaylist() else { return }
        renaming.wrappedValue = id
        router.go(to: .playlist(id))
    }

    /// Where it can be seen while working; a click puts it away.
    @ViewBuilder
    private var news: some View {
        if let problem = controller.problem {
            Button { controller.problem = nil } label: {
                Text(problem)
                    .role(.small)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("dismiss")
            .padding(8)
        } else if !controller.skippedFiles.isEmpty {
            Text(controller.libraryLine).role(.small).foregroundStyle(Theme.faint).lineLimit(2).padding(8)
        }
    }
}

private extension View {
    /// `.r` in the mock.
    func sidebarRow(selected: Bool) -> some View {
        padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
            .background(selected ? Theme.selection : .clear, in: .rect(cornerRadius: Radius.small))
            .hoverable(radius: Radius.small)
    }
}

/// A name and its hours. Songs dropped on one of yours are added.
private struct CollectionRow: View {
    let source: String
    let hours: String?
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    @State private var targeted = false

    private var playlist: Playlist? { controller.playlists.first { $0.id == source } }
    private var route: Route { playlist == nil ? .album(source) : .playlist(source) }

    var body: some View {
        let selected = router.route == route
        Button { navigate(route) } label: {
            HStack(spacing: 8) {
                Text(playlist?.name ?? controller.catalog.albums.first { $0.id == source }?.title ?? "")
                    .role(.body).fontWeight(selected ? .medium : .regular).foregroundStyle(Theme.text).lineLimit(1).padding(.top, 1)
                Spacer(minLength: 0)
                if let hours {
                    Text(hours).role(.small).monospacedDigit().foregroundStyle(Theme.faint).fixedSize().padding(.top, 1)
                }
            }
            .sidebarRow(selected: selected)
            .background(Theme.primary.opacity(targeted ? 0.1 : 0), in: .rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.primary).opacity(targeted ? 1 : 0))
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .dropDestination(for: URL.self) { urls, _ in
            guard let playlist else { return false }
            let songs = urls.compactMap { controller.catalog.songsByID[$0.standardizedFileURL.path] }
            guard !songs.isEmpty else { return false }
            withAnimation(Theme.quick) { controller.add(songs, to: playlist.id) }
            return true
        } isTargeted: { targeted = $0 && playlist != nil }
        .onDrag({
            router.draggingCollection = source
            return NSItemProvider(object: source as NSString)
        }, preview: {
            HStack(spacing: 8) {
                Artwork(key: controller.alarmArtwork(of: source), size: 28, radius: 3)
                Text(controller.alarmName(of: source)).role(.body).foregroundStyle(Theme.text)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Theme.popover, in: .rect(cornerRadius: Radius.small))
        })
        .sottovaMenu { playlist.map { MenuEntry.yours($0, controller: controller, router: router, navigate: navigate, renaming: renaming) } ?? [] }
    }
}

/// The foot's control: what silence is like between pieces, chosen from a native menu that opens upward.
private struct SilenceFoot: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var anchor = NSView()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Text("Silence").foregroundStyle(Theme.muted).padding(.top, 1)
                Spacer(minLength: 8)
                Text(controller.settings.name).foregroundStyle(Theme.text).lineLimit(1).padding(.top, 1)
                Ph.caretUpDown.icon(.line, size: 11).foregroundStyle(Theme.muted)
            }
            .role(.body)
            .sidebarRow(selected: false)
        }
        .buttonStyle(.plain)
        .background(AnchorView(view: anchor))
        .accessibilityLabel("Silence")
        .accessibilityValue(controller.settings.name)
    }

    private func open() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var presets = controller.allPresets
        if controller.settings.name == "Custom" { presets.append(controller.settings) }
        for preset in presets {
            let item = FootItem(title: preset.name) {
                if preset.name == "Custom" {
                    var saving = preset
                    saving.name = ""
                    router.presetEdit = PresetEdit(preset: saving)
                } else {
                    controller.apply(preset)
                }
            }
            item.attributedTitle = Self.title(preset)
            item.state = preset.name == controller.settings.name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if controller.customPresets.contains(where: { $0.name == controller.settings.name }) {
            let current = controller.settings
            menu.addItem(FootItem(title: "Edit \(current.name)…") {
                router.presetEdit = PresetEdit(preset: current, replacing: current.name)
            })
        }
        menu.addItem(FootItem(title: "New preset…") {
            var preset = controller.settings
            preset.name = ""
            preset.crossfade = false
            router.presetEdit = PresetEdit(preset: preset)
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height - 3 + menu.size.height), in: anchor)
    }

    /// The name, and its range in a right-aligned column.
    private static func title(_ preset: SottovaCore.Settings) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 13)
        let range = Format.range(preset).replacingOccurrences(of: "–", with: " to ")
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 160)]
        let title = NSMutableAttributedString(string: preset.name, attributes: [.font: font, .paragraphStyle: style])
        title.append(NSAttributedString(string: "\t\(range)", attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]))
        return title
    }

    private struct AnchorView: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private final class FootItem: NSMenuItem {
        private let run: () -> Void

        init(title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError("menus are built in code") }

        @objc private func fire() { run() }
    }
}
#endif
