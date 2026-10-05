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
        minimumReadableSchemaVersion: 1
    )

    /// Canonical library document (`.wwlibrary`). Declared now; storage/location lands with the library owner.
    public static let library = DocumentFormat(
        identifier: "com.brandonmartinez.wavewrangler.library",
        filenameExtension: "wwlibrary",
        currentSchemaVersion: SchemaVersion.library,
        minimumReadableSchemaVersion: 1
    )
}

/// A successfully decoded, checksum-verified and semantically validated canonical value.
public struct DecodedDocument<Payload: Sendable>: Sendable {
    public let payload: Payload
    public let revision: Int

    public init(payload: Payload, revision: Int) {
        self.payload = payload
        self.revision = revision
    }
}

/// Encodes/decodes a canonical document value to bytes. Kept behind a protocol so the selected
/// representation (versioned single JSON value) stays swappable.
public protocol CanonicalDocumentCoding: Sendable {
    associatedtype Payload: Sendable

    var format: DocumentFormat { get }
    func decode(_ data: Data) throws(PersistenceError) -> DecodedDocument<Payload>
    func encode(_ payload: Payload, revision: Int) throws(PersistenceError) -> Data
}
