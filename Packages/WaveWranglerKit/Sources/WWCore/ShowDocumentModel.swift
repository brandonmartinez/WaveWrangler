import Foundation

/// Schema versions of WaveWrangler's canonical documents.
///
/// Bump a version only together with an explicit migration from every supported older version.
/// Readers refuse versions newer than they support (no edit, save or downsave).
public enum SchemaVersion {
    /// Canonical portable show document payload (`ShowDocumentModel`).
    public static let show = 1
    /// Canonical library document payload (`LibraryModel`).
    public static let library = 1
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

    public init(id: ShowID = ShowID(), title: String, notes: String = "") {
        self.id = id
        self.title = title
        self.notes = notes
    }
}

/// A person who speaks on the show. Per-episode source/channel assignments live in
/// `Episode.speakerAssignments` so that an episode is self-contained.
public struct Speaker: Sendable, Equatable, Codable, Identifiable {
    public var id: SpeakerID
    public var name: String
    public var notes: String

    public init(id: SpeakerID = SpeakerID(), name: String, notes: String = "") {
        self.id = id
        self.name = name
        self.notes = notes
    }
}
