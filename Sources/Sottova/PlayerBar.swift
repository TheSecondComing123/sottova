import SwiftUI
import SottovaCore

/// The floating bar at the bottom of the window. During a gap the progress line goes quiet and says so.
struct PlayerBar: View {
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @Environment(\.colorScheme) private var colorScheme

    private var running: Bool {
        controller.status == .playing || controller.status == .resting
    }

    var body: some View {
        HStack(spacing: 16) {
            nowPlaying
                .frame(minWidth: 170, maxWidth: 280, alignment: .leading)
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                HStack(spacing: 18) {
                    // balances the skip button so play sits on the progress line's center
                    Color.clear.frame(width: 30, height: 30)
                    PlayCircle(size: 36, playing: running) { controller.toggle() }
                        .disabled(controller.tracks.isEmpty)
                    IconButton(systemImage: "forward.end.fill", help: controller.status == .resting ? "end the gap" : "skip", size: 30) {
                        controller.skip()
                    }
                    .disabled(controller.status == .idle)
                }
                ProgressLine()
                    .frame(minWidth: 220, maxWidth: 440)
            }
            Spacer(minLength: 12)
            Volume()
                .frame(minWidth: 150, maxWidth: 280, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 84)
        .background {
            // in light mode a material reads darker than the page, so the bar looks sunk instead of raised
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 10).fill(Theme.raised.opacity(0.85))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Theme.raised)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: colorScheme == .dark ? 18 : 12, y: colorScheme == .dark ? 8 : 4)
    }

    private var nowPlaying: some View {
        let song = controller.status == .idle ? nil : controller.current
        let resting = controller.status == .resting
        return HStack(spacing: 12) {
            Artwork(key: song?.artwork, size: 52, radius: 6)
                .opacity(resting ? 0.45 : 1)
                .saturation(resting ? 0 : 1)
                .animation(Theme.ambient, value: resting)
            VStack(alignment: .leading, spacing: 3) {
                // in a gap the last piece stays, dimmed: the dots under the transport already say it's resting
                Group {
                    if let song {
                        LinkText(text: song.work) { navigate(.album(song.albumID)) }
                    } else {
                        Text("nothing playing")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(resting ? Theme.faint : Theme.text)
                .lineLimit(1)

                if let song {
                    LinkText(text: song.artist) { navigate(.artist(song.artist)) }
                        .font(.system(size: 13))
                        .foregroundStyle(resting ? Theme.faint : Theme.muted)
                }
            }
            .animation(Theme.ambient, value: resting)
        }
    }
}

/// Elapsed and total time around the track's fade shape, so every page shows the fades. During a gap the times
/// step back and the shape becomes breathing dots on a bare line. The labels change once a second, so that's their rate.
private struct ProgressLine: View {
    @Environment(Controller.self) private var controller
    @Environment(\.windowVisible) private var visible

    var body: some View {
        let resting = controller.status == .resting
        TimelineView(.periodic(from: .now, by: controller.status == .playing && visible ? 1 : 60)) { _ in
            let track = controller.track
            HStack(spacing: 10) {
                time(track?.elapsed ?? 0)
                Timeline(controller: controller, compact: true, visible: visible)
                    .frame(height: 18)
                time(track?.duration ?? 0)
            }
        }
        .opacity(controller.status == .idle ? 0 : 1)
        .animation(Theme.ambient, value: resting)
    }

    private func time(_ seconds: Double) -> some View {
        Text(Format.time(seconds))
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.faint)
            .frame(width: 36)
            .opacity(controller.status == .resting ? 0 : 1)
    }
}

private struct Volume: View {
    @Environment(Controller.self) private var controller
    @State private var hovering = false
    @State private var dragging = false
    private let width: CGFloat = 92

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 8) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
            // a plain line like the rest of the bar; the knob only shows when you reach for it
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.text.opacity(0.15)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Theme.text).frame(width: width * controller.volume, height: 4)
                Circle()
                    .fill(Theme.text)
                    .frame(width: 10, height: 10)
                    .offset(x: width * controller.volume - 5)
                    .opacity(hovering || dragging ? 1 : 0)
            }
            .frame(width: width, height: 16)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    controller.volume = min(max(drag.location.x / width, 0), 1)
                }
                .onEnded { _ in dragging = false })
            .animation(Theme.quick, value: hovering || dragging)
            .accessibilityRepresentation {
                Slider(value: $controller.volume, in: 0...1) { Text("Volume") }
            }
        }
        .help("volume")
    }
}
