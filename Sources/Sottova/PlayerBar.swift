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
            HStack(spacing: 10) {
                presetMenu
                Volume()
            }
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
                RoundedRectangle(cornerRadius: 10).fill(Theme.raised.opacity(0.94))
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
                Group {
                    if let song, !resting {
                        LinkText(text: song.title) { navigate(.album(song.albumID)) }
                    } else {
                        Text(resting ? "resting" : "nothing playing")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Group {
                        if let song, !resting {
                            LinkText(text: song.artist) { navigate(.artist(controller.catalog.artist(of: song))) }
                        } else {
                            Text(controller.subline(at: context.date))
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                }
            }
            .animation(Theme.ambient, value: resting)
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(SottovaCore.Settings.presets, id: \.name) { preset in
                Button {
                    controller.apply(preset)
                } label: {
                    if preset.name == controller.settings.name {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .semibold))
                Text(controller.settings.name)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .hoverable(radius: 6)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(Format.gaps(controller.settings))
    }
}

/// Elapsed and total time with a thin line between. Once a second is enough: the label only changes that often,
/// and animating the width would relayout at display rate for the whole track.
private struct ProgressLine: View {
    @Environment(Controller.self) private var controller
    @Environment(\.windowVisible) private var visible

    var body: some View {
        let resting = controller.status == .resting
        TimelineView(.periodic(from: .now, by: controller.status == .playing && visible ? 1 : 60)) { _ in
            ZStack {
                if resting {
                    HStack(spacing: 10) {
                        line(fill: 0)
                        Text("resting")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.faint)
                            .fixedSize()
                        line(fill: 0)
                    }
                    .transition(.opacity)
                } else {
                    let track = controller.track
                    let elapsed = track?.elapsed ?? 0
                    let duration = track?.duration ?? 0
                    HStack(spacing: 10) {
                        time(elapsed)
                        line(fill: duration > 0 ? min(elapsed / duration, 1) : 0)
                        time(duration)
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(height: 14)
        .opacity(controller.status == .idle ? 0 : 1)
        .animation(Theme.ambient, value: resting)
    }

    private func line(fill: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Theme.text.opacity(0.15))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.text)
                    .scaleEffect(x: fill, anchor: .leading)
            }
            .frame(height: 4)
    }

    private func time(_ seconds: Double) -> some View {
        Text(Format.time(seconds))
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.faint)
            .frame(width: 36)
    }
}

private struct Volume: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 8) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
            Slider(value: $controller.volume, in: 0...1)
                .controlSize(.mini)
                .tint(Theme.text)
                .frame(width: 92)
        }
        .help("volume")
    }
}
