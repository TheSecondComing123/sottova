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

/// Cover and words over the songs, all scrolling together.
struct CollectionFrame<Name: View, Actions: View, Songs: View>: View {
    let cover: String?
    /// Nothing in it yet: the only place here an empty frame belongs.
    let empty: Bool
    var dropTargeted = false
    let lines: [String]
    /// Where the painting's credit is, and what re-reads it.
    var credit: (url: URL?, key: String?) = (nil, nil)
    @ViewBuilder let name: Name
    @ViewBuilder let actions: Actions
    @ViewBuilder let songs: (_ narrow: Bool) -> Songs
    @State private var width: CGFloat = 1024

    var body: some View {
        let narrow = width < 860
        let side: CGFloat = narrow ? 120 : 160
        PageScroll(insets: EdgeInsets(top: 16, leading: narrow ? 32 : 40, bottom: 24, trailing: narrow ? 32 : 40)) {
            HStack(alignment: .bottom, spacing: 20) {
                if let cover {
                    CoverImage(key: cover, size: side)
                } else if empty {
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(dropTargeted ? Theme.primary.opacity(0.1) : .clear)
                        .strokeBorder(dropTargeted ? Theme.primary : Theme.frame, lineWidth: 1)
                        .frame(width: side, height: side)
                }
                VStack(alignment: .leading, spacing: 0) {
                    name
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .role(.body)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, index == 0 ? 8 : 0)
                    }
                    CoverCredit(url: credit.url, key: credit.key).padding(.top, 4)
                    actions.padding(.top, 14)
                }
            }
            .padding(.bottom, 20)
            songs(narrow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// `.btn` with three dots: the rest of what a collection does.
struct CollectionMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Ph.dotsThree.icon(size: 14)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(Theme.selection, in: .rect(cornerRadius: Radius.small))
                .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Theme.stroke, lineWidth: 0.5) }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("more")
    }
}

/// Play, the same word and width whatever's going, as the title bar has the pause: paused it resumes, sounding it has nothing to do.
struct PlayButton: View {
    let songs: [Song]
    var source: String?
    @Environment(Controller.self) private var controller

    var body: some View {
        let key = Controller.Origin.key(of: songs, source: source)
        let ours = controller.origin?.key == key && controller.status != .idle
        ThemeButton(title: "Play", icon: .play) {
            if !ours {
                controller.play(songs, source: source)
            } else if controller.status == .paused {
                controller.toggle()
            }
        }
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
        Menu("Silence") {
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
            CollectionFrame(cover: album.artwork, empty: false,
                            lines: [DayPlan(alarms: controller.alarms).hours(of: id), songCount(album.songs)].compactMap { $0 }
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
                    CollectionMenu {
                        Button("Shuffle") { controller.play(album.songs.shuffled(), shuffled: true) }
                        Button("Make it yours") { controller.makeYours(album).map { navigate(.playlist($0)) } }
                            .help("a copy you can reorder and add to. songs added to its folder later won't join it")
                        Divider()
                        Button("Choose cover…") { router.coverFor = .album(id) }
                        Button("Start at…") { router.alarm = .new(.album(id)) }
                        SilenceChoices(title: album.title, chosen: controller.albumSettings[id]) { controller.albumSettings[id] = $0 }
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
    /// Renaming moves the file, so the id changes under the page.
    @State private var renamedTo: String?
    @State private var editing = false
    @State private var name = ""
    @State private var target: Int?
    @State private var dragFrom: Int?
    @FocusState private var typing: Bool

    private var pid: String { renamedTo ?? id }

    var body: some View {
        if let playlist = controller.playlists.first(where: { $0.id == pid }) {
            let songs = controller.songs(of: playlist)
            let cover = controller.playlistCovers[pid] ?? songs.first?.artwork
            let isEmpty = playlist.paths.isEmpty
            let missing = playlist.paths.count - songs.count
            CollectionFrame(cover: cover, empty: isEmpty, dropTargeted: isEmpty && target == 0,
                            lines: isEmpty ? [] : [DayPlan(alarms: controller.alarms).hours(of: pid), songCount(songs) + (missing > 0 ? ", \(missing) missing" : "")].compactMap { $0 }
                                + ownSilence(isEmpty ? nil : playlist.gaps, songs: songs, controller: controller),
                            credit: (Controller.coverURL(forPlaylist: pid), controller.playlistCovers[pid])) {
                title(playlist)
            } actions: {
                if !isEmpty {
                    HStack(spacing: 6) {
                        PlayButton(songs: songs, source: pid)
                        menu(playlist, songs: songs)
                    }
                }
            } songs: { narrow in
                if isEmpty {
                    Text("Drag songs or a folder here.")
                        .role(.body)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
                        .contentShape(.rect)
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, at: 0, in: playlist) } isTargeted: { target = $0 ? 0 : nil }
                } else {
                    rows(playlist, songs: songs, narrow: narrow)
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

    private func rows(_ playlist: Playlist, songs: [Song], narrow: Bool) -> some View {
        let columns = CollectionColumns(songs: songs, narrow: narrow)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(playlist.paths.enumerated()), id: \.offset) { index, path in
                if index == 0 && !playlist.breaks.isEmpty || playlist.breaks.contains(index) {
                    PartHeading(number: playlist.breaks.count { $0 <= index } + 1, name: playlist.partNames[index],
                                length: partLength(playlist, from: index), first: index == 0) {
                        controller.namePart($0, at: index, in: pid)
                    } join: {
                        withAnimation(Theme.quick) { controller.setBreak(false, at: index, in: pid) }
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 12)
                }
                row(path, at: index, in: playlist, songs: songs, columns: columns)
                    .overlay(alignment: .top) { insertionLine(at: index) }
                    .dropDestination(for: URL.self) { urls, _ in drop(urls, at: index, in: playlist) } isTargeted: { on in
                        if on { target = index } else if target == index { target = nil }
                    }
            }
            .environment(\.songOrder, playlist.paths)
            // below the last row: drop to add at the end
            Color.clear
                .frame(height: 48)
                .overlay(alignment: .top) { insertionLine(at: playlist.paths.count) }
                .dropDestination(for: URL.self) { urls, _ in drop(urls, at: playlist.paths.count, in: playlist) } isTargeted: { on in
                    if on { target = playlist.paths.count } else if target == playlist.paths.count { target = nil }
                }
        }
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
            LibraryLine(song: song, columns: columns.line, performer: columns.performer(of: song), remove: { ids in
                // one row is this row, even when the song is in here twice
                let rows = ids == [path] ? IndexSet([index]) : IndexSet(playlist.paths.indices.filter { ids.contains(playlist.paths[$0]) })
                withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: rows) }
            }, dragStarted: { dragFrom = index }, part: index == 0 ? nil : (playlist.breaks.contains(index), {
                withAnimation(Theme.quick) { controller.setBreak(!playlist.breaks.contains(index), at: index, in: pid) }
            })) {
                controller.play(songs, from: playable, source: pid)
            }
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
                [.item("Remove from this collection") { withAnimation(Theme.quick) { controller.removeFromPlaylist(pid, at: [index]) } }]
            }
        }
    }

    private func insertionLine(at index: Int) -> some View {
        Rectangle()
            .fill(Theme.primary)
            .frame(height: 2)
            .padding(.leading, 22)
            .offset(y: -1)
            .opacity(target == index ? 1 : 0)
    }

    /// A song already here moves to `index`; anything else is added there, a folder as the songs of it you have.
    private func drop(_ urls: [URL], at index: Int, in playlist: Playlist) -> Bool {
        target = nil
        let paths = urls.map { $0.standardizedFileURL.path }
        let folders = urls.filter(\.hasDirectoryPath).map { $0.standardizedFileURL.path(percentEncoded: false) }
        withAnimation(Theme.quick) {
            let dragged = dragFrom.flatMap { playlist.paths.indices.contains($0) && paths == [playlist.paths[$0]] ? $0 : nil }
            dragFrom = nil
            if paths.count == 1, folders.isEmpty, let from = dragged ?? playlist.paths.firstIndex(of: paths[0]) {
                controller.movePlaylistSongs(pid, fromOffsets: [from], toOffset: index)
            } else {
                let inFolders = controller.catalog.songs.filter { song in folders.contains { song.id.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
                controller.add(paths.compactMap { controller.catalog.songsByID[$0] } + inFolders, to: pid, at: index)
            }
        }
        return true
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
                .onTapGesture(count: 2) { startRename(playlist) }
                .help("double-click to rename")
        }
    }

    private func menu(_ playlist: Playlist, songs: [Song]) -> some View {
        CollectionMenu {
            Button("Shuffle") { controller.play(songs.shuffled(), source: pid, shuffled: true) }
            Divider()
            Button("Rename") { startRename(playlist) }
            Button("Choose cover…") { router.coverFor = .playlist(pid) }
            Button("Start at…") { router.alarm = .new(.playlist(pid)) }
            SilenceChoices(title: playlist.name, chosen: playlist.gaps) { controller.setGaps($0, for: pid) }
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

/// A part's name and length over the song that starts it. Double-click to name it; right-click to join it to the one before.
private struct PartHeading: View {
    let number: Int
    let name: String?
    let length: Double
    let first: Bool
    let rename: (String) -> Void
    let join: () -> Void
    @Environment(Router.self) private var router
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if editing {
                TextField("Part \(number)", text: $draft)
                    .role(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.text)
                    .focused($typing)
                    .onSubmit(commit)
                    .onExitCommand(perform: end)
                    .onDisappear { router.typing = false }
                    .onChange(of: typing) { _, focused in
                        router.typing = focused
                        if !focused { commit() }
                    }
                    .modifier(FieldLook(focused: true))
                    .frame(width: 220)
                    .padding(.leading, -8)
            } else {
                Text(name ?? "Part \(number)")
                    .role(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.text)
                    .help("double-click to rename")
            }
            Spacer(minLength: 16)
            Text(Format.length(length))
                .role(.body)
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
        }
        .frame(height: editing ? 24 : 18)
        .padding(.top, first ? 0 : editing ? 21 : 24)
        .padding(.bottom, editing ? 1 : 4)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: start)
        .sottovaMenu {
            [.item("Rename", action: start)] + (first ? [] : [.item("Join the part before", action: join)])
        }
        .onAppear {
            #if SHOT
            if let shot = UserDefaults.standard.string(forKey: "shotNaming"), shot == name { draft = shot; editing = true }
            #endif
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

/// Every collection, in day order, from the Collections heading in the sidebar.
struct CollectionGrid: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 28, alignment: .top)]

    var body: some View {
        let plan = DayPlan(alarms: controller.alarms)
        let collections = controller.collections
        let order = plan.inDayOrder(collections.map(\.id))
        let ordered = order.compactMap { id in collections.first { $0.id == id } }
        PageScroll(insets: EdgeInsets(top: 16, leading: 40, bottom: 24, trailing: 40)) {
            HStack(alignment: .center) {
                Text("Collections")
                    .role(.title)
                    .offset(y: -2)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                ThemeButton(title: "New", icon: .plus, iconWeight: .bold) {
                    guard let id = controller.newPlaylist() else { return }
                    renaming.wrappedValue = id
                    navigate(.playlist(id))
                }
            }
            .padding(.bottom, 27)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                ForEach(ordered) { CollectionCard(collection: $0, hours: plan.shortHours(of: $0.id)) }
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

    private var cover: String? {
        switch collection {
        case .album(let album): album.artwork
        case .yours(let playlist): controller.playlistCovers[playlist.id] ?? controller.songs(of: playlist).first?.artwork
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover {
                CoverImage(key: cover, size: 200)
            } else {
                RoundedRectangle(cornerRadius: Radius.small)
                    .strokeBorder(Theme.frame, lineWidth: 1)
                    .frame(width: 200, height: 200)
                    .overlay(alignment: .bottomLeading) {
                        Text(collection.title)
                            .role(.item)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(3)
                            .padding([.leading, .trailing, .top], 14)
                            .padding(.bottom, 12)
                    }
            }
            Text(cover == nil ? " " : collection.title)
                .role(.body)
                .fontWeight(.medium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.top, 10)
            Text(hours ?? " ")
                .role(.body)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .onTapGesture { open() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([collection.title, hours].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .sottovaMenu {
            switch collection {
            case .album(let album): MenuEntry.album(album, controller: controller, router: router, navigate: navigate)
            case .yours(let playlist): MenuEntry.yours(playlist, controller: controller, router: router, navigate: navigate, renaming: renaming)
            }
        }
    }

    private func open() {
        switch collection {
        case .album(let album): navigate(.album(album.id))
        case .yours(let playlist): navigate(.playlist(playlist.id))
        }
    }
}
