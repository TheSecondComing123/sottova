#if NEWLOOK
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
    }

    /// Off Now, what's sounding. Silence says nothing up here.
    @ViewBuilder
    private var nowPlaying: some View {
        if router.route != .home, controller.status == .playing || controller.status == .paused, let song = controller.current {
            HStack(spacing: 6) {
                Text(song.title).foregroundStyle(Theme.text)
                Text(song.artist).foregroundStyle(Theme.muted).layoutPriority(-1)
            }
            .role(.body)
            .lineLimit(1)
            .padding(.leading, 96)
            .padding(.trailing, narrow ? 110 : 190)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
        }
    }
}

private struct BarIcon: View {
    let icon: Ph
    var strong = false
    var on = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        icon.icon(.line, size: 18)
            .foregroundStyle(!enabled ? Theme.disabled : strong || on ? Theme.text : Theme.muted)
            .frame(width: 32, height: 28)
            .background(on ? Theme.selection : enabled && hovering ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.small))
            .onHover { hovering = $0 }
    }
}

private struct BarButton: View {
    let icon: Ph
    var strong = false
    var on = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { BarIcon(icon: icon, strong: strong, on: on) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Set, it says how long is left beside it.
private struct Moon: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        let timer = controller.sleepTimer
        let resting = controller.status == .resting
        Menu {
            SleepChoices(controller: controller)
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 2) {
                    if let timer {
                        Text(Format.sleep(timer, resting: resting, at: context.date))
                            .role(.small)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    BarIcon(icon: .barMoon, strong: timer != nil)
                }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("sleep timer")
        .accessibilityLabel("sleep timer")
        .accessibilityValue(timer.map { Format.sleep($0, resting: resting, at: .now) } ?? "off")
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

    private static let top: CGFloat = 48

    private var seekable: Track? {
        controller.status == .playing || controller.status == .paused ? controller.track : nil
    }

    var body: some View {
        // paused, nothing ticks: a seek or a skip has to redraw it
        let _ = (controller.seeks, controller.skips)
        let status = controller.status
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: 51 - Self.top)
            TimelineView(.periodic(from: .now, by: status == .playing && visible ? 0.25 : 60)) { _ in
                let (fill, level) = reading(status)
                UnevenRoundedRectangle(bottomTrailingRadius: 1, topTrailingRadius: 1)
                    .fill(status == .paused ? Theme.faint : Theme.primary)
                    .frame(width: width * fill, height: 2)
                    .opacity(level)
                    .offset(y: 50 - Self.top)
            }
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
            .frame(height: 12)
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
                    .offset(y: 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 12, alignment: .topLeading)
        .offset(y: Self.top)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
#endif
