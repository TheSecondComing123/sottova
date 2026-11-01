import AppKit
import SwiftUI
import SottovaCore

struct MainWindow: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var visible = true
    /// A theme change rebuilds this view, which would add them all again; they only need the router, which stays.
    @MainActor private static var watching = false
    @State private var renaming: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var narrow = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: router.route.section)
                .frame(width: narrow ? 176 : 216)
                .overlay(alignment: .top) { TitleDrag().frame(height: 44) }
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            VStack(spacing: 0) {
                TitleBar(narrow: narrow, toggleQueue: toggleQueue)
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .topTrailing) {
                if router.showsQueue {
                    QueuePanel(close: toggleQueue)
                        .padding(.trailing, narrow ? 16 : 60)
                        .padding(.top, 50)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.98, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        // in the toolbar, so the title bar is 52 pt with the traffic lights on this line, and clicks reach them
        .toolbar {
            // empty, it keeps the title bar 52 pt with the lights at 19, 19; the bar itself is content
            ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
                .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 855, minHeight: 640)
        .onGeometryChange(for: Bool.self) { $0.size.width < 1040 } action: { narrow = $0 }
        .background(WindowVisibility(visible: $visible))
        .environment(\.windowVisible, visible)
        .environment(\.renaming, $renaming)
        .environment(\.navigate, Navigate { route in
            // a name opens Songs filtered to it
            if case .artist(let name) = route {
                router.go(to: .songs)
                router.songFilter = name
                return
            }
            if case .composer(let name) = route {
                router.go(to: .songs)
                router.songFilter = name
                return
            }
            // an album made yours opens as its copy
            if case .album(let id) = route, let copy = controller.copy(ofAlbum: id) {
                router.go(to: .playlist(copy.id))
            } else {
                router.go(to: route)
            }
        })
        // drop music folders anywhere on the window
        .dropDestination(for: URL.self, action: { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            controller.addFolders(folders)
            return !folders.isEmpty
        }, isTargeted: { router.droppingMusic = $0 })
        .onAppear(perform: watchMouseButtons)
        .onAppear { controller.undo = undoManager }
        .onChange(of: undoManager) { controller.undo = undoManager }
        .confirmationDialog(trashQuestion, isPresented: Binding(get: { router.trashing != nil }, set: { if !$0 { router.trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                guard let id = router.trashing else { return }
                if router.route == .playlist(id) { router.go(to: .home) }
                controller.trashPlaylist(id)
            }
        } message: {
            Text("Its rows on Your day go too: they'd have nothing to play.")
        }
        // at the window, never inside a lazy row that could be recycled with the sheet open
        .sheet(item: Binding(get: { router.coverFor }, set: { router.coverFor = $0 })) { CoverPicker(target: $0) }
        .sheet(item: Binding(get: { router.alarm }, set: { router.alarm = $0 })) { AlarmSheet(request: $0) }
        .disabled(router.presetEdit != nil)
        // not a system sheet: Tahoe's sits mid-window with 26 pt corners and dims the page twice as far as the mock
        .overlay {
            if let edit = router.presetEdit {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.28)
                        .contentShape(.rect)
                        .onTapGesture {}
                    SilenceSheet(edit: edit)
                        .padding(.top, 52)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, narrow ? 176 : 216)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: router.presetEdit?.id)
        .sheet(item: Binding(get: { router.trimming }, set: { router.trimming = $0 })) { TrimSheet(song: $0) }
    }

    private var trashQuestion: String {
        let name = controller.playlists.first { $0.id == router.trashing }?.name ?? "this collection"
        return "Move \(name) to the Trash?"
    }

    @ViewBuilder
    private var page: some View {
        Group {
            switch router.route {
            case .home: NowPage()
            case .songs: SongList()
            case .collections: CollectionGrid()
            case .artists: NameList()
            case .alarms: DayPage()
            case .shelf: FreeMusicPage()
            case .album(let id): AlbumCollection(id: id)
            case .playlist(let id): YourCollection(id: id)
            // navigate sends names to Songs; these only come back through history from before that
            case .artist, .composer: SongList()
            }
        }
        .id(router.route)
        // the old page leaves fast, so the two never sit on top of each other at full strength
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Theme.curve(0.08))))
    }

    private func toggleQueue() {
        router.toggleQueue()
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
        guard !Self.watching else { return }
        Self.watching = true
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard router.presetEdit == nil else { return event }
            guard event.keyCode == 53, router.showsQueue, !(event.window?.firstResponder is NSText) else { return event }
            toggleQueue()
            return nil
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: swipe)
        _ = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: router.goBack()
            case 4: router.goForward()
            default: return event
            }
            return nil
        }
    }
}

