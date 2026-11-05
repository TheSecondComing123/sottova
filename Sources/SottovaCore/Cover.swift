import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A public-domain painting from a museum's open-access collection.
public struct Painting: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let year: String?
    public let museum: String
    public let thumbnail: URL
    public let image: URL

    /// Museum-label order: "Vilhelm Hammershøi, Moonlight, Strandgade 30, 1900–1906 · The Met".
    public var credit: String {
        [artist, title, year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") + " · \(museum)"
    }
}

/// Searches each museum separately, so one that's slow or down doesn't hold up the others.
public enum PaintingSearch {
    public enum Museum: String, CaseIterable, Sendable {
        case met = "the Met", chicago = "the Art Institute", cleveland = "Cleveland"
    }

    public static func search(_ query: String, in museum: Museum) async throws -> [Painting] {
        switch museum {
        case .met: try await met(query)
        case .chicago: try await chicago(query)
        case .cleveland: try await cleveland(query)
        }
    }

    private static func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // the Art Institute turns away requests without one
        request.setValue("Sottova/0.1 (macOS music player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func url(_ base: String, _ items: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private static func chicago(_ query: String) async throws -> [Painting] {
        let root = try await json(url("https://api.artic.edu/api/v1/artworks/search", [
            "q": query, "query[term][is_public_domain]": "true", "limit": "12",
            "fields": "id,title,image_id,artist_title,date_display",
        ])) as? [String: Any]
        return (root?["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let image = item["image_id"] as? String else { return nil }
            let iiif = "https://www.artic.edu/iiif/2/\(image)/full"
            return Painting(id: "aic:\(id)", title: item["title"] as? String ?? "Untitled", artist: item["artist_title"] as? String ?? "",
                            year: item["date_display"] as? String, museum: Museum.chicago.rawValue,
                            thumbnail: URL(string: "\(iiif)/400,/0/default.jpg")!, image: URL(string: "\(iiif)/1686,/0/default.jpg")!)
        }
    }

    private static func cleveland(_ query: String) async throws -> [Painting] {
        let root = try await json(url("https://openaccess-api.clevelandart.org/api/artworks/", [
            "q": query, "cc0": "1", "has_image": "1", "type": "Painting", "limit": "12",
        ])) as? [String: Any]
        return (root?["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let images = item["images"] as? [String: Any],
                  let web = (images["web"] as? [String: Any])?["url"] as? String, let thumb = URL(string: web) else { return nil }
            let print = (images["print"] as? [String: Any])?["url"] as? String
            // "Du Jin (Chinese, 1446–c. 1519)" reads as just the name on a label
            let creator = ((item["creators"] as? [[String: Any]])?.first?["description"] as? String)?
                .components(separatedBy: " (").first ?? ""
            return Painting(id: "cma:\(id)", title: item["title"] as? String ?? "Untitled", artist: creator,
                            year: item["creation_date"] as? String, museum: Museum.cleveland.rawValue,
                            thumbnail: thumb, image: print.flatMap(URL.init(string:)) ?? thumb)
        }
    }

    /// The Met's search returns only ids, so the first few are looked up together and kept if they're public-domain paintings.
    private static func met(_ query: String) async throws -> [Painting] {
        let root = try await json(url("https://collectionapi.metmuseum.org/public/collection/v1.1/search", [
            "q": query, "hasImages": "true",
        ])) as? [String: Any]
        let ids = (root?["objectIDs"] as? [Int] ?? []).prefix(20)
        return await withTaskGroup(of: (Int, Painting?).self) { group in
            for (order, id) in ids.enumerated() {
                group.addTask {
                    guard let item = try? await json(URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects/\(id)")!) as? [String: Any],
                          item["isPublicDomain"] as? Bool == true, item["classification"] as? String == "Paintings",
                          let small = (item["primaryImageSmall"] as? String).flatMap(URL.init(string:)),
                          let full = (item["primaryImage"] as? String).flatMap(URL.init(string:)) else { return (order, nil) }
                    return (order, Painting(id: "met:\(id)", title: item["title"] as? String ?? "Untitled",
                                            artist: item["artistDisplayName"] as? String ?? "", year: item["objectDate"] as? String,
                                            museum: Museum.met.rawValue, thumbnail: small, image: full))
                }
            }
            var found: [(Int, Painting)] = []
            for await (order, painting) in group {
                if let painting { found.append((order, painting)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// cover.jpg: a centered square, at most 1200 px, with the painting's credit in its IPTC so it travels with the file.
public enum CoverFile {
    public static func write(_ data: Data, to url: URL, credit: String?) throws {
        try jpeg(data, credit: credit).write(to: url, options: .atomic)
    }

    public static func jpeg(_ data: Data, credit: String?) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        let side = min(full.width, full.height)
        guard let square = full.cropping(to: CGRect(x: (full.width - side) / 2, y: (full.height - side) / 2, width: side, height: side))
        else { throw CocoaError(.fileReadCorruptFile) }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImageDestinationImageMaxPixelSize: 1200]
        if let credit {
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCredit: credit]
        }
        CGImageDestinationAddImage(destination, square, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return jpeg as Data
    }

    public static func credit(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCredit] as? String
    }
}
