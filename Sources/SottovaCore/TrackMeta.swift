import Foundation

public struct TrackMeta: Codable, Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var duration: Double
    /// ArtworkStore key, nil when the file has no art.
    public var artwork: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil, duration: Double = 0, artwork: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.duration = duration
        self.artwork = artwork
    }
}
