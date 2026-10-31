import AVFoundation
import Foundation
import Testing
@testable import SottovaCore

struct LibraryTests {
    private let folder: URL

    init() throws {
        // /var is a symlink to /private/var and the scanner reports the real path;
        // resolvingSymlinksInPath() strips /private again, so this uses realpath
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(temp) }
        folder = URL(filePath: String(cString: temp)).appending(path: "sottova-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "album"), withIntermediateDirectories: true)
        for name in ["a.mp3", "album/b.flac", "cover.jpg"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
    }

    private func scanned(_ library: inout Library) {
        library.merge(Library.scan([folder]))
    }

    @Test func scanFindsAudioRecursivelyAndIgnoresTheRest() {
        var library = Library()
        scanned(&library)
        #expect(Set(library.entries.keys.map { URL(filePath: $0).lastPathComponent }) == ["a.mp3", "b.flac"])
    }

    @Test func rescanKeepsMeasuredLoudness() {
        var library = Library()
        scanned(&library)
        let path = folder.appending(path: "a.mp3").path
        library.entries[path]?.loudness = Loudness(lufs: -14, truePeakDb: -1)
        #expect(library.entries[path]?.loudness != nil)
        let before = library.entries
        scanned(&library)
        #expect(library.entries == before)
    }

    @Test func changedFileIsMeasuredAgain() throws {
        var library = Library()
        scanned(&library)
        let url = folder.appending(path: "a.mp3")
        library.entries[url.path]?.loudness = Loudness(lufs: -14, truePeakDb: -1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        scanned(&library)
        #expect(library.entries[url.path]?.loudness == nil)
        #expect(library.pending.contains(url.path))
    }

    @Test func deletedFileDisappears() throws {
        var library = Library()
        scanned(&library)
        let url = folder.appending(path: "album/b.flac")
        #expect(library.entries[url.path] != nil)
        try FileManager.default.removeItem(at: url)
        scanned(&library)
        #expect(library.entries[url.path] == nil)
    }

    @Test func savesAndLoadsTheSameLibrary() throws {
        var library = Library()
        library.folders = [Library.Folder(bookmark: try folder.bookmarkData(), path: folder.path)]
        scanned(&library)
        let file = folder.appending(path: "library.json")
        try library.save(to: file)
        let loaded = try Library.load(from: file)
        #expect(loaded.entries == library.entries)
        #expect(loaded.folders == library.folders)
    }

    /// Digital silence measures −∞ LUFS and −∞ dBTP, which plain JSON can't hold.
    @Test func aSilentFileDoesntStopSaves() throws {
        let url = folder.appending(path: "silent.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        var library = Library()
        library.entries[url.path] = Library.Entry(size: 1, modified: Date(timeIntervalSince1970: 1), loudness: try Loudness.measure(url), meta: TrackMeta(duration: 1))
        #expect(library.entries[url.path]?.loudness?.lufs == -.infinity)
        let file = folder.appending(path: "library.json")
        try library.save(to: file)
        let loaded = try Library.load(from: file)
        #expect(loaded.entries == library.entries)
        #expect(loaded.entries[url.path]?.loudness?.gainDb() == 0)
        // and it's measured, so it isn't analyzed again every launch
        #expect(loaded.pending.isEmpty)
    }

    private func scannedWithLoudness() -> Library {
        var library = Library()
        scanned(&library)
        for path in library.entries.keys {
            library.entries[path]?.loudness = Loudness(lufs: -14, truePeakDb: -1)
            library.entries[path]?.meta = TrackMeta(duration: 1)
        }
        return library
    }

    @Test func aFolderThatsGoneKeepsItsEntriesUntilAScanGetsThrough() throws {
        var library = scannedWithLoudness()
        let before = library.entries
        let away = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + "-away")
        try FileManager.default.moveItem(at: folder, to: away)
        let scan = Library.scan([folder])
        #expect(scan.unreachable == [folder.path])
        library.merge(scan)
        #expect(library.entries.count == 2)
        #expect(library.entries.values.allSatisfy { $0.loudness != nil && $0.unreachable == true })
        #expect(library.playable.isEmpty)
        #expect(library.pending.isEmpty)
        #expect(Catalog(entries: library.entries).songs.isEmpty)
        try FileManager.default.moveItem(at: away, to: folder)
        scanned(&library)
        #expect(library.entries == before)
        #expect(library.playable.count == 2)
    }

    @Test func aDeniedFolderKeepsItsEntries() throws {
        var library = scannedWithLoudness()
        let path = folder.path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        scanned(&library)
        #expect(library.entries.count == 2)
        #expect(library.playable.isEmpty)
    }

    /// One denied folder inside says nothing about the rest, whose deleted files still go.
    @Test func aDeniedFolderInsideOnlyKeepsItsOwnEntries() throws {
        var library = scannedWithLoudness()
        let inner = folder.appending(path: "album")
        try FileManager.default.removeItem(at: folder.appending(path: "a.mp3"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inner.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path) }
        let scan = Library.scan([folder])
        #expect(scan.unreachable == [inner.path])
        library.merge(scan)
        #expect(library.entries.keys.map { URL(filePath: $0).lastPathComponent } == ["b.flac"])
        #expect(library.entries[inner.appending(path: "b.flac").path]?.unreachable == true)
    }

    @Test func aFolderItsBookmarkCantFindStaysListedAndKeepsItsEntries() throws {
        var library = scannedWithLoudness()
        library.folders = [Library.Folder(bookmark: Data("not a bookmark".utf8), path: folder.path + "-unplugged")]
        library.entries = library.entries.reduce(into: [:]) { $0[$1.key.replacing(folder.path, with: folder.path + "-unplugged")] = $1.value }
        let resolved = library.resolveFolders()
        #expect(resolved.map(\.path) == [folder.path + "-unplugged"])
        library.merge(Library.scan(resolved))
        #expect(library.entries.count == 2)
    }

    @Test func bookmarkFollowsAMovedFolder() throws {
        var library = Library()
        library.folders = [Library.Folder(bookmark: try folder.bookmarkData(), path: folder.path)]
        let moved = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: folder) }
        let resolved = library.resolveFolders()
        #expect(resolved.map(\.standardizedFileURL.path) == [moved.standardizedFileURL.path])
        #expect(library.folders[0].path == resolved[0].path)
    }
}
