import AppKit
import SwiftUI
import SottovaCore

/// The transport, drawn in the window's content under a hidden toolbar: hosted in the toolbar it sits beside the lights.
struct TitleBar: View {
    let narrow: Bool
    let toggleQueue: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router

    var body: some View {
        let running = controller.status == .playing || controller.status == .resting
        let idle = controller.status == .idle
        ZStack {
            nowPlaying
            HStack(spacing: 2) {
                BarButton(icon: running ? .barPause : .barPlay, strong: true, help: running ? "pause" : "play") { controller.toggle() }
                    .disabled(controller.tracks.isEmpty)
                BarButton(icon: .barSkip, strong: true, help: controller.status == .resting ? "end the silence" : "skip") { controller.skip() }
                    .disabled(idle)
                Spacer(minLength: 0)
                Moon().disabled(idle)
                BarButton(icon: .barQueue, on: router.showsQueue, help: router.showsQueue ? "hide the queue" : "show the queue", action: toggleQueue)
                    .disabled(controller.tracks.isEmpty)
                if !narrow {
                    BarVolume().padding(.leading, 14)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 20)
        }
        .frame(height: 52)
        .background(TitleDrag())
    }

    /// Off Now, what's sounding. Silence says nothing up here.
    @ViewBuilder
    private var nowPlaying: some View {
        if router.route != .home, controller.status == .playing || controller.status == .paused, let song = controller.current {
            // not on the click that brings the window forward: going to Now would clear a picked row's selection
            BarControl(firstClick: false, pressScale: 0.99, help: "show what's playing", action: { _ in router.go(to: .home) }) { _ in
                HStack(spacing: 6) {
                    Text(song.title).foregroundStyle(Theme.text)
                    Text(song.artist).foregroundStyle(Theme.muted).layoutPriority(-1)
                }
                .role(.body)
                .lineLimit(1)
            } access: {
                Button("\(song.title), \(song.artist)") { router.go(to: .home) }
                    .accessibilityHint("show what's playing")
            }
            .padding(.leading, 96)
            .padding(.trailing, narrow ? 110 : 190)
        }
    }
}

/// The blank parts of the title bar's band, which move and zoom the window as a title bar does.
struct TitleDrag: View {
    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.performZoom(nil) })
    }
}

private struct BarIcon: View {
    let icon: Ph
    var strong = false
    var on = false
    let hovering: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        icon.icon(.line, size: 18)
            .foregroundStyle(!enabled ? Theme.disabled : strong || on ? Theme.text : Theme.muted)
            .frame(width: 32, height: 28)
            .background(on ? Theme.selection : enabled && hovering ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.small))
    }
}

private struct BarButton: View {
    let icon: Ph
    var strong = false
    var on = false
    let help: String
    let action: () -> Void

    var body: some View {
        BarControl(help: help, action: { _ in action() }) { hovering in
            BarIcon(icon: icon, strong: strong, on: on, hovering: hovering)
        } access: {
            Button(help, action: action)
        }
    }
}

/// A control in the title bar's band, pressed through a plain view as `Strip` is, so the window can't take the press
/// as a drag. `firstClick`: whether the click that brings an inactive window forward acts too.
private struct BarControl<Label: View, Access: View>: View {
    var firstClick = true
    var pressScale = 0.96
    let help: String
    let action: (NSView) -> Void
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    @ViewBuilder let access: () -> Access
    @State private var pressed = false
    @State private var hovering = false

    var body: some View {
        label(hovering)
            .scaleEffect(pressed ? pressScale : 1)
            .overlay(BarHit(firstClick: firstClick, help: help, pressed: $pressed, hovering: $hovering, action: action))
            .accessibilityRepresentation(representation: access)
    }
}

private struct BarHit: NSViewRepresentable {
    let firstClick: Bool
    let help: String
    @Binding var pressed: Bool
    @Binding var hovering: Bool
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> Hit { Hit() }

    func updateNSView(_ hit: Hit, context: Context) {
        hit.control = self
        hit.enabled = context.environment.isEnabled
        hit.toolTip = help
    }

    final class Hit: NSView {
        var control: BarHit?
        var enabled = true
        private var armed = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { control?.firstClick ?? false }

        private func inside(_ event: NSEvent) -> Bool {
            bounds.contains(convert(event.locationInWindow, from: nil))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { control?.hovering = true }
        override func mouseExited(with event: NSEvent) { control?.hovering = false }

        override func mouseDown(with event: NSEvent) {
            armed = enabled
            control?.pressed = armed
        }

        override func mouseDragged(with event: NSEvent) {
            control?.pressed = armed && inside(event)
        }

        override func mouseUp(with event: NSEvent) {
            let fires = armed && enabled && inside(event)
            armed = false
            control?.pressed = false
            if fires { control?.action(self) }
        }
    }
}

/// Set, it says how long is left beside it.
private struct Moon: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let timer = controller.sleepTimer
        let resting = controller.status == .resting
        BarControl(help: "sleep timer", action: open) { hovering in
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 2) {
                    if let timer {
                        Text(Format.sleep(timer, resting: resting, at: context.date))
                            .role(.small)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    BarIcon(icon: .barMoon, strong: timer != nil, hovering: hovering)
                }
            }
        } access: {
            Menu("sleep timer") { SleepChoices(controller: controller) }
                .accessibilityValue(timer.map { Format.sleep($0, resting: resting, at: .now) } ?? "off")
        }
        .fixedSize()
    }

    private func open(under view: NSView) {
        NSMenu(StatusMenu.sleepChoices(controller)).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }
}

private struct BarVolume: View {
    @Environment(Controller.self) private var controller
    private let width: CGFloat = 68

    var body: some View {
        @Bindable var controller = controller
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.hairline).frame(height: 3)
            Capsule().fill(Theme.muted).frame(width: width * controller.volume, height: 3)
            Circle()
                .fill(Theme.knob)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .offset(x: width * controller.volume - 6)
            Scrubber(changed: { controller.volume = $0 })
        }
        .frame(width: width, height: 28)
        .help("volume")
        .accessibilityRepresentation {
            Slider(value: $controller.volume, in: 0...1) { Text("Volume") }
        }
    }
}

/// The line under the bar is the player. A piece fills it, silence leaves it bare, and a click or drag moves in the piece.
struct Hairline: View {
    @Environment(Controller.self) private var controller
    @Environment(\.windowVisible) private var visible
    @State private var width: CGFloat = 0
    @State private var pointer: CGFloat?
    @State private var dragging = false
    @State private var fill = HairlineFill()

    private struct Key: Equatable {
        let status: PlaybackStatus, seeks, skips: Int, visible: Bool, width: CGFloat
    }

    // to 54, only 2 pt into the page: rows scrolled under it stay clickable
    private static let top: CGFloat = 44

    private var seekable: Track? {
        controller.status == .playing || controller.status == .paused ? controller.track : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: 51 - Self.top)
            FillHost(view: fill)
                .frame(height: 2)
                .offset(y: 50 - Self.top)
            Scrubber(changed: { fraction in
                guard seekable != nil else { return }
                dragging = true
                pointer = fraction * width
            }, ended: { fraction in
                dragging = false
                pointer = nil
                guard let track = seekable else { return }
                controller.seek(to: track.duration * fraction)
            }, hovered: { fraction in
                if !dragging { pointer = fraction.map { $0 * width } }
            })
            .frame(height: 10)
            if let track = seekable, let pointer {
                Text(Format.time(track.duration * pointer / max(width, 1)))
                    .role(.label)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Theme.popover, in: .rect(cornerRadius: 4))
                    .fixedSize()
                    .alignmentGuide(.leading) { $0.width / 2 - min(max(pointer, $0.width / 2 + 4), width - $0.width / 2 - 4) }
                    // under the line: above it is the window's edge and the buttons
                    .offset(y: 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 10, alignment: .topLeading)
        .offset(y: Self.top)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // a layer on its own clock: through SwiftUI, four updates a second cost 12% of a core in a hold
        .task(id: Key(status: controller.status, seeks: controller.seeks, skips: controller.skips, visible: visible, width: width)) {
            while !Task.isCancelled {
                let status = controller.status
                let (share, level) = reading(status)
                fill.show(width: width * share, level: level, paused: status == .paused)
                guard status == .playing, visible else { return }
                try? await Task.sleep(for: .seconds(0.25))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("position")
        .accessibilityValue(Format.time(seekable?.elapsed ?? 0))
        .accessibilityAdjustableAction { direction in
            guard let track = seekable else { return }
            controller.seek(to: track.elapsed + (direction == .increment ? 10 : -10))
        }
    }

    private func reading(_ status: PlaybackStatus) -> (fill: Double, level: Double) {
        guard status != .idle, let track = controller.track, track.duration > 0 else { return (0, 0) }
        let seen = track.visual(at: track.elapsed)
        let level = status == .resting || (controller.inSilence && !seen.silent) ? Track.Visual.resting.hairline : seen.hairline
        return (min(track.elapsed / track.duration, 1), level)
    }
}

private struct FillHost: NSViewRepresentable {
    let view: HairlineFill
    func makeNSView(context: Context) -> HairlineFill { view }
    func updateNSView(_ view: HairlineFill, context: Context) {}
}

final class HairlineFill: NSView {
    private let bar = CALayer()
    private var paused = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        bar.cornerRadius = 1
        bar.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(width: CGFloat, level: Double, paused: Bool) {
        self.paused = paused
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = CGRect(x: 0, y: 0, width: width, height: 2)
        bar.opacity = Float(level)
        color()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { color() }

    private func color() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.backgroundColor = NSColor(paused ? Theme.faint : Theme.primary).cgColor
        }
    }
}

/// A plain view, since in the title bar's band a DragGesture gets nothing in an inactive window, and a press there
/// would otherwise move the window. Reports where along itself, 0 to 1.
struct Scrubber: NSViewRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (CGFloat) -> Void = { _ in }
    var hovered: (CGFloat?) -> Void = { _ in }

    func makeNSView(context: Context) -> Strip { Strip() }

    func updateNSView(_ strip: Strip, context: Context) {
        strip.scrubber = self
    }

    final class Strip: NSView {
        var scrubber: Scrubber?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func fraction(_ event: NSEvent) -> CGFloat {
            bounds.width > 0 ? min(max(convert(event.locationInWindow, from: nil).x / bounds.width, 0), 1) : 0
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseDown(with event: NSEvent) { scrubber?.changed(fraction(event)) }
        override func mouseDragged(with event: NSEvent) { scrubber?.changed(fraction(event)) }
        override func mouseUp(with event: NSEvent) { scrubber?.ended(fraction(event)) }
        override func mouseMoved(with event: NSEvent) { scrubber?.hovered(fraction(event)) }
        override func mouseExited(with event: NSEvent) { scrubber?.hovered(nil) }
    }
}
