import SwiftUI
import SottovaCore

/// Free music: the starter shelf. Pick sets, and they download into Music › Sottova Library, which Sottova watches,
/// so each piece shows up as it lands. The download carries on while you're on another page.
struct ShelfPage: View {
    @Environment(Controller.self) private var controller
    @State private var picked: Set<ShelfSet.ID> = Set(Shelf.sets.filter { !ShelfDownload.isDone($0) }.map(\.id))
    private let shelf = ShelfDownload.shelf

    var body: some View {
        let chosen = Shelf.sets.filter { picked.contains($0.id) && !ShelfDownload.isDone($0) }
        PageScroll {
            PageHeader(title: "Free music",
                       detail: "public domain and Creative Commons recordings from archive.org, saved to Music › Sottova Library as plain files",
                       songs: [])
                .padding(.bottom, 16)
            // where Play sits on the other pages
            Group {
                if shelf.running {
                    Button("Stop") { ShelfDownload.task?.cancel() }
                } else {
                    Button(chosen.isEmpty ? "Everything's in your library" : "Download \(Self.size(chosen.reduce(0) { $0 + $1.megabytes }))") {
                        start(chosen)
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .buttonStyle(InvertedButton())
            .padding(.bottom, 8)
            if let problem = shelf.problem {
                Text(problem)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            ForEach(ShelfSet.Kind.allCases, id: \.self) { kind in
                SectionTitle(title: kind.rawValue)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                VStack(spacing: 2) {
                    ForEach(Shelf.sets.filter { $0.kind == kind }) { row($0) }
                }
                .frame(maxWidth: 720)
            }
        }
    }

    private func row(_ set: ShelfSet) -> some View {
        let done = ShelfDownload.isDone(set)
        let progress = shelf.progress[set.id]
        let on = done || picked.contains(set.id)
        return Button {
            if picked.contains(set.id) { picked.remove(set.id) } else { picked.insert(set.id) }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(on ? Theme.text : .clear)
                    .strokeBorder(on ? .clear : Theme.border, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .overlay { if on { Ph.check.icon(.bold, size: 10).foregroundStyle(Theme.background) } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(set.creator) · \(set.license)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                Text(done ? "in your library" : progress.map { "\(Int($0 * 100))%" } ?? Self.size(set.megabytes))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                // the set's share of the download, a hairline under its row
                if let progress, !done {
                    GeometryReader { geo in
                        Rectangle().fill(Theme.text).frame(width: geo.size.width * progress, height: 1)
                    }
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                }
            }
            .contentShape(.rect)
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .disabled(done || shelf.running)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func start(_ sets: [ShelfSet]) {
        try? FileManager.default.createDirectory(at: Shelf.folder, withIntermediateDirectories: true)
        // a folder already watched (Music itself, say) sees the new one; adding it too would list every piece twice
        let path = Shelf.folder.path(percentEncoded: false)
        if !controller.folders.contains(where: { path == $0.path(percentEncoded: false) || path.hasPrefix($0.path(percentEncoded: false) + "/") }) {
            controller.addFolders([Shelf.folder])
        }
        ShelfDownload.task = Task { await shelf.download(sets) }
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
