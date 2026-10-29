import AppKit
import SwiftUI
import SottovaCore

struct MainWindow: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var visible = true
    @State private var mouseButtons: Any?
    @State private var escapeKey: Any?
    @State private var swipes: Any?
    @State private var showsQueue = false
    @State private var renaming: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: router.route.section) { root in
                router.go(to: root)
            }
            .frame(width: 228)

            Rectangle().fill(Theme.border).frame(width: 1)

            VStack(spacing: 0) {
                TopBar()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // the page makes room for the queue, so no column hides under it; padding, not safe-area padding, or
                    // sideways shelves would still draw under the panel and show through its gutters
                    .padding(.trailing, showsQueue ? 356 : 0)
                    .overlay(alignment: .trailing) {
                        if showsQueue {
                            QueuePanel(close: toggleQueue)
                                .padding([.trailing, .bottom], 16)
                                .padding(.top, 8)
                                // it leaves the way it came
                                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                        }
                    }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                PlayerBar(showsQueue: showsQueue, toggleQueue: toggleQueue)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 640)
        .background(WindowVisibility(visible: $visible))
        .environment(\.windowVisible, visible)
        .environment(\.renaming, $renaming)
        .environment(\.navigate, Navigate { route in
            router.go(to: route)
        })
        // drop music folders anywhere on the window
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            controller.addFolders(folders)
            return !folders.isEmpty
        }
        .onAppear(perform: watchMouseButtons)
        // at the window, never inside a lazy row that could be recycled with the sheet open
        .sheet(item: Binding(get: { router.coverFor }, set: { router.coverFor = $0 })) { CoverPicker(target: $0) }
        .sheet(item: Binding(get: { router.alarm }, set: { router.alarm = $0 })) { AlarmSheet(request: $0) }
        .sheet(item: Binding(get: { router.trimming }, set: { router.trimming = $0 })) { TrimSheet(song: $0) }
    }

    @ViewBuilder
    private var page: some View {
        Group {
            if !router.query.isEmpty {
                SearchPage(query: router.query)
            } else {
                switch router.route {
                case .home: HomePage()
                case .songs: SongsPage()
                case .albums: AlbumsPage()
                case .artists: ArtistsPage()
                case .alarms: AlarmsPage()
                case .album(let id): AlbumPage(id: id)
                case .artist(let name): ArtistPage(name: name)
                case .playlist(let id): PlaylistPage(id: id)
                case .composer(let name): ComposerPage(name: name)
                }
            }
        }
        .id(router.query.isEmpty ? AnyHashable(router.route) : AnyHashable("search"))
        // the old page leaves fast, so the two never sit on top of each other at full strength
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Theme.curve(0.08))))
    }

    private func toggleQueue() {
        // in on a spring with no overshoot, a 340 pt edge mustn't wobble; out on the quick curve
        withAnimation(showsQueue ? Theme.quick : .spring(duration: 0.3, bounce: 0)) { showsQueue.toggle() }
    }

    /// Two fingers sideways on a trackpad go back and forward, as in Safari: only when the gesture starts sideways,
    /// and not over a shelf that can still scroll that way.
    private func swipe(_ event: NSEvent) -> NSEvent? {
        guard event.phase == .began, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2,
              !shelfScrolls(event) else { return event }
        let canBack = !router.back.isEmpty, canForward = !router.forward.isEmpty
        guard canBack || canForward else { return event }
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: canForward ? -1 : 0, max: canBack ? 1 : 0) { amount, _, isComplete, _ in
            guard isComplete else { return }
            if amount >= 1 { router.goBack() } else if amount <= -1 { router.goForward() }
        }
        return nil
    }

    /// True when the pointer is over a sideways scroll view with room to move in the gesture's direction.
    private func shelfScrolls(_ event: NSEvent) -> Bool {
        var view = event.window?.contentView?.hitTest(event.locationInWindow)
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 1 {
                let x = scroll.contentView.bounds.origin.x
                // fingers moving right scroll toward the start
                return event.scrollingDeltaX > 0 ? x > 0 : x + scroll.contentView.bounds.width < document.frame.width - 1
            }
            view = current.superview
        }
        return false
    }

    /// The back and forward buttons on a mouse, and Esc for the queue when nothing is being typed.
    private func watchMouseButtons() {
        if escapeKey == nil {
            escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, showsQueue, !(event.window?.firstResponder is NSText) else { return event }
                toggleQueue()
                return nil
            }
        }
        if swipes == nil {
            swipes = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: swipe)
        }
        guard mouseButtons == nil else { return }
        mouseButtons = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: router.goBack()
            case 4: router.goForward()
            default: return event
            }
            return nil
        }
    }
}

private struct Sidebar: View {
    let section: Route
    let select: (Route) -> Void
    @Environment(Controller.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renaming) private var renaming
    @Namespace private var pill

    private let items: [(Route, String, Ph)] = [
        (.home, "Home", .house),
        (.songs, "Songs", .musicNote),
        (.albums, "Albums", .vinylRecord),
        (.artists, "Artists", .microphoneStage),
        (.alarms, "Alarms", .alarm),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // the wordmark sits on the same line as the search field; the traffic lights sit above it
            Text("sottova")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 24)
                // the top bar's 8 + 60, so it centers on the search field's line
                .frame(height: 60)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .gesture(WindowDragGesture())

            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.0) { index, entry in
                    navRow(entry.0, entry.1, entry.2, accent: index)
                }
            }
            .padding(.horizontal, 12)

            // the two lists scroll together, so many playlists never push the footer off the window
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Listening")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    VStack(spacing: 2) {
                        ForEach(SottovaCore.Settings.presets, id: \.name) { preset in
                            presetRow(preset)
                        }
                        if controller.settings.name == "Custom" {
                            presetRow(controller.settings)
                        }
                    }
                    .padding(.horizontal, 12)

                    HStack {
                        Text("Playlists")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        IconButton(icon: .plus, weight: .bold, help: "new playlist", size: 24) {
                            guard let id = controller.newPlaylist() else { return }
                            renaming.wrappedValue = id
                            select(.playlist(id))
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 4)

                    VStack(spacing: 2) {
                        ForEach(controller.playlists) { playlist in
                            PlaylistRow(playlist: playlist, selected: section == .playlist(playlist.id)) { select(.playlist(playlist.id)) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                    .animation(Theme.quick, value: controller.playlists.map(\.id))
                }
                .overlayScrollers()
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)

            // only when there's news: the song count alone is already on the Songs page
            if controller.folders.isEmpty || controller.pendingAnalysis > 0 || !controller.skippedFiles.isEmpty {
                Text(controller.libraryLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 2) {
                footerRow("Add folder", .folderPlus, action: controller.chooseFolders)
                footerRow("Settings", .gearSix) { openSettings() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private func navRow(_ item: Route, _ label: String, _ icon: Ph, accent: Int) -> some View {
        let selected = section == item
        return Button { select(item) } label: {
            HStack(spacing: 12) {
                // each section its own accent in a color palette; in monochrome it follows the label
                icon.icon(size: 18)
                    .foregroundStyle(Theme.accent(accent * 3, or: selected ? \.text : \.muted))
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            // a quiet fill: the selection shouldn't outshine the play button and the title on the page
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.hover)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(reduceMotion ? Theme.quick : Theme.settle, value: section)
    }

    /// Spread across the accents so neighbors differ: 2, 6, 10, 14…
    private func presetAccent(_ preset: SottovaCore.Settings) -> Int {
        2 + 4 * (SottovaCore.Settings.presets.firstIndex { $0.name == preset.name } ?? 4)
    }

    private func presetRow(_ preset: SottovaCore.Settings) -> some View {
        let active = controller.settings.name == preset.name
        return Button { controller.apply(preset) } label: {
            HStack(spacing: 12) {
                // the active mode is marked in the icon column; the rows are type only, so the ranges carry the comparison
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent(presetAccent(preset)))
                    .frame(width: 2, height: 14)
                    .opacity(active ? 1 : 0)
                    .frame(width: 20)
                Text(preset.name)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Theme.text : Theme.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                // every row, so the modes compare at a glance; a crossfade has no range, and its glyph shows the overlap
                if !preset.crossfade {
                    Text(Format.range(preset))
                        .lineLimit(1)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(active ? Theme.muted : Theme.faint)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(Theme.quick, value: active)
        .disabled(preset.name == "Custom")
        // the range is on the row already; only crossfade's overlap needs saying
        .help(preset.crossfade ? Format.gaps(preset) : "")
    }

    private func footerRow(_ label: String, _ icon: Ph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.icon(size: 16)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}

private struct TopBar: View {
    @Environment(Router.self) private var router
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var router = router
        HStack(spacing: 12) {
            arrow(.caretLeft, enabled: !router.back.isEmpty, help: "back", action: router.goBack)
            arrow(.caretRight, enabled: !router.forward.isEmpty, help: "forward", action: router.goForward)

            HStack(spacing: 8) {
                Ph.magnifyingGlass.icon(size: 16)
                    .foregroundStyle(Theme.muted)
                TextField("search songs, albums, artists", text: $router.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($searching)
                    .onExitCommand { router.query = ""; searching = false }
                    .onChange(of: searching) { _, focused in router.typing = focused }
                    .onChange(of: router.searchRequests) { searching = true }
                    // AppKit hands a new window's focus to its first text field; here that would swallow Space
                    .onAppear { DispatchQueue.main.async { searching = false } }
                if !router.query.isEmpty {
                    IconButton(icon: .x, weight: .bold, help: "clear search", size: 24) { router.query = "" }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: 560)
            .background(Theme.raised, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searching ? Theme.muted : Theme.border))
            .animation(Theme.quick, value: searching)

            // the rest of the bar still drags the window
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .padding(.top, 8)
    }

    private func arrow(_ icon: Ph, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.icon(.bold, size: 14)
                .foregroundStyle(enabled ? Theme.text : Theme.decor)
                .frame(width: 32, height: 32)
                .hoverable(radius: 16)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A playlist in the sidebar: its cover, name and count. Songs dropped on it are added, and the count ticks up.
private struct PlaylistRow: View {
    let playlist: Playlist
    let selected: Bool
    let select: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.renaming) private var renaming
    @Environment(Router.self) private var router
    @State private var targeted = false

    var body: some View {
        let first = playlist.paths.lazy.compactMap { controller.catalog.songsByID[$0] }.first
        Button(action: select) {
            HStack(spacing: 12) {
                Artwork(key: controller.playlistCovers[playlist.id] ?? first?.artwork, size: 16, radius: 4, title: playlist.name)
                    .frame(width: 20)
                Text(playlist.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(playlist.paths.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .contentTransition(.numericText(value: Double(playlist.paths.count)))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Theme.hover : .clear, in: .rect(cornerRadius: 8))
            .background(Theme.accent(for: playlist.name).opacity(targeted ? 0.14 : 0), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent(for: playlist.name), lineWidth: 1.5).opacity(targeted ? 1 : 0))
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .dropDestination(for: URL.self) { urls, _ in
            let songs = urls.compactMap { controller.catalog.songsByID[$0.standardizedFileURL.path] }
            guard !songs.isEmpty else { return false }
            withAnimation(Theme.quick) { controller.add(songs, to: playlist.id) }
            return true
        } isTargeted: { on in
            // the highlight comes on at once and leaves on the quick curve
            withAnimation(on ? nil : Theme.quick) { targeted = on }
        }
        .sottovaMenu {
            [
                .item("Play") { controller.play(controller.songs(of: playlist), source: playlist.id) },
                .item("Shuffle") { controller.play(controller.songs(of: playlist).shuffled(), source: playlist.id, shuffled: true) },
                .divider,
                .item("Rename") {
                    renaming.wrappedValue = playlist.id
                    select()
                },
                .item("Choose cover…") { router.coverFor = .playlist(playlist.id) },
                .item("Start at…") { router.alarm = .new(.playlist(playlist.id)) },
                .item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: playlist.id)]) },
                .divider,
                .item("Move to Trash") {
                    if selected { navigate(.home) }
                    controller.trashPlaylist(playlist.id)
                },
            ]
        }
    }
}
