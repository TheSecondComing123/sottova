import AppKit
import SwiftUI
import SottovaCore

/// Free music: each set downloads on its own, into Music › Sottova Library, carrying on while you're on another page.
struct FreeMusicPage: View {
    @Environment(Controller.self) private var controller
    private let shelf = ShelfDownload.shelf
    @Environment(\.listLayout) private var layout
    @Environment(\.pageLayout) private var page

    private var columns: [GridItem] {
        let count = page.width < 1000 ? 2 : page.width < 1500 ? 3 : 4
        return Array(repeating: GridItem(.flexible(minimum: 240, maximum: 320), spacing: 28, alignment: .top), count: count)
    }
    var body: some View {
        let margin = layout.margin
        PageScroll(insets: EdgeInsets(top: 16, leading: margin, bottom: 24, trailing: margin)) {
            Text("Free music")
                .role(.title)
                .offset(y: -2)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("Ten openly licensed albums. Downloads go to Music, Sottova Library.")
                .role(.body)
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)
                .padding(.bottom, 24)
            ForEach(ShelfSet.Kind.allCases, id: \.self) { kind in
                GroupHead(title: kind.rawValue)
                    .padding(.bottom, 14)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                    ForEach(Shelf.sets.filter { $0.kind == kind }) { tile($0).id($0.id) }
                }
                .padding(.bottom, 32)
            }
        }
    }

    /// A painting shipped with the app: this page fetches nothing until asked.
    private func tile(_ set: ShelfSet) -> some View {
        let running = shelf.downloading.contains(set.id)
        let progress = shelf.progress[set.id] ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if let url = Bundle.main.url(forResource: set.id, withExtension: "jpg", subdirectory: "Covers"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.hover)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color(white: 0.5, opacity: 0.28), lineWidth: 1))
            .accessibilityHidden(true)
            .padding(.bottom, 8)
            Text(set.title).role(.item).fontWeight(.medium).foregroundStyle(Theme.text)
                .lineLimit(2).frame(height: 40, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.creator).role(.small).foregroundStyle(Theme.muted).lineLimit(1)
                // a failure takes the line, whole
                Group {
                    if let failure = shelf.failed[set.id], !running {
                        Text(failure).fixedSize(horizontal: false, vertical: true)
                    } else if running {
                        Text("\(Int(progress * Double(set.megabytes))) MB of \(Self.size(set.megabytes))").monospacedDigit().lineLimit(1)
                    } else {
                        Text("\(set.license), \(Self.size(set.megabytes))")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .role(.small)
                .foregroundStyle(Theme.muted)
            }
            .frame(minHeight: 36, alignment: .topLeading)
            Group {
                if running {
                    // what's already downloaded stays on disk, so this isn't a Cancel
                    ThemeButton(title: "Stop") { ShelfDownload.tasks[set.id]?.cancel() }
                } else if shelf.failed[set.id] != nil {
                    ThemeButton(title: "Try again") { start(set) }
                } else if ShelfDownload.isDone(set) {
                    Text("In your library").role(.body).foregroundStyle(Theme.muted)
                        .frame(height: 24)
                } else {
                    ThemeButton(title: "Download", icon: .trayArrowDown, iconWeight: .duotone) { start(set) }
                }
            }
            .frame(height: 24, alignment: .leading)
            .padding(.top, 4)
            // always there, so the rows below don't move when a download starts or ends
            Rectangle().fill(Theme.hairline).frame(height: 2)
                .padding(.top, 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().fill(Theme.faint).frame(width: geo.size.width * progress, height: 2)
                    }
                }
                .opacity(running ? 1 : 0)
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
