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
        // rows fade out under the floating player bar instead of showing through the strip beneath it
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

/// One row of tiles that scrolls sideways, so a shelf never wraps an orphan onto a second line.
private struct Shelf<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 4) {
                ForEach(items) { item in
                    cell(item).frame(width: 188)
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -32)
    }

    /// Whether `count` tiles run past a page `width` wide, so "Show all" only appears when some are out of sight.
    /// 188 pt cells 4 apart, 24 pt insets, and the shelf bleeds 32 pt past the page on each side.
    static func overflows(_ count: Int, in width: CGFloat) -> Bool {
        48 + CGFloat(count) * 192 - 4 > width + 64
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

struct SongsPage: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @AppStorage("songSort") private var sort = SongSort.title
    @State private var filter = ""
    @FocusState private var filtering: Bool

    var body: some View {
        let all = controller.catalog.songs
        if all.isEmpty {
            EmptyLibrary(what: "songs")
        } else {
            let needle = Song.folded(filter)
            let songs = controller.catalog.songs(by: sort, matching: needle)
            PageScroll {
                let art = songs.contains { $0.artwork != nil }
                let albums = Set(songs.map(\.albumID)).count > 1
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Songs")
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 8) {
                            Text((needle.isEmpty ? Format.count(all.count, "song") : "\(songs.count) of \(all.count) songs")
                                 + " · \(Format.length(songs.reduce(0) { $0 + $1.duration })) ·")
                                .foregroundStyle(Theme.muted)
                            sortMenu
                        }
                        .font(.system(size: 13))
                    }
                    HStack(spacing: 16) {
                        PlayRow(songs: songs)
                        Spacer(minLength: 0)
                        filterField
                    }
                }
                .padding(.bottom, 24)
                if songs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("no songs match “\(filter)”")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        LinkText(text: "clear filter") { filter = "" }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 24)
                } else {
                    SongColumns(showsArt: art, showsAlbum: albums)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRow(song: song, number: index + 1, showsArt: art, showsAlbum: albums) { controller.play(songs, from: index) }
                        }
                        .environment(\.songOrder, songs.map(\.id))
                    }
                }
            }
        }
    }

    /// The order, read as part of the sentence above the list: "72 songs, 6 h 2 min · by title ⌄".
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SongSort.menu, id: \.self) { Text($0.label.prefix(1).uppercased() + $0.label.dropFirst()).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(sort.label)
                Ph.caretDown.icon(.bold, size: 10)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Ph.magnifyingGlass.icon(size: 14)
                .foregroundStyle(Theme.faint)
            TextField("filter songs", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($filtering)
                .onExitCommand { filter = ""; filtering = false }
                .onChange(of: filtering) { _, focused in router.typing = focused }
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 32)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filtering ? Theme.muted : Theme.border))
        .animation(Theme.quick, value: filtering)
    }
}

/// Yours and the ones that came with your files, in one grid.
struct CollectionsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let collections = controller.collections
        if collections.isEmpty {
            EmptyLibrary(what: "collections")
        } else {
            PageScroll {
                PageHeader(title: "Collections", detail: Format.count(collections.count, "collection"), songs: [])
                LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                    ForEach(collections) { CollectionTile(collection: $0) }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

/// Beside Shuffle: the gaps a collection plays with and how long they make it, opening the choice. Its border
/// darkens when it has gaps of its own, like a filter that's on.
struct GapsButton: View {
    let title: String
    let songs: [Song]
    @Binding var gaps: SottovaCore.Settings?
    @Environment(Controller.self) private var controller
    @State private var open = false

    var body: some View {
        let duration = songs.reduce(0) { $0 + $1.duration }
        let s = gaps?.gaps(over: controller.yourSettings) ?? controller.yourSettings
        let paced = s.lengthWithGaps(count: songs.count, music: duration)
        Button { open = true } label: {
            HStack(spacing: 8) {
                Text(s.crossfade ? "Crossfades" : "\(s.name) gaps")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if paced > duration {
                    Text(Format.length(paced))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Ph.caretDown.icon(.bold, size: 10)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(gaps == nil ? Theme.border : Theme.muted))
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .help(paced > duration ? "about \(Format.length(paced)) with the gaps" : "choose the gaps between these")
        // pinned to the label's start, which stays put while the label's length changes with each choice
        .popover(isPresented: $open, attachmentAnchor: .point(.bottomLeading), arrowEdge: .bottom) {
            AlbumGaps(title: title, gaps: $gaps)
        }
    }
}

/// Which gaps an album plays with, laid out like Settings > Playback: the score of what it'll sound like, then the
/// choices as cards, then the range and fades when it has its own.
private struct AlbumGaps: View {
    let title: String
    @Binding var gaps: SottovaCore.Settings?
    @Environment(Controller.self) private var controller

    var body: some View {
        let own = gaps
        let yours = controller.yourSettings
        VStack(alignment: .leading, spacing: 0) {
            Text("Gaps for \(title)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .lineLimit(1)
            Text("only for this one; everything else keeps yours")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)
                .padding(.bottom, 16)

            ScoreDiagram(settings: own?.gaps(over: yours) ?? yours, height: 112)
                .padding(.bottom, 12)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                // Yours, then every preset, three to a row
                let cells = controller.allPresets.count + 1
                ForEach(Array(stride(from: 0, to: cells, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + 3, cells), id: \.self) { cell in
                            if cell == 0 {
                                card(named("Your setting", yours), active: own == nil, accent: nil) { gaps = nil }
                            } else {
                                preset(cell - 1, own)
                            }
                        }
                    }
                }
                GridRow {
                    card(named("Custom", own ?? yours), active: own?.name == "Custom", accent: 2 + 4 * controller.allPresets.count) {
                        var custom = own ?? yours
                        custom.name = "Custom"
                        custom.crossfade = false
                        gaps = custom
                    }
                    .gridCellColumns(3)
                }
            }

            if own?.name == "Custom" {
                caption("Silence between songs")
                GapRange(low: field(\.gapMin), high: field(\.gapMax))
                    .padding(.horizontal, 12)
                caption("Fades")
                HStack(spacing: 12) {
                    ValueStepper(label: "In", value: field(\.fadeIn), range: 0...20, unit: "s")
                    ValueStepper(label: "Out", value: field(\.fadeOut), range: 0...20, unit: "s")
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        // its own ground so the edge shows against the page; the cards, score and steppers keep their borders on it
        .presentationBackground(Theme.raised)
        .animation(Theme.quick, value: own?.name)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func preset(_ index: Int, _ own: SottovaCore.Settings?) -> some View {
        let preset = controller.allPresets[index]
        return card(preset, active: own?.name == preset.name, accent: 2 + 4 * index) { gaps = preset }
    }

    private func named(_ name: String, _ settings: SottovaCore.Settings) -> SottovaCore.Settings {
        var s = settings
        s.name = name
        return s
    }

    private func card(_ settings: SottovaCore.Settings, active: Bool, accent: Int?, action: @escaping () -> Void) -> some View {
        PresetCard(preset: settings, active: active, accent: accent, action: action)
    }

    private func field(_ path: WritableKeyPath<SottovaCore.Settings, Double>) -> Binding<Double> {
        Binding(get: { gaps?[keyPath: path] ?? 0 },
                set: { gaps?[keyPath: path] = $0 })
    }
}

/// A playlist laid out like an album: its cover, name and gaps, then its songs. Drop songs on a row to put them
/// there; drag a row onto another to move it.
struct PlaylistPage: View {
    let id: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    @State private var art: CGFloat = 232
    /// Renaming moves the file, so the id changes under the page.
    @State private var renamedTo: String?
    @Environment(Router.self) private var router
    @State private var editing = false
    @State private var name = ""
    @State private var target: Int?
    /// The row a drag inside this list started from.
    @State private var dragFrom: Int?
    @FocusState private var typing: Bool

    private var pid: String { renamedTo ?? id }

    var body: some View {
        if let playlist = controller.playlists.first(where: { $0.id == pid }) {
            let songs = controller.songs(of: playlist)
            let duration = songs.reduce(0) { $0 + $1.duration }
            let missing = playlist.paths.count - songs.count
            PageScroll {
                HStack(alignment: .bottom, spacing: 32) {
                    Artwork(key: controller.playlistCovers[pid] ?? songs.first?.artwork, size: art, radius: 12, outlined: true,
                            title: playlist.name)
                    VStack(alignment: .leading, spacing: 12) {
                        title(playlist)
                        Text([Format.count(playlist.paths.count, "song"), Format.length(duration), missing > 0 ? "\(missing) missing" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                        CoverCredit(url: Controller.coverURL(forPlaylist: pid), key: controller.playlistCovers[pid])
                        AlarmLine(source: pid)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
                .background(alignment: .top) {
                    if let key = controller.playlistCovers[pid] ?? songs.first?.artwork {
                        ArtWash(key: key)
                            .frame(height: art + 200)
                            .padding(.horizontal, -32)
                            .padding(.top, -12)
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: songs, source: pid, more: AnyView(HStack(spacing: 16) {
                    if !songs.isEmpty {
                        GapsButton(title: playlist.name, songs: songs, gaps: Binding(
                            get: { playlist.gaps }, set: { controller.setGaps($0, for: pid) }))
                    }
                    menu(playlist)
                }))
                    .padding(.bottom, 24)

                if playlist.paths.isEmpty {
                    Text("drag songs here from any page")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Theme.accent(for: playlist.name).opacity(target == 0 ? 0.14 : 0), in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(target == 0 ? Theme.accent(for: playlist.name) : Theme.border,
                                                                                 style: StrokeStyle(lineWidth: target == 0 ? 1.5 : 1, dash: [4, 4])))
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, at: 0, in: playlist) } isTargeted: { target = $0 ? 0 : nil }
                } else {
                    SongColumns()
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playlist.paths.enumerated()), id: \.offset) { index, path in
                            // where a part starts, a thin rule with its number; part 1 is named once there are others
                            if index == 0 && !playlist.breaks.isEmpty || playlist.breaks.contains(index) {
                                PartRule(number: playlist.breaks.count { $0 <= index } + 1, name: playlist.partNames[index], removable: index > 0) {
                                    controller.namePart($0, at: index, in: pid)
                                } join: {
                                    withAnimation(Theme.quick) { controller.setBreak(false, at: index, in: pid) }
                                }
                            }
                            row(path, at: index, in: playlist, songs: songs)
                                .overlay(alignment: .top) { insertionLine(playlist, at: index) }
                                .dropDestination(for: URL.self) { urls, _ in drop(urls, at: index, in: playlist) } isTargeted: { on in
                                    if on { target = index } else if target == index { target = nil }
                                }
                        }
                        .environment(\.songOrder, playlist.paths)
                        // below the last row: drop to add at the end
                        Color.clear
                            .frame(height: 48)
                            .overlay(alignment: .top) { insertionLine(playlist, at: playlist.paths.count) }
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, at: playlist.paths.count, in: playlist) } isTargeted: { on in
                                if on { target = playlist.paths.count } else if target == playlist.paths.count { target = nil }
                            }
                    }
                }
            }
            .onAppear {
                if renaming.wrappedValue == pid { startRename(playlist) }
            }
            .onChange(of: renaming.wrappedValue) { _, new in
                if new == pid { startRename(playlist) }
            }
        } else {
            Missing(text: "this collection isn't in your library anymore")
        }
    }

    @ViewBuilder
    private func title(_ playlist: Playlist) -> some View {
        if editing {
            // the same type as the title, so nothing moves when it turns into a field
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 48, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.text)
                .focused($typing)
                .accessibilityLabel("collection name")
                .onSubmit { commitRename() }
                .onExitCommand { endRename() }
                .onChange(of: typing) { _, focused in
                    router.typing = focused
                    if !focused { commitRename() }
                }
        } else {
            Text(playlist.name)
                .font(.system(size: 48, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .onTapGesture(count: 2) { startRename(playlist) }
                .help("double-click to rename")
        }
    }

    private func menu(_ playlist: Playlist) -> some View {
        MoreMenu {
            Button("Rename") { startRename(playlist) }
            Button("Choose cover…") { router.coverFor = .playlist(pid) }
            Button("Start at…") { router.alarm = .new(.playlist(pid)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: pid)]) }
            Divider()
            Button("Move to Trash") {
                if controller.alarmsLost(trashing: playlist).isEmpty {
                    navigate(.home)
                    controller.trashPlaylist(pid)
                } else {
                    router.trashing = pid
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ path: String, at index: Int, in playlist: Playlist, songs: [Song]) -> some View {
        if let song = controller.catalog.songsByID[path] {
            // where this row sits among the songs that can play
            let playable = playlist.paths[..<index].count { controller.catalog.songsByID[$0] != nil }
            SongRow(song: song, number: index + 1, remove: { ids in
                // one row is this row, even when the song is in here twice
                let rows = ids == [path] ? IndexSet([index]) : IndexSet(playlist.paths.indices.filter { ids.contains(playlist.paths[$0]) })
                withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: rows) }
            }, dragStarted: { dragFrom = index }, part: index == 0 ? nil : (playlist.breaks.contains(index), {
                withAnimation(Theme.quick) { controller.setBreak(!playlist.breaks.contains(index), at: index, in: pid) }
            })) {
                controller.play(songs, from: playable, source: pid)
            }
        } else {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .frame(width: 28)
                Color.clear.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(filePath: path).deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                    Text("file not found")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                Spacer()
                Text("–")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 60)
            .help(path)
            .sottovaMenu {
                [.item("Remove from this collection") { withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: [index]) } }]
            }
        }
    }

    /// Where a drop will land: a 2 pt line in the playlist's color at the title's left edge.
    private func insertionLine(_ playlist: Playlist, at index: Int) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent(for: playlist.name))
            .frame(height: 2)
            .padding(.leading, 52)
            .offset(y: -1)
            .opacity(target == index ? 1 : 0)
    }

    /// A song already in the playlist moves to `index`; anything else is added there.
    private func drop(_ urls: [URL], at index: Int, in playlist: Playlist) -> Bool {
        target = nil
        let paths = urls.map { $0.standardizedFileURL.path }
        withAnimation(Theme.quick) {
            // a song already here moves rather than being added twice; add a copy from the context menu. Dragged from
            // this list, it's the row it was dragged from, which matters when the song is in here twice
            let dragged = dragFrom.flatMap { playlist.paths.indices.contains($0) && paths == [playlist.paths[$0]] ? $0 : nil }
            dragFrom = nil
            if paths.count == 1, let from = dragged ?? playlist.paths.firstIndex(of: paths[0]) {
                controller.movePlaylistSongs(pid, fromOffsets: [from], toOffset: index)
            } else {
                let songs = paths.compactMap { controller.catalog.songsByID[$0] }
                controller.add(songs, to: pid, at: index)
            }
        }
        return true
    }

    private func startRename(_ playlist: Playlist) {
        name = playlist.name
        editing = true
        renaming.wrappedValue = nil
        DispatchQueue.main.async {
            typing = true
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commitRename() {
        guard editing else { return }
        if let renamed = controller.rename(pid, to: name), renamed != pid {
            renamedTo = renamed
        }
        endRename()
    }

    private func endRename() {
        editing = false
        typing = false
    }
}

/// The … button beside a collection's gaps.
/// A part's name or number over the song that starts it, with a way to rename it and to join it to the part before.
private struct PartRule: View {
    let number: Int
    let name: String?
    let removable: Bool
    let rename: (String) -> Void
    let join: () -> Void
    @Environment(Router.self) private var router
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 12) {
            if editing {
                TextField("Part \(number)", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .focused($typing)
                    .fixedSize()
                    .onSubmit(commit)
                    .onExitCommand(perform: end)
                    .onChange(of: typing) { _, focused in
                        router.typing = focused
                        if !focused { commit() }
                    }
            } else {
                Text(name ?? "Part \(number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .help("double-click to rename")
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if removable {
                IconButton(icon: .x, weight: .bold, help: "join the part before", size: 20, action: join)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, number == 1 ? 0 : 16)
        .frame(height: number == 1 ? 24 : 40, alignment: .bottom)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: start)
        .sottovaMenu {
            [.item("Rename", action: start)] + (removable ? [.item("Join the part before", action: join)] : [])
        }
    }

    private func start() {
        draft = name ?? ""
        editing = true
        DispatchQueue.main.async {
            typing = true
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commit() {
        guard editing else { return }
        rename(draft)
        end()
    }

    private func end() {
        editing = false
        typing = false
    }
}

struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Ph.dotsThree.icon(.bold, size: 16)
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .hoverable(radius: 8)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("more")
        .accessibilityLabel("more")
    }
}

struct AlbumPage: View {
    let id: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(Router.self) private var router
    @State private var art: CGFloat = 232

    var body: some View {
        if let album = controller.catalog.albumsByID[id] {
            PageScroll {
                HStack(alignment: .bottom, spacing: 32) {
                    Artwork(key: album.artwork, size: art, radius: 12, outlined: true, title: album.title, subtitle: album.artist)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(album.title)
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 0) {
                            LinkText(text: album.artist) { navigate(.artist(album.artist)) }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(" · " + [album.year.map(String.init), Format.count(album.songs.count, "song"), Format.length(album.duration)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                        }
                        CoverCredit(url: album.songs.first.map { URL(filePath: $0.id).deletingLastPathComponent().appending(path: "cover.jpg") },
                                    key: album.artwork)
                        AlarmLine(source: album.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { art = Format.heroArt(for: $0) }
                .background(alignment: .top) {
                    if let key = album.artwork {
                        ArtWash(key: key)
                            .frame(height: art + 200)
                            .padding(.horizontal, -32)
                            .padding(.top, -12)
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: album.songs, more: AnyView(HStack(spacing: 16) {
                    GapsButton(title: album.title, songs: album.songs, gaps: Binding(
                        get: { controller.albumSettings[album.id] }, set: { controller.albumSettings[album.id] = $0 }))
                    MoreMenu {
                        Button("Make it yours") { controller.makeYours(album).map { navigate(.playlist($0)) } }
                            // a copy is a list of files: what lands in the folder later isn't in it
                            .help("a copy you can reorder and add to. songs added to its folder later won't join it")
                        Button("Choose cover…") { router.coverFor = .album(album.id) }
                        Button("Start at…") { router.alarm = .new(.album(album.id)) }
                    }
                }))
                    .padding(.bottom, 24)

                LazyVStack(spacing: 0) {
                    ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, number: song.trackNumber ?? index + 1, showsArt: false, showsAlbum: false, albumArtist: album.artist) {
                            controller.play(album.songs, from: index)
                        }
                    }
                    .environment(\.songOrder, album.songs.map(\.id))
                }
            }
        } else {
            Missing(text: "this collection isn't in your library anymore")
        }
    }
}

struct ArtistsPage: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let artists = controller.catalog.artists
        if artists.isEmpty {
            EmptyLibrary(what: "artists")
        } else {
            PageScroll {
                PageHeader(title: "Artists", detail: Format.count(artists.count, "artist"), songs: [])
                // composers known only from tags; one with a page of its own links to its works from there
                let composers = controller.catalog.composers.filter { controller.catalog.artistsByName[$0] == nil }
                if !composers.isEmpty {
                    SectionTitle(title: "Composers")
                        .padding(.bottom, 8)
                    // a grid like the performers below: this is already the show-all page, and its columns line up
                    LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                        ForEach(composers, id: \.self) { ComposerTile(name: $0) }
                    }
                    .padding(.horizontal, -8)
                    .padding(.bottom, 32)
                    SectionTitle(title: "Performers")
                        .padding(.bottom, 8)
                }
                LazyVGrid(columns: albumGrid, alignment: .leading, spacing: 16) {
                    ForEach(artists) { ArtistTile(artist: $0) }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

private struct ComposerTile: View {
    let name: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        let works = controller.catalog.works(by: name)
        Tile(artwork: nil, circle: true, coverTitle: name, play: { controller.play(works.flatMap(\.recordings).shuffled(), shuffled: true) },
             open: { navigate(.composer(name)) }) {
            VStack(spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Format.count(works.count, "work"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// A composer's works set like a concert program: each work with its catalog number, then every recording of it.
struct ComposerPage: View {
    let name: String
    @Environment(Controller.self) private var controller

    var body: some View {
        let works = controller.catalog.works(by: name)
        if works.isEmpty {
            Missing(text: "nothing by \(name) in your library anymore")
        } else {
            let songs = works.flatMap(\.recordings)
            PageScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text(name)
                        .font(.system(size: 48, weight: .bold))
                        .tracking(-1.2)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text([Format.count(works.count, "work"), Format.count(songs.count, "recording"),
                          Format.length(songs.reduce(0) { $0 + $1.duration })].joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 24)
                .padding(.bottom, 32)

                PlayRow(songs: songs)
                    .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 24) {
                    ForEach(works) { work in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(work.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if let number = work.catalogNumber {
                                    Text(number)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.faint)
                                }
                            }
                            .padding(.horizontal, 12)
                            ForEach(Array(work.recordings.enumerated()), id: \.element.id) { index, song in
                                SongRow(song: song, number: index + 1, performerFirst: true) { controller.play(work.recordings, from: index) }
                            }
                            .environment(\.songOrder, work.recordings.map(\.id))
                        }
                    }
                }
            }
        }
    }
}

struct ArtistPage: View {
    let name: String
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate

    var body: some View {
        if let artist = controller.catalog.artistsByName[name] {
            let songs = artist.songs
            let collections = artist.albums.map { controller.copy(ofAlbum: $0.id).map(MusicCollection.yours) ?? .album($0) }
            let art = songs.contains { $0.artwork != nil }
            PageScroll {
                HStack(alignment: .bottom, spacing: 32) {
                    // initials on a 200 pt disc would be the loudest thing on the page; without a picture the name leads
                    if artist.artwork != nil {
                        Artwork(key: artist.artwork, size: 200, circle: true, outlined: true, title: artist.name)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(artist.name)
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 0) {
                            Text("\(Format.count(collections.count, "collection")) · \(Format.count(songs.count, "song"))")
                                .foregroundStyle(Theme.muted)
                            let works = controller.catalog.works(by: name).count
                            if works > 0 {
                                Text(" · ").foregroundStyle(Theme.muted)
                                LinkText(text: "\(Format.count(works, "work")) by work") { navigate(.composer(name)) }
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        .font(.system(size: 13))
                    }
                }
                .padding(.bottom, 32)

                PlayRow(songs: songs)
                    .padding(.bottom, 32)

                if !collections.isEmpty {
                    SectionTitle(title: "Collections")
                        .padding(.bottom, 8)
                    Shelf(items: collections) { CollectionTile(collection: $0) }
                        .padding(.bottom, 32)
                }

                SectionTitle(title: "Songs")
                    .padding(.bottom, 8)
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        // the artist's own name under every title would only repeat the page's
                        SongRow(song: song, number: index + 1, showsArt: art, albumArtist: name) { controller.play(songs, from: index) }
                    }
                    .environment(\.songOrder, songs.map(\.id))
                }
            }
        } else {
            Missing(text: "this artist isn't in your library anymore")
        }
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
