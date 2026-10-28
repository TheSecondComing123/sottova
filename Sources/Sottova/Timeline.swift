import SwiftUI
import SottovaCore

/// The track as bars shaped by its fade envelope, the silence as dots, then the next fade-in.
/// The gap has a fixed width on purpose: drawing its real length would give away when the next track starts.
struct Timeline: View {
    let controller: Controller
    var bars = 32

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: controller.status == .idle || controller.status == .paused)) { context in
            Canvas { gc, size in
                draw(in: gc, size: size, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in gc: GraphicsContext, size: CGSize, time: Double) {
        let color = Mocha.accent(for: controller.title)
        let resting = controller.status == .resting
        let trackWidth = size.width * 0.62
        let step = trackWidth / CGFloat(bars)

        for i in 0..<bars {
            let height: CGFloat
            var fill = color.opacity(0.22)
            if let track = controller.track {
                let t = (Double(i) + 0.5) / Double(bars) * track.duration
                height = max(3, CGFloat(track.gain(at: t, controller.settings.curve)) * size.height)
                if resting {
                    fill = color.opacity(0.35)
                } else if t <= track.elapsed {
                    fill = color
                }
            } else {
                height = 3
                fill = Mocha.surface1
            }
            bar(in: gc, x: CGFloat(i) * step, width: step * 0.62, height: height, size: size, fill: fill)
        }

        // the silence: dots that breathe while resting, a slow wave rather than a countdown
        let dots = 5
        let gapStart = trackWidth + step
        let gapWidth = size.width * 0.24
        for i in 0..<dots {
            let x = gapStart + gapWidth * (CGFloat(i) + 0.5) / CGFloat(dots)
            var opacity = 0.35
            if resting {
                opacity = 0.3 + 0.55 * max(0, sin(time * 1.6 - Double(i) * 0.7))
            }
            let r: CGFloat = 2.5
            gc.fill(Path(ellipseIn: CGRect(x: x - r, y: size.height - r * 2 - 1, width: r * 2, height: r * 2)), with: .color(Mocha.overlay0.opacity(opacity)))
        }

        // the next track is unknown, so its fade-in is drawn in neutral
        let nextStart = gapStart + gapWidth + step * 0.5
        for (i, level) in [0.12, 0.3, 0.55].enumerated() {
            bar(in: gc, x: nextStart + CGFloat(i) * step, width: step * 0.62, height: max(3, level * size.height), size: size, fill: Mocha.overlay0.opacity(0.4))
        }
    }

    private func bar(in gc: GraphicsContext, x: CGFloat, width: CGFloat, height: CGFloat, size: CGSize, fill: Color) {
        let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
        gc.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)), with: .color(fill))
    }
}
