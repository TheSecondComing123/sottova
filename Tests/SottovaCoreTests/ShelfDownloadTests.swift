import Foundation
import Testing
@testable import SottovaCore

/// Answers from a table, so nothing reaches the network.
final class StubbedArchive: URLProtocol {
    struct Answer {
        var status = 200
        var type = "audio/mpeg"
        var body = Data()
        var offline = false
    }

    nonisolated(unsafe) static var answers: [String: Answer] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let answer = Self.answers[request.url!.path] ?? Answer(status: 404, type: "text/html", body: Data("<html>not found</html>".utf8))
        if answer.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: ["Content-Type": answer.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Suite(.serialized)
struct ShelfDownloadTests {
    private let root: URL
    private let shelf: Shelf
    private let song = Data("ID3 pretend audio".utf8)
    private let errorPage = Data("<html>503 slow down</html>".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sottova-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedArchive.self]
        shelf = Shelf(session: URLSession(configuration: config))
        StubbedArchive.answers = [:]
    }

    private func set(_ id: String, retag: (album: String, artist: String, composer: String)? = nil) -> ShelfSet {
        ShelfSet(id: id, title: "Title \(id)", creator: "Someone", kind: .ambient, license: "CC0", licenseURL: "https://example.com", megabytes: 1, retag: retag)
    }

    /// A metadata answer listing these files, with the songs' real sizes.
    private func lists(_ id: String, mp3s: [String], cover: Bool = false) throws {
        struct File: Encodable { var name, format: String; var size: String? }
        let files = mp3s.map { File(name: $0, format: "VBR MP3", size: "\(song.count)") } + (cover ? [File(name: "front.jpg", format: "JPEG", size: nil)] : [])
        let body = try JSONEncoder().encode(["files": files])
        StubbedArchive.answers["/metadata/\(id)"] = .init(type: "application/json", body: body)
    }

    private func landed(_ set: ShelfSet) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: set.folder).path)) ?? []).sorted()
    }

    @Test func aWholeSetLands() async throws {
        let one = set("whole")
        try lists("whole", mp3s: ["a.mp3", "b.mp3"], cover: true)
        for name in ["a.mp3", "b.mp3"] { StubbedArchive.answers["/download/whole/\(name)"] = .init(body: song) }
        StubbedArchive.answers["/download/whole/front.jpg"] = .init(type: "image/jpeg", body: Data("jpeg".utf8))
        await shelf.download([one], into: root)
        #expect(shelf.problem == nil)
        #expect(landed(one) == ["a.mp3", "b.mp3", "cover.jpg", "credits.txt"])
        #expect(try Data(contentsOf: root.appending(path: "\(one.folder)/a.mp3")) == song)
    }

    @Test(arguments: [false, true])
    func anErrorPageNeverLandsAsASong(retagged: Bool) async throws {
        let one = set("page", retag: retagged ? ("Album", "Artist", "Composer") : nil)
        try lists("page", mp3s: ["a.mp3", "b.mp3"])
        StubbedArchive.answers["/download/page/a.mp3"] = .init(status: 503, type: "text/html", body: errorPage)
        await shelf.download([one], into: root)
        #expect(!landed(one).contains("a.mp3"))
        #expect(shelf.problem?.contains("503") == true)
    }

    /// A proxy's "everything's fine" page, with a 200 on it.
    @Test func aWebPageWithAnOKStatusDoesntLandEither() async throws {
        let one = set("portal")
        try lists("portal", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/portal/a.mp3"] = .init(type: "text/html", body: errorPage)
        await shelf.download([one], into: root)
        #expect(!landed(one).contains("a.mp3"))
        #expect(shelf.problem != nil)
    }

    @Test func aFileOfTheWrongSizeDoesntLand() async throws {
        let one = set("short")
        try lists("short", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/short/a.mp3"] = .init(body: song.prefix(4))
        await shelf.download([one], into: root)
        #expect(!landed(one).contains("a.mp3"))
        #expect(shelf.problem != nil)
    }

    @Test func anErrorPageDoesntLandAsACover() async throws {
        let one = set("cover")
        try lists("cover", mp3s: ["a.mp3"], cover: true)
        StubbedArchive.answers["/download/cover/a.mp3"] = .init(body: song)
        await shelf.download([one], into: root)
        #expect(!landed(one).contains("cover.jpg"))
        #expect(landed(one).contains("a.mp3"))
        #expect(shelf.problem?.contains("404") == true)
    }

    @Test func anErrorInsteadOfTheListSaysSo() async throws {
        let one = set("list")
        StubbedArchive.answers["/metadata/list"] = .init(status: 503, type: "text/html", body: errorPage)
        await shelf.download([one], into: root)
        #expect(shelf.problem?.contains("503") == true)
        #expect(landed(one).isEmpty)
    }

    @Test func aSetWithNoSongsIsAFailureNotASuccess() async throws {
        let one = set("empty")
        try lists("empty", mp3s: [])
        await shelf.download([one], into: root)
        #expect(shelf.problem?.contains(one.title) == true)
    }

    @Test func everyFailureIsReportedNotOnlyTheLast() async throws {
        let (first, second, fine, third) = (set("first"), set("second"), set("fine"), set("third"))
        StubbedArchive.answers["/metadata/first"] = .init(status: 500, type: "text/html", body: errorPage)
        StubbedArchive.answers["/metadata/second"] = .init(offline: true)
        try lists("fine", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/fine/a.mp3"] = .init(body: song)
        StubbedArchive.answers["/metadata/third"] = .init(status: 503, type: "text/html", body: errorPage)
        await shelf.download([first, second, fine, third], into: root)
        for failed in [first, second, third] { #expect(shelf.problem?.contains(failed.title) == true) }
        #expect(shelf.problem?.contains(fine.title) == false)
        #expect(landed(fine).contains("a.mp3"))
    }

    @Test func askingAgainPicksUpAfterAnErrorPage() async throws {
        let one = set("again")
        try lists("again", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/again/a.mp3"] = .init(status: 503, type: "text/html", body: errorPage)
        await shelf.download([one], into: root)
        StubbedArchive.answers["/download/again/a.mp3"] = .init(body: song)
        await shelf.download([one], into: root)
        #expect(shelf.problem == nil)
        #expect(try Data(contentsOf: root.appending(path: "\(one.folder)/a.mp3")) == song)
    }

    @Test func aSetAloneReportsOnItsOwnRow() async throws {
        let (good, bad) = (set("good"), set("bad"))
        try lists("good", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/good/a.mp3"] = .init(body: song)
        StubbedArchive.answers["/metadata/bad"] = .init(offline: true)
        await shelf.download(good, into: root)
        await shelf.download(bad, into: root)
        #expect(shelf.failed[good.id] == nil)
        #expect(shelf.progress[good.id] == 1)
        #expect(shelf.failed[bad.id] == "Didn't finish. The connection dropped.")
        #expect(shelf.downloading.isEmpty)
        #expect(shelf.problem == nil)
    }

    @Test func aRefusalSaysWhatArchiveSaid() async throws {
        let one = set("busy")
        StubbedArchive.answers["/metadata/busy"] = .init(status: 503, type: "text/html", body: errorPage)
        await shelf.download(one, into: root)
        #expect(shelf.failed[one.id] == "Didn't finish. Archive.org answered 503.")
    }

    @Test func tryingAgainClearsTheFailure() async throws {
        let one = set("retry")
        StubbedArchive.answers["/metadata/retry"] = .init(offline: true)
        await shelf.download(one, into: root)
        #expect(shelf.failed[one.id] != nil)
        try lists("retry", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/retry/a.mp3"] = .init(body: song)
        await shelf.download(one, into: root)
        #expect(shelf.failed[one.id] == nil)
        #expect(landed(one).contains("credits.txt"))
    }

    @Test func cancellingForgetsProgressAndIsntAFailure() async throws {
        let one = set("stop")
        try lists("stop", mp3s: ["a.mp3"])
        StubbedArchive.answers["/download/stop/a.mp3"] = .init(body: song)
        let task = Task { await shelf.download(one, into: root) }
        task.cancel()
        await task.value
        #expect(shelf.failed[one.id] == nil)
        #expect(shelf.progress[one.id] == nil)
        #expect(shelf.downloading.isEmpty)
    }
}
