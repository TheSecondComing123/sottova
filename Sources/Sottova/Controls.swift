import AppKit
import SwiftUI
import SottovaCore

/// Play and skip as the player bar draws them, so the panel and the window agree.
struct Controls: View {
    let controller: Controller

    private var running: Bool {
        controller.status == .playing || controller.status == .resting
    }

    var body: some View {
        HStack(spacing: 8) {
            PlayCircle(size: 32, playing: running) { controller.toggle() }
                .disabled(controller.tracks.isEmpty)
            IconButton(icon: .skipForward, weight: .fill, help: controller.status == .resting ? "end the gap" : "skip", size: 32) {
                controller.skip()
            }
            .disabled(controller.status == .idle)
        }
    }
}

extension Controller {
    /// Asks for music folders. Activates first: from the menu-bar panel the open panel otherwise lands behind the
    /// frontmost app.
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    /// The song being heard or held: not during a gap, when the last one has finished.
    var sounding: Song? {
        status == .playing || status == .paused ? current : nil
    }

    var headline: String {
        switch status {
        case .idle: "sottova"
        case .resting: "resting"
        case .playing, .paused: title ?? "starting"
        }
    }

    func subline(at now: Date) -> String {
        switch status {
        case .idle:
            return tracks.isEmpty ? "add a music folder to start" : "ready when you are"
        case .playing:
            return sleepTimer.map { "playing · stops \(Format.sleep($0, resting: false, at: now, sentence: true))" } ?? "playing"
        case .paused:
            return "paused"
        case .resting:
            switch hold {
            case .away: return "waiting till you're back"
            case .call: return "waiting till your call ends"
            case .media: return "waiting while something else plays"
            case .busy: return "waiting while your calendar has something on"
            case nil: break
            }
            let left = nextTrackAt?.timeIntervalSince(now) ?? 0
            if left < 60 { return "next track in a moment" }
            if left < 300 { return "next track in a few minutes" }
            return "next track in a while"
        }
    }

    /// Albums without the ones made into playlists, which are listed there instead.
    var shownAlbums: [Album] {
        let hidden = albumsInPlaylists
        return hidden.isEmpty ? catalog.albums : catalog.albums.filter { !hidden.contains($0.id) }
    }

    /// The copy of an album made yours, which shows and opens in the album's place.
    func copy(ofAlbum id: String) -> Playlist? {
        playlists.first { $0.fromAlbum == id }
    }

    /// Yours first, then the albums from your files.
    var collections: [MusicCollection] {
        playlists.map(MusicCollection.yours) + shownAlbums.map(MusicCollection.album)
    }

    var libraryLine: String {
        guard !folders.isEmpty else { return "no folder yet" }
        var parts = [Format.count(tracks.count, "song")]
        if pendingAnalysis > 0 {
            parts.append("reading \(pendingAnalysis) more")
        }
        if !skippedFiles.isEmpty {
            parts.append("\(skippedFiles.count) skipped, format not supported")
        }
        return parts.joined(separator: " · ")
    }
}
