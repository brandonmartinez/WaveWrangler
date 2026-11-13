import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExportArtwork: Sendable, Equatable {
    public enum Format: Sendable { case jpeg, png }
    public let data: Data
    public let format: Format

    public init(data: Data, format: Format) throws {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              type as String == (format == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4_096).contains(width), (1...4_096).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ExportFailure.invalidMetadata("Artwork must be a valid JPEG/PNG, at most 8 MiB and 4096 pixels per side")
        }
        self.data = data
        self.format = format
    }
}

/// Public delivery values only. The caller must not include private notes or source paths.
public struct ExportMetadata: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var publicDescription: String?
    public var copyright: String?
    public var genre: String?
    /// ISO 8601 date or date-time, preserved as text.
    public var date: String?
    public var episodeNumber: Int?
    public var artwork: ExportArtwork?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil,
                publicDescription: String? = nil, copyright: String? = nil, genre: String? = nil,
                date: String? = nil, episodeNumber: Int? = nil, artwork: ExportArtwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.publicDescription = publicDescription
        self.copyright = copyright
        self.genre = genre
        self.date = date
        self.episodeNumber = episodeNumber
        self.artwork = artwork
    }

    func validate(for codec: ExportCodec) throws {
        for value in [title, artist, album, publicDescription, copyright, genre, date].compactMap({ $0 }) {
            guard value.utf8.count <= 64 * 1_024, !value.contains("\0") else {
                throw ExportFailure.invalidMetadata("Text exceeds 64 KiB or contains NUL")
            }
        }
        if let episodeNumber, !(1...Int(Int32.max)).contains(episodeNumber) {
            throw ExportFailure.invalidMetadata("Episode number must be a positive 32-bit integer")
        }
        if let date {
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            let validDay = day.date(from: date).map { day.string(from: $0) == date } ?? false
            guard validDay || ISO8601DateFormatter().date(from: date) != nil else {
                throw ExportFailure.invalidMetadata("Date must be ISO 8601")
            }
        }
        if case .wave = codec {
            guard artwork == nil, episodeNumber == nil else {
                throw ExportFailure.invalidMetadata("WAV INFO supports text only; artwork and episode numbers are unsupported")
            }
            guard [title, artist, album, publicDescription, copyright, genre, date]
                .compactMap({ $0 }).allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) }) else {
                throw ExportFailure.invalidMetadata("WAV INFO text is restricted to ASCII for interoperability")
            }
        }
    }

    var mp3Tag: Data {
        var frames = Data()
        for (key, value) in [
            ("TIT2", title), ("TPE1", artist), ("TALB", album), ("TCOP", copyright),
            ("TCON", genre), ("TDRC", date), ("TVES", episodeNumber.map(String.init)),
        ] {
            if let value { frames.append(Self.id3Frame(key, Data([3]) + Data(value.utf8))) }
        }
        if let publicDescription {
            // Standard comment plus a named public-description field (not private production notes).
            frames.append(Self.id3Frame("COMM", Data([3]) + Data("eng\0".utf8) + Data(publicDescription.utf8)))
            frames.append(Self.id3Frame("TXXX", Data([3]) + Data("DESCRIPTION\0".utf8) + Data(publicDescription.utf8)))
        }
        if let artwork {
            let mime = artwork.format == .jpeg ? "image/jpeg" : "image/png"
            frames.append(Self.id3Frame("APIC", Data([3]) + Data(mime.utf8) + Data([0, 3, 0]) + artwork.data))
        }
        guard !frames.isEmpty else { return Data() }
        return Data("ID3".utf8) + Data([4, 0, 0]) + Self.syncsafe(frames.count) + frames
    }

    private static func id3Frame(_ key: String, _ payload: Data) -> Data {
        Data(key.utf8) + syncsafe(payload.count) + Data([0, 0]) + payload
    }

    private static func syncsafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 127), UInt8((value >> 14) & 127),
              UInt8((value >> 7) & 127), UInt8(value & 127)])
    }

    var waveInfo: Data {
        var body = Data("INFO".utf8)
        for (key, value) in [
            ("INAM", title), ("IART", artist), ("IPRD", album), ("ICMT", publicDescription),
            ("ICOP", copyright), ("IGNR", genre), ("ICRD", date),
        ] {
            if let value {
                let bytes = Data(value.utf8) + Data([0])
                body.append(Data(key.utf8) + Self.littleEndian(UInt32(bytes.count)) + bytes)
                if bytes.count % 2 != 0 { body.append(0) }
            }
        }
        return body.count == 4 ? Data() : Data("LIST".utf8) + Self.littleEndian(UInt32(body.count)) + body
    }

    static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    var m4aItems: [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        for (identifier, value) in [
            (AVMetadataIdentifier.iTunesMetadataSongName, title),
            (.iTunesMetadataArtist, artist), (.iTunesMetadataAlbum, album),
            (.iTunesMetadataDescription, publicDescription), (.iTunesMetadataCopyright, copyright),
            (.iTunesMetadataUserGenre, genre), (.iTunesMetadataReleaseDate, date),
        ] {
            if let value {
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = value as NSString
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                items.append(item)
            }
        }
        if let episodeNumber {
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = "tves" as NSString
            item.value = NSNumber(value: episodeNumber)
            item.dataType = kCMMetadataBaseDataType_SInt32 as String
            items.append(item)
        }
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = artwork.data as NSData
            item.dataType = (artwork.format == .jpeg ? kCMMetadataBaseDataType_JPEG : kCMMetadataBaseDataType_PNG) as String
            items.append(item)
        }
        return items
    }
}
