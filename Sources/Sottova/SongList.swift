import AppKit
import SwiftUI
import SottovaCore

/// Who's in a song's row and how wide. Songs and a collection share the row, not the columns.
struct LineColumns {
    var who: CGFloat?
    /// The right-hand name, under whatever heading.
    var performer: CGFloat?
    var collection: CGFloat?
    var art = false
    var height: CGFloat = 28
    /// Left of Who: room for the speaker, inside the row's hover plate.
    var gutter: CGFloat = 32
    var markerX: CGFloat = 12
}

/// The row behind Songs and a collection's parts: click picks, double-click plays, right-click and drag as anywhere.
struct LibraryLine: View {
    let song: Song
    let columns: LineColumns
    var performer: String?
    var remove: ((Set<String>) -> Void)?
    var dragStarted: (() -> Void)?
    var part: (starts: Bool, flip: () -> Void)?
    let play: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.songOrder) private var order
    @Environment(\.appearsActive) private var active
    @Environment(\.songDrag) private var drag
    @State private var hovering = false
    @State private var naming = false

    private var picked: [Song] {
        guard router.selected.count > 1, router.selected.contains(song.id) else { return [song] }
        let ids = order.isEmpty ? Array(router.selected) : order.filter(router.selected.contains)
        return ids.compactMap { controller.catalog.songsByID[$0] }
    }

    var body: some View {
        let isPicked = router.selected.contains(song.id)
        HStack(spacing: 0) {
            if columns.art {
                Artwork(key: song.artwork, size: 24, radius: 3, outlined: true)
                    .padding(.trailing, 10)
            }
            if let width = columns.who {
                name(song.who) { navigate(.artist(song.who)) }
                    // a name cut short still doesn't touch the title
                    .padding(.trailing, 12)
                    .frame(width: width, alignment: .leading)
            }
            LineTitle(song: song)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let width = columns.performer {
                // the clear keeps the column where a song has no performer, so no title runs under the heading
                ZStack(alignment: .leading) {
                    Color.clear
                    if let performer { name(performer) { navigate(.artist(performer)) } }
                }
                .frame(width: width)
            }
            if let width = columns.collection {
                name(controller.copy(ofAlbum: song.albumID)?.name ?? song.album) { navigate(.album(song.albumID)) }
                    .frame(width: width, alignment: .leading)
            }
            Text(Format.time(song.duration))
                .role(.body)
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.leading, columns.gutter)
        .padding(.trailing, 12)
        .frame(height: columns.height)
        .background(alignment: .leading) { LineMarker(song: song).offset(x: columns.markerX) }
        .background(Theme.selection.opacity(hovering || (isPicked && active) ? 1 : isPicked ? 0.5 : 0), in: .rect(cornerRadius: Radius.small))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .simultaneousGesture(TapGesture().onEnded { router.select(song.id, in: order) })
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityAction(named: "Play", play)
        .modifier(RowDrag(several: isPicked && router.selected.count > 1, id: song.id, namespace: drag) { dragStarted?() })
        .sottovaMenu {
            MenuEntry.song(song, picked: picked, play: play, remove: remove, part: part, naming: { naming = true },
                           controller: controller, router: router, navigate: navigate)
        }
        .popover(isPresented: $naming, arrowEdge: .bottom) { NameCollection(songs: picked, open: $naming, name: MenuEntry.name(for: picked, controller: controller)) }
    }

    private func name(_ text: String, go: @escaping () -> Void) -> some View {
        LinkText(text: text) {
            // the row's own tap has picked it; while picking, or on the click that brings the window forward, stay here
            let keys = NSEvent.modifierFlags
            guard !router.press.activating, router.press.picks < 2, !keys.contains(.command), !keys.contains(.shift) else { return }
            go()
        }
            .role(.body)
            .foregroundStyle(Theme.muted)
    }
}

/// A row in a pick of several carries all of them; `.onDrag` can only carry its own.
private struct RowDrag: ViewModifier {
    let several: Bool
    let id: String
    let namespace: Namespace.ID?
    let started: () -> Void

    func body(content: Content) -> some View {
        if several, let namespace {
            content.draggable(containerItemID: id, containerNamespace: namespace)
        } else {
            content.onDrag {
                started()
                return NSItemProvider(object: URL(filePath: id) as NSURL)
            }
        }
    }
}

/// Around a list of `LibraryLine`s: what a drag of several picked rows carries, and what the keys act on.
struct SongListRun: ViewModifier {
    let order: [String]
    let play: (String) -> Void
    var remove: ((Set<String>) -> Void)?
    @Environment(Router.self) private var router
    @Namespace private var drag

    func body(content: Content) -> some View {
        content
            .environment(\.songDrag, drag)
            .dragContainer(for: URL.self, itemID: \.path, in: drag) { (ids: [String]) in ids.map { URL(filePath: $0) } }
            .dragContainerSelection(order.filter(router.selected.contains), containerNamespace: drag)
            .onChange(of: order, initial: true) {
                router.run = SongRun(route: router.route, order: order, play: play, remove: remove)
            }
    }
}

/// Their own views, so a change of track re-renders them and not the row.
private struct LineTitle: View {
    let song: Song
    @Environment(Controller.self) private var controller

    var body: some View {
        let sounding = controller.sounding?.id == song.id
        Text(song.title)
            .role(.body)
            .fontWeight(sounding ? .medium : .regular)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityValue(sounding ? "playing" : "")
    }
}

private struct LineMarker: View {
    let song: Song
    @Environment(Controller.self) private var controller

    var body: some View {
        if controller.sounding?.id == song.id {
            Ph.speakerHigh.icon(size: 14)
                .foregroundStyle(controller.status == .playing ? Theme.primary : Theme.muted)
        }
    }
}

/// Column widths from the whole library, so typing in the filter doesn't move them.
private struct ColumnFit {
    struct Key: Equatable {
        let catalog: UUID
        let names: [String]
    }

    var who: CGFloat = 160
    var performer: CGFloat = 190
    var collection: CGFloat = 180

    init() {}

    init(songs: [Song], collection name: (Song) -> String) {
        let fit = { (names: [String], most: CGFloat) -> CGFloat in
            let widest = Set(names).map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 0
            return min(max(widest + 23, 76), most).rounded()
        }
        who = fit(songs.map(\.who), 160)
        performer = fit(songs.compactMap(\.performer), 190)
        collection = fit(songs.map(name), 180)
    }

    func columns(narrow: Bool) -> LineColumns {
        narrow ? LineColumns(who: who, gutter: 22, markerX: 0)
            : LineColumns(who: who, performer: performer, collection: collection, gutter: 22, markerX: 0)
    }
}

/// Songs: name first, the filter always there, a click on a heading sorts by it.
struct SongList: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @AppStorage("songsSort") private var sort = SongSort.who
    @AppStorage("songsSortReversed") private var reversed = false
    @FocusState private var filtering: Bool
    @Environment(\.listLayout) private var layout
    @MainActor private static var answeredSearch = 0
    @State private var fit = ColumnFit()

    private var narrow: Bool { layout.narrow }
    private var margin: CGFloat { layout.margin }

    var body: some View {
        @Bindable var router = router
        let all = controller.catalog.songs
        Group {
            if all.isEmpty {
                EmptyLibrary(what: "songs")
            } else {
                let needle = Song.folded(router.songFilter)
                let sorted = controller.catalog.songs(by: sort, matching: needle)
                let songs: [Song] = reversed ? sorted.reversed() : sorted
                let columns = fit.columns(narrow: narrow)
                PageScroll(insets: EdgeInsets(top: 16, leading: margin, bottom: 24, trailing: margin)) {
                    HStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 18) {
                            Text("Songs")
                                .role(.title)
                                .offset(y: -2)
                                .foregroundStyle(Theme.text)
                                .accessibilityAddTraits(.isHeader)
                            // centered on the count's line, so the buttons coming and going don't move it
                            HStack(spacing: 12) {
                                Text(count(of: songs.count, in: all.count, filtered: !needle.isEmpty))
                                    .role(.body)
                                    .foregroundStyle(Theme.faint)
                                if router.selected.count > 1 {
                                    PickActions(songs: songs.filter { router.selected.contains($0.id) })
                                        .transition(.opacity)
                                }
                            }
                            .frame(height: 24)
                            .padding(.top, 13)
                            .animation(Theme.quick, value: router.selected.count > 1)
                        }
                        Spacer(minLength: 0)
                        TextField("Filter", text: $router.songFilter, prompt: Text(""))
                            .role(.body)
                            .foregroundStyle(Theme.text)
                            // AppKit draws a prompt in its own gray, whatever color it's given
                            .overlay(alignment: .leading) {
                                if router.songFilter.isEmpty { Text("Filter").role(.body).foregroundStyle(Theme.faint).allowsHitTesting(false) }
                            }
                            .focused($filtering)
                            .onExitCommand { router.songFilter = ""; filtering = false }
                            .onChange(of: filtering) { _, focused in router.typing = focused }
                            .modifier(FieldLook(focused: filtering))
                            .frame(width: narrow ? 180 : 220)
                    }
                    .padding(.bottom, 19)
                    if songs.isEmpty {
                        HStack(spacing: 4) {
                            Text("Nothing matches “\(router.songFilter)”.").foregroundStyle(Theme.muted)
                            ThemeLink(text: "Clear the filter", underlined: true) { router.songFilter = "" }
                        }
                        .role(.body)
                        .padding(.top, 8)
                    } else {
                        headings(columns)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                LibraryLine(song: song, columns: columns, performer: song.performer) { controller.play(songs, from: index) }
                            }
                            .environment(\.songOrder, songs.map(\.id))
                        }
                        .modifier(SongListRun(order: songs.map(\.id)) { id in
                            if let index = songs.firstIndex(where: { $0.id == id }) { controller.play(songs, from: index) }
                        })
                        .padding(.leading, -22)
                        .padding(.trailing, -12)
                    }
                }
            }
        }
        // a library's every name measured, so only when they change: not on each redraw
        .onChange(of: ColumnFit.Key(catalog: controller.catalog.version, names: controller.playlists.map(\.name)), initial: true) {
            fit = ColumnFit(songs: all, collection: { controller.copy(ofAlbum: $0.albumID)?.name ?? $0.album })
        }
        .onAppear(perform: answerSearch)
        .onChange(of: router.searchRequests) { answerSearch() }
        .onDisappear { router.typing = false }
    }

    private func answerSearch() {
        guard router.searchRequests != Self.answeredSearch else { return }
        Self.answeredSearch = router.searchRequests
        filtering = true
    }

    private func count(of shown: Int, in all: Int, filtered: Bool) -> String {
        if router.selected.count > 1 { return "\(router.selected.count) picked" }
        if filtered { return shown == 0 ? "" : "\(shown) of \(all)" }
        return Format.count(all, "song")
    }

    private func headings(_ columns: LineColumns) -> some View {
        HStack(spacing: 0) {
            heading("Who", .who).frame(width: columns.who, alignment: .leading)
            heading("Title", .title).frame(maxWidth: .infinity, alignment: .leading)
            if !narrow {
                heading("Performer", .performer).frame(width: columns.performer, alignment: .leading)
                heading("Collection", .album).frame(width: columns.collection, alignment: .leading)
            }
            heading("Time", .longest).frame(width: 40, alignment: .trailing)
        }
        .frame(height: 22)
    }

    private func heading(_ title: String, _ column: SongSort) -> some View {
        Button {
            if sort == column { reversed.toggle() } else { (sort, reversed) = (column, false) }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == column {
                    // up from the top of the order, down when the order starts at its largest
                    Ph.caretDown.icon(.bold, size: 8).rotationEffect(reversed == (column == .longest) ? .degrees(180) : .zero)
                }
            }
            .role(.column)
            .foregroundStyle(sort == column ? Theme.muted : Theme.faint)
        }
        .buttonStyle(.plain)
        .accessibilityValue(sort == column ? (reversed ? "sorted, reversed" : "sorted") : "")
    }
}

/// What a pick of several can do, beside its count.
private struct PickActions: View {
    let songs: [Song]
    @Environment(Controller.self) private var controller
    @State private var naming = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(MenuEntry.collections(songs, name: "", controller: controller) { naming = true }.enumerated()), id: \.offset) { _, entry in
                    if case .action(let action) = entry.kind { Button(entry.title, action: action) } else { Divider() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Add to").role(.body).foregroundStyle(Theme.text)
                    Ph.caretDown.icon(.bold, size: 8).foregroundStyle(Theme.muted)
                }
                .padding(.leading, 11)
                .padding(.trailing, 9)
                .frame(height: 24)
                .background(Theme.selection, in: .rect(cornerRadius: Radius.small))
                .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.stroke, lineWidth: 0.5) }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $naming, arrowEdge: .bottom) { NameCollection(songs: songs, open: $naming, name: MenuEntry.name(for: songs, controller: controller)) }
            #if SHOT
            .onAppear { naming = UserDefaults.standard.bool(forKey: "shotNameCollection") }
            #endif
            ThemeButton(title: "Play next") { controller.playNext(songs) }
        }
    }
}

/// Asks what a new collection of `songs` is called, makes it and opens it.
struct NameCollection: View {
    let songs: [Song]
    @Binding var open: Bool
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @State private var name: String
    @FocusState private var typing: Bool

    /// Named before the field takes focus, so the name comes up selected and typing replaces it.
    init(songs: [Song], open: Binding<Bool>, name: String) {
        (self.songs, _open, _name) = (songs, open, State(initialValue: name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(songs.count == 1 ? "New collection with this song" : "New collection with these \(songs.count) songs")
                .role(.body)
                .foregroundStyle(Theme.muted)
            TextField("Name", text: $name, prompt: Text(""))
                .role(.body)
                .foregroundStyle(Theme.text)
                .focused($typing)
                .defaultFocus($typing, true)
                .onSubmit(create)
                .onExitCommand { open = false }
                .modifier(FieldLook(focused: typing))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ThemeButton(title: "Cancel") { open = false }
                ThemeButton(title: "Create", primary: true, action: create)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        open = false
        controller.newCollection(named: name, songs: songs).map { navigate(.playlist($0)) }
    }
}

/// Everyone in the library from the Go menu, each with a cover from their songs. A tile opens Songs filtered to them.
struct NameList: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        PageScroll(insets: EdgeInsets(top: 16, leading: 40, bottom: 24, trailing: 40)) {
            Text("Artists")
                .role(.title)
                .offset(y: -2)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 19)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                ForEach(Person.all(in: controller.catalog.songs)) { person in
                    PersonTile(person: person) { navigate(.artist(person.name)) }
                }
            }
        }
    }
}

private struct PersonTile: View {
    let person: Person
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let count = person.songs == 1 ? "1 song" : "\(person.songs) songs"
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Artwork(key: person.artwork, radius: Radius.small, outlined: true, title: person.name, initials: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.name).role(.body).fontWeight(.medium).foregroundStyle(Theme.text).underline(hovering).lineLimit(1)
                    Text(count).role(.body).foregroundStyle(Theme.muted)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .accessibilityLabel("\(person.name), \(count)")
    }
}
