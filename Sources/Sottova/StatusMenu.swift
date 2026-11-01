import AppKit
import SottovaCore

/// The menu bar's menu, rebuilt each time it opens, so it shows the state at that moment.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: Controller
    private let router: Router

    init(controller: Controller, router: Router) {
        (self.controller, self.router) = (controller, router)
        super.init()
        let icon = Ph.speakerHigh.image(.duotone).copy() as? NSImage
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        item.button?.image = icon
        item.button?.setAccessibilityLabel("Sottova")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let screen = controller.nowScreen()
        menu.removeAllItems()
        menu.addItem(header(screen))
        let groups = [actions(screen), rows(), [silence(), sleep()], [.item("Open Sottova") { AppDelegate.showMain() }]]
        for group in groups where !group.isEmpty {
            menu.addItem(.separator())
            menu.add(group)
        }
    }

    /// A view, as a disabled item's title would be dimmed: not clickable, and it never lights up.
    private func header(_ screen: NowScreen) -> NSMenuItem {
        let title = NSTextField(labelWithString: screen.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(wrappingLabelWithString: screen.sub)
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.isHidden = screen.sub.isEmpty
        let problem = NSTextField(wrappingLabelWithString: controller.problem ?? "")
        problem.font = .systemFont(ofSize: 13)
        problem.isHidden = controller.problem == nil
        let stack = NSStackView(views: [title, sub, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 2, right: 12)
        let width: CGFloat = 300
        for label in [title, sub, problem] { label.widthAnchor.constraint(lessThanOrEqualToConstant: width - 28).isActive = true }
        sub.preferredMaxLayoutWidth = width - 28
        problem.preferredMaxLayoutWidth = width - 28
        stack.frame.size = NSSize(width: width, height: stack.fittingSize.height)
        let item = NSMenuItem()
        item.view = stack
        return item
    }

    private func actions(_ screen: NowScreen) -> [MenuEntry] {
        let controller = controller
        let playOrPause: MenuEntry = controller.status == .paused ? .item("Play", action: controller.play) : .item("Pause", action: controller.pause)
        let next = MenuEntry.item("Play the next song now", action: controller.skip)
        switch screen.kind {
        case .firstRun: return [.item("Choose a folder…", action: controller.chooseFolders)]
        case .reading: return []
        case .quiet: return [.item("Play something", action: controller.play)]
        case .piece: return [playOrPause, .item("Skip", action: controller.skip)]
        case .silence:
            if screen.action == .openSound { return [.item("Open Sound settings") { NSWorkspace.shared.open(.soundSettings) }] }
            return controller.hold != nil && controller.status != .paused ? [next] : [playOrPause, next]
        }
    }

    private func rows() -> [MenuEntry] {
        let plan = controller.dayPlan()
        return plan.rows.filter(\.alarm.on).map { row in
            var entry = MenuEntry.item(row.alarm.name) { [self] in
                AppDelegate.showMain()
                let source = row.alarm.source
                router.go(to: controller.playlists.contains { $0.id == source } ? .playlist(source) : .album(source))
            }
            entry.detail = plan.label(of: row.alarm.source) ?? ""
            return entry
        }
    }

    private func silence() -> MenuEntry {
        let controller = controller
        var entry = MenuEntry.submenu("Silence", controller.allPresets.map { preset in
            .item(preset.name, checked: preset.name == controller.settings.name) { controller.apply(preset) }
        })
        entry.detail = controller.settings.name
        return entry
    }

    private func sleep() -> MenuEntry {
        let controller = controller
        let timer = controller.sleepTimer
        let resting = controller.status == .resting
        var entries: [MenuEntry] = timer.map { [.item("stops \(Format.sleep($0, resting: resting, at: .now, sentence: true))", enabled: false) {}, .divider] } ?? []
        entries.append(.item(resting ? "After the next song" : "After this song", checked: timer == .afterCurrent) {
            timer == .afterCurrent ? controller.cancelSleep() : controller.sleepAfterCurrent()
        })
        entries.append(.divider)
        entries += [15.0, 30, 45, 60, 90].map { minutes in .item(Format.minutes(minutes * 60)) { controller.sleep(minutes: minutes) } }
        if timer != nil { entries += [.divider, .item("Turn off", action: controller.cancelSleep)] }
        var entry = MenuEntry.submenu("Sleep", entries)
        entry.enabled = controller.status != .idle
        return entry
    }
}

extension URL {
    static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
}
