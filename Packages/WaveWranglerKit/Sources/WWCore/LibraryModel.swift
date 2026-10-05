import Foundation

/// Canonical library document payload: durable, user-authored organization across shows.
///
/// The library is user work (aliases, collections, order, unavailable entries), so it is a canonical
/// document that may live in a user-chosen cloud folder. Device-local access records and the rebuildable
/// derived index are separate and never authoritative for anything stored here.
public struct LibraryModel: Sendable, Equatable, Codable {
    /// Logical identity of this library document. Used to confirm that a re-granted or relocated folder holds
    /// the same library; paths and bookmarks are only location hints.
    public var libraryID: LibraryID
    public var schemaVersion: Int
    public var entries: [LibraryShowEntry]
    public var collections: [LibraryCollection]
    /// Most-recent-first logical show references.
    public var recentShowIDs: [ShowID]

    public init(
        libraryID: LibraryID = LibraryID(),
        schemaVersion: Int = SchemaVersion.library,
        entries: [LibraryShowEntry] = [],
        collections: [LibraryCollection] = [],
        recentShowIDs: [ShowID] = []
    ) {
        self.libraryID = libraryID
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.collections = collections
        self.recentShowIDs = recentShowIDs
    }
}

/// A logical reference to a show document. Location is resolved through device-local access records.
public struct LibraryShowEntry: Sendable, Equatable, Codable, Identifiable {
    public var showID: ShowID
    public var alias: String?
    public var lastKnownTitle: String
    /// Last coherent publication the library has reconciled with; `nil` until first reconciliation.
    public var lastKnownPublication: PublicationStamp?
    /// A user-visible record that the show could not be reached; retained rather than silently dropped.
    public var unavailable: UnavailableRecord?

    public var id: ShowID { showID }

    /// Ordering hint only; use `lastKnownPublication` to identify what was reconciled.
    public var lastKnownRevision: Int? { lastKnownPublication?.revision }

    public init(
        showID: ShowID,
        alias: String? = nil,
        lastKnownTitle: String,
        lastKnownPublication: PublicationStamp? = nil,
        unavailable: UnavailableRecord? = nil
    ) {
        self.showID = showID
        self.alias = alias
        self.lastKnownTitle = lastKnownTitle
        self.lastKnownPublication = lastKnownPublication
        self.unavailable = unavailable
    }
}

public struct UnavailableRecord: Sendable, Equatable, Codable {
    public var note: String
    public var recordedAt: Date

    public init(note: String, recordedAt: Date) {
        self.note = note
        self.recordedAt = recordedAt
    }
}

public struct LibraryCollection: Sendable, Equatable, Codable, Identifiable {
    public var id: CollectionID
    public var name: String
    /// User-ordered logical show references.
    public var showIDs: [ShowID]

    public init(id: CollectionID = CollectionID(), name: String, showIDs: [ShowID] = []) {
        self.id = id
        self.name = name
        self.showIDs = showIDs
    }
}
