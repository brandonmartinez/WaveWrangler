import Foundation
import WWCore

/// Identity and version range of one canonical document format.
public struct DocumentFormat: Sendable, Equatable {
    /// Stored in the envelope `format` field; equals the exported Uniform Type Identifier.
    public let identifier: String
    public let filenameExtension: String?
    /// The schema version this build writes.
    public let currentSchemaVersion: Int
    /// The oldest schema version this build can read (older versions need an explicit migration).
    public let minimumReadableSchemaVersion: Int

    public init(identifier: String, filenameExtension: String?, currentSchemaVersion: Int, minimumReadableSchemaVersion: Int) {
        self.identifier = identifier
        self.filenameExtension = filenameExtension
        self.currentSchemaVersion = currentSchemaVersion
        self.minimumReadableSchemaVersion = minimumReadableSchemaVersion
    }

    /// Portable show document (`.wwshow`). Must match `UTExportedTypeDeclarations` in the app Info.plist.
    public static let show = DocumentFormat(
        identifier: "com.brandonmartinez.wavewrangler.show",
        filenameExtension: "wwshow",
        currentSchemaVersion: SchemaVersion.show,
        // Schemas 1–3 open as `.needsMigration` and change only through the consented C5 migration
        // (`ShowSchemaMigration`, `DocumentMigrator.show`).
        minimumReadableSchemaVersion: SchemaVersion.show
    )

    /// Canonical library document (`.wwlibrary`). Declared now; storage/location lands with the library owner.
    public static let library = DocumentFormat(
        identifier: "com.brandonmartinez.wavewrangler.library",
        filenameExtension: "wwlibrary",
        currentSchemaVersion: SchemaVersion.library,
        // Schema 1 is read through `LibraryCoder`, which upgrades it explicitly.
        minimumReadableSchemaVersion: SchemaVersion.library
    )
}

/// A successfully decoded, checksum-verified and semantically validated canonical value.
public struct DecodedDocument<Payload: Sendable>: Sendable {
    public let payload: Payload
    public let publication: PublicationStamp

    /// Ordering hint only; identify the publication with `publication`.
    public var revision: Int { publication.revision }

    public init(payload: Payload, publication: PublicationStamp) {
        self.payload = payload
        self.publication = publication
    }
}

/// Encoded bytes plus the identity of the publication they represent.
public struct EncodedDocument: Sendable {
    public let data: Data
    public let publication: PublicationStamp

    public init(data: Data, publication: PublicationStamp) {
        self.data = data
        self.publication = publication
    }
}

/// Encodes/decodes a canonical document value to bytes. Kept behind a protocol so the selected
/// representation (versioned single JSON value) stays swappable.
public protocol CanonicalDocumentCoding: Sendable {
    associatedtype Payload: Sendable

    var format: DocumentFormat { get }
    func decode(_ data: Data) throws(PersistenceError) -> DecodedDocument<Payload>
    /// Encodes one publication. Callers pass a fresh `publicationID` for every write.
    func encodeDocument(_ payload: Payload, revision: Int, publicationID: UUID) throws(PersistenceError) -> EncodedDocument
}

extension CanonicalDocumentCoding {
    public func encode(_ payload: Payload, revision: Int, publicationID: UUID = UUID()) throws(PersistenceError) -> Data {
        try encodeDocument(payload, revision: revision, publicationID: publicationID).data
    }
}
