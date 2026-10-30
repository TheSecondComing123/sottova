import Foundation
import Testing
@testable import SottovaCore

struct ID3Tests {
    private let audio = Data([0xFF, 0xFB, 0x90, 0x64] + Array(repeating: 0x55, count: 64))

    /// An old tag as Musopen ships it: v2.3, the unsynchronisation flag set, a synchsafe size.
    private func oldTag(size: Int, footer: Bool = false) -> Data {
        var tag = Data("ID3".utf8) + Data([3, 0, footer ? 0x90 : 0x80])
        tag.append(contentsOf: [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)])
        tag.append(Data(repeating: 0x41, count: size + (footer ? 10 : 0)))
        return tag
    }

    /// Reads the frames back the way a tag reader would.
    private func frames(_ data: Data) -> [String: String] {
        let b = [UInt8](data)
        let end = ID3.existingTagLength(data)
        var out: [String: String] = [:]
        var i = 10
        while i + 10 <= end {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self)
            let size = b[i + 4..<i + 8].reduce(0) { $0 << 8 | Int($1) }
            let content = Array(b[i + 10..<i + 10 + size])
            if id.hasPrefix("W") {
                out[id] = String(decoding: content, as: UTF8.self)
            } else {
                #expect(content.prefix(3) == [1, 0xFF, 0xFE])
                let units = stride(from: 3, to: content.count, by: 2).map { UInt16(content[$0]) | UInt16(content[$0 + 1]) << 8 }
                out[id] = String(decoding: units, as: UTF16.self)
            }
            i += 10 + size
        }
        return out
    }

    @Test func replacesTheOldTagAndKeepsTheAudio() {
        let tagged = ID3.retag(oldTag(size: 526) + audio, [("TIT2", "Ballade No. 1, Op. 23"), ("TCOM", "Frédéric Chopin"),
                                                           ("WCOP", "https://creativecommons.org/publicdomain/zero/1.0/")])
        #expect(tagged.prefix(6) == Data("ID3".utf8) + Data([3, 0, 0]))
        #expect(tagged.dropFirst(ID3.existingTagLength(tagged)) == audio)
        #expect(frames(tagged) == ["TIT2": "Ballade No. 1, Op. 23", "TCOM": "Frédéric Chopin",
                                   "WCOP": "https://creativecommons.org/publicdomain/zero/1.0/"])
    }

    @Test func aFooterIsPartOfTheOldTag() {
        let tagged = ID3.retag(oldTag(size: 20, footer: true) + audio, [("TIT2", "x")])
        #expect(tagged.dropFirst(ID3.existingTagLength(tagged)) == audio)
    }

    @Test func aFileWithNoTagGetsOne() {
        let tagged = ID3.retag(audio, [("TPE1", "Musopen"), ("TALB", "")])
        #expect(tagged.dropFirst(ID3.existingTagLength(tagged)) == audio)
        #expect(frames(tagged) == ["TPE1": "Musopen"])
    }
}
