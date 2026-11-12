import Foundation
import ImageIO

public enum PublicationArtworkSelection: Sendable, Equatable, Codable {
    case none
    case image(PublicationArtwork)

    public var image: PublicationArtwork? {
        if case .image(let image) = self { return image }
        return nil
    }
}

/// Immutable, locally validated original image bytes, not a path or audio-source authorization.
/// Changing the embedded artwork schema also requires a show schema bump.
public struct PublicationArtwork: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1
    public static let maximumBytes = 10 * 1_024 * 1_024
    public static let maximumDimension = 4_096
    public let schemaVersion: Int
    public let data: Data
    public let mediaType: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(data: Data) throws(DomainError) {
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw .invalidPublication("Choose a JPEG or PNG image no larger than 10 MB.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png"].contains(type),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw .invalidPublication("Choose a complete, single-image JPEG or PNG file.")
        }
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height) else {
            throw .invalidPublication("Artwork dimensions must be between 1 and 4,096 pixels on each side.")
        }
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw .invalidPublication("This artwork could not be decoded. Choose a different JPEG or PNG.")
        }
        schemaVersion = Self.currentSchemaVersion
        self.data = data
        mediaType = type == "public.png" ? "image/png" : "image/jpeg"
        pixelWidth = width
        pixelHeight = height
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, data, mediaType, pixelWidth, pixelHeight }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version <= Self.currentSchemaVersion else {
            throw DomainError.unsupportedPublicationArtworkSchema(found: version, supported: Self.currentSchemaVersion)
        }
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported artwork schema.")
        }
        let image = try Self(data: values.decode(Data.self, forKey: .data))
        guard try values.decode(String.self, forKey: .mediaType) == image.mediaType,
              try values.decode(Int.self, forKey: .pixelWidth) == image.pixelWidth,
              try values.decode(Int.self, forKey: .pixelHeight) == image.pixelHeight else {
            throw DecodingError.dataCorruptedError(forKey: .data, in: values, debugDescription: "Artwork dimensions or type do not match its bytes.")
        }
        self = image
    }
}
