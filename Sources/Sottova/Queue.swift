import AppKit
import SwiftUI
import SottovaCore

/// What plays next, floating over the right of the page. Not modal:
/// the page stays live behind it. Drag rows to reorder; the list is native, so the insertion line is too.
struct QueuePanel: View {
    let close: () -> Void
    @Environment(Controller.self) private var controller
    @Environment(\.navigate) private var navigate
    @State private var picked = Set<QueueEntry.ID>()

    private static let rowHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Queue")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                    if !controller.upNext.isEmpty {
                        Text("\(Format.count(controller.upNext.count, "song")), \(Format.length(queuedLength))")
                            .role(.small)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !controller.upNext.isEmpty {
                    ThemeLink(text: "Clear queue", color: Theme.muted) { withAnimation(Theme.quick) { controller.clearQueue() } }
                        .help("empty the queue")
                }
                Button(action: close) {
                    Ph.x.icon(.bold, size: 11)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("close queue")
            }
            .role(.body)
            .frame(height: 36)
            .padding(.horizontal, 14)
            .padding(.bottom, 5)
            if controller.upNext.isEmpty {
                Text("Drop songs here")
                    .role(.body)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .dropDestination(for: URL.self) { urls, _ in queue(urls, at: 0) }
            } else {
                HStack(spacing: 8) {
                    Text("\(selected.count) picked")
                        .role(.small)
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    ThemeButton(title: "Play now", primary: true) {
                        if let first = selected.first { controller.playQueued(first.id) }
                    }
                    .disabled(selected.isEmpty)
                    ThemeLink(text: "Remove", color: Theme.muted) { remove(Set(selected.map(\.id))) }
                        .disabled(selected.isEmpty)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                List(selection: $picked) {
                    ForEach(controller.upNext) { entry in
                        QueueRow(entry: entry, picked: picked.contains(entry.id))
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
                .onDeleteCommand { remove(picked) }
                // the pick when the row is in it, else the row alone, as in Finder; double-click and Return play
                .contextMenu(forSelectionType: QueueEntry.ID.self) { ids in
                    MenuEntries(entries: menu(for: ids))
                } primaryAction: { ids in
                    if let first = controller.upNext.first(where: { ids.contains($0.id) }) { controller.playQueued(first.id) }
                }
                #if SHOT
                .onAppear { picked = Set(controller.upNext.prefix(UserDefaults.standard.integer(forKey: "shotQueuePicked")).map(\.id)) }
                #endif
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(Theme.quick, value: controller.upNext)
                .frame(height: min(CGFloat(controller.upNext.count) * Self.rowHeight, 500))
            }
        }
        .padding(.top, 13)
        .padding(.bottom, 8)
        .frame(width: 320)
        .background(Theme.popover, in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(.black.opacity(0.5), lineWidth: 0.5).padding(-0.25))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func remove(_ ids: Set<QueueEntry.ID>) {
        withAnimation(Theme.quick) { controller.removeQueued(ids) }
        picked.subtract(ids)
    }

    private func menu(for ids: Set<QueueEntry.ID>) -> [MenuEntry] {
        let entries = controller.upNext.filter { ids.contains($0.id) }
        guard let first = entries.first else { return [] }
        let remove = MenuEntry.item(entries.count == 1 ? "Remove from the queue" : "Remove \(entries.count) from the queue") { self.remove(ids) }
        guard entries.count == 1, let song = controller.catalog.songsByID[first.path] else {
            return [.item("Play now") { controller.playQueued(first.id) }, .divider, remove]
        }
        return [
            .item("Play now") { controller.playQueued(first.id) },
            .item("Go to \(controller.copy(ofAlbum: song.albumID)?.name ?? song.album)") { navigate(.album(song.albumID)) },
            .divider,
            remove,
        ]
    }

    private var queuedLength: Double {
        controller.upNext.reduce(0) { $0 + (controller.catalog.songsByID[$1.path]?.duration ?? 0) }
    }

    private var selected: [QueueEntry] { controller.upNext.filter { picked.contains($0.id) } }

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
    let picked: Bool
    @Environment(Controller.self) private var controller
    @Environment(\.appearsActive) private var active
    @State private var hovering = false

    var body: some View {
        let song = controller.catalog.songsByID[entry.path]
        HStack(spacing: 8) {
            if let song {
                // the artist whole or not at all: squeezed, it leaves a sliver of a letter
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(song.title).foregroundStyle(Theme.text)
                        Text(song.artist).foregroundStyle(Theme.muted)
                    }
                    .fixedSize()
                    Text(song.title).foregroundStyle(Theme.text).truncationMode(.tail)
                }
                .role(.body)
                .lineLimit(1)
                .help("\(song.title), \(song.artist)")
            } else {
                Text(URL(filePath: entry.path).deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if let song {
                    Text(Format.time(song.duration)).role(.body).monospacedDigit().foregroundStyle(Theme.faint).revealed(!hovering)
                }
                IconButton(icon: .x, weight: .bold, help: "remove from the queue", size: 24) {
                    withAnimation(Theme.quick) { controller.removeQueued([entry.id]) }
                }
                .revealed(hovering)
            }
        }
        .frame(height: 36)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .background(SystemHighlightOff())
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 4))
        // the rows' own pick and hover, as in Songs, in place of the system's blue
        .listRowBackground(
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(picked ? Theme.picked.opacity(active ? 1 : 0.7) : Theme.hover.opacity(hovering ? 1 : 0))
                .padding(.horizontal, 6)
        )
    }
}

/// The list keeps its selection, for the keys and the menu, but draws none: the rows draw the app's own.
private struct SystemHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (enclosingScrollView?.documentView as? NSTableView)?.selectionHighlightStyle = .none
        }
    }
}
