import AVFoundation
import Foundation
import Testing
@testable import SottovaCore

/// Collections and rows kept in step: a rename while playing, parts emptied by a removal, a save that fails, and
/// which of two open rows Now names.
@Suite(.disabled(if: LiveClock.repeatsAnHour(), "rows on the live clock can't be set up while the clocks repeat an hour"))
@MainActor
struct CollectionRowTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-coll-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func controller(_ root: URL) throws -> Controller {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 480)
        let c = Controller(engine: engine, storage: root, playlistFolder: root.appending(path: "collections"), artworkFolder: root.appending(path: "art"))
        c.saveVolume = { _ in }
        return c
    }

    private func seed(_ c: Controller, in root: URL, count: Int = 6) async throws -> [Song] {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<count {
            let url = root.appending(path: "song-\(i).caf")
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            c.library.entries[url.path] = Library.Entry(size: 0, modified: .now, loudness: Loudness(lufs: -18, truePeakDb: -10), meta: TrackMeta(title: "Song \(i)", artist: "Artist", album: "Album", trackNumber: i + 1, duration: 3))
        }
        c.refreshTracks()
        for _ in 0..<500 where c.catalog.songs.count != count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.catalog.songs.count == count)
        return c.catalog.albums[0].songs
    }

    private func rotatingRow(_ id: String, next: Int) -> Alarm {
        var row = Alarm(source: id, name: "Morning", hour: Calendar.current.component(.hour, from: .now + 6 * 3600), minute: 2, weekdays: Set(1...7))
        row.rotates = true
        row.nextPart = next
        return row
    }

    @Test func quietPageNamesLatestStartingOpenRow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 16, minute: 30)))
        var early = Alarm(source: "early", name: "Earlier", hour: 15, minute: 0, weekdays: Set(1...7))
        early.whileHere = true
        early.minutes = 240
        var later = Alarm(source: "later", name: "Later", hour: 16, minute: 0, weekdays: Set(1...7))
        later.whileHere = true
        later.minutes = 60
        let plan = DayPlan(alarms: [early, later], now: now, calendar: calendar)
        #expect(plan.quiet().headline == "Later")
        #expect(plan.quietSource == later.source)
    }
}
