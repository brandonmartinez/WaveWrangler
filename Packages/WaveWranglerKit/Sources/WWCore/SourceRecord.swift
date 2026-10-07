import Foundation

/// Recording-level role of a source within its episode.
public enum SourceRole: String, Sendable, Codable, Equatable, CaseIterable {
    case unassigned
    case primary
    case backup
}

/// The portable, logical record of one referenced original recording.
///
/// This carries *no* path, filename-as-identity or bookmark: device-local access records keyed by `id`
/// live outside canonical data (see `WWSources`). `displayNameHint` is only a human hint for relinking.
public struct SourceRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: SourceID
    public var displayNameHint: String
    public var observations: SourceObservations
    public var placement: SourcePlacement
    public var role: SourceRole
    public var roleConfirmation: Confirmation

    public init(
        id: SourceID = SourceID(),
        displayNameHint: String,
        observations: SourceObservations = SourceObservations(),
        placement: SourcePlacement = SourcePlacement(),
        role: SourceRole = .unassigned,
        roleConfirmation: Confirmation = .provisional
    ) {
        self.id = id
        self.displayNameHint = displayNameHint
        self.observations = observations
        self.placement = placement
        self.role = role
        self.roleConfirmation = roleConfirmation
    }
}

/// Recorded-media facts. Every field is `.unknown` until an explicitly permitted inspection observes it;
/// M1 metadata-only paths never fill these in by reading content or headers.
public struct SourceObservations: Sendable, Equatable, Codable {
    public var durationSeconds: Knowledge<Double>
    public var channelCount: Knowledge<Int>
    public var sampleRate: Knowledge<Double>

    public init(
        durationSeconds: Knowledge<Double> = .unknown,
        channelCount: Knowledge<Int> = .unknown,
        sampleRate: Knowledge<Double> = .unknown
    ) {
        self.durationSeconds = durationSeconds
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}

/// Where a source sits in the episode's recorder structure and how its channels are labeled.
public struct SourcePlacement: Sendable, Equatable, Codable {
    public var recorderGroupID: RecorderGroupID?
    public var epochID: RecordingEpochID?
    public var channelLabels: [ChannelLabel]

    public init(
        recorderGroupID: RecorderGroupID? = nil,
        epochID: RecordingEpochID? = nil,
        channelLabels: [ChannelLabel] = []
    ) {
        self.recorderGroupID = recorderGroupID
        self.epochID = epochID
        self.channelLabels = channelLabels
    }
}

public struct ChannelLabel: Sendable, Equatable, Codable {
    /// Zero-based channel index within the source.
    public var channel: Int
    public var label: String

    public init(channel: Int, label: String) {
        self.channel = channel
        self.label = label
    }
}

/// A channel of a specific logical source.
///
/// Since show schema 2 the channel is an explicit `Knowledge<Int>`: `.known(n)` is a zero-based channel
/// index a person stated (or the generic API recorded), and `.unknown` means "this source, channel not
/// yet stated". `.unknown` is never encoded as, or treated as, channel 0. Schema 1 stored a bare index and
/// used 0 as a placeholder; `ShowSchemaMigration` (WWPersistence) converts that placeholder to `.unknown`.
public struct ChannelReference: Sendable, Hashable, Codable, CustomStringConvertible {
    public var sourceID: SourceID
    /// Zero-based channel index when known; `.unknown` until a person states it.
    public var channel: Knowledge<Int>

    public init(sourceID: SourceID, channel: Knowledge<Int>) {
        self.sourceID = sourceID
        self.channel = channel
    }

    /// A reference to a stated zero-based channel, or to an unknown channel of the source when `nil`.
    public init(sourceID: SourceID, statedChannel: Int?) {
        self.init(sourceID: sourceID, channel: statedChannel.map { .known($0) } ?? .unknown)
    }

    /// `<source>#<zero-based index>` or `<source>#unknown`; for diagnostics, never shown to people.
    public var description: String {
        "\(sourceID)#\(channel.value.map(String.init) ?? "unknown")"
    }
}

/// A speaker's per-episode primary and backup channels.
public struct SpeakerAssignment: Sendable, Equatable, Codable {
    public var speakerID: SpeakerID
    public var primary: ChannelReference?
    public var primaryConfirmation: Confirmation
    public var backups: [ChannelReference]

    public init(
        speakerID: SpeakerID,
        primary: ChannelReference? = nil,
        primaryConfirmation: Confirmation = .provisional,
        backups: [ChannelReference] = []
    ) {
        self.speakerID = speakerID
        self.primary = primary
        self.primaryConfirmation = primaryConfirmation
        self.backups = backups
    }
}
