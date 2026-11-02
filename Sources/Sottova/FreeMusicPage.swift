import AppKit
import SwiftUI
import SottovaCore

/// Free music: each set downloads on its own, into Music › Sottova Library, carrying on while you're on another page.
struct FreeMusicPage: View {
    @Environment(Controller.self) private var controller
    private let shelf = ShelfDownload.shelf
    @State private var width: CGFloat = 1024
    private static let titleWidth = (Shelf.sets.map { ($0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width }.max() ?? 0).rounded(.up)

    var body: some View {
        let margin: CGFloat = width < 860 ? 32 : 40
        PageScroll(insets: EdgeInsets(top: 16, leading: margin, bottom: 24, trailing: margin)) {
            Text("Free music")
                .role(.title)
                .offset(y: -2)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 19)
            ForEach(Shelf.sets) { row($0) }
            Text("CC BY sets credit the artist.")
                .role(.body)
                .foregroundStyle(Theme.faint)
                .padding(.top, 16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func row(_ set: ShelfSet) -> some View {
        let running = shelf.downloading.contains(set.id)
        let progress = shelf.progress[set.id] ?? 0
        return HStack(spacing: 12) {
            Text(set.title)
                .role(.body)
                .fontWeight(.medium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: Self.titleWidth, alignment: .leading)
            Text("\(set.creator), \(set.license), \(Self.size(set.megabytes))")
                .role(.body)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 12)
            if running {
                Text("\(Int(progress * Double(set.megabytes))) MB")
                    .role(.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                ThemeButton(title: "Cancel") { ShelfDownload.tasks[set.id]?.cancel() }
            } else if ShelfDownload.isDone(set) {
                HStack(spacing: 6) {
                    Ph.check.icon(.bold, size: 10)
                    Text("In your library").role(.body)
                }
                .foregroundStyle(Theme.muted)
            } else if let failure = shelf.failed[set.id] {
                Text(failure)
                    .role(.body)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                ThemeButton(title: "Try again") { start(set) }
            } else {
                ThemeButton(title: "Download") { start(set) }
            }
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            if running {
                Rectangle().fill(Theme.hairline).frame(height: 2)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().fill(Theme.faint).frame(width: geo.size.width * progress, height: 2)
                        }
                    }
            }
        }
    }

    private func start(_ set: ShelfSet) {
        try? FileManager.default.createDirectory(at: Shelf.folder, withIntermediateDirectories: true)
        // a folder already watched (Music itself, say) sees the new one; adding it too would list every piece twice
        let path = Shelf.folder.path(percentEncoded: false)
        if !controller.folders.contains(where: { path == $0.path(percentEncoded: false) || path.hasPrefix($0.path(percentEncoded: false) + "/") }) {
            controller.addFolders([Shelf.folder])
        }
        ShelfDownload.tasks[set.id] = Task { await shelf.download(set) }
    }

    private static func size(_ megabytes: Int) -> String {
        megabytes >= 1000 ? String(format: "%.1f GB", Double(megabytes) / 1000) : "\(megabytes) MB"
    }
}

/// One download for the app, so it outlives the page.
@MainActor
enum ShelfDownload {
    static let shelf = Shelf()
    static var task: Task<Void, Never>?
    /// The sets running alone, each stopped by its row's Cancel.
    static var tasks: [ShelfSet.ID: Task<Void, Never>] = [:]

    /// A finished set writes its credits last; one being downloaded may have them from before.
    static func isDone(_ set: ShelfSet) -> Bool {
        (shelf.progress[set.id].map { $0 >= 1 } ?? true)
            && FileManager.default.fileExists(atPath: Shelf.folder.appending(path: set.folder).appending(path: "credits.txt").path)
    }
}
