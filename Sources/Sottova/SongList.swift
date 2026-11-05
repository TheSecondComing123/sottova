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
    /// What it's picked by, when that isn't the song: a collection's row.
    var key: String?
    /// The collection it's queued from, with its silence.
    var source: String?
    /// The page's own lines, after the song's in the right-click.
    var more: (() -> [MenuEntry])?
    let play: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.songOrder) private var order
    @Environment(\.appearsActive) private var active
    @Environment(\.songDrag) private var drag
    @Environment(\.songsLifted) private var liftedPick
    @State private var hovering = false
    @State private var lifted = false
    @State private var menuOpen = false
    @State private var naming = false

    private var id: String { key ?? song.id }

    private var picked: [Song] {
        guard router.selected.count > 1, router.selected.contains(id) else { return [song] }
        let ids = order.isEmpty ? Array(router.selected) : order.filter(router.selected.contains)
        return ids.compactMap { controller.catalog.songsByID[Playlist.path(ofRow: $0)] }
    }

    var body: some View {
        let isPicked = router.selected.contains(id)
        HStack(spacing: 0) {
            if columns.art {
                Artwork(key: song.artwork, size: 24, radius: 3, outlined: true)
                    .padding(.trailing, 10)
            }
            if let width = columns.who {
                name(song.who)
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
                    if let performer { name(performer) }
                }
                .frame(width: width)
            }
            if let width = columns.collection {
                name(song.album)
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
        .background {
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(isPicked ? Theme.picked.opacity(active ? 1 : 0.7) : Theme.hover.opacity(hovering ? 1 : 0))
        }
        .overlay {
            if menuOpen {
                RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.primary, lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        #if SHOT
        .onAppear { if UserDefaults.standard.string(forKey: "shotHoverSong") == song.title { hovering = true } }
        #endif
        .onTapGesture(count: 2, perform: play)
        .simultaneousGesture(TapGesture().onEnded { router.select(id, in: order) })
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityAction(named: "Play") { router.playRow(id) }
        .modifier(RowDrag(several: isPicked && router.selected.count > 1, id: id, path: song.id, namespace: drag) { dragStarted?() })
        .opacity(lifted || liftedPick.contains(id) ? 0.4 : 1)
        .onDragSessionUpdated { lifted = $0.phase.lifted }
        .sottovaMenu(open: { menuOpen = $0 }) {
            MenuEntry.song(song, picked: picked, source: source, play: { router.playRow(id) }, remove: remove, part: part, naming: { naming = true },
                           controller: controller, router: router, navigate: navigate)
                + (more?() ?? [])
        }
        .popover(isPresented: $naming, arrowEdge: .bottom) { NameCollection(songs: picked, open: $naming, name: MenuEntry.name(for: picked, controller: controller)) }
    }

    /// Plain words: a click on a row picks it, wherever it lands. Go to is in the right-click and the Song menu.
    private func name(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .role(.body)
            .foregroundStyle(Theme.muted)
    }
}

/// A row in a pick of several carries all of them; `.onDrag` can only carry its own.
private struct RowDrag: ViewModifier {
    let several: Bool
    let id: String
    let path: String
    let namespace: Namespace.ID?
    let started: () -> Void

    func body(content: Content) -> some View {
        if several, let namespace {
            content.draggable(containerItemID: id, containerNamespace: namespace)
        } else {
            content.onDrag {
                started()
                return NSItemProvider(object: URL(filePath: path) as NSURL)
            }
        }
    }
}

/// Around a list of `LibraryLine`s: what a drag of several picked rows carries, and what the keys act on.
struct SongListRun: ViewModifier {
    let order: [String]
    /// The collection whose silence they play with.
    var source: String?
    var remove: ((Set<String>) -> Void)?
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Namespace private var drag
    @State private var lifted: Set<String> = []

    func body(content: Content) -> some View {
        content
            .environment(\.songDrag, drag)
            .environment(\.songsLifted, lifted)
            .onDragSessionUpdated { session in
                lifted = session.phase.lifted ? Set(session.draggedItemIDs(for: String.self)) : []
            }
            .dragContainer(for: URL.self, itemID: \.path, in: drag) { (ids: [String]) in ids.map { URL(filePath: Playlist.path(ofRow: $0)) } }
            .dragContainerSelection(order.filter(router.selected.contains), containerNamespace: drag)
            .onChange(of: order, initial: true, register)
            // a rename moves the collection's id, and nothing else
            .onChange(of: source, register)
    }

    private func register() {
        router.run = SongRun(route: router.route, order: order, play: { [controller, order, source] keys in
            // a collection's missing files have rows, not places in what plays
            let rows = order.filter { controller.catalog.songsByID[Playlist.path(ofRow: $0)] != nil }
            controller.playPick(keys.compactMap(rows.firstIndex(of:)), of: rows.compactMap { controller.catalog.songsByID[Playlist.path(ofRow: $0)] },
                                source: source)
        }, remove: remove, source: source)
    }
}

private extension DragSession.Phase {
    var lifted: Bool { self == .initial || self == .active }
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
            .truncationMode(.tail)
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
        who = max(118, fit(songs.map(\.who), 160))
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
    /// Bumped to put the cursor in the filter.
    @State private var focusAsks = 0
    @Environment(\.listLayout) private var layout
    @MainActor private static var answeredSearch = 0
    @State private var fit = ColumnFit()

    private var narrow: Bool { layout.narrow }
    private var margin: CGFloat { layout.margin }
    @Environment(\.pageLayout) private var page
    /// The open queue floats 60 pt in from the right and is 320 wide: the list ends 24 short of it rather than
    /// running its headings under its edge. A narrow window hasn't the room, so there it still floats over.
    private var trailing: CGFloat { router.showsQueue && !page.narrowWindow ? 60 + 320 + 24 : margin }

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
                let picked = songs.filter { router.selected.contains($0.id) }
                PageScroll(insets: EdgeInsets(top: 16, leading: margin, bottom: 24, trailing: trailing), maxWidth: 1100) {
                    HStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 18) {
                            Text("Songs")
                                .role(.title)
                                .offset(y: -2)
                                .foregroundStyle(Theme.text)
                                .accessibilityAddTraits(.isHeader)
                            // centered on the count's line, so the buttons coming and going don't move it
                            HStack(spacing: 12) {
                                Text(count(of: songs.count, in: all.count, picked: picked.count, filtered: !needle.isEmpty))
                                    .role(.body)
                                    .foregroundStyle(Theme.faint)
                            }
                            .frame(height: 24)
                            .padding(.top, 13)
                        }
                        Spacer(minLength: 0)
                        SearchField(text: $router.songFilter, prompt: "Filter songs", focusAsks: focusAsks) { router.typing = $0 }
                            .padding(.horizontal, 6)
                            .fieldGround()
                            .frame(width: narrow ? 180 : 220)
                    }
                    .padding(.bottom, 19)
                    if !picked.isEmpty {
                        PickActions(picked: songs.indices.filter { router.selected.contains(songs[$0].id) }, list: songs)
                            .padding(.bottom, 12)
                    }
                    if songs.isEmpty {
                        HStack(spacing: 4) {
                            Text("Nothing matches “\(router.songFilter)”.").foregroundStyle(Theme.muted)
                            ThemeLink(text: "Clear the filter", style: .inline) { router.songFilter = "" }
                        }
                        .role(.body)
                        .padding(.top, 8)
                        // the keys and the Song menu act on what's shown, so on nothing here
                        .modifier(SongListRun(order: []))
                    } else {
                        headings(columns)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                LibraryLine(song: song, columns: columns, performer: song.performer) { controller.play(songs, from: index) }
                            }
                            .environment(\.songOrder, songs.map(\.id))
                        }
                        .modifier(SongListRun(order: songs.map(\.id)))
                        .padding(.leading, -22)
                        .padding(.trailing, -12)
                    }
                }
            }
        }
        // a library's every name measured, so only when they change: not on each redraw
        .onChange(of: ColumnFit.Key(catalog: controller.catalog.version, names: controller.playlists.map(\.name)), initial: true) {
            fit = ColumnFit(songs: all, collection: { $0.album })
        }
        .onAppear(perform: answerSearch)
        .onChange(of: router.searchRequests) { answerSearch() }
        .onDisappear { router.typing = false }
    }

    private func answerSearch() {
        guard router.searchRequests != Self.answeredSearch else { return }
        Self.answeredSearch = router.searchRequests
        focusAsks += 1
    }

    private func count(of shown: Int, in all: Int, picked: Int, filtered: Bool) -> String {
        if picked > 0 { return "\(picked) picked" }
        if filtered { return shown == 0 ? "" : "\(shown) of \(all)" }
        return Format.count(all, "song")
    }

    private func headings(_ columns: LineColumns) -> some View {
        HStack(spacing: 0) {
            heading("Artist / composer", .who).frame(width: columns.who, alignment: .leading)
            heading("Title", .title).frame(maxWidth: .infinity, alignment: .leading)
            if !narrow {
                heading("Performer", .performer).frame(width: columns.performer, alignment: .leading)
                heading("Album", .album).frame(width: columns.collection, alignment: .leading)
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

/// AppKit's own search field: its magnifier, its clear ×, and Esc to empty it.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusAsks: Int
    let typing: (Bool) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .exterior
        field.isBezeled = false
        field.drawsBackground = false
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.answered != focusAsks else { return }
        context.coordinator.answered = focusAsks
        // the field may not be in its window yet on the first pass
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var answered = 0

        init(parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            parent.text = (note.object as? NSSearchField)?.stringValue ?? ""
        }

        func controlTextDidBeginEditing(_ note: Notification) { parent.typing(true) }
        func controlTextDidEndEditing(_ note: Notification) { parent.typing(false) }

        /// Esc empties it and gives the keys back to the list.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.text = ""
            control.stringValue = ""
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}

/// Named actions for one song or a pick of several.
struct PickActions: View {
    /// Places in `list`.
    let picked: [Int]
    let list: [Song]
    var source: String?
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var naming = false

    private var songs: [Song] { picked.map { list[$0] } }

    var body: some View {
        HStack(spacing: 8) {
            // as Return plays it
            if let state = controller.pickState(picked, of: list, source: source), !state.paused {
                ThemeButton(title: "Pause", primary: true, icon: .pause) { controller.pause() }
            } else {
                ThemeButton(title: "Play", primary: true, icon: .play) { controller.playPick(picked, of: list, source: source) }
            }
            ThemeLink(text: "Play next", color: Theme.muted) { controller.playNext(songs, source: source) }
                .role(.body)
            Menu {
                ForEach(Array(MenuEntry.collections(songs, name: "", controller: controller) { naming = true }.enumerated()), id: \.offset) { _, entry in
                    if case .action(let action) = entry.kind { Button(entry.title, action: action) } else { Divider() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Add to").role(.body).foregroundStyle(Theme.muted)
                    Ph.caretDown.icon(.bold, size: 8).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 4)
                .frame(height: 24)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $naming, arrowEdge: .bottom) { NameCollection(songs: songs, open: $naming, name: MenuEntry.name(for: songs, controller: controller)) }
            #if SHOT
            .onAppear { naming = UserDefaults.standard.bool(forKey: "shotNameCollection") }
            #endif
            if songs.count == 1, let song = songs.first {
                ThemeLink(text: "Trim…", color: Theme.muted) { router.trimming = song }
                    .role(.body)
            }
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
        controller.newPlaylist(named: name, songs: songs).map { navigate(.playlist($0)) }
    }
}

/// Everyone in the library from the Go menu, each with a cover from their songs. A tile opens Songs filtered to them.
struct NameList: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        if controller.catalog.songs.isEmpty {
            EmptyLibrary(what: "artists")
        } else {
            PageScroll(insets: EdgeInsets(top: 16, leading: 40, bottom: 24, trailing: 40), maxWidth: 1040) {
                Text("Artists")
                    .role(.title)
                    .offset(y: -2)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 19)
                LazyVStack(spacing: 0) {
                    ForEach(Person.all(in: controller.catalog.songs)) { person in
                        PersonTile(person: person) { navigate(.artist(person.name)) }
                    }
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
            HStack(spacing: 12) {
                Artwork(key: person.artwork, size: 40, radius: 3, outlined: true)
                    .accessibilityLabel("album artwork from \(person.name)'s songs")
                    .accessibilityHidden(person.artwork == nil)
                Text(person.name)
                    .font(Role.item.font)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(count)
                    .role(.small)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8)
            .frame(height: 52)
            .background(hovering ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.small))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.995))
        .onHover { hovering = $0 }
        .accessibilityLabel("\(person.name), \(count)")
    }
}
