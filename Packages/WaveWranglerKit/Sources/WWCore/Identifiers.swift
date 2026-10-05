import Foundation

/// A strongly typed logical identifier.
///
/// Logical IDs are the *only* identity WaveWrangler uses for shows, episodes, sources and people.
/// Paths, filenames and bookmarks are location/permission hints and must never be used as identity.
/// `Tag` is a phantom marker type so that, for example, a `SourceID` cannot be passed where a
/// `SpeakerID` is expected.
public struct LogicalID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

public enum ShowTag {}
public enum EpisodeTag {}
public enum RecorderGroupTag {}
public enum RecordingEpochTag {}
public enum SourceTag {}
public enum SpeakerTag {}
public enum CollectionTag {}
public enum LibraryTag {}
public enum EditTag {}

public typealias ShowID = LogicalID<ShowTag>
public typealias EpisodeID = LogicalID<EpisodeTag>
public typealias RecorderGroupID = LogicalID<RecorderGroupTag>
public typealias RecordingEpochID = LogicalID<RecordingEpochTag>
public typealias SourceID = LogicalID<SourceTag>
public typealias SpeakerID = LogicalID<SpeakerTag>
public typealias CollectionID = LogicalID<CollectionTag>
/// Logical identity of one canonical library document (stable across moves, renames and devices).
public typealias LibraryID = LogicalID<LibraryTag>
public typealias EditID = LogicalID<EditTag>
