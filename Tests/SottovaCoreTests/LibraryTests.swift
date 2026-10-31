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
