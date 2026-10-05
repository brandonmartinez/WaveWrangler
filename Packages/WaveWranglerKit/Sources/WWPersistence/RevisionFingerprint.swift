import CryptoKit
import Foundation

/// Identity of one exact on-disk revision: the envelope's revision/checksum plus a digest of the whole file.
///
/// Comparing `byteDigest` detects *any* change to the bytes (including damage or a competing writer that
/// happened to reuse a revision number). It is integrity bookkeeping, not authenticity.
public struct RevisionFingerprint: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// Envelope revision, or `nil` when the bytes have no readable envelope header.
    public let revision: Int?
    public let schemaVersion: Int?
    /// Envelope payload checksum, when readable.
    public let checksum: String?
    /// SHA-256 over the complete file bytes.
    public let byteDigest: String

    public init(revision: Int?, schemaVersion: Int?, checksum: String?, byteDigest: String) {
        self.revision = revision
        self.schemaVersion = schemaVersion
        self.checksum = checksum
        self.byteDigest = byteDigest
    }

    /// Fingerprints arbitrary bytes without decoding or validating the payload.
    public init(of data: Data) {
        let header = EnvelopeHeaderInfo.peek(data)
        self.init(
            revision: header?.revision,
            schemaVersion: header?.schemaVersion,
            checksum: header?.checksum,
            byteDigest: Self.digest(data)
        )
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var shortDigest: String { String(byteDigest.prefix(16)) }

    public var description: String {
        "r\(revision.map(String.init) ?? "?")/\(shortDigest)"
    }
}

/// The envelope header fields, read without touching the payload.
public struct EnvelopeHeaderInfo: Sendable, Equatable, Decodable {
    public let checksum: String
    public let format: String
    public let revision: Int
    public let schemaVersion: Int

    public static func peek(_ data: Data) -> EnvelopeHeaderInfo? {
        try? JSONDecoder().decode(EnvelopeHeaderInfo.self, from: data)
    }
}
