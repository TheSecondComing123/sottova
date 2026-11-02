import AppKit
import SwiftUI
import SottovaCore

extension Controller {
    /// Asks for music folders. Activates first: from the menu bar the open panel otherwise lands behind the
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
        (status == .playing || status == .paused) && !inSilence ? current : nil
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
