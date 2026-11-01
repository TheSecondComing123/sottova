import SwiftUI
import SottovaCore

/// What plays next, floating over the right of the page the way the player bar floats over its bottom. Not modal:
/// the page stays live behind it. Drag rows to reorder; the list is native, so the insertion line is too.
struct QueuePanel: View {
    let close: () -> Void
    @Environment(Controller.self) private var controller

    private static let rowHeight: CGFloat = 45

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next")
                .role(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.bottom, 5)
            if controller.upNext.isEmpty {
                Text("Nothing queued. Drop songs here, or right-click one and pick Play next.")
                    .role(.body)
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .dropDestination(for: URL.self) { urls, _ in queue(urls, at: 0) }
            } else {
                List {
                    ForEach(controller.upNext) { entry in
                        QueueRow(entry: entry).row()
                    }
                    .onMove { controller.moveQueued(fromOffsets: $0, toOffset: $1) }
                    .onInsert(of: [.fileURL]) { index, providers in
                        Task {
                            var urls: [URL] = []
                            for provider in providers {
                                if let url = await Self.url(from: provider) { urls.append(url) }
                            }
                            _ = queue(urls, at: index)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(Theme.quick, value: controller.upNext)
                .frame(height: min(CGFloat(controller.upNext.count) * Self.rowHeight, 500))
                Text("Drag to change the order.")
                    .role(.body)
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
            }
        }
        .padding(.top, 13)
        .padding(.bottom, 8)
        .frame(width: 320)
        .background(Theme.popover, in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(.black.opacity(0.5), lineWidth: 0.5).padding(-0.25))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 14)
    }

    private func queue(_ urls: [URL], at index: Int) -> Bool {
        let songs = urls.compactMap { controller.catalog.songsByID[$0.standardizedFileURL.path] }
        guard !songs.isEmpty else { return false }
        withAnimation(Theme.quick) { controller.playNext(songs, at: index) }
        return true
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
        }
    }

}

private struct QueueRow: View {
    let entry: QueueEntry
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @State private var hovering = false

    var body: some View {
        let song = controller.catalog.songsByID[entry.path]
        HStack(spacing: 8) {
            if let song {
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).role(.body).foregroundStyle(Theme.text)
                    Text(song.artist).role(.small).foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if !hovering {
                    Text(Format.time(song.duration)).role(.body).monospacedDigit().foregroundStyle(Theme.faint)
                }
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
        .frame(height: 45)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help("drag to reorder")
        .sottovaMenu {
            [.item("Play now") { controller.playQueued(entry.id) }]
                + (song.map { song in [.item("Go to \(controller.copy(ofAlbum: song.albumID)?.name ?? song.album)") { navigate(.album(song.albumID)) }] } ?? [])
                + [
                    .divider,
                    .item("Remove from the queue") { withAnimation(Theme.quick) { controller.removeQueued(entry.id) } },
                ]
        }
    }
}


private extension View {
    /// A list row with nothing of the list's own look: no separator, background or inset beyond the panel's.
    func row() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 4))
    }
}
