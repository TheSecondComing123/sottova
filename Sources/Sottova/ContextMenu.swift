import AppKit
import SwiftUI

/// One line of a right-click menu.
struct MenuEntry {
    enum Kind {
        case action(() -> Void)
        case submenu([MenuEntry])
        case divider
    }

    var title = ""
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

extension View {
    /// Sottova's own right-click menu, in the app's type and colors instead of the system's. The entries are built
    /// when the menu opens, so they show the state at that moment.
    func sottovaMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClick { point, window in MenuPresenter.shared.show(entries(), at: point, over: window) })
            .accessibilityAction(named: "Show menu") {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                MenuPresenter.shared.show(entries(), at: NSEvent.mouseLocation, over: window)
            }
    }
}

/// Takes right-clicks and control-clicks, and nothing else: every other event falls through to the view beneath.
private struct RightClick: NSViewRepresentable {
    let open: (NSPoint, NSWindow) -> Void

    func makeNSView(context: Context) -> Catcher {
        Catcher()
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.open = open
    }

    final class Catcher: NSView {
        var open: ((NSPoint, NSWindow) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            show(event)
        }

        override func mouseDown(with event: NSEvent) {
            show(event)
        }

        private func show(_ event: NSEvent) {
            guard let window else { return }
            open?(window.convertPoint(toScreen: event.locationInWindow), window)
        }
    }
}

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
        close(fading: false)
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
