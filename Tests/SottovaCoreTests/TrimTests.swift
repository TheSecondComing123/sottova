import Foundation
import Testing
@testable import SottovaCore

@MainActor
struct TrimTests {
    @Test func framesStayInsideTheFileAndLastASecond() {
        let rate = 1000.0
        #expect(Trim(start: 2, end: 8).frames(sampleRate: rate, length: 10_000) == (2000, 8000))
        #expect(Trim(start: 3).frames(sampleRate: rate, length: 10_000) == (3000, 10_000))
        // past the end, or an end before the start, still leaves a second to play
        #expect(Trim(start: 20).frames(sampleRate: rate, length: 10_000) == (9000, 10_000))
        #expect(Trim(start: 5, end: 4).frames(sampleRate: rate, length: 10_000) == (5000, 6000))
        #expect(Trim(start: -1, end: 50).frames(sampleRate: rate, length: 10_000) == (0, 10_000))
    }

    @Test func trimsAreSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sottova-trims-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Controller(storage: dir)
        c.setTrim(Trim(start: 42.5, end: 300), for: "/music/stay.flac")
        let reopened = Controller(storage: dir)
        reopened.run()
        #expect(reopened.trims["/music/stay.flac"] == Trim(start: 42.5, end: 300))
    }
}
