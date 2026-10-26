import Foundation

/// Schema versions of WaveWrangler's canonical documents.
///
/// Bump a version only together with an explicit migration from every supported older version.
/// Readers refuse versions newer than they support (no edit, save or downsave).
public enum SchemaVersion {
    /// Canonical portable show document payload (`ShowDocumentModel`).
    /// 2: speaker channel references carry an explicit `Knowledge<Int>` channel (`.unknown` until stated)
    /// instead of a bare index with 0 as a placeholder. Schema 1 shows are upgraded only through the
    /// explicit, consented C5 migration (WWPersistence `ShowSchemaMigration`), which keeps a backup first.
    /// 3: episodes may carry `alignment` (WW-020: source occurrences/epochs, groups and versioned positive maps
    /// as strict `WWTimeMap` JSON). Schema 1 and 2 shows are upgraded only through the same consented migration.
    /// An embedded map's `timeMapSchemaVersion` is part of this schema: a time-map schema bump requires a show
    /// schema bump (pinned by `AlignmentPersistenceTests.schemaVersionsArePinned`).
    /// 4: human-accepted file-local pitch-preserving timing beside the unchanged recorder maps.
    /// 5: shared episode in/out markers and source-bound local transcripts.
    /// 6: nondestructive filler audible-word timing reviews with immutable detection provenance.
    /// 7: portable show profiles, speaker appearance, recorder definitions and episode workspace preferences.
    /// 8: manual cross-track ripple cuts on the original aligned frame grid.
    /// 9: recording/channel input gain, speaker/Master controls, and ordered Audio Unit document state.
    public static let show = 9
    /// Canonical library document payload (`LibraryModel`).
    /// 2: adds `libraryID`. Schema 1 libraries are upgraded with a derived, stable ID (see WWPersistence
    /// `LibraryCoder`); the original bytes are kept as a backup before the first schema 2 publication.
    public static let library = 2
}

/// The complete canonical value of one portable show document.
///
/// Everything a user would lose if the file were lost lives here: the show, all of its episodes, recorder
/// groups, logical source records, speakers, human corrections/decisions and the named edit history.
/// Device-local access records (bookmarks, location hints, availability observations) and derived
/// indexes/caches are deliberately *not* part of this value.
public struct ShowDocumentModel: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var show: Show
    public var speakers: [Speaker]
    public var episodes: [Episode]
    public var history: EditHistory

    public init(
        schemaVersion: Int = SchemaVersion.show,
        show: Show,
        speakers: [Speaker] = [],
        episodes: [Episode] = [],
        history: EditHistory = EditHistory()
    ) {
        self.schemaVersion = schemaVersion
        self.show = show
        self.speakers = speakers
        self.episodes = episodes
        self.history = history
    }

    /// A new, empty untitled show.
    public static func untitled(id: ShowID = ShowID(), title: String = "Untitled Show") -> ShowDocumentModel {
        ShowDocumentModel(show: Show(id: id, title: title))
    }

    public func episode(_ id: EpisodeID) -> Episode? {
        episodes.first { $0.id == id }
    }

    public func speaker(_ id: SpeakerID) -> Speaker? {
        speakers.first { $0.id == id }
    }
}

public struct Show: Sendable, Equatable, Codable, Identifiable {
    public var id: ShowID
    public var title: String
    public var notes: String
    public var profile: ShowProfile?

    public init(id: ShowID = ShowID(), title: String, notes: String = "", profile: ShowProfile? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.profile = profile
    }
}

/// A person who speaks on the show. Per-episode source/channel assignments live in
/// `Episode.speakerAssignments` so that an episode is self-contained.
public struct Speaker: Sendable, Equatable, Codable, Identifiable {
    public var id: SpeakerID
    public var name: String
    public var notes: String
    public var appearance: SpeakerAppearance?

    public init(id: SpeakerID = SpeakerID(), name: String, notes: String = "", appearance: SpeakerAppearance? = nil) {
        self.id = id
        self.name = name
        self.notes = notes
        self.appearance = appearance
    }
}
