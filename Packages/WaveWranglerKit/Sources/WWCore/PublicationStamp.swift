import Foundation

/// Identity of one published revision of a canonical document.
///
/// `revision` is only an ordering hint: two devices, or a restored Version, can publish the same revision
/// number with different content. `publicationID` is unique per publication, and `checksum` identifies
/// the payload content. Conflict detection compares the publication ID and checksum, never the revision
/// number alone.
public struct PublicationStamp: Sendable, Hashable, Codable {
    public var revision: Int
    public var publicationID: UUID
    /// `sha256:<hex>` over the canonical payload encoding.
    public var checksum: String

    public init(revision: Int, publicationID: UUID, checksum: String) {
        self.revision = revision
        self.publicationID = publicationID
        self.checksum = checksum
    }
}
