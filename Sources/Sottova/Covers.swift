import AppKit
import SwiftUI
import SottovaCore

enum CoverTarget: Identifiable, Hashable {
    case album(String)
    case playlist(String)

    var id: Self { self }
}

/// A cover from a file, or from a public-domain painting found in three museums' open collections. The picked
/// image is cropped square and written next to the music; a painting's credit goes inside the JPEG.
struct CoverPicker: View {
    let target: CoverTarget
    @Environment(Controller.self) private var controller
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searched = ""
    @State private var results: [Painting] = []
    @State private var searching = false
    @State private var silent: [String] = []
    @State private var picked: Painting?
    @State private var file: (data: Data, image: NSImage)?
    @State private var targeted = false
    /// Use cover's download, which Cancel stops.
    @State private var saveTask: Task<Void, Never>?
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var typing: Bool

    private var name: String {
        switch target {
        case .album(let id): controller.catalog.albumsByID[id]?.title ?? "this collection"
        case .playlist(let id): controller.playlists.first { $0.id == id }?.name ?? "this collection"
        }
    }

    private var currentCover: String? {
        switch target {
        case .album(let id): controller.catalog.albumsByID[id]?.artwork
        case .playlist(let id): controller.playlistCovers[id] ?? controller.playlists.first { $0.id == id }.flatMap { controller.songs(of: $0).first?.artwork }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Choose a cover for \(name)")
                .role(.sheet)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    preview
                    if picked != nil || file != nil || currentCover != nil {
                        Text(picked == nil && file == nil ? "Current cover" : "New cover")
                            .role(.small).foregroundStyle(Theme.muted)
                    }
                    ThemeLink(text: "choose a file…", color: Theme.text, action: chooseFile)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let picked {
                        Text(picked.credit)
                            .font(Role.column.font)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 200, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Search museum paintings").role(.body).foregroundStyle(Theme.text)
                    searchField
                    if searched.isEmpty && !searching {
                        HStack(spacing: 8) {
                            Text("Try").role(.small).foregroundStyle(Theme.muted)
                            ForEach(["Hammershøi", "Nocturne", "Moonlight"], id: \.self) { word in
                                ThemeButton(title: word) { query = word; search() }
                            }
                        }
                    } else {
                        Text(status)
                            .font(Role.column.font)
                            .foregroundStyle(Theme.faint)
                    }
                    if !results.isEmpty {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(136), spacing: 16, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                                ForEach(results) { painting in
                                    tile(painting)
                                }
                            }
                            .overlayScrollers()
                        }
                        .frame(height: 340)
                    }
                }
            }

            HStack(spacing: 12) {
                if let failure { Text(failure).role(.small).foregroundStyle(Theme.text) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    saveTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ThemeButtonStyle())
                Button(saving ? "Saving…" : "Use cover", action: save)
                    .buttonStyle(ThemeButtonStyle(primary: true))
                    // while typing a search, return searches
                    .keyboardShortcut(typing ? nil : .defaultAction)
                    .disabled((picked == nil && file == nil) || saving)
            }
        }
        .padding(24)
        .frame(width: 712)
        .background(Theme.sidebar)
        .presentationBackground(Theme.sidebar)
        #if SHOT
        .onAppear {
            let defaults = UserDefaults.standard
            switch defaults.string(forKey: "shotCoverState") {
            case "searching": query = "moonlight"; searched = query; searching = true
            case "failed":
                query = "moonlight"; searched = query
                silent = PaintingSearch.Museum.allCases.map(\.rawValue)
            case "selected":
                if let folder = defaults.string(forKey: "shotCovers"), let data = try? Data(contentsOf: URL(filePath: folder).appending(path: "compline.jpg")), let image = NSImage(data: data) {
                    file = (data, image)
                }
            default: break
            }
        }
        #endif
    }

    /// The square that will be written, which is also where a file can be dropped.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.window).fill(Theme.raised)
            if let file {
                Image(nsImage: file.image).resizable().scaledToFill()
            } else if let picked {
                AsyncImage(url: picked.thumbnail) { $0.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.small) }
            } else if let currentCover {
                Artwork(key: currentCover, size: 200, radius: Radius.small)
            } else {
                Text("drop an image here")
                    .font(Role.body.font)
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(.rect(cornerRadius: Radius.window))
        .overlay(RoundedRectangle(cornerRadius: Radius.window).strokeBorder(targeted ? Theme.text : Theme.border, lineWidth: targeted ? 2 : 1))
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(Theme.settle, value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return load(url)
        } isTargeted: { targeted = $0 }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Ph.magnifyingGlass.icon(size: 14)
                .foregroundStyle(Theme.faint)
            TextField("Artist, title or mood", text: $query)
                .textFieldStyle(.plain)
                .font(Role.body.font)
                .foregroundStyle(Theme.text)
                .focused($typing)
                .onSubmit(search)
                .onChange(of: typing) { _, focused in router.typing = focused }
                .accessibilityLabel("Search paintings")
            Button("Search", action: search)
                .buttonStyle(ThemeButtonStyle())
                .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .fieldGround(focused: typing)
    }

    private var status: String {
        if searching { return "asking the Met, the Art Institute and Cleveland…" }
        if results.isEmpty { return silent.count == 3 ? "no connection. you can still drop an image" : "no public-domain paintings match “\(searched)”" }
        if !silent.isEmpty { return "\(silent.joined(separator: " and ")) didn't answer; showing the rest" }
        return "\(results.count) public-domain paintings"
    }

    private func tile(_ painting: Painting) -> some View {
        Button {
            picked = painting
            file = nil
            failure = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: painting.thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.raised
                }
                .frame(width: 136, height: 136)
                .clipShape(.rect(cornerRadius: Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(picked == painting ? Theme.text : .clear, lineWidth: 2))
                .accessibilityHidden(true)
                Text(painting.title)
                    .font(Role.label.font)
                    .foregroundStyle(Theme.text)
                Text([painting.artist, painting.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(Role.column.font)
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .frame(width: 136, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .help(painting.credit)
        .accessibilityAddTraits(picked == painting ? .isSelected : [])
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            var found: [[Painting]] = []
            var quiet: [String] = []
            await withTaskGroup(of: (PaintingSearch.Museum, [Painting]?).self) { group in
                for museum in PaintingSearch.Museum.allCases {
                    group.addTask { (museum, try? await PaintingSearch.search(q, in: museum)) }
                }
                for await (museum, paintings) in group {
                    if let paintings { found.append(paintings) } else { quiet.append(museum.rawValue) }
                }
            }
            // one from each museum in turn, so the first row isn't all one collection
            var mixed: [Painting] = []
            for i in 0..<(found.map(\.count).max() ?? 0) {
                mixed += found.compactMap { i < $0.count ? $0[i] : nil }
            }
            results = mixed
            silent = quiet
            searched = q
            searching = false
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "choose a cover for \(name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = load(url)
    }

    private func load(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            failure = "that file isn't an image"
            return false
        }
        file = (data, image)
        picked = nil
        failure = nil
        return true
    }

    private func save() {
        saving = true
        saveTask = Task {
            defer { saving = false }
            let data: Data
            var credit: String?
            if let file {
                data = file.data
            } else if let picked {
                do {
                    data = try await URLSession.shared.data(from: picked.image).0
                } catch {
                    failure = "couldn't download the painting: \(error.localizedDescription)"
                    return
                }
                credit = picked.credit
            } else {
                return
            }
            guard !Task.isCancelled else { return }
            switch target {
            case .album(let id): controller.setCover(data, credit: credit, forAlbum: id)
            case .playlist(let id): controller.setCover(data, credit: credit, forPlaylist: id)
            }
            dismiss()
        }
    }
}

/// The painting's credit under a title, read from the cover file itself.
struct CoverCredit: View {
    let url: URL?
    let key: String?
    @State private var credit: String?

    var body: some View {
        Group {
            if let credit {
                Text(credit).role(.small).foregroundStyle(Theme.faint).lineLimit(2).help(credit)
            }
        }
        .task(id: key) { credit = url.flatMap(CoverFile.credit(at:)) }
    }
}
