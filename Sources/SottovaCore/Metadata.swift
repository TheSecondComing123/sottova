import AVFoundation

enum Metadata {
    /// Unreadable tags just come back nil. Throws only if the audio itself can't be opened (so the caller can mark the file unplayable).
    static func read(_ url: URL, artwork store: ArtworkStore?) async throws -> TrackMeta {
        let file = try AVAudioFile(forReading: url)
        // commonMetadata is empty for FLAC and WAV, but filtering the full list by common identifiers works everywhere
        let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []

        func find(_ identifiers: [AVMetadataIdentifier]) -> AVMetadataItem? {
            identifiers.lazy.compactMap { AVMetadataItem.metadataItems(from: items, filteredByIdentifier: $0).first }.first
        }
        func string(_ identifiers: AVMetadataIdentifier...) async -> String? {
            guard let item = find(identifiers), let text = try? await item.load(.stringValue), !text.isEmpty else { return nil }
            return text
        }
        func number(_ identifiers: AVMetadataIdentifier...) async -> Int? {
            guard let item = find(identifiers) else { return nil }
            if let text = try? await item.load(.stringValue) { return Metadata.number(text) }
            if let data = try? await item.load(.dataValue) { return Metadata.number(data) }
            return nil
        }

        var meta = TrackMeta(duration: Double(file.length) / file.fileFormat.sampleRate)
        meta.title = await string(.commonIdentifierTitle)
        meta.artist = await string(.commonIdentifierArtist)
        meta.album = await string(.commonIdentifierAlbumName)
        meta.albumArtist = await string(.id3MetadataBand, .iTunesMetadataAlbumArtist, .vorbis("ALBUMARTIST"))
        meta.trackNumber = await number(.id3MetadataTrackNumber, .iTunesMetadataTrackNumber, .vorbis("TRACKNUMBER"))
        meta.discNumber = await number(.id3MetadataPartOfASet, .iTunesMetadataDiscNumber, .vorbis("DISCNUMBER"))
        // the common creation date is ID3's TDAT (day and month), and TYER, TDRC and ©day have no common key
        meta.year = await string(.id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate, .vorbis("DATE"))?
            .prefixMatch(of: /\d{4}/).flatMap { Int($0.output) }

        if let store {
            var art = try? await find([.commonIdentifierArtwork])?.load(.dataValue)
            if art == nil, url.pathExtension.lowercased() == "flac", let bytes = try? Data(contentsOf: url, options: .alwaysMapped) {
                art = flacPicture(bytes)
            }
            meta.artwork = (art ?? folderCover(next: url)).flatMap(store.save)
        }
        return meta
    }

    /// "3", " 07 " or ID3's "3/12".
    static func number(_ text: String) -> Int? {
        Int(text.prefix { $0 != "/" }.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// iTunes trkn/disk atoms: 8 raw bytes, the number is the big-endian UInt16 at bytes 2–3.
    static func number(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }

    /// AVFoundation only surfaces a front-cover PICTURE block, so walk the blocks ourselves.
    /// Prefers the front cover (type 3), else the first picture.
    static func flacPicture(_ data: Data) -> Data? {
        var reader = Reader(data)
        guard reader.take(4) == Data("fLaC".utf8) else { return nil }
        var first: Data?
        while let header = reader.uint32(), let block = reader.take(Int(header & 0xff_ffff)) {
            if header >> 24 & 0x7f == 6, let found = picture(block) {
                if found.type == 3 { return found.image }
                first = first ?? found.image
            }
            if header >> 31 == 1 { break }
        }
        return first
    }

    private static func picture(_ block: Data) -> (type: UInt32, image: Data)? {
        var reader = Reader(block)
        guard let type = reader.uint32(),
              let mimeLength = reader.uint32(), reader.take(Int(mimeLength)) != nil,
              let descriptionLength = reader.uint32(), reader.take(Int(descriptionLength)) != nil,
              reader.take(16) != nil, // width, height, depth, colors
              let length = reader.uint32(), let image = reader.take(Int(length))
        else { return nil }
        return (type, image)
    }

    private static func folderCover(next url: URL) -> Data? {
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        for name in ["cover", "folder", "front"] {
            let match = files.first {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name
                    && ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased())
            }
            if let match { return try? Data(contentsOf: match) }
        }
        return nil
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        mutating func take(_ count: Int) -> Data? {
            guard count <= data.endIndex - offset else { return nil }
            defer { offset += count }
            return data[offset..<offset + count]
        }

        mutating func uint32() -> UInt32? {
            take(4)?.reduce(0) { $0 << 8 | UInt32($1) }
        }
    }
}

private extension AVMetadataIdentifier {
    /// FLAC Vorbis comments have no SDK constants.
    static func vorbis(_ field: String) -> AVMetadataIdentifier {
        AVMetadataIdentifier(rawValue: "vorb/\(field)")
    }
}
