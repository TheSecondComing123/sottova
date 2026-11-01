import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SottovaCore

struct MetadataTests {
    private let folder: URL
    private let streamInfo = (type: UInt8(0), body: Data(count: 34))

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "sottova-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func flacPrefersTheFrontCover() {
        let file = flac([streamInfo, picture(type: 0, "other"), picture(type: 3, "front")])
        #expect(Metadata.flacPicture(file) == Data("front".utf8))
        // a slice whose startIndex isn't 0
        #expect(Metadata.flacPicture((Data(count: 2) + file).dropFirst(2)) == Data("front".utf8))
    }

    @Test func flacFallsBackToTheFirstPicture() {
        let file = flac([streamInfo, picture(type: 0, "other"), picture(type: 8, "artist")])
        #expect(Metadata.flacPicture(file) == Data("other".utf8))
    }

    @Test func flacIgnoresBlocksThatArentPictures() {
        let lookalike = picture(type: 3, "front").body
        let file = flac([streamInfo, (type: 1, body: lookalike), (type: 4, body: Data(count: 20))])
        #expect(Metadata.flacPicture(file) == nil)
    }

    @Test func flacSurvivesTruncation() {
        let file = flac([streamInfo, picture(type: 0, "other"), picture(type: 3, "front")])
        for length in 0..<file.count {
            let found = Metadata.flacPicture(file.prefix(length))
            #expect(found == nil || found == Data("other".utf8), "cut at \(length)")
        }
    }

    @Test(arguments: [("3", 3), ("3/12", 3), (" 07 ", 7), ("", nil), ("/12", nil), ("three", nil), ("0", nil)] as [(String, Int?)])
    func trackNumberText(_ text: String, expected: Int?) {
        #expect(Metadata.number(text) == expected)
    }

    @Test func trackNumberAtom() {
        #expect(Metadata.number(Data([0, 0, 0, 3, 0, 12, 0, 0])) == 3)
        #expect(Metadata.number(Data([0, 0, 1, 2, 0, 0, 0, 0])) == 258)
        #expect(Metadata.number(Data(count: 8)) == nil)
        #expect(Metadata.number(Data([0, 0, 0])) == nil)
    }

    @Test func m4aRoundTrips() async throws {
        let cover = jpeg(size: 800)
        let tags: [(AVMetadataIdentifier, any NSCopying & NSObjectProtocol, CFString?)] = [
            (.iTunesMetadataSongName, "Song" as NSString, nil),
            (.iTunesMetadataArtist, "Artist" as NSString, nil),
            (.iTunesMetadataAlbum, "Album" as NSString, nil),
            (.iTunesMetadataAlbumArtist, "Album Artist" as NSString, nil),
            (.iTunesMetadataComposer, "Composer" as NSString, nil),
            (.iTunesMetadataTrackNumber, Data([0, 0, 0, 3, 0, 12, 0, 0]) as NSData, kCMMetadataBaseDataType_RawData),
            (.iTunesMetadataReleaseDate, "2019-05-01" as NSString, nil),
            (.iTunesMetadataCoverArt, cover as NSData, kCMMetadataBaseDataType_JPEG),
        ]
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: try silence("source.caf")), presetName: AVAssetExportPresetAppleM4A))
        session.metadata = tags.map { identifier, value, dataType in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.dataType = dataType as String?
            return item
        }
        let url = folder.appending(path: "tagged.m4a")
        try await session.export(to: url, as: .m4a)

        let store = ArtworkStore(directory: folder.appending(path: "art"))
        let meta = try await Metadata.read(url, artwork: store)
        #expect(meta.title == "Song")
        #expect(meta.artist == "Artist")
        #expect(meta.album == "Album")
        #expect(meta.albumArtist == "Album Artist")
        #expect(meta.composer == "Composer")
        #expect(meta.trackNumber == 3)
        #expect(meta.year == 2019)
        #expect(abs(meta.duration - 1) < 0.05)
        let key = try #require(meta.artwork)
        #expect(key == store.save(cover))
        let thumbnail = try #require(store.image(for: key, maxPixel: 80))
        #expect(max(thumbnail.width, thumbnail.height) <= 80)
        let stored = try #require(store.image(for: key, maxPixel: 1000))
        #expect(max(stored.width, stored.height) <= 800)
    }

    @Test func untaggedFileUsesTheFolderCover() async throws {
        let url = try silence("untagged.caf")
        let cover = jpeg(size: 300)
        try cover.write(to: folder.appending(path: "Cover.JPG"))
        let store = ArtworkStore(directory: folder.appending(path: "art"))
        let meta = try await Metadata.read(url, artwork: store)
        #expect(meta.title == nil)
        #expect(meta.artwork != nil)
        #expect(meta.artwork == store.save(cover))
    }

    @Test func saveIsIdempotent() throws {
        let directory = folder.appending(path: "art")
        let store = ArtworkStore(directory: directory)
        let cover = jpeg(size: 100)
        let key = try #require(store.save(cover))
        #expect(key.count == 16)
        #expect(store.save(cover) == key)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["\(key).jpg"])
        #expect(store.save(Data("not an image".utf8)) == nil)
    }

    private func flac(_ blocks: [(type: UInt8, body: Data)]) -> Data {
        var data = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            data.append(block.type | (index == blocks.count - 1 ? 0x80 : 0))
            data.append(uint32(block.body.count).suffix(3))
            data.append(block.body)
        }
        return data
    }

    private func picture(type: Int, _ image: String) -> (type: UInt8, body: Data) {
        let mime = Data("image/jpeg".utf8), description = Data("cover".utf8), bytes = Data(image.utf8)
        var body = uint32(type) + uint32(mime.count) + mime + uint32(description.count) + description
        body += uint32(500) + uint32(500) + uint32(24) + uint32(0) + uint32(bytes.count) + bytes
        return (6, body)
    }

    private func uint32(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
    }

    private func jpeg(size: Int) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.95, green: 0.55, blue: 0.66, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// One second of stereo silence with no tags.
    private func silence(_ name: String) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = buffer.frameCapacity
        let url = folder.appending(path: name)
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}
