import CryptoKit
import Foundation
import WWCore

/// The canonical library coder. Writes schema 2; reads schema 2 strictly and schema 1 through an explicit,
/// validated upgrade (schema 1 had no `libraryID`).
///
/// The upgraded ID is **derived** from the schema 1 publication ID (name-based UUID), so every read of the
/// same schema 1 file yields the same identity until the first schema 2 publication fixes it on disk. The
/// first publication over schema 1 bytes keeps them as a non-overwriting migration backup (`LibraryStore`).
public struct LibraryCoder: CanonicalDocumentCoding {
    public typealias Payload = LibraryModel

    private let current = JSONEnvelopeCoder<LibraryModel>.library
    public var format: DocumentFormat { current.format }

    public static var library: LibraryCoder { LibraryCoder() }

    public init() {}

    public func decode(_ data: Data) throws(PersistenceError) -> DecodedDocument<LibraryModel> {
        do {
            return try current.decode(data)
        } catch .unsupportedOlderSchema(found: 1, minimum: _) {
            return try Self.decodeSchema1(data)
        }
    }

    public func encodeDocument(_ payload: LibraryModel, revision: Int, publicationID: UUID) throws(PersistenceError) -> EncodedDocument {
        try current.encodeDocument(payload, revision: revision, publicationID: publicationID)
    }

    /// Whether `data` is a schema 1 library (upgraded in memory on read).
    public static func isSchema1(_ data: Data) -> Bool {
        EnvelopeHeaderInfo.peek(data)?.schemaVersion == 1
    }

    // MARK: - Schema 1

    struct LibraryModelV1: Codable, Sendable {
        var schemaVersion: Int
        var entries: [LibraryShowEntry]
        var collections: [LibraryCollection]
        var recentShowIDs: [ShowID]
    }

    static let schema1Format = DocumentFormat(
        identifier: DocumentFormat.library.identifier,
        filenameExtension: DocumentFormat.library.filenameExtension,
        currentSchemaVersion: 1,
        minimumReadableSchemaVersion: 1
    )

    static func decodeSchema1(_ data: Data) throws(PersistenceError) -> DecodedDocument<LibraryModel> {
        // Full schema 1 envelope checks: format, checksum, no unrecognized content, schema 1 payload version.
        let v1 = JSONEnvelopeCoder<LibraryModelV1>(format: schema1Format) { payload, schema in
            payload.schemaVersion == schema ? [] : [ValidationIssue(.schemaVersionMismatch, "payload \(payload.schemaVersion) != expected \(schema)")]
        }
        let decoded = try v1.decode(data)
        let upgraded = LibraryModel(
            libraryID: derivedLibraryID(fromSchema1Publication: decoded.publication.publicationID),
            schemaVersion: SchemaVersion.library,
            entries: decoded.payload.entries,
            collections: decoded.payload.collections,
            recentShowIDs: decoded.payload.recentShowIDs
        )
        let issues = upgraded.validationIssues()
        guard issues.isEmpty else { throw .invalidPayload(issues) }
        return DecodedDocument(payload: upgraded, publication: decoded.publication)
    }

    /// Name-based (SHA-256, RFC 4122 version 5 layout) UUID for a schema 1 library.
    static func derivedLibraryID(fromSchema1Publication publicationID: UUID) -> LibraryID {
        var bytes = Array(SHA256.hash(data: Data("com.brandonmartinez.wavewrangler.library.schema1:\(publicationID.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return LibraryID(UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])))
    }
}
