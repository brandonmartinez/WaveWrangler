import CryptoKit
import Foundation
import WWCore

/// Identity of one exact on-disk item: its envelope publication stamp (when readable) plus a digest of the
/// whole file.
///
/// Conflict and reconciliation detection compare `byteDigest`, which covers the publication ID and payload
/// checksum and also detects damage. `revision` is an ordering hint only. Integrity bookkeeping, not
/// authenticity.
public struct RevisionFingerprint: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// Envelope revision, or `nil` when the bytes have no readable envelope header.
    public let revision: Int?
    public let schemaVersion: Int?
    /// Envelope payload checksum, when readable.
    public let checksum: String?
    /// Envelope publication ID (fresh per write), when readable.
    public let publicationID: UUID?
    /// SHA-256 over the complete file bytes.
    public let byteDigest: String

    public init(revision: Int?, schemaVersion: Int?, checksum: String?, publicationID: UUID? = nil, byteDigest: String) {
        self.revision = revision
        self.schemaVersion = schemaVersion
        self.checksum = checksum
        self.publicationID = publicationID
        self.byteDigest = byteDigest
    }

    /// Fingerprints arbitrary bytes without decoding or validating the payload.
    public init(of data: Data) {
        let header = EnvelopeHeaderInfo.peek(data)
        self.init(
            revision: header?.revision,
            schemaVersion: header?.schemaVersion,
            checksum: header?.checksum,
            publicationID: header?.publicationID,
            byteDigest: Self.digest(data)
        )
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var shortDigest: String { String(byteDigest.prefix(16)) }

    /// The envelope publication stamp, when every field is readable.
    public var publication: PublicationStamp? {
        guard let revision, let checksum, let publicationID else { return nil }
        return PublicationStamp(revision: revision, publicationID: publicationID, checksum: checksum)
    }

    public var description: String {
        "r\(revision.map(String.init) ?? "?")/\(shortDigest)"
    }
}

/// The envelope header fields, read without touching the payload (best effort; any field may be absent in
/// a damaged or foreign file).
public struct EnvelopeHeaderInfo: Sendable, Equatable, Decodable {
    public let checksum: String?
    public let format: String?
    public let publicationID: UUID?
    public let revision: Int?
    public let schemaVersion: Int?

    public static func peek(_ data: Data) -> EnvelopeHeaderInfo? {
        try? JSONDecoder().decode(EnvelopeHeaderInfo.self, from: data)
    }
}
