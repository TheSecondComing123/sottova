import Foundation

/// Writes a fresh ID3v2.3 tag over the one an MP3 starts with. Only for downloads that come with next to no tags
/// (the Musopen Chopin files carry a title and a comment): the old tag is dropped, not merged.
enum ID3 {
    /// `frames` are text frames by ID ("TIT2", "TPE1"…), written in this order; "W…" frames are URLs.
    static func retag(_ audio: Data, _ frames: [(id: String, value: String)]) -> Data {
        var body = Data()
        for (id, value) in frames where !value.isEmpty {
            var content = Data()
            if id.hasPrefix("W") {
                content.append(contentsOf: Array(value.utf8))
            } else {
                // encoding 1: UTF-16 with a byte-order mark, so "Frédéric" survives
                content.append(1)
                content.append(contentsOf: [0xFF, 0xFE])
                for unit in value.utf16 { content.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
            }
            body.append(contentsOf: Array(id.utf8))
            body.append(contentsOf: bigEndian(UInt32(content.count)))
            body.append(contentsOf: [0, 0])
            body.append(content)
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [3, 0, 0])
        tag.append(contentsOf: synchsafe(UInt32(body.count)))
        tag.append(body)
        return tag + audio.dropFirst(existingTagLength(audio))
    }

    /// The bytes an ID3v2 tag takes at the start of the file: header, body, and a footer if the flags say so.
    static func existingTagLength(_ data: Data) -> Int {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return 0 }
        let size = b[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        return min(10 + size + (b[5] & 0x10 != 0 ? 10 : 0), data.count)
    }

    private static func bigEndian(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    }

    private static func synchsafe(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)]
    }
}
