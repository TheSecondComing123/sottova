import SwiftUI
import SottovaCore

/// The track's fade envelope as one filled shape, the silence as dots on a bare baseline, then the next fade-in.
/// The fades get fixed shares of the width (Track.position): at true scale an 8 s fade on an 8-minute piece is a sliver.
/// The gap has a fixed width on purpose: drawing its real length would give away when the next track starts.
struct Timeline: View {
    let controller: Controller
    /// The player bar's version: only the playing track, or only the gap, across the whole width.
    var compact = false
    /// The menu-bar panel's window stays alive while closed; animating it then cost about 10% CPU.
    var visible = true

    var body: some View {
        let resting = controller.status == .resting
        // only the breathing dots need frames; while playing the played part grows a few points a second
        // the hero and the bar share one rate, so a gap redraws the window 15 times a second, not 45
        TimelineView(.animation(minimumInterval: resting ? 1 / 15 : 0.5,
                                paused: !visible || controller.status == .idle || controller.status == .paused)) { context in
            Canvas { gc, size in
                draw(in: gc, size: size, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in gc: GraphicsContext, size: CGSize, time: Double) {
        let resting = controller.status == .resting
        if compact {
            // a hairline that swells to 4 pt while the track holds and thins out through its fades
            let middle = size.height / 2
            gc.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)), with: .color(Theme.border))
            if resting {
                dots(in: gc, around: size.width / 2, y: middle, time: time, breathing: true)
            } else if let track = controller.track {
                stroke(track, in: gc, width: size.width, middle: middle)
            }
            return
        }
        let height = size.height - 1
        gc.fill(Path(CGRect(x: 0, y: height, width: size.width, height: 1)), with: .color(Theme.border))
        let trackWidth = size.width * 0.7
        if let track = controller.track {
            envelope(track, in: gc, width: trackWidth, height: height, resting: resting)
        }
        dots(in: gc, around: trackWidth + size.width * 0.09, y: height + 0.5, time: time, breathing: resting)
        nextFadeIn(in: gc, from: size.width * 0.9, width: size.width * 0.1, height: height)
    }

    private func envelope(_ track: Track, in gc: GraphicsContext, width: CGFloat, height: CGFloat, resting: Bool) {
        let curve = controller.settings.curve
        // the sleep timer's ease-down lowers the whole shape: what's left of the piece will be that quiet
        let sleep = controller.sleepLevel
        var shape = Path()
        shape.move(to: CGPoint(x: 0, y: height))
        for x in stride(from: 0, through: width, by: 2) {
            let gain = track.gain(at: track.time(at: Double(x / width)), curve) * sleep
            shape.addLine(to: CGPoint(x: x, y: height - CGFloat(gain) * height))
        }
        shape.addLine(to: CGPoint(x: width, y: height))
        shape.closeSubpath()
        guard !resting else {
            // the track is done, not undone: it stays drawn as played, just quieter
            gc.fill(shape, with: .color(Theme.text.opacity(0.4)))
            return
        }
        let played = CGFloat(track.position(at: track.elapsed)) * width
        var done = gc
        done.clip(to: Path(CGRect(x: 0, y: 0, width: played, height: height)))
        done.fill(shape, with: .color(Theme.accent(for: controller.current?.album)))
        var ahead = gc
        ahead.clip(to: Path(CGRect(x: played, y: 0, width: width - played, height: height)))
        ahead.fill(shape, with: .color(Theme.text.opacity(0.18)))
    }

    private func stroke(_ track: Track, in gc: GraphicsContext, width: CGFloat, middle: CGFloat) {
        let curve = controller.settings.curve
        // falling asleep, the band thins toward the hairline with the sound
        let sleep = controller.sleepLevel
        var top: [CGPoint] = []
        for x in stride(from: 0, through: width, by: 2) {
            let gain = track.gain(at: track.time(at: Double(x / width)), curve) * sleep
            top.append(CGPoint(x: x, y: middle - 2 * CGFloat(gain)))
        }
        var band = Path()
        band.addLines(top)
        band.addLines(top.reversed().map { CGPoint(x: $0.x, y: 2 * middle - $0.y) })
        band.closeSubpath()
        let played = CGFloat(track.position(at: track.elapsed)) * width
        var done = gc
        done.clip(to: Path(CGRect(x: 0, y: 0, width: played, height: middle * 2)))
        done.fill(band, with: .color(Theme.accent(for: controller.current?.album)))
        var ahead = gc
        ahead.clip(to: Path(CGRect(x: played, y: 0, width: width - played, height: middle * 2)))
        ahead.fill(band, with: .color(Theme.text.opacity(0.3)))
    }

    /// The silence: dots on the baseline that breathe while resting, a slow wave rather than a countdown.
    private func dots(in gc: GraphicsContext, around center: CGFloat, y: CGFloat, time: Double, breathing: Bool) {
        let r: CGFloat = 2.5
        for i in 0..<5 {
            // a 60 pt cluster, 15 pt apart: spread wider, five dots read as dust
            let x = center + CGFloat(i - 2) * 15
            let opacity = breathing ? 0.3 + 0.7 * max(0, sin(time * 1.6 - Double(i) * 0.7)) : 0.6
            gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(Theme.muted.opacity(opacity)))
        }
    }

    /// The next track is unknown: only the start of its fade-in, cut off at the edge.
    private func nextFadeIn(in gc: GraphicsContext, from x0: CGFloat, width: CGFloat, height: CGFloat) {
        var shape = Path()
        shape.move(to: CGPoint(x: x0, y: height))
        for x in stride(from: 0, through: width, by: 2) {
            let gain = controller.settings.curve.fadeIn(Double(x / width)) * 0.5
            shape.addLine(to: CGPoint(x: x0 + x, y: height - CGFloat(gain) * height))
        }
        shape.addLine(to: CGPoint(x: x0 + width, y: height))
        shape.closeSubpath()
        gc.fill(shape, with: .color(Theme.decor.opacity(0.3)))
    }
}

/// Click or drag along a piece to move in it. Dragging only shows where; the jump comes on release, because every
/// jump fades back in from silence. x maps through the drawing's own fade shares, so the time shown is the time
/// under the pointer, not a straight fraction of the length.
struct Seeker: ViewModifier {
    let controller: Controller
    /// The share of the width the piece is drawn across: the hero leaves room for the gap and the next fade-in.
    var span: CGFloat = 1
    @State private var pointer: CGFloat?
    @State private var dragging = false
    @State private var width: CGFloat = 0

    private var seekable: Track? {
        guard controller.status == .playing || controller.status == .paused else { return nil }
        return controller.track
    }

    private var piece: CGFloat { width * span }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .topLeading) {
                if let track = seekable, let x = pointer, x >= 0, x <= piece {
                    Rectangle()
                        .fill(Theme.text)
                        .frame(width: 1)
                        .offset(x: x)
                        .allowsHitTesting(false)
                    Text(Format.time(track.time(at: Double(x / piece))))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Theme.raised, in: .rect(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                        .fixedSize()
                        // centered on the tick but kept over the line, 8 pt above it
                        .alignmentGuide(.leading) { $0.width / 2 - min(max(x, $0.width / 2), piece - $0.width / 2) }
                        .alignmentGuide(.top) { $0.height + 8 }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                guard !dragging else { return }
                if case .active(let point) = phase { pointer = point.x } else { pointer = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard seekable != nil else { return }
                    dragging = true
                    pointer = min(max(drag.location.x, 0), piece)
                }
                .onEnded { drag in
                    dragging = false
                    pointer = nil
                    guard seekable != nil, piece > 0, drag.startLocation.x <= piece else { return }
                    controller.seek(to: controller.track?.time(at: Double(min(max(drag.location.x, 0), piece) / piece)) ?? 0)
                })
    }
}

extension View {
    func seeker(_ controller: Controller, span: CGFloat = 1) -> some View {
        modifier(Seeker(controller: controller, span: span))
    }
}
