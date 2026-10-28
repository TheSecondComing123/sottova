import AppKit
import SwiftUI
import SottovaCore

struct MainWindow: View {
    @Environment(Controller.self) private var controller
    @State private var route = Route.home
    @State private var back: [Route] = []
    @State private var forward: [Route] = []
    @State private var query = ""
    @State private var visible = true
    @State private var mouseButtons: Any?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: route.section) { root in
                query = ""
                go(to: root)
            }
            .frame(width: 228)

            Rectangle().fill(Theme.border).frame(width: 1)

            VStack(spacing: 0) {
                TopBar(query: $query, canGoBack: !back.isEmpty, canGoForward: !forward.isEmpty, goBack: goBack, goForward: goForward)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                PlayerBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 640)
        .background(WindowVisibility(visible: $visible))
        .environment(\.windowVisible, visible)
        .environment(\.navigate, Navigate { route in
            query = ""
            go(to: route)
        })
        // drop music folders anywhere on the window
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            controller.addFolders(folders)
            return !folders.isEmpty
        }
        .onAppear(perform: watchMouseButtons)
    }

    @ViewBuilder
    private var page: some View {
        Group {
            if !query.isEmpty {
                SearchPage(query: query)
            } else {
                switch route {
                case .home: HomePage()
                case .songs: SongsPage()
                case .albums: AlbumsPage()
                case .artists: ArtistsPage()
                case .album(let id): AlbumPage(id: id)
                case .artist(let name): ArtistPage(name: name)
                }
            }
        }
        .id(query.isEmpty ? AnyHashable(route) : AnyHashable("search"))
        // the old page leaves fast, so the two never sit on top of each other at full strength
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.08))))
    }

    private func go(to destination: Route) {
        guard destination != route else { return }
        withAnimation(Theme.page) {
            back.append(route)
            forward.removeAll()
            route = destination
        }
    }

    private func goBack() {
        guard let previous = back.popLast() else { return }
        withAnimation(Theme.page) {
            forward.append(route)
            route = previous
        }
    }

    private func goForward() {
        guard let next = forward.popLast() else { return }
        withAnimation(Theme.page) {
            back.append(route)
            route = next
        }
    }

    /// The back and forward buttons on a mouse.
    private func watchMouseButtons() {
        guard mouseButtons == nil else { return }
        mouseButtons = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: goBack()
            case 4: goForward()
            default: return event
            }
            return nil
        }
    }
}

private struct Sidebar: View {
    let section: Route
    let select: (Route) -> Void
    @Environment(Controller.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    private let items: [(Route, String, String)] = [
        (.home, "Home", "house"),
        (.songs, "Songs", "music.note"),
        (.albums, "Albums", "square.stack"),
        (.artists, "Artists", "music.microphone"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // the wordmark sits on the same line as the search field; the traffic lights sit above it
            Text("sottova")
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 22)
                .frame(height: 66, alignment: .bottom)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .gesture(WindowDragGesture())

            VStack(spacing: 2) {
                ForEach(items, id: \.0) { item, label, symbol in
                    navRow(item, label, symbol)
                }
            }
            .padding(.horizontal, 12)

            Text("Listening")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(SottovaCore.Settings.presets, id: \.name) { preset in
                    presetRow(preset)
                }
                if controller.settings.name == "Custom" {
                    presetRow(controller.settings)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            // only when there's news: the song count alone is already on the Songs page
            if controller.folders.isEmpty || controller.pendingAnalysis > 0 || !controller.skippedFiles.isEmpty {
                Text(controller.libraryLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 2) {
                footerRow("Add Folder", "folder.badge.plus", action: addFolders)
                footerRow("Settings", "gearshape") { openSettings() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    private func navRow(_ item: Route, _ label: String, _ symbol: String) -> some View {
        let selected = section == item
        return Button { select(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            // a quiet fill: the selection shouldn't outshine the play button and the title on the page
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.hover)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(reduceMotion ? Theme.quick : Theme.settle, value: section)
    }

    private func presetRow(_ preset: SottovaCore.Settings) -> some View {
        let active = controller.settings.name == preset.name
        return Button { controller.apply(preset) } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(active ? Theme.text : Theme.decor)
                    .frame(width: 6, height: 6)
                    .frame(width: 20)
                Text(preset.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? Theme.text : Theme.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                if active {
                    Text(Format.range(preset))
                        .lineLimit(1)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(Theme.quick, value: active)
        .disabled(preset.name == "Custom")
        .help(Format.gaps(preset))
    }

    private func footerRow(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .hoverable(radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.addFolders(panel.urls)
    }
}

private struct TopBar: View {
    @Binding var query: String
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 10) {
            arrow("chevron.left", enabled: canGoBack, help: "back", action: goBack)
            arrow("chevron.right", enabled: canGoForward, help: "forward", action: goForward)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField("search songs, albums, artists", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .focused($searching)
                    .onExitCommand { query = ""; searching = false }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: 560)
            .background(Theme.raised, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searching ? Theme.muted : Theme.border))
            .animation(Theme.quick, value: searching)

            // the rest of the bar still drags the window
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .padding(.top, 6)
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.decor)
                .frame(width: 32, height: 32)
                .background(Theme.raised, in: .circle)
                .overlay(Circle().strokeBorder(Theme.border))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .help(help)
    }
}
