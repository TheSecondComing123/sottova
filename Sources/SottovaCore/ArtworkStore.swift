import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cover art on disk as JPEGs named by content hash, so every track on an album shares one file.
public final class ArtworkStore: Sendable {
    private let directory: URL
    // NSCache is thread-safe but isn't marked Sendable
    private nonisolated(unsafe) let cache = NSCache<NSString, CGImage>()

    public init(directory: URL) {
        self.directory = directory
        // decoded tiles are ~1 MB each; without a limit, scrolling a big library holds them all until memory pressure
        cache.totalCostLimit = 150 << 20
    }

    /// A decoded image already in memory, so a view can show it on its first frame without a fade.
    public func cached(for key: String, maxPixel: Int) -> CGImage? {
        cache.object(forKey: "\(key)@\(maxPixel)" as NSString)
    }

    /// Returns the key, or nil if the bytes aren't an image.
    func save(_ imageData: Data) -> String? {
        let key = SHA256.hash(data: imageData).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = file(for: key)
        if FileManager.default.fileExists(atPath: url.path) { return key }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = thumbnail(source, maxPixel: 600)
        else { return nil }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            // the system can purge Caches, so make the folder every time something is written
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // atomic, so a reader on another thread never sees half a JPEG
            try (jpeg as Data).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return key
    }

    public func image(for key: String, maxPixel: Int) -> CGImage? {
        let cacheKey = "\(key)@\(maxPixel)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let source = CGImageSourceCreateWithURL(file(for: key) as CFURL, nil),
              let image = thumbnail(source, maxPixel: maxPixel)
        else { return nil }
        cache.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return image
    }

    private func file(for key: String) -> URL {
        directory.appending(path: "\(key).jpg")
    }

    private func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
