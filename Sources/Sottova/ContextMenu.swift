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
    var icon: Ph?
    var checked = false
    let kind: Kind

    static func item(_ title: String, _ icon: Ph? = nil, checked: Bool = false, action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, icon: icon, checked: checked, kind: .action(action))
    }

    static func submenu(_ title: String, _ icon: Ph? = nil, _ entries: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, icon: icon, kind: .submenu(entries))
    }

    static var divider: MenuEntry { MenuEntry(kind: .divider) }

    var selectable: Bool {
        if case .divider = kind { false } else { true }
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

        init(entries: [MenuEntry]) {
            self.entries = entries
        }
    }

    private var panels: [(panel: MenuPanel, level: Level)] = []
    private weak var owner: NSWindow?
    private var monitors: [Any] = []
    private var resign: NSObjectProtocol?

    func show(_ entries: [MenuEntry], at point: NSPoint, over window: NSWindow) {
        close()
        owner = window
        open(entries, topLeft: point, depth: 0)
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

    private func open(_ entries: [MenuEntry], topLeft: NSPoint, depth: Int, alongside row: NSRect? = nil) {
        let level = Level(entries: entries)
        let host = NSHostingView(rootView: MenuList(level: level, depth: depth, presenter: self))
        let size = host.fittingSize
        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
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

        let screen = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        if let row {
            // a submenu sits beside its row, and flips to the other side at the screen's edge
            origin = NSPoint(x: row.maxX - 4, y: row.maxY - size.height + 4)
            if origin.x + size.width > screen.maxX { origin.x = row.minX - size.width + 4 }
        } else if origin.x + size.width > screen.maxX {
            origin.x = topLeft.x - size.width
        }
        origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))
        panel.setFrameOrigin(origin)

        panels.append((panel, level))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
    }

    /// Hovering a row: its submenu opens beside it; any other row closes the submenu that was open.
    func hover(_ index: Int, depth: Int, row: NSRect) {
        guard depth < panels.count else { return }
        let level = panels[depth].level
        guard level.highlighted != index || panels.count == depth + 1 else { return }
        level.highlighted = index
        closeBelow(depth)
        if case .submenu(let entries) = level.entries[index].kind {
            open(entries, topLeft: .zero, depth: depth + 1, alongside: screenRect(row, depth: depth))
            panels[depth].panel.makeKey()
        }
    }

    func choose(_ index: Int, depth: Int, row: NSRect) {
        guard depth < panels.count else { return }
        switch panels[depth].level.entries[index].kind {
        case .action(let action):
            close()
            owner?.makeKey()
            // after the menu is gone, so a sheet the action opens attaches to the window, not the menu
            DispatchQueue.main.async(execute: action)
        case .submenu:
            hover(index, depth: depth, row: row)
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
            choose(index, depth: depth, row: rowRect(index, depth: depth))
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

    func close() {
        closeBelow(-1)
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
    private var rows: [Int: [Int: CGRect]] = [:]

    func record(_ frame: CGRect, index: Int, depth: Int) {
        rows[depth, default: [:]][index] = frame
    }

    private func rowRect(_ index: Int, depth: Int) -> NSRect {
        rows[depth]?[index] ?? .zero
    }

    private func screenRect(_ row: CGRect, depth: Int) -> NSRect {
        let frame = panels[depth].panel.frame
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

private struct MenuList: View {
    let level: MenuPresenter.Level
    let depth: Int
    let presenter: MenuPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(level.entries.enumerated()), id: \.offset) { index, entry in
                if entry.selectable {
                    row(entry, index: index)
                } else {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(4)
        .frame(minWidth: 200)
        .fixedSize()
        .background(Theme.raised, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .coordinateSpace(.named("menu"))
    }

    private func row(_ entry: MenuEntry, index: Int) -> some View {
        let lit = level.highlighted == index
        return GeometryReader { geo in
            let frame = geo.frame(in: .named("menu"))
            HStack(spacing: 8) {
                Group {
                    if entry.checked {
                        Ph.check.icon(.bold, size: 12)
                    } else if let icon = entry.icon {
                        icon.icon(size: 16)
                    }
                }
                .foregroundStyle(lit ? Theme.text : Theme.muted)
                .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 16)
                if case .submenu = entry.kind {
                    Ph.caretRight.icon(.bold, size: 10)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(lit ? Theme.hover : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { inside in if inside { presenter.hover(index, depth: depth, row: frame) } }
            .onTapGesture { presenter.choose(index, depth: depth, row: frame) }
            .onAppear { presenter.record(frame, index: index, depth: depth) }
        }
        .frame(height: 28)
        .frame(minWidth: titleWidth(entry))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(entry.checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { presenter.choose(index, depth: depth, row: .zero) }
    }

    /// GeometryReader takes no width of its own, so the row asks for what its title needs.
    private func titleWidth(_ entry: MenuEntry) -> CGFloat {
        let text = (entry.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return ceil(text) + 8 + 16 + 8 + 16 + 10 + 8
    }
}
