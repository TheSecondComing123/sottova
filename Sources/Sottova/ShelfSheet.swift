import SwiftUI
import SottovaCore

/// "Get free music": the starter shelf. Pick sets, and they download into Music › Sottova Library, which Sottova
/// watches, so each piece shows up as it lands. The download carries on with the sheet closed.
struct ShelfSheet: View {
    let controller: Controller
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<ShelfSet.ID> = Set(Shelf.sets.filter { !ShelfDownload.isDone($0) }.map(\.id))
    private let shelf = ShelfDownload.shelf

    var body: some View {
        let chosen = Shelf.sets.filter { picked.contains($0.id) && !ShelfDownload.isDone($0) }
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Free music")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("public domain and Creative Commons recordings from archive.org, saved to Music › Sottova Library as plain files")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(ShelfSet.Kind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .padding(.bottom, 4)
                    ForEach(Shelf.sets.filter { $0.kind == kind }) { row($0) }
                }
            }

            if let problem = shelf.problem {
                Text(problem)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 12) {
                Spacer()
                Button(shelf.running ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(QuietButton())
                if shelf.running {
                    Button("Stop") { ShelfDownload.task?.cancel() }
                        .buttonStyle(InvertedButton())
                } else {
                    Button("Download \(Self.size(chosen.reduce(0) { $0 + $1.megabytes }))") { start(chosen) }
                        .buttonStyle(InvertedButton())
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.background)
        .presentationBackground(Theme.background)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                Text(done ? "in your library" : progress.map { "\(Int($0 * 100))%" } ?? Self.size(set.megabytes))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                // the set's share of the download, a hairline under its row
                if let progress, !done {
                    GeometryReader { geo in
                        Rectangle().fill(Theme.text).frame(width: geo.size.width * progress, height: 1)
                    }
                    .frame(height: 1)
                    .padding(.horizontal, 8)
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

/// One download for the app, so it outlives the sheet and both windows show the same one.
@MainActor
enum ShelfDownload {
    static let shelf = Shelf()
    static var task: Task<Void, Never>?

    /// A finished set writes its credits last; one being downloaded may have them from before.
    static func isDone(_ set: ShelfSet) -> Bool {
        (shelf.progress[set.id].map { $0 >= 1 } ?? true)
            && FileManager.default.fileExists(atPath: Shelf.folder.appending(path: set.folder).appending(path: "credits.txt").path)
    }
}
