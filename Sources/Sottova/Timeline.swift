import SwiftUI
import SottovaCore

/// The track as bars shaped by its fade envelope, the silence as dots on a bare baseline, then the next fade-in.
/// The gap has a fixed width on purpose: drawing its real length would give away when the next track starts.
struct Timeline: View {
    let controller: Controller
    var bars = 32
    /// The menu-bar panel's window stays alive while closed; animating it then cost about 10% CPU.
    var visible = true

    var body: some View {
        let resting = controller.status == .resting
        // only the breathing dots need frames; while playing a bar fills every few seconds
        TimelineView(.animation(minimumInterval: resting ? 1 / 30 : 0.5,
                                paused: !visible || controller.status == .idle || controller.status == .paused)) { context in
            Canvas { gc, size in
                draw(in: gc, size: size, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in gc: GraphicsContext, size: CGSize, time: Double) {
        let resting = controller.status == .resting
        let trackWidth = size.width * 0.62
        let step = trackWidth / CGFloat(bars)

        gc.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.border))

        for i in 0..<bars {
            var height: CGFloat = 0
            var fill = Theme.decor
            if let track = controller.track {
                let t = (Double(i) + 0.5) / Double(bars) * track.duration
                height = CGFloat(track.gain(at: t, controller.settings.curve)) * size.height
                if resting {
                    // the track is done, not undone: it stays drawn as played, just quieter
                    fill = Theme.text.opacity(0.55)
                } else if t <= track.elapsed {
                    fill = Theme.text
                } else {
                    fill = Theme.text.opacity(0.2)
                }
            }
            if height >= 1 {
                bar(in: gc, x: CGFloat(i) * step, width: step * 0.62, height: height, size: size, fill: fill)
            }
        }

        // the silence: dots that breathe while resting, a slow wave rather than a countdown
        let dots = 5
        let gapStart = trackWidth + step
        let gapWidth = size.width * 0.22
        for i in 0..<dots {
            let x = gapStart + gapWidth * (CGFloat(i) + 0.5) / CGFloat(dots)
            var opacity = 0.6
            if resting {
                opacity = 0.35 + 0.65 * max(0, sin(time * 1.6 - Double(i) * 0.7))
            }
            let r: CGFloat = 2.5
            gc.fill(Path(ellipseIn: CGRect(x: x - r, y: size.height - r * 2 - 4, width: r * 2, height: r * 2)),
                    with: .color((resting ? Theme.text : Theme.decor).opacity(opacity)))
        }

        // the next track is unknown: a fade-in that rises and trails off, drawn in neutral
        let nextStart = gapStart + gapWidth + step * 0.5
        let levels = [0.08, 0.16, 0.26, 0.36, 0.44, 0.5]
        for (i, level) in levels.enumerated() {
            let x = nextStart + CGFloat(i) * step
            guard x + step * 0.62 <= size.width else { break }
            let fade = 0.5 * (1 - Double(i) / Double(levels.count))
            bar(in: gc, x: x, width: step * 0.62, height: level * size.height, size: size, fill: Theme.decor.opacity(fade))
        }
    }

    private func bar(in gc: GraphicsContext, x: CGFloat, width: CGFloat, height: CGFloat, size: CGSize, fill: Color) {
        let rect = CGRect(x: x, y: size.height - 1 - height, width: width, height: height)
        gc.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)), with: .color(fill))
    }
}
