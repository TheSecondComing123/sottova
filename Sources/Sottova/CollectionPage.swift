import AppKit
import SwiftUI
import SottovaCore

/// Which columns a collection needs, from its songs: Who only when it says something, covers only when they differ and
/// Who doesn't already tell the rows apart.
struct CollectionColumns {
    let line: LineColumns
    let whoShown: Bool
    let artistsDiffer: Bool

    init(songs: [Song], narrow: Bool) {
        whoShown = songs.contains { $0.who != $0.artist } && Set(songs.map(\.who)).count > 1
        artistsDiffer = Set(songs.map(\.artist)).count > 1
        let art = !whoShown && Set(songs.compactMap(\.artwork)).count > 1
        let names = whoShown ? songs.compactMap(\.performer) : artistsDiffer ? songs.map(\.artist) : []
        // the longest name and some air, as the mock has it: 78 for Schubert, 130 for Louis Armstrong
        let widest = songs.map { ($0.who as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 0
        line = LineColumns(who: whoShown ? min((widest + 23).rounded(), 160) : nil,
                           performer: names.isEmpty || narrow ? nil : 168,
                           art: art, height: art ? 32 : 28, gutter: 22, markerX: 0)
    }

    func performer(of song: Song) -> String? {
        whoShown ? song.performer : artistsDiffer ? song.artist : nil
    }
}

/// `.cov` in the mock.
struct CoverImage: View {
    let key: String
    let size: CGFloat

    var body: some View {
        Artwork(key: key, size: size, radius: Radius.small)
            .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color(white: 0.5, opacity: 0.28), lineWidth: 1) }
    }
}

/// Cover and words over the songs, all scrolling together, at every width.
struct CollectionFrame<Name: View, Actions: View, Songs: View>: View {
    let cover: String?
    /// Picks the cover's ground when there's no painting.
    let title: String
    var dropTargeted = false
    /// The row it plays for, as words you can click.
    var row: Alarm?
    let lines: [String]
    /// Where the painting's credit is, and what re-reads it.
    var credit: (url: URL?, key: String?) = (nil, nil)
    @ViewBuilder let name: Name
    @ViewBuilder let actions: Actions
    @ViewBuilder let songs: (_ narrow: Bool) -> Songs
    @Environment(\.listLayout) private var layout

    var body: some View {
        PageScroll(insets: EdgeInsets(top: 16, leading: layout.margin, bottom: 24, trailing: layout.margin), maxWidth: 1240) {
            HStack(alignment: .bottom, spacing: 24) {
                art
                words
            }
            .padding(.bottom, 32)
            songs(layout.narrow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var art: some View {
        Group {
            if let cover {
                CoverImage(key: cover, size: layout.cover)
            } else {
                // its ground only: the name is the title beside it
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(Theme.coverGround(for: title))
                    .strokeBorder(Theme.border, lineWidth: 1)
                    .frame(width: layout.cover, height: layout.cover)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(Theme.primary.opacity(0.1))
                .strokeBorder(Theme.primary, lineWidth: 1)
                .opacity(dropTargeted ? 1 : 0)
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 0) {
            name
            if !lines.isEmpty {
                Text(lines.joined(separator: ", "))
                    .role(.body)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }
            if let row { RowLine(row: row).padding(.top, 2) }
            CoverCredit(url: credit.url, key: credit.key).padding(.top, 4)
            actions.padding(.top, 14)
        }
    }
}

/// When a collection's row plays and how, in the words Your day uses. The time opens the row.
private struct RowLine: View {
    let row: Alarm
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router

    var body: some View {
        let plan = DayPlan(alarms: controller.alarms)
        WordFlow {
            // a word like the rest, with their caret's room so the gaps match
            ThemeLink(text: plan.when(row), color: Theme.muted) { router.alarm = .edit(row) }.role(.body).padding(.trailing, WordMenu<EmptyView>.caret)
            // a collection's own parts say "next" on their heading
            let ownParts = controller.playlists.contains { $0.id == row.source && !$0.breaks.isEmpty }
            ForEach(plan.sentence(row, nextPart: row.rotates && !ownParts ? controller.nextPartName(for: row) : nil), id: \.text) { RowWord(alarm: row, piece: $0) }
        }
        .foregroundStyle(Theme.muted)
    }
}

/// Three dots, quieter than the buttons beside it: the rest of what a collection does.
struct CollectionMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Ph.dotsThree.icon(size: 14)
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .hoverable(radius: 4)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("more")
    }
}

/// Play, the same word and width whatever's going, as the title bar has the pause: sounding, it has nothing to do.
struct PlayButton: View {
    let songs: [Song]
    var source: String?
    @Environment(Controller.self) private var controller

    var body: some View {
        // going, it pauses; paused or not this one, it plays
        if let state = controller.collectionState(songs, source: source), !state.paused {
            ThemeButton(title: "Pause", primary: true, icon: .pause) { controller.pause() }
        } else {
            ThemeButton(title: "Play", primary: true, icon: .play) { controller.playCollection(songs, source: source) }
        }
    }
}

/// Shuffle, lit while this one is going shuffled; pressed again, a new order.
struct ShuffleButton: View {
    let songs: [Song]
    var source: String?
    @Environment(Controller.self) private var controller

    var body: some View {
        let on = controller.collectionState(songs, source: source)?.shuffled == true
        ThemeButton(title: "Shuffle", on: on, icon: .shuffle, iconWeight: .bold) { controller.play(songs.shuffled(), source: source, shuffled: true) }
            .help(on ? "playing shuffled; click for a new order" : "play in a random order")
            .accessibilityValue(on ? "on" : "")
    }
}

/// The silence a collection plays with, in its menu: yours, a preset, or typed for it alone.
struct SilenceChoices: View {
    let title: String
    let chosen: SottovaCore.Settings?
    let choose: (SottovaCore.Settings?) -> Void
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router

    var body: some View {
        Menu("Silence between songs") {
            Toggle("Your setting", isOn: Binding(get: { chosen == nil }, set: { _ in choose(nil) }))
            ForEach(controller.allPresets, id: \.name) { preset in
                Toggle(preset.name, isOn: Binding(get: { chosen?.name == preset.name }, set: { _ in choose(preset) }))
            }
            Divider()
            Toggle("Custom…", isOn: Binding(get: { chosen?.name == "Custom" }, set: { _ in custom() }))
        }
    }

    private func custom() {
        var own = chosen?.gaps(over: controller.yourSettings) ?? controller.yourSettings
        own.name = "Custom"
        own.crossfade = chosen?.name == "Custom" && own.crossfade
        router.presetEdit = PresetEdit(preset: own, collection: (title, choose))
    }
}

/// "Add to collection ▸" for a page's •••, as the right-click has it.
private struct AddToCollection: View {
    let songs: [Song]
    let name: String
    @Environment(Controller.self) private var controller

    var body: some View {
        Menu("Add to collection") {
            ForEach(controller.playlists) { playlist in
                Button(playlist.name) { controller.add(songs, to: playlist.id) }
            }
            if !controller.playlists.isEmpty { Divider() }
            Button("New collection") { controller.newPlaylist(named: name, songs: songs) }
        }
    }
}

/// Only when it isn't yours: what this collection's silence is and how long it makes it.
@MainActor
private func ownSilence(_ gaps: SottovaCore.Settings?, songs: [Song], controller: Controller) -> [String] {
    guard let gaps else { return [] }
    let music = songs.reduce(0) { $0 + $1.duration }
    let paced = gaps.gaps(over: controller.yourSettings).lengthWithGaps(count: songs.count, music: music)
    return ["\(gaps.name) silence" + (paced > music ? ", about \(Format.length(paced))" : "")]
}

private func songCount(_ songs: [Song]) -> String {
    "\(Format.count(songs.count, "song")), \(Format.length(songs.reduce(0) { $0 + $1.duration }))"
}

/// An album as it came with your files: flat rows. Reordering or parts take "Make it yours", said out loud.
struct AlbumCollection: View {
    let id: String
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate

    var body: some View {
        if let album = controller.catalog.albumsByID[id] {
            CollectionFrame(cover: album.artwork, title: album.title, row: DayPlan(alarms: controller.alarms).firstRow(of: id),
                            lines: [songCount(album.songs)]
                                + ownSilence(controller.albumSettings[id], songs: album.songs, controller: controller),
                            credit: (album.songs.first.map { URL(filePath: $0.id).deletingLastPathComponent().appending(path: "cover.jpg") }, album.artwork)) {
                Text(album.title)
                    .role(.title)
                    .offset(y: -2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(4)
                    .accessibilityAddTraits(.isHeader)
            } actions: {
                HStack(spacing: 6) {
                    PlayButton(songs: album.songs)
                    ShuffleButton(songs: album.songs)
                    ThemeButton(title: "Make it yours") { controller.makeYours(album).map { navigate(.playlist($0)) } }
                        .help("a copy you can add to, reorder and split")
                    CollectionMenu {
                        Button("Play next") { controller.playNext(album.songs) }
                        AddToCollection(songs: album.songs, name: album.title)
                        Divider()
                        Button("Start at…") { router.alarm = .new(.album(id)) }
                        SilenceChoices(title: album.title, chosen: controller.albumSettings[id]) { controller.albumSettings[id] = $0 }
                        Divider()
                        Button("Choose cover…") { router.coverFor = .album(id) }
                        if album.artist != "Various Artists" {
                            Divider()
                            Button("Go to \(album.artist)") { navigate(.artist(album.artist)) }
                        }
                    }
                }
            } songs: { narrow in
                let columns = CollectionColumns(songs: album.songs, narrow: narrow)
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                        LibraryLine(song: song, columns: columns.line, performer: columns.performer(of: song)) { controller.play(album.songs, from: index) }
                    }
                    .environment(\.songOrder, album.songs.map(\.id))
                }
                .modifier(SongListRun(order: album.songs.map(\.id)) { id in
                    if let index = album.songs.firstIndex(where: { $0.id == id }) { controller.play(album.songs, from: index) }
                })
                .padding(.leading, -22)
                .padding(.trailing, -12)
            }
        } else {
            Missing(text: "this collection isn't in your library anymore")
        }
    }
}

/// One of yours: a list of files, with parts. Drop songs on a row to put them there; drag a row onto another to move it.
struct YourCollection: View {
    let id: String
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    /// Renaming moves the file, so the id changes under the page, and undo moves it back.
    @State private var renamedTo: [String] = []
    @State private var editing = false
    @State private var name = ""
    @State private var target: Int?
    @State private var dragFrom: Int?
    /// A part heading on its way somewhere: the lines show only between parts.
    @State private var draggingPart: Int?
    /// A part just started, whose name field opens.
    @State private var naming: Int?
    /// Bumped by the header's Add songs: the field at the foot comes into view and takes the keys.
    @State private var addRequests = 0
    @FocusState private var typing: Bool

    private var pid: String { renamedTo.last { name in controller.playlists.contains { $0.id == name } } ?? id }

    var body: some View {
        if let playlist = controller.playlists.first(where: { $0.id == pid }) {
            let songs = controller.songs(of: playlist)
            let cover = controller.playlistCovers[pid] ?? songs.first?.artwork
            let isEmpty = playlist.paths.isEmpty
            let missing = playlist.paths.count - songs.count
            CollectionFrame(cover: cover, title: playlist.name, dropTargeted: isEmpty && target == 0, row: isEmpty ? nil : DayPlan(alarms: controller.alarms).firstRow(of: pid),
                            lines: isEmpty ? [] : [songCount(songs) + (missing > 0 ? ", \(missing) missing" : "")]
                                + ownSilence(isEmpty ? nil : playlist.gaps, songs: songs, controller: controller),
                            credit: (Controller.coverURL(forPlaylist: pid), controller.playlistCovers[pid])) {
                title(playlist)
            } actions: {
                HStack(spacing: 6) {
                    if !isEmpty {
                        PlayButton(songs: songs, source: pid)
                        ShuffleButton(songs: songs, source: pid)
                    }
                    // empty, the field under the header is already there
                    if !isEmpty {
                        ThemeButton(title: "Add songs", icon: .plus, iconWeight: .bold) { addRequests += 1 }
                    }
                    menu(playlist, songs: songs)
                }
            } songs: { narrow in
                if isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        addField(who: nil, alone: true)
                        Text("or drag songs or a folder here")
                            .role(.body)
                            .foregroundStyle(Theme.faint)
                            .padding(.leading, 22)
                    }
                    .padding(.leading, -22)
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
                    .contentShape(.rect)
                    .dropDestination(for: URL.self) { urls, _ in drop(urls, at: 0, in: playlist) } isTargeted: { target = $0 ? 0 : nil }
                } else {
                    rows(playlist, songs: songs, narrow: narrow)
                }
            }
            .onAppear {
                if renaming.wrappedValue == pid { startRename(playlist) }
                #if SHOT
                if UserDefaults.standard.string(forKey: "shotAddQuery") != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { addRequests += 1 }
                }
                #endif
            }
            .onChange(of: renaming.wrappedValue) { _, new in
                if new == pid { startRename(playlist) }
            }
            .onChange(of: pid, initial: true) { router.shownCollection = pid }
            .onChange(of: router.addSongsRequests) { addRequests += 1 }
            .onChange(of: router.newPartRequests) { if router.selected.count > 1 { newPartFromPick(playlist) } }
        } else {
            Missing(text: "this collection isn't in your library anymore")
                .onAppear {
                    router.shownCollection = nil
                    // gone by an undo of New collection or Make it yours: leave, as Move to Trash does
                    router.leave(.playlist(id))
                }
        }
    }

    private func rows(_ playlist: Playlist, songs: [Song], narrow: Bool) -> some View {
        let columns = CollectionColumns(songs: songs, narrow: narrow)
        let next = Set(controller.alarms.filter { $0.source == pid && $0.rotates }.map { controller.partChoices(for: $0).next })
        let keys = playlist.paths.indices.filter { controller.catalog.songsByID[playlist.paths[$0]] != nil }.map { Playlist.rowKey($0, playlist.paths[$0]) }
        return VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(playlist.identifiedPaths, id: \.id) { _, index, path in
                    if index == 0 && !playlist.breaks.isEmpty || playlist.breaks.contains(index) {
                        let part = playlist.breaks.count { $0 <= index }
                        PartHeading(index: index, number: part + 1, name: playlist.partNames[index], length: partLength(playlist, from: index),
                                    next: next.contains(part), last: part == playlist.breaks.count, naming: $naming) {
                            controller.namePart($0, at: index, in: pid)
                        } move: { by in
                            withAnimation(Theme.quick) { controller.movePart(part, to: part + by, in: pid) }
                        } join: {
                            withAnimation(Theme.quick) { controller.setBreak(false, at: index, in: pid) }
                        } drag: {
                            draggingPart = part
                            return NSItemProvider(object: Self.partURL(part) as NSURL)
                        }
                        .padding(.leading, 22)
                        .padding(.trailing, 12)
                        // in the gap over the heading
                        .overlay(alignment: .top) { insertionLine(at: index, part: true).padding(.top, index == 0 ? 0 : 14) }
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, at: index, in: playlist) } isTargeted: { on in
                            if on { target = index } else if target == index { target = nil }
                        }
                    }
                    row(path, at: index, in: playlist, songs: songs, columns: columns)
                        .modifier(SplitTarget(index: index, on: index > 0 && !playlist.breaks.contains(index)) {
                            withAnimation(Theme.quick) { controller.setBreak(true, at: index, in: pid) }
                            naming = index
                        })
                        // the arrows' scroll target on a stand-in: on the row, an id with the index in it would make a moved row new
                        .background { Color.clear.id(Playlist.rowKey(index, path)) }
                        .overlay(alignment: .top) { insertionLine(at: index) }
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, at: index, in: playlist) } isTargeted: { on in
                            if on { target = index } else if target == index { target = nil }
                        }
                }
                .environment(\.songOrder, keys)
            }
            // below the last row, out of the lazy stack so Add songs can always reach it: drop to add at the end
            addField(who: columns.line.who)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .overlay(alignment: .top) { insertionLine(at: playlist.paths.count) }
                .dropDestination(for: URL.self) { urls, _ in drop(urls, at: playlist.paths.count, in: playlist) } isTargeted: { on in
                    if on { target = playlist.paths.count } else if target == playlist.paths.count { target = nil }
                }
        }
        .modifier(SongListRun(order: keys, play: { key in
            if let index = keys.firstIndex(of: key) { controller.play(songs, from: index, source: pid) }
        }, remove: { keys in
            guard let current = controller.playlists.first(where: { $0.id == pid }) else { return }
            remove(current.rows(keys))
        }))
        .padding(.leading, -22)
        .padding(.trailing, -12)
    }

    private func partLength(_ playlist: Playlist, from start: Int) -> Double {
        let end = playlist.breaks.filter { $0 > start }.min() ?? playlist.paths.count
        return playlist.paths[start..<end].reduce(0) { $0 + (controller.catalog.songsByID[$1]?.duration ?? 0) }
    }

    @ViewBuilder
    private func row(_ path: String, at index: Int, in playlist: Playlist, songs: [Song], columns: CollectionColumns) -> some View {
        if let song = controller.catalog.songsByID[path] {
            let playable = playlist.paths[..<index].count { controller.catalog.songsByID[$0] != nil }
            let key = Playlist.rowKey(index, path)
            LibraryLine(song: song, columns: columns.line, performer: columns.performer(of: song), remove: { _ in
                // the menu offers the pick only when this row is in it
                remove(router.selected.count > 1 && router.selected.contains(key) ? playlist.rows(router.selected) : [index])
            }, dragStarted: {
                dragFrom = index
                draggingPart = nil
            }, part: index == 0 ? nil : (playlist.breaks.contains(index), {
                withAnimation(Theme.quick) { controller.setBreak(!playlist.breaks.contains(index), at: index, in: pid) }
            }), key: key, more: {
                guard router.selected.count > 1, router.selected.contains(key) else { return [] }
                return [.item("New part from selection") { newPartFromPick(playlist) }]
            }) {
                controller.play(songs, from: playable, source: pid)
            }
            .modifier(RowEdits(index: index, sounding: controller.sounding?.id == path) { remove([index]) })
        } else {
            HStack(spacing: 0) {
                Text(URL(filePath: path).deletingPathExtension().lastPathComponent).lineLimit(1)
                Spacer(minLength: 16)
                Text("File not found")
            }
            .role(.body)
            .foregroundStyle(Theme.faint)
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .frame(height: 28)
            .help(path)
            .sottovaMenu {
                [.item("Remove from this collection") { remove([index]) }]
            }
        }
    }

    /// Over a row while songs are dragged; over a heading, or the foot, while a part is.
    private func insertionLine(at index: Int, part: Bool = false) -> some View {
        Rectangle()
            .fill(Theme.primary)
            .frame(height: 2)
            .padding(.leading, 22)
            .offset(y: -1)
            .opacity(target == index && (part == (draggingPart != nil) || index == controller.playlists.first { $0.id == pid }?.paths.count) ? 1 : 0)
    }

    private static func partURL(_ part: Int) -> URL { URL(string: "sottova-part:\(part)")! }

    /// A song already here moves to `index`; anything else is added there, a folder as the songs of it you have. A
    /// part lands only between parts.
    private func drop(_ urls: [URL], at index: Int, in playlist: Playlist) -> Bool {
        target = nil
        if let url = urls.first, url.scheme == "sottova-part", let part = Int(url.absoluteString.dropFirst("sottova-part:".count)) {
            draggingPart = nil
            guard let place = (playlist.partStarts + [playlist.paths.count]).firstIndex(of: index) else { return false }
            withAnimation(Theme.quick) { controller.movePart(part, to: place > part ? place - 1 : place, in: pid) }
            return true
        }
        let paths = urls.map { $0.standardizedFileURL.path }
        let folders = urls.filter(\.hasDirectoryPath).map { $0.standardizedFileURL.path(percentEncoded: false) }
        withAnimation(Theme.quick) {
            let dragged = dragFrom.flatMap { playlist.paths.indices.contains($0) && paths == [playlist.paths[$0]] ? $0 : nil }
            dragFrom = nil
            let picked = playlist.rows(router.selected)
            if paths.count == 1, folders.isEmpty, let from = dragged ?? playlist.paths.firstIndex(of: paths[0]) {
                move([from], to: index, in: playlist)
            } else if paths.count > 1, folders.isEmpty, picked.map({ playlist.paths[$0] }) == paths {
                // several picked rows dragged within the list: move them, don't copy
                move(picked, to: index, in: playlist)
            } else {
                let inFolders = controller.catalog.songs.filter { song in folders.contains { song.id.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
                router.selected = []
                controller.add(paths.compactMap { controller.catalog.songsByID[$0] } + inFolders, to: pid, at: index)
            }
        }
        return true
    }

    private func addField(who: CGFloat?, alone: Bool = false) -> some View {
        AddSongs(requests: addRequests, have: Set(controller.playlists.first { $0.id == pid }?.paths ?? []), who: who, alone: alone) { song in
            withAnimation(Theme.quick) { controller.add([song], to: pid) }
            if let paths = controller.playlists.first(where: { $0.id == pid })?.paths, let last = paths.indices.last {
                router.selected = [Playlist.rowKey(last, paths[last])]
            }
        }
    }

    private func remove(_ rows: IndexSet) {
        router.selected = []
        withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: rows) }
    }

    /// Picked rows stay picked where they land.
    private func move(_ rows: IndexSet, to index: Int, in playlist: Playlist) {
        let wasPicked = rows.allSatisfy { router.selected.contains(Playlist.rowKey($0, playlist.paths[$0])) }
        controller.movePlaylistSongs(pid, fromOffsets: rows, toOffset: index)
        guard wasPicked, let moved = controller.playlists.first(where: { $0.id == pid }) else { return }
        let start = index - rows.count { $0 < index }
        router.selected = Set((start..<start + rows.count).map { Playlist.rowKey($0, moved.paths[$0]) })
    }

    @ViewBuilder
    private func title(_ playlist: Playlist) -> some View {
        if editing {
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .role(.title)
                .offset(y: -2)
                .foregroundStyle(Theme.text)
                .focused($typing)
                .accessibilityLabel("collection name")
                .onSubmit(commitRename)
                .onExitCommand(perform: endRename)
                .onDisappear { router.typing = false }
                .onChange(of: typing) { _, focused in
                    router.typing = focused
                    if !focused { commitRename() }
                }
        } else {
            Text(playlist.name)
                .role(.title)
                .offset(y: -2)
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .accessibilityAddTraits(.isHeader)
                .onTapGesture { startRename(playlist) }
                .pointerStyle(.horizontalText)
                .help("click to rename")
                .accessibilityAction(named: "Rename") { startRename(playlist) }
        }
    }

    private func menu(_ playlist: Playlist, songs: [Song]) -> some View {
        CollectionMenu {
            Button("Choose cover…") { router.coverFor = .playlist(pid) }
            SilenceChoices(title: playlist.name, chosen: playlist.gaps) { controller.setGaps($0, for: pid) }
            Button("Start at…") { router.alarm = .new(.playlist(pid)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: pid)]) }
            Divider()
            Button("Move to Trash") {
                if controller.alarmsLost(trashing: playlist).isEmpty {
                    router.leave(.playlist(pid))
                    controller.trashPlaylist(pid)
                } else {
                    router.trashing = pid
                }
            }
        }
    }

    private func newPartFromPick(_ playlist: Playlist) {
        let rows = playlist.rows(router.selected)
        withAnimation(Theme.quick) { controller.newPart(from: rows, in: pid) }
        router.selected = []
        if let first = rows.first { naming = first }
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
            renamedTo.append(renamed)
        }
        endRename()
    }

    private func endRename() {
        editing = false
        typing = false
    }
}

/// At the foot of a collection, and all of an empty one: type, and your library's songs come up under it to add.
private struct AddSongs: View {
    let requests: Int
    /// What's in the collection already: those come after the rest, so Return adds something new.
    let have: Set<String>
    /// The rows' Who column, so a hit's names line up with theirs.
    let who: CGFloat?
    /// The only Add songs on an empty collection: it shows it's a field before it's hovered.
    let alone: Bool
    let add: (Song) -> Void
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let needle = Song.folded(query)
        let found = needle.isEmpty ? [] : controller.catalog.songs(by: .who, matching: needle)
        let hits = Array((found.filter { !have.contains($0.id) } + found.filter { have.contains($0.id) }).prefix(8))
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    TextField("Add songs", text: $query, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .role(.body)
                        .foregroundStyle(Theme.text)
                        // AppKit draws a prompt in its own gray, whatever color it's given
                        .overlay(alignment: .leading) {
                            if query.isEmpty { Text("Add songs").role(.body).foregroundStyle(focused ? Theme.muted : Theme.faint).allowsHitTesting(false) }
                        }
                        .focused($focused)
                        .onSubmit {
                            if let first = hits.first, !have.contains(first.id) {
                                add(first)
                                query = ""
                            }
                            focused = true
                        }
                        .onExitCommand {
                            query = ""
                            focused = false
                        }
                }
                // on the rows' text column, the glass in the gutter before it, as the Songs filter has
                .padding(.leading, 22)
                .padding(.trailing, 12)
                .frame(height: 28)
                .overlay(alignment: .leading) {
                    Ph.magnifyingGlass.icon(size: 12).foregroundStyle(Theme.faint).padding(.leading, 5).allowsHitTesting(false)
                }
                .background(Theme.selection.opacity(focused || hovering ? 1 : alone ? 0.5 : 0), in: .rect(cornerRadius: Radius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.muted, lineWidth: 1).opacity(focused ? 1 : 0)
                }
                .contentShape(.rect)
                .onHover { hovering = $0 }
                .onTapGesture { focused = true }
                .id("add")
                ForEach(Array(hits.enumerated()), id: \.element.id) { index, song in
                    AddHit(song: song, top: index == 0 && !have.contains(song.id), here: have.contains(song.id), who: who) {
                        add(song)
                        focused = true
                    }
                }
            }
            .onChange(of: focused) { _, on in router.typing = on }
            .onDisappear { router.typing = false }
            .onChange(of: requests) {
                withAnimation(Theme.quick) { proxy.scrollTo("add", anchor: .center) }
                focused = true
            }
            .onAppear {
                #if SHOT
                if let typed = UserDefaults.standard.string(forKey: "shotAddQuery") { query = typed }
                #endif
            }
        }
    }
}

/// A song from the library under the add field: its [+] adds it, and so does Return on the top one.
private struct AddHit: View {
    let song: Song
    let top: Bool
    let here: Bool
    let who: CGFloat?
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(song.who)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.trailing, 12)
                .frame(width: who, alignment: .leading)
            Text(song.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            if here {
                Text("already here").foregroundStyle(Theme.faint).padding(.trailing, 16)
            }
            Text(Format.time(song.duration))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(width: 40, alignment: .trailing)
        }
        .role(.body)
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: Radius.small).fill(Theme.selection.opacity(hovering ? 1 : top ? 0.5 : 0)).padding(.trailing, here ? 0 : -18)
        }
        // past the time, where a row's × sits
        .overlay(alignment: .trailing) {
            if !here {
                Button(action: add) {
                    Ph.plus.icon(.bold, size: 10)
                        .foregroundStyle(hovering ? Theme.text : Theme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .help(top ? "add it (Return)" : "add it")
                .accessibilityLabel("Add \(song.title)")
                .offset(x: 14)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !here { add() } }
    }
}

/// On hover, a grip where the speaker sits and an × past the time, both drawn over the row so nothing moves.
/// The whole row drags; the grip says so. Remove is in the right-click too.
private struct RowEdits: ViewModifier {
    let index: Int
    let sounding: Bool
    let remove: () -> Void
    @State private var row = false
    @State private var cross = false

    func body(content: Content) -> some View {
        let shown = row || cross
        content
            .onHover { row = $0 }
            // on the ×, the pointer is past the row, whose own plate goes: this one, the same shape, stays
            .background {
                RoundedRectangle(cornerRadius: Radius.small).fill(Theme.selection.opacity(cross ? 1 : 0))
            }
            .overlay(alignment: .leading) {
                // the speaker already marks the row that's playing
                if shown && !sounding {
                    Ph.dotsSixVertical.icon(.bold, size: 12)
                        .foregroundStyle(Theme.faint)
                        .frame(width: 14, height: 28)
                        .pointerStyle(.grabIdle)
                }
            }
            .overlay(alignment: .trailing) {
                Button(action: remove) {
                    Ph.x.icon(.bold, size: 9)
                        .foregroundStyle(cross ? Theme.text : Theme.faint)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .help("remove from this collection")
                .accessibilityLabel("Remove from this collection")
                .onHover { cross = $0 }
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                // in the list's right margin, past the plate, which ends in the gap after the time
                .offset(x: 20)
            }
            .onAppear {
                #if SHOT
                if UserDefaults.standard.object(forKey: "shotEditRow") != nil, UserDefaults.standard.integer(forKey: "shotEditRow") == index { cross = true }
                #endif
            }
    }
}

/// On the seam over a row: after a moment's hover on the row's top edge, a hairline says "New part", and a click
/// starts one there. Until it shows it takes no clicks, so picking near a row's edge never splits.
private struct SplitTarget: ViewModifier {
    let index: Int
    let on: Bool
    let split: () -> Void
    @State private var near = false
    @State private var seam = false

    func body(content: Content) -> some View {
        if on {
            content
                .overlay(alignment: .top) {
                    // the label on the line at its end, just short of the times so it doesn't crowd them
                    ZStack(alignment: .trailing) {
                        Rectangle().fill(Theme.muted).frame(height: 1)
                        Text("New part").role(.column).foregroundStyle(Theme.muted).fixedSize()
                            .padding(.horizontal, 6)
                            .background(Theme.background)
                            .padding(.trailing, 46)
                    }
                    .opacity(seam ? 1 : 0)
                    .animation(Theme.curve(seam ? 0.12 : 0.08), value: seam)
                    // thin, so the rows keep nearly all of their height for picking
                    .frame(height: 8)
                    .contentShape(.rect)
                    .padding(.leading, 22)
                    .padding(.trailing, 12)
                    .offset(y: -4)
                    .onTapGesture(perform: split)
                    .allowsHitTesting(seam)
                    .help("start a new part here")
                    .accessibilityElement()
                    .accessibilityLabel("Start a new part here")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, split)
                }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { near = point.y < 6 } else { near = false }
                }
                .task(id: near) {
                    guard near else { seam = false; return }
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { seam = true }
                }
                .onAppear {
                    #if SHOT
                    let defaults = UserDefaults.standard
                    if defaults.object(forKey: "shotSplit") != nil, defaults.integer(forKey: "shotSplit") == index { near = true }
                    #endif
                }
        } else {
            content
        }
    }
}

/// A part's name, length and whether a row plays it next, over the song that starts it. Click the name to rename it.
private struct PartHeading: View {
    let index: Int
    let number: Int
    let name: String?
    let length: Double
    let next: Bool
    let last: Bool
    @Binding var naming: Int?
    let rename: (String) -> Void
    let move: (Int) -> Void
    let join: () -> Void
    let drag: () -> NSItemProvider
    @Environment(Router.self) private var router
    @State private var editing = false
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var first: Bool { number == 1 }
    private var unnamed: String { "Part \(number)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if editing {
                    field
                } else {
                    Text(name ?? unnamed)
                        .role(.row)
                        .foregroundStyle(name == nil ? Theme.muted : Theme.text)
                        .lineLimit(1)
                        .onTapGesture(perform: start)
                        .pointerStyle(.horizontalText)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityAction(named: "Rename", start)
                }
                Text(Format.length(length))
                    .role(.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .fixedSize()
                if next {
                    Text("next").role(.body).foregroundStyle(Theme.primary).fixedSize()
                }
                Spacer(minLength: 24)
            }
            .frame(height: 22)
            .overlay(alignment: .trailing) {
                let shown = hovering && !editing
                CollectionMenu {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        if case .action(let action) = entry.kind { Button(entry.title, action: action) } else { Divider() }
                    }
                }
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .animation(Theme.curve(shown ? 0.12 : 0.08), value: shown)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 6).padding(.bottom, 4)
        }
        .padding(.top, first ? 0 : 28)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        // the whole heading drags; the name inside keeps its text cursor for renaming
        .pointerStyle(.grabIdle)
        .onDrag(drag)
        .sottovaMenu { entries }
        .onChange(of: naming, initial: true) { _, new in
            if new == index {
                naming = nil
                start()
            }
        }
        .onAppear {
            #if SHOT
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "shotNaming") == name ?? unnamed { draft = name ?? unnamed; editing = true }
            if defaults.string(forKey: "shotPartHover") == name ?? unnamed { hovering = true }
            #endif
        }
    }

    private var entries: [MenuEntry] {
        var entries: [MenuEntry] = [.item("Rename", action: start)]
        if !first { entries.append(.item("Move up") { move(-1) }) }
        if !last { entries.append(.item("Move down") { move(1) }) }
        if !first { entries += [.divider, .item("Join the part before", action: join)] }
        return entries
    }

    /// In place on the same line, its ring drawn around it, so nothing under it moves.
    private var field: some View {
        let width = (draft as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Role.row.size, weight: .medium)]).width
        return TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .role(.row)
            .foregroundStyle(Theme.text)
            .focused($typing)
            .accessibilityLabel("part name")
            .onSubmit(commit)
            .onExitCommand(perform: end)
            .onDisappear { router.typing = false }
            .onChange(of: typing) { _, focused in
                router.typing = focused
                if !focused { commit() }
            }
            .frame(width: max(160, width.rounded(.up) + 24) - 16)
            .padding(.horizontal, 8)
            .background { Color.clear.modifier(FieldLook(focused: true)) }
            .padding(.leading, -8)
    }

    private func start() {
        draft = name ?? unnamed
        editing = true
        DispatchQueue.main.async {
            typing = true
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commit() {
        guard editing else { return }
        // "Part 3" left as it was stays a number, so it follows the part's place
        if name != nil || draft.trimmingCharacters(in: .whitespaces) != unnamed { rename(draft) }
        end()
    }

    private func end() {
        editing = false
        typing = false
    }
}

/// Every collection, in day order, from Collections in the sidebar: yours, then the folders.
struct CollectionGrid: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming

    var body: some View {
        let plan = DayPlan(alarms: controller.alarms)
        let collections = controller.collections
        let order = plan.inDayOrder(collections.map(\.id))
        let ordered = order.compactMap { id in collections.first { $0.id == id } }
        let yours = ordered.filter { if case .yours = $0 { true } else { false } }
        let folders = ordered.filter { if case .album = $0 { true } else { false } }
        PageScroll(insets: EdgeInsets(top: 16, leading: 40, bottom: 24, trailing: 40)) {
            HStack(alignment: .center) {
                Text("Collections")
                    .role(.title)
                    .offset(y: -2)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                ThemeButton(title: "New", icon: .plus, iconWeight: .line) {
                    guard let id = controller.newPlaylist() else { return }
                    renaming.wrappedValue = id
                    navigate(.playlist(id))
                }
            }
            .padding(.bottom, 27)
            // one kind alone needs no heading
            let headed = !yours.isEmpty && !folders.isEmpty
            VStack(alignment: .leading, spacing: 40) {
                section(headed ? "Yours" : nil, yours, plan: plan)
                section(headed ? "Folders" : nil, folders, plan: plan)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String?, _ collections: [MusicCollection], plan: DayPlan) -> some View {
        if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if let title { GroupHead(title: title) }
                LazyVGrid(columns: TileGrid.columns, alignment: .leading, spacing: TileGrid.rowGap) {
                    ForEach(collections) { CollectionCard(collection: $0, hours: plan.shortHours(of: $0.id)) }
                }
            }
        }
    }
}

private struct CollectionCard: View {
    let collection: MusicCollection
    let hours: String?
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    @State private var hovering = false
    @State private var targeted = false

    private var cover: String? {
        switch collection {
        case .album(let album): album.artwork
        case .yours(let playlist): controller.playlistCovers[playlist.id] ?? controller.songs(of: playlist).first?.artwork
        }
    }

    private var songs: [Song] {
        switch collection {
        case .album(let album): album.songs
        case .yours(let playlist): controller.songs(of: playlist)
        }
    }

    private var playlist: Playlist? {
        if case .yours(let playlist) = collection { playlist } else { nil }
    }

    private var shown: Bool {
        #if SHOT
        if UserDefaults.standard.string(forKey: "shotHoverTile") == collection.title { return true }
        #endif
        return hovering
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Button(action: open) {
                    Artwork(key: cover, radius: Radius.small, outlined: true, title: collection.title)
                }
                .buttonStyle(PressStyle(scale: 0.98))
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(Theme.primary.opacity(0.1))
                    .strokeBorder(Theme.primary)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
                if !songs.isEmpty {
                    PlayButton(songs: songs, source: playlist?.id)
                        .padding(10)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                }
            }
            HStack(alignment: .top, spacing: 4) {
                TileCaption(title: collection.title, detail: hours ?? (songs.isEmpty ? "no songs yet" : nil))
                Spacer(minLength: 0)
                TileDots(title: collection.title, entries: entries)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
            }
            .contentShape(.rect)
            .onTapGesture { open() }
        }
        .animation(Theme.curve(shown ? 0.12 : 0.08), value: shown)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([collection.title, hours].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .dropDestination(for: URL.self) { urls, _ in
            guard let playlist else { return false }
            let songs = urls.compactMap { controller.catalog.songsByID[$0.standardizedFileURL.path] }
            guard !songs.isEmpty else { return false }
            withAnimation(Theme.quick) { controller.add(songs, to: playlist.id) }
            return true
        } isTargeted: { targeted = $0 && playlist != nil }
        .sottovaMenu { entries }
    }

    private var entries: [MenuEntry] {
        switch collection {
        case .album(let album): MenuEntry.album(album, controller: controller, router: router, navigate: navigate)
        case .yours(let playlist): MenuEntry.yours(playlist, controller: controller, router: router, navigate: navigate, renaming: renaming)
        }
    }

    private func open() {
        switch collection {
        case .album(let album): navigate(.album(album.id))
        case .yours(let playlist): navigate(.playlist(playlist.id))
        }
    }
}

/// A tile's right-click, behind three dots that show on hover.
private struct TileDots: View {
    let title: String
    let entries: [MenuEntry]

    var body: some View {
        Menu { MenuEntries(entries: entries) } label: {
            Ph.dotsThree.icon(size: 14)
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .hoverable(radius: 4)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("more")
        .accessibilityLabel("more for \(title)")
    }
}

/// Collections, Artists and Free music lay their tiles out alike.
enum TileGrid {
    static let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 20, alignment: .top)]
    static let rowGap: CGFloat = 24
}

/// Under a grid tile: the name, then one muted line, kept even when there's nothing to say so rows stay level.
struct TileCaption: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).role(.body).fontWeight(.medium).foregroundStyle(Theme.text).lineLimit(1)
            Text(detail ?? " ").role(.body).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}

/// A section's head on a grid page, in a collection part's type and hairline, so the app has one.
struct GroupHead: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .role(.row)
                .foregroundStyle(Theme.text)
                .frame(height: 22)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
