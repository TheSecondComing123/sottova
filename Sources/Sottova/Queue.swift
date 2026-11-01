import SwiftUI
import SottovaCore

/// What plays next, floating over the right of the page the way the player bar floats over its bottom. Not modal:
/// the page stays live behind it. Drag rows to reorder; the list is native, so the insertion line is too.
struct QueuePanel: View {
    let close: () -> Void
    @Environment(Controller.self) private var controller

    #if NEWLOOK
    private static let rowHeight: CGFloat = 45

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next")
                .role(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
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
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
        .padding(.top, 13)
        .padding(.bottom, 8)
        .frame(width: 320)
        .background(Theme.popover, in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(.black.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 14)
    }
    #else
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                IconButton(icon: .x, weight: .bold, help: "close", size: 24, action: close)
            }
            // the list adds its own inset, so the header steps in to meet its rows
            .padding(.leading, 24)
            .padding(.trailing, 8)
            .frame(height: 48)

            List {
                if controller.status != .idle {
                    label("Now playing")
                    nowPlaying
                        .row()
                }
                HStack(alignment: .firstTextBaseline) {
                    label("Next up")
                    Spacer()
                    if !controller.upNext.isEmpty {
                        LinkText(text: "Clear") { withAnimation(Theme.quick) { controller.clearQueue() } }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, controller.status == .idle ? 0 : 16)
                .overlayScrollers()
                .row()
                if controller.upNext.isEmpty {
                    Text("nothing queued yet. drop songs here, or right-click one and pick play next")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .dropDestination(for: URL.self) { urls, _ in queue(urls, at: 0) }
                        .row()
                }
                ForEach(controller.upNext) { entry in
                    QueueRow(entry: entry)
                        .row()
                }
                .onMove { controller.moveQueued(fromOffsets: $0, toOffset: $1) }
                // songs dragged in from a page land where the list's insertion line shows
                .onInsert(of: [.fileURL]) { index, providers in
                    Task {
                        var urls: [URL] = []
                        for provider in providers {
                            if let url = await Self.url(from: provider) { urls.append(url) }
                        }
                        _ = queue(urls, at: index)
                    }
                }
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
    #endif

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

    #if !NEWLOOK
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.faint)
            .accessibilityAddTraits(.isHeader)
            .row()
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if controller.status == .resting {
            // like the rest of the app, the gap doesn't say how long it has left
            VStack(alignment: .leading, spacing: 2) {
                Text("silence")
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
            // the same art size as the rows below, so the titles line up in one column
            SongLine(song: song, art: 32, trailing: Format.time(song.duration))
                .frame(height: 48)
        } else {
            Text("nothing playing")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .frame(height: 56, alignment: .leading)
        }
    }
    #endif
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
                #if NEWLOOK
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).role(.body).foregroundStyle(Theme.text)
                    Text(song.artist).role(.small).foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if !hovering {
                    Text(Format.time(song.duration)).role(.body).monospacedDigit().foregroundStyle(Theme.faint)
                }
                #else
                SongLine(song: song, art: 32, trailing: hovering ? nil : Format.time(song.duration))
                #endif
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
        #if NEWLOOK
        .frame(height: 45)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        #else
        .frame(height: 48)
        #endif
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

#if !NEWLOOK
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

#endif

private extension View {
    /// A list row with nothing of the list's own look: no separator, background or inset beyond the panel's.
    func row() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            #if NEWLOOK
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 4))
            #else
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
            #endif
    }
}
