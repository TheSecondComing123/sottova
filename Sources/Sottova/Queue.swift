import SwiftUI
import SottovaCore

/// What plays next, floating over the right of the page the way the player bar floats over its bottom. Not modal:
/// the page stays live behind it. Drag rows to reorder; the list is native, so the insertion line is too.
struct QueuePanel: View {
    let close: () -> Void
    @Environment(Controller.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                IconButton(icon: .x, weight: .bold, help: "close", size: 24, action: close)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 48)

            List {
                label("Now playing")
                nowPlaying
                    .row()
                HStack(alignment: .firstTextBaseline) {
                    label("Next up")
                    Spacer()
                    if !controller.upNext.isEmpty {
                        LinkText(text: "Clear") { withAnimation(Theme.quick) { controller.clearQueue() } }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 16)
                .row()
                if controller.upNext.isEmpty {
                    Text("nothing queued. play next on any song puts it here")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .padding(.vertical, 8)
                        .row()
                }
                ForEach(controller.upNext) { entry in
                    QueueRow(entry: entry)
                        .row()
                }
                .onMove { controller.moveQueued(fromOffsets: $0, toOffset: $1) }
                Text(controller.upNext.isEmpty ? "shuffling everything" : "then shuffling everything")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 12)
                    .row()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(Theme.quick, value: controller.upNext)
        }
        .frame(width: 340)
        .background(Theme.raised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.faint)
            .row()
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if controller.status == .resting {
            // like the rest of the app, the gap doesn't say how long it has left
            VStack(alignment: .leading, spacing: 2) {
                Text("resting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(controller.subline(at: context.date))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                }
            }
            .frame(height: 56, alignment: .leading)
        } else if controller.status != .idle, let song = controller.current {
            SongLine(song: song, art: 40, trailing: Format.time(song.duration))
                .frame(height: 56)
        } else {
            Text("nothing playing")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .frame(height: 56, alignment: .leading)
        }
    }
}

private struct QueueRow: View {
    let entry: QueueEntry
    @Environment(Controller.self) private var controller
    @State private var hovering = false

    var body: some View {
        let song = controller.catalog.songsByID[entry.path]
        HStack(spacing: 8) {
            if let song {
                SongLine(song: song, art: 32, trailing: hovering ? nil : Format.time(song.duration))
            } else {
                Text(URL(filePath: entry.path).deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if hovering {
                IconButton(icon: .x, weight: .bold, help: "remove from the queue", size: 24) {
                    withAnimation(Theme.quick) { controller.removeQueued(entry.id) }
                }
            }
        }
        .frame(height: 48)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// Art, the work over the performer, and a time on the right.
private struct SongLine: View {
    let song: Song
    let art: CGFloat
    let trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            Artwork(key: song.artwork, size: art, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.work)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(song.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

private extension View {
    /// A list row with nothing of the list's own look: no separator, background or inset beyond the panel's.
    func row() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
    }
}
