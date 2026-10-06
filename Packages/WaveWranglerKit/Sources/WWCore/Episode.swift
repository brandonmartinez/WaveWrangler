import Foundation

public enum EpisodeStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case planned
    case recorded
    case organizing
    case ready
    case published
}

public struct Episode: Sendable, Equatable, Codable, Identifiable {
    public var id: EpisodeID
    public var title: String
    /// Optional user-facing episode number; uniqueness is not enforced (specials, re-runs, etc.).
    public var number: Int?
    public var recordedOn: CalendarDay?
    public var publishedOn: CalendarDay?
    public var notes: String
    public var status: EpisodeStatus
    public var recorderGroups: [RecorderGroup]
    public var sources: [SourceRecord]
    public var speakerAssignments: [SpeakerAssignment]
    /// Versioned positive maps (M2, WW-020). `nil` (omitted from the encoding) until the first map is
    /// recorded, so shows without alignment keep their exact schema-2 bytes.
    public var alignment: EpisodeAlignment?

    public init(
        id: EpisodeID = EpisodeID(),
        title: String,
        number: Int? = nil,
        recordedOn: CalendarDay? = nil,
        publishedOn: CalendarDay? = nil,
        notes: String = "",
        status: EpisodeStatus = .planned,
        recorderGroups: [RecorderGroup] = [],
        sources: [SourceRecord] = [],
        speakerAssignments: [SpeakerAssignment] = [],
        alignment: EpisodeAlignment? = nil
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.recordedOn = recordedOn
        self.publishedOn = publishedOn
        self.notes = notes
        self.status = status
        self.recorderGroups = recorderGroups
        self.sources = sources
        self.speakerAssignments = speakerAssignments
        self.alignment = alignment
    }

    public func source(_ id: SourceID) -> SourceRecord? {
        sources.first { $0.id == id }
    }

    public func recorderGroup(_ id: RecorderGroupID) -> RecorderGroup? {
        recorderGroups.first { $0.id == id }
    }

    public func assignment(for speaker: SpeakerID) -> SpeakerAssignment? {
        speakerAssignments.first { $0.speakerID == speaker }
    }
}

/// One recorder/device whose files share a clock. M1 records only human notes about the clock; measured
/// clock relationships are M2 alignment data and are intentionally absent.
public struct RecorderGroup: Sendable, Equatable, Codable, Identifiable {
    public var id: RecorderGroupID
    public var name: String
    public var deviceName: String
    public var clockNote: String
    public var epochs: [RecordingEpoch]

    public init(
        id: RecorderGroupID = RecorderGroupID(),
        name: String,
        deviceName: String = "",
        clockNote: String = "",
        epochs: [RecordingEpoch] = []
    ) {
        self.id = id
        self.name = name
        self.deviceName = deviceName
        self.clockNote = clockNote
        self.epochs = epochs
    }
}

/// A continuous-clock span of a recorder (e.g. one start/stop take). Offsets are M2 data.
public struct RecordingEpoch: Sendable, Equatable, Codable, Identifiable {
    public var id: RecordingEpochID
    public var label: String
    public var note: String

    public init(id: RecordingEpochID = RecordingEpochID(), label: String, note: String = "") {
        self.id = id
        self.label = label
        self.note = note
    }
}
