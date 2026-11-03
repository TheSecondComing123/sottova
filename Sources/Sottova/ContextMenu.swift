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
    /// Pressed from the menu bar; a right-click menu only shows it.
    var shortcut: KeyboardShortcut?
    let kind: Kind

    static func item(_ title: String, checked: Bool = false, enabled: Bool = true, shortcut: KeyboardShortcut? = nil,
                     action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, checked: checked, enabled: enabled, shortcut: shortcut, kind: .action(action))
    }

    static func submenu(_ title: String, _ entries: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(entries))
    }

    static var divider: MenuEntry { MenuEntry(kind: .divider) }

    /// ⌘⌫ is a menu's key and a text field's: pressed while typing, it stays the field's.
    static func unlessTyping(_ action: @escaping () -> Void) -> () -> Void {
        {
            if NSApp.currentEvent?.type == .keyDown, let field = NSApp.keyWindow?.firstResponder as? NSTextView {
                field.deleteToBeginningOfLine(nil)
            } else {
                action()
            }
        }
    }
}

private extension NSEvent.ModifierFlags {
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.control) { insert(.control) }
    }
}

/// The same entries as a SwiftUI menu's contents: a ••• button's, or the menu bar's.
struct MenuEntries: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            switch entry.kind {
            case .divider:
                Divider()
            case .action(let action):
                Group {
                    if entry.checked {
                        Toggle(entry.title, isOn: Binding(get: { true }, set: { _ in action() }))
                    } else {
                        Button(entry.title, action: action)
                    }
                }
                .keyboardShortcut(entry.shortcut)
                .disabled(!entry.enabled)
            case .submenu(let entries):
                Menu(entry.title) { MenuEntries(entries: entries) }
                    .disabled(!entry.enabled)
            }
        }
    }
}

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
                if let shortcut = entry.shortcut {
                    // AppKit spells the delete key as backspace
                    item.keyEquivalent = shortcut.key == .delete ? "\u{8}" : String(shortcut.key.character)
                    item.keyEquivalentModifierMask = NSEvent.ModifierFlags(shortcut.modifiers)
                }
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

    }
}

#if SHOT
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

