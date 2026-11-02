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
    @State private var hovering = false

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
                    .frame(width: width, alignment: .leading)
            }
            LineTitle(song: song)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let width = columns.performer {
                Group {
                    if let performer { name(performer) { navigate(.artist(performer)) } }
                }
                .frame(width: width, alignment: .leading)
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
        .background(Theme.selection.opacity(hovering || isPicked ? 1 : 0), in: .rect(cornerRadius: Radius.small))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .simultaneousGesture(TapGesture().onEnded { router.select(song.id, in: order) })
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityAction(named: "Play", play)
        .onDrag {
            dragStarted?()
            return NSItemProvider(object: URL(filePath: song.id) as NSURL)
        }
        .sottovaMenu {
            MenuEntry.song(song, picked: picked, play: play, remove: remove, part: part, controller: controller, router: router, navigate: navigate)
        }
    }

    private func name(_ text: String, go: @escaping () -> Void) -> some View {
        LinkText(text: text, action: go)
            .role(.body)
            .foregroundStyle(Theme.muted)
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

/// Songs: name first, the filter always there, a click on a heading sorts by it.
struct SongList: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @AppStorage("songsSort") private var sort = SongSort.who
    @AppStorage("songsSortReversed") private var reversed = false
    @FocusState private var filtering: Bool
    @State private var width: CGFloat = 1024
    @MainActor private static var answeredSearch = 0

    private var narrow: Bool { width < 860 }
    private var margin: CGFloat { narrow ? 32 : 40 }

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
                let columns = columns(all)
                PageScroll(insets: EdgeInsets(top: 16, leading: margin, bottom: 24, trailing: margin)) {
                    HStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 18) {
                            Text("Songs")
                                .role(.title)
                                .offset(y: -2)
                                .foregroundStyle(Theme.text)
                                .accessibilityAddTraits(.isHeader)
                            Text(count(of: songs.count, in: all.count, filtered: !needle.isEmpty))
                                .role(.body)
                                .foregroundStyle(Theme.faint)
                                .padding(.top, 16)
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
                        .padding(.horizontal, -12)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear(perform: answerSearch)
        .onChange(of: router.searchRequests) { answerSearch() }
        .onDisappear { router.typing = false }
    }

    private func answerSearch() {
        guard router.searchRequests != Self.answeredSearch else { return }
        Self.answeredSearch = router.searchRequests
        filtering = true
    }

    /// From the whole library, so typing in the filter doesn't move them.
    private func columns(_ songs: [Song]) -> LineColumns {
        let fit = { (names: [String], most: CGFloat) -> CGFloat in
            let widest = Set(names).map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 0
            return min(max(widest + 23, 76), most).rounded()
        }
        let who = fit(songs.map(\.who), 160)
        return narrow ? LineColumns(who: who) : LineColumns(who: who, performer: fit(songs.compactMap(\.performer), 190),
                                                            collection: fit(songs.map { controller.copy(ofAlbum: $0.albumID)?.name ?? $0.album }, 180))
    }

    private func count(of shown: Int, in all: Int, filtered: Bool) -> String {
        if router.selected.count > 1 { return "\(router.selected.count) of \(all) picked" }
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
        .padding(.leading, 20)
        .frame(height: 22)
    }

    private func heading(_ title: String, _ column: SongSort) -> some View {
        Button {
            if sort == column { reversed.toggle() } else { (sort, reversed) = (column, false) }
        } label: {
            Text(title)
                .role(.column)
                .foregroundStyle(sort == column ? Theme.muted : Theme.faint)
        }
        .buttonStyle(.plain)
        .accessibilityValue(sort == column ? (reversed ? "sorted, reversed" : "sorted") : "")
    }
}

/// A plain list of names from the Go menu, in place of the artist tiles. A name opens Songs filtered to it.
struct NameList: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        let names = Set(controller.catalog.songs.map(\.who)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        PageScroll(insets: EdgeInsets(top: 16, leading: 40, bottom: 24, trailing: 40)) {
            Text("Artists")
                .role(.title)
                .offset(y: -2)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 19)
            ForEach(names, id: \.self) { name in
                LinkText(text: name) { navigate(.artist(name)) }
                    .foregroundStyle(Theme.text)
                    .role(.body)
                    .frame(height: 28)
            }
        }
    }
}
