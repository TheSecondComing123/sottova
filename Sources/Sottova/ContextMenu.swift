import AppKit
import SwiftUI
import SottovaCore

/// One line of a right-click menu.
struct MenuEntry {
    enum Kind {
        case action(() -> Void)
        case submenu([MenuEntry])
        case divider
    }

    var title = ""
    /// On the menu's right, dimmer.
    var detail = ""
    var checked = false
    /// Off: shown dimmed and can't be chosen, so the menu keeps its shape.
    var enabled = true
    let kind: Kind

    static func item(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, checked: checked, enabled: enabled, kind: .action(action))
    }

    static func submenu(_ title: String, _ entries: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(entries))
    }

    static var divider: MenuEntry { MenuEntry(kind: .divider) }

    var selectable: Bool {
        if case .divider = kind { false } else { enabled }
    }
}

#if NEWLOOK
extension View {
    /// A native right-click menu. The entries are built when the menu opens, so they show the state at that moment.
    func sottovaMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClick { event, view in
            let entries = entries()
            if !entries.isEmpty { NSMenu.popUpContextMenu(NSMenu(entries), with: event, for: view) }
        })
        .accessibilityAction(named: "Show menu") {
            let entries = entries()
            if !entries.isEmpty { NSMenu(entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
        }
    }
}

extension NSMenu {
    @MainActor convenience init(_ entries: [MenuEntry]) {
        self.init()
        autoenablesItems = false
        add(entries)
    }

    @MainActor func add(_ entries: [MenuEntry]) {
        for entry in entries {
            let before = numberOfItems
            switch entry.kind {
            case .divider:
                addItem(.separator())
            case .action(let action):
                let item = NSMenuItem(title: entry.title, action: #selector(MenuRun.run), keyEquivalent: "")
                item.target = MenuRun.shared
                item.representedObject = MenuRun.Box(action)
                item.state = entry.checked ? .on : .off
                item.isEnabled = entry.enabled
                addItem(item)
            case .submenu(let entries):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = NSMenu(entries)
                item.isEnabled = entry.enabled
                addItem(item)
            }
            if !entry.detail.isEmpty, numberOfItems > before { items[before].attributedTitle = entry.titleWithDetail }
        }
    }
}

extension MenuEntry {
    /// A right tab is how a menu lines up a column of its own.
    fileprivate var titleWithDetail: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let text = NSMutableAttributedString(string: title + "\t", attributes: [.font: NSFont.menuFont(ofSize: 13), .paragraphStyle: style])
        text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 13), .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }
}

/// Menu items hold their target weakly, and an action can't carry a closure.
@MainActor
private final class MenuRun: NSObject {
    static let shared = MenuRun()

    final class Box {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    @objc func run(_ item: NSMenuItem) {
        (item.representedObject as? Box)?.action()
    }
}
#else
extension View {
    /// Sottova's own right-click menu, in the app's type and colors instead of the system's. The entries are built
    /// when the menu opens, so they show the state at that moment.
    func sottovaMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClick { event, view in
            guard let window = view.window else { return }
            MenuPresenter.shared.show(entries(), at: window.convertPoint(toScreen: event.locationInWindow), over: window)
        })
        .accessibilityAction(named: "Show menu") {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            MenuPresenter.shared.show(entries(), at: NSEvent.mouseLocation, over: window)
        }
    }
}
#endif

/// Takes right-clicks and control-clicks, and nothing else: every other event falls through to the view beneath.
private struct RightClick: NSViewRepresentable {
    let open: (NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> Catcher {
        Catcher()
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.open = open
    }

    final class Catcher: NSView {
        var open: ((NSEvent, NSView) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            open?(event, self)
        }

        override func mouseDown(with event: NSEvent) {
            open?(event, self)
        }

        #if !NEWLOOK
        // the press that opened the menu keeps coming here: sliding onto a row and letting go chooses it
        override func rightMouseDragged(with event: NSEvent) {
            MenuPresenter.shared.track(NSEvent.mouseLocation)
        }

        override func mouseDragged(with event: NSEvent) {
            MenuPresenter.shared.track(NSEvent.mouseLocation)
        }

        override func rightMouseUp(with event: NSEvent) {
            MenuPresenter.shared.release(at: NSEvent.mouseLocation)
        }

        override func mouseUp(with event: NSEvent) {
            MenuPresenter.shared.release(at: NSEvent.mouseLocation)
        }
        #endif
    }
}

#if SHOT && NEWLOOK
/// Opens the real menu of whatever sits at `point` in the window, with no input event sent, and writes the menu's
/// window number to `ready` for scripts/harness.sh.
@MainActor
func shotMenu(at point: NSPoint, in window: NSWindow) {
    func catcher(in view: NSView) -> RightClick.Catcher? {
        for sub in view.subviews.reversed() {
            if let found = catcher(in: sub) { return found }
        }
        guard let view = view as? RightClick.Catcher, view.bounds.contains(view.convert(point, from: nil)) else { return nil }
        return view
    }
    guard let view = window.contentView.flatMap(catcher),
          let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
    shotMenuReady()
    view.open?(event, view)
}

/// Tracking a menu blocks, so this is set up before one opens.
@MainActor
func shotMenuReady() {
    let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? []
        let menu = windows.first { $0[kCGWindowOwnerPID] as? pid_t == getpid() && $0[kCGWindowLayer] as? Int ?? 0 > 0 }
        try? Data(String(menu?[kCGWindowNumber] as? Int ?? 0).utf8).write(to: ShotEnv.root.appending(path: "ready"))
    }
    RunLoop.main.add(timer, forMode: .common)
}
#endif

#if !NEWLOOK
/// The open menu and its submenus, one panel each, and the monitors that close them.
@MainActor
final class MenuPresenter {
    static let shared = MenuPresenter()

    @Observable @MainActor
    final class Level {
        let entries: [MenuEntry]
        var highlighted: Int?
        /// Each row's frame in its panel, for placing a submenu beside it.
        @ObservationIgnored var frames: [Int: CGRect] = [:]

        init(entries: [MenuEntry]) {
            self.entries = entries
        }
    }

    private var panels: [(panel: MenuPanel, level: Level)] = []
    private weak var owner: NSWindow?
    private var monitors: [Any] = []
    private var resign: NSObjectProtocol?

    func show(_ entries: [MenuEntry], at point: NSPoint, over window: NSWindow) {
        guard !entries.isEmpty else { return }
        close(fading: false)
        dragged = false
        owner = window
        open(entries, at: point, depth: 0)
        // a click anywhere else closes the menu and does nothing more, as a system menu does
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, !self.panels.contains(where: { $0.panel === event.window }) else { return event }
            self.close()
            return event.type == .scrollWheel ? event : nil
        }!)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }!)
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// The menu's corner sits on `point`; a submenu sits beside `row` instead. Either flips at the screen's edge.
    private func open(_ entries: [MenuEntry], at point: NSPoint, depth: Int, beside row: NSRect? = nil) {
        let level = Level(entries: entries)
        let screen = (NSScreen.screens.first { $0.frame.contains(row?.origin ?? point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let probe = NSHostingView(rootView: MenuList(level: level, depth: depth, grows: .topLeading, presenter: self))
        let size = probe.fittingSize

        var origin = NSPoint(x: point.x, y: point.y - size.height)
        var leftward = false
        if let row {
            origin = NSPoint(x: row.maxX + 2, y: row.maxY - size.height + 4)
            if origin.x + size.width > screen.maxX { origin.x = row.minX - size.width - 2 }
        } else if origin.x + size.width > screen.maxX {
            origin.x = point.x - size.width
            leftward = true
        }
        let upward = origin.y < screen.minY && row == nil
        if upward { origin.y = point.y }
        origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))

        // the menu grows out of the corner at the pointer, so it reads as coming from what was clicked
        let corner = UnitPoint(x: leftward ? 1 : 0, y: upward ? 1 : 0)
        let host = NSHostingView(rootView: MenuList(level: level, depth: depth, grows: corner, presenter: self))
        let panel = MenuPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // a right-click on a window in the background doesn't make the app active, and a panel would hide itself
        panel.hidesOnDeactivate = false
        panel.appearance = owner?.effectiveAppearance
        panel.presenter = self
        panel.depth = depth
        panels.append((panel, level))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        // the shadow was taken from the first, slightly smaller frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak panel] in panel?.invalidateShadow() }
    }

    /// Hovering a row: its submenu opens beside it; any other row closes the submenu that was open.
    func hover(_ index: Int, depth: Int) {
        guard depth < panels.count else { return }
        let level = panels[depth].level
        guard level.highlighted != index || panels.count == depth + 1 else { return }
        level.highlighted = index
        closeBelow(depth)
        if case .submenu(let entries) = level.entries[index].kind {
            open(entries, at: .zero, depth: depth + 1, beside: screenRect(index, depth: depth))
            panels[depth].panel.makeKey()
        }
    }

    /// Leaving a row clears it, unless it's holding its submenu open.
    func leave(_ index: Int, depth: Int) {
        guard depth < panels.count, panels.count == depth + 1, panels[depth].level.highlighted == index else { return }
        panels[depth].level.highlighted = nil
    }

    func choose(_ index: Int, depth: Int) {
        guard depth < panels.count else { return }
        switch panels[depth].level.entries[index].kind {
        case .action(let action):
            close()
            owner?.makeKey()
            // after the menu is gone, so a sheet the action opens attaches to the window, not the menu
            DispatchQueue.main.async(execute: action)
        case .submenu:
            hover(index, depth: depth)
            if depth + 1 < panels.count {
                panels[depth + 1].level.highlighted = panels[depth + 1].level.entries.firstIndex { $0.selectable }
                panels[depth + 1].panel.makeKey()
            }
        case .divider:
            break
        }
    }

    /// Arrows move, Return picks, → opens a submenu, ← and Esc step back out.
    func key(_ event: NSEvent, depth: Int) -> Bool {
        guard depth < panels.count else { return false }
        let level = panels[depth].level
        let selectable = level.entries.indices.filter { level.entries[$0].selectable }
        switch event.keyCode {
        case 125, 126: // down, up
            let down = event.keyCode == 125
            let current = level.highlighted.flatMap(selectable.firstIndex)
            let next = current.map { (down ? $0 + 1 : $0 - 1 + selectable.count) % selectable.count } ?? (down ? 0 : selectable.count - 1)
            level.highlighted = selectable[next]
            closeBelow(depth)
        case 36, 76, 124: // return, enter, right
            guard let index = level.highlighted else { return true }
            if event.keyCode == 124, case .action = level.entries[index].kind { return true }
            choose(index, depth: depth)
        case 123, 53: // left, escape
            if depth == 0 {
                close()
                owner?.makeKey()
            } else {
                closeBelow(depth - 1)
                panels[depth - 1].panel.makeKey()
            }
        default:
            return false
        }
        return true
    }

    /// Fades out, softer than it came in; a new menu replacing this one doesn't wait for it.
    func close(fading: Bool = true) {
        let closing = panels.map(\.panel)
        panels.removeAll()
        for panel in closing {
            guard fading else { panel.orderOut(nil); continue }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 0 } completionHandler: { panel.orderOut(nil) }
        }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        resign.map(NotificationCenter.default.removeObserver)
        resign = nil
    }

    private func closeBelow(_ depth: Int) {
        while panels.count > depth + 1 {
            panels.removeLast().panel.orderOut(nil)
        }
    }

    /// Row frames come from SwiftUI in the panel's flipped space; submenus are placed on the screen.
    /// Whether the press that opened the menu has moved since; a click that doesn't move leaves the menu open.
    private var dragged = false

    func track(_ point: NSPoint) {
        dragged = true
        if let (index, depth) = row(at: point) { hover(index, depth: depth) }
    }

    func release(at point: NSPoint) {
        defer { dragged = false }
        guard dragged, let (index, depth) = row(at: point), case .action = panels[depth].level.entries[index].kind else { return }
        choose(index, depth: depth)
    }

    /// The choosable row under a point on screen, in the deepest menu that has one there.
    private func row(at point: NSPoint) -> (Int, Int)? {
        for depth in panels.indices.reversed() {
            let level = panels[depth].level
            if let index = level.entries.indices.first(where: { level.entries[$0].selectable && screenRect($0, depth: depth).contains(point) }) {
                return (index, depth)
            }
        }
        return nil
    }

    private func screenRect(_ index: Int, depth: Int) -> NSRect {
        let frame = panels[depth].panel.frame
        let row = panels[depth].level.frames[index] ?? .zero
        return NSRect(x: frame.minX + row.minX, y: frame.maxY - row.maxY, width: row.width, height: row.height)
    }
}

final class MenuPanel: NSPanel {
    weak var presenter: MenuPresenter?
    var depth = 0

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if presenter?.key(event, depth: depth) != true { super.keyDown(with: event) }
    }
}

/// Type only: the label is the item. A ✓ marks the option in use, a › a submenu, and the row under the pointer
/// takes the play button's color.
private struct MenuList: View {
    let level: MenuPresenter.Level
    let depth: Int
    let grows: UnitPoint
    let presenter: MenuPresenter
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(level.entries.enumerated()), id: \.offset) { index, entry in
                if case .divider = entry.kind {
                    Rectangle()
                        .fill(Theme.text.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    MenuRow(entry: entry, index: index, level: level, depth: depth, presenter: presenter)
                }
            }
        }
        .padding(4)
        .frame(minWidth: 180)
        .fixedSize()
        .background(Theme.menu, in: .rect(cornerRadius: 12))
        // light catching the edge: on a dark window the shadow alone loses the menu's outline
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.text.opacity(0.08)))
        .coordinateSpace(.named("menu"))
        .scaleEffect(shown || depth > 0 || reduceMotion ? 1 : 0.96, anchor: grows)
        .onAppear { withAnimation(.spring(duration: 0.2, bounce: 0)) { shown = true } }
    }
}

private struct MenuRow: View {
    let entry: MenuEntry
    let index: Int
    let level: MenuPresenter.Level
    let depth: Int
    let presenter: MenuPresenter

    var body: some View {
        let lit = level.highlighted == index
        HStack(spacing: 24) {
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.checked {
                Ph.check.icon(.bold, size: 12)
            } else if case .submenu = entry.kind {
                Ph.caretRight.icon(.bold, size: 10)
                    .opacity(lit ? 1 : 0.6)
            }
        }
        .foregroundStyle(lit ? Theme.onPrimary : entry.enabled ? Theme.text : Theme.faint)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(lit ? Theme.primary : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("menu")) } action: { level.frames[index] = $0 }
        .onHover { guard entry.enabled else { return }; $0 ? presenter.hover(index, depth: depth) : presenter.leave(index, depth: depth) }
        .onTapGesture { if entry.enabled { presenter.choose(index, depth: depth) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(entry.checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { presenter.choose(index, depth: depth) }
    }
}
#endif
