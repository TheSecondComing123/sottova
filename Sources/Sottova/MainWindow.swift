import AppKit
import SwiftUI
import SottovaCore

struct MainWindow: View {
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @State private var visible = true
    /// A theme change rebuilds this view, which would add them all again; they only need the router, which stays.
    @MainActor private static var watching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var activeState
    @State private var layout = PageLayout(windowWidth: 1240, pageHeight: 748)
    private var narrow: Bool { layout.narrowWindow }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: router.route.section)
                .frame(width: layout.sidebar)
                .overlay(alignment: .top) { TitleDrag().frame(height: 44) }
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            VStack(spacing: 0) {
                TitleBar(narrow: narrow, toggleQueue: toggleQueue)
                    // over the page: a ScrollView's backing view reaches up through this band and takes its clicks,
                    // refusing the one that brings an inactive window forward
                    .zIndex(1)
                if let problem = controller.problem {
                    ProblemNotice(message: problem) { controller.problem = nil }
                    .padding(.horizontal, layout.list.margin)
                    .padding(.vertical, 12)
                    .background(Theme.raised)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        layout = PageLayout(windowWidth: layout.width + layout.sidebar, pageHeight: $0)
                    }
                    // a scrolled page's rows would otherwise draw on up through the bar, which has no fill
                    .clipped()
            }
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Toast().padding(.bottom, 16).padding(.horizontal, 16) }
            .overlay(alignment: .topTrailing) {
                if router.showsQueue {
                    QueuePanel(close: toggleQueue)
                        .padding(.trailing, narrow ? 16 : 60)
                        .padding(.top, 50)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.98, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        // inside the safe area's edge, so it's the whole window, full screen or not, less the bar
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layout = PageLayout(windowWidth: $0, pageHeight: layout.height) }
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
        .environment(\.pageLayout, layout)
        .environment(\.listLayout, layout.list)
        .background(WindowVisibility(visible: $visible))
        .environment(\.windowVisible, visible)
        .environment(\.renaming, Binding(get: { router.renaming }, set: { router.renaming = $0 }))
        .environment(\.navigate, Navigate { router.open($0, in: controller) })
        // drop music folders anywhere on the window
        .dropDestination(for: URL.self, action: { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            controller.addFolders(folders)
            return !folders.isEmpty
        }, isTargeted: { router.droppingMusic = $0 })
        .onAppear(perform: watchMouseButtons)
        .onAppear { controller.undo = undoManager }
        .onChange(of: undoManager) { controller.undo = undoManager }
        // back from Settings, which takes it while it's in front
        .onChange(of: activeState) { if activeState == .key { controller.undo = undoManager } }
        .confirmationDialog(trashQuestion, isPresented: Binding(get: { router.trashing != nil }, set: { if !$0 { router.trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                guard let id = router.trashing else { return }
                router.leave(.playlist(id))
                controller.trashPlaylist(id)
            }
        } message: {
            Text("Its hours on Your day go too: they'd have nothing to play.")
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
                        .padding(.leading, layout.sidebar)
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

    /// The back and forward buttons on a mouse, and the keys when nothing is being typed: Esc for the queue, then the list.
    private func watchMouseButtons() {
        guard !Self.watching else { return }
        Self.watching = true
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // the page's window itself: a sheet, a popover and Settings have their own keys
            guard router.presetEdit == nil, let window = event.window, window.frameAutosaveName == "main", window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return event }
            if event.keyCode == 53, router.showsQueue {
                toggleQueue()
                return nil
            }
            // the queue's own list keeps its keys
            return !(window.firstResponder is NSTableView) && router.key(event) ? nil : event
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            router.pressActivates = !(event.window?.isKeyWindow ?? true)
            return event
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

struct ProblemNotice: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(message)
                .role(.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ThemeButton(title: "Dismiss", action: dismiss)
                .accessibilityLabel("dismiss message")
        }
    }
}

