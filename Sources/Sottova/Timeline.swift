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
        TimelineView(.animation(minimumInterval: resting ? (compact ? 1 / 15 : 1 / 30) : 0.5,
                                paused: !visible || controller.status == .idle || controller.status == .paused)) { context in
            Canvas { gc, size in
                draw(in: gc, size: size, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in gc: GraphicsContext, size: CGSize, time: Double) {
        let resting = controller.status == .resting
        let height = size.height - 1
        gc.fill(Path(CGRect(x: 0, y: height, width: size.width, height: 1)), with: .color(Theme.border))

        if compact {
            if resting {
                dots(in: gc, from: size.width * 0.3, width: size.width * 0.4, y: height + 0.5, time: time, breathing: true)
            } else if let track = controller.track {
                envelope(track, in: gc, width: size.width, height: height, resting: false)
            }
            return
        }
        let trackWidth = size.width * 0.7
        if let track = controller.track {
            envelope(track, in: gc, width: trackWidth, height: height, resting: resting)
        }
        dots(in: gc, from: trackWidth, width: size.width * 0.18, y: height + 0.5, time: time, breathing: resting)
        nextFadeIn(in: gc, from: size.width * 0.9, width: size.width * 0.1, height: height)
    }

    private func envelope(_ track: Track, in gc: GraphicsContext, width: CGFloat, height: CGFloat, resting: Bool) {
        let curve = controller.settings.curve
        var shape = Path()
        shape.move(to: CGPoint(x: 0, y: height))
        for x in stride(from: 0, through: width, by: 2) {
            let gain = track.gain(at: track.time(at: Double(x / width)), curve)
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
        done.fill(shape, with: .color(Theme.text))
        var ahead = gc
        ahead.clip(to: Path(CGRect(x: played, y: 0, width: width - played, height: height)))
        ahead.fill(shape, with: .color(Theme.text.opacity(0.18)))
    }

    /// The silence: dots on the baseline that breathe while resting, a slow wave rather than a countdown.
    private func dots(in gc: GraphicsContext, from x0: CGFloat, width: CGFloat, y: CGFloat, time: Double, breathing: Bool) {
        let r: CGFloat = 1.5
        for i in 0..<5 {
            let x = x0 + width * (CGFloat(i) + 0.5) / 5
            let opacity = breathing ? 0.35 + 0.65 * max(0, sin(time * 1.6 - Double(i) * 0.7)) : 0.6
            gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color((breathing ? Theme.text : Theme.decor).opacity(opacity)))
        }
    }

    /// The next track is unknown: only the start of its fade-in, trailing off at the edge.
    private func nextFadeIn(in gc: GraphicsContext, from x0: CGFloat, width: CGFloat, height: CGFloat) {
        var shape = Path()
        shape.move(to: CGPoint(x: x0, y: height))
        for x in stride(from: 0, through: width, by: 2) {
            let gain = controller.settings.curve.fadeIn(Double(x / width)) * 0.5
            shape.addLine(to: CGPoint(x: x0 + x, y: height - CGFloat(gain) * height))
        }
        shape.addLine(to: CGPoint(x: x0 + width, y: height))
        shape.closeSubpath()
        gc.fill(shape, with: .linearGradient(Gradient(colors: [Theme.decor.opacity(0.6), Theme.decor.opacity(0)]),
                                             startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x0 + width, y: 0)))
    }
}
