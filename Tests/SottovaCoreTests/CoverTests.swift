import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SottovaCore

@MainActor
struct CoverTests {
    /// A 3000×2000 PNG, so the crop and the size cap both have something to do.
    private func wideImage() -> Data {
        let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sottova-cover-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesASquareCappedJPEGThatKeepsItsCredit() throws {
        let url = temp().appending(path: "cover.jpg")
        try CoverFile.write(wideImage(), to: url, credit: "Vilhelm Hammershøi, Moonlight, 1900 · the Met")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1200)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1200)
        #expect(CoverFile.credit(at: url) == "Vilhelm Hammershøi, Moonlight, 1900 · the Met")
    }

    @Test func notAnImageIsAnError() {
        #expect(throws: (any Error).self) { try CoverFile.write(Data("hello".utf8), to: temp().appending(path: "c.jpg"), credit: nil) }
    }

    @Test func aPlaylistsPictureFollowsARename() throws {
        let c = Controller(storage: temp(), playlistFolder: temp())
        let id = try #require(c.newPlaylist(named: "Night"))
        c.setCover(wideImage(), credit: nil, forPlaylist: id)
        #expect(c.playlistCovers[id] != nil)
        let renamed = try #require(c.rename(id, to: "Late"))
        #expect(FileManager.default.fileExists(atPath: Controller.coverURL(forPlaylist: renamed).path))
        #expect(c.playlistCovers[renamed] != nil)
    }
}
