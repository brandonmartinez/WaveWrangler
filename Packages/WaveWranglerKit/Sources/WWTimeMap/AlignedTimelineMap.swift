import Foundation
import WWCore

/// All recorder-group maps of one aligned timeline, sharing a single explicit ``TimelineReference``.
///
/// Invariants: every group map names the same reference; exactly one map belongs to the reference group;
/// group, epoch and occurrence identities are each owned by exactly one group. Queries delegate to the
/// group map that owns the occurrence.
public struct AlignedTimelineMap: Sendable, Equatable {
    public let reference: TimelineReference
    public let groups: [GroupTimeMap]

    private let groupIndexByOccurrence: [SourceOccurrenceID: Int]

    public init(reference: TimelineReference, groups: [GroupTimeMap]) throws(TimeMapError) {
        var seenGroups: Set<RecorderGroupID> = []
        var seenEpochs: Set<RecordingEpochID> = []
        var index: [SourceOccurrenceID: Int] = [:]
        for (position, map) in groups.enumerated() {
            guard map.reference == reference else { throw .referenceMismatch(map.group) }
            guard seenGroups.insert(map.group).inserted else { throw .duplicateGroup(map.group) }
            for epoch in map.epochs {
                guard seenEpochs.insert(epoch.epoch).inserted else { throw .epochInMultipleGroups(epoch.epoch) }
            }
            for occurrence in map.occurrenceIDs {
                guard index.updateValue(position, forKey: occurrence) == nil else { throw .occurrenceInMultipleGroups(occurrence) }
            }
        }
        guard seenGroups.contains(reference.group) else { throw .missingReferenceGroup(reference.group) }
        self.reference = reference
        self.groups = groups
        self.groupIndexByOccurrence = index
    }

    public func group(containing occurrence: SourceOccurrenceID) -> GroupTimeMap? {
        groupIndexByOccurrence[occurrence].map { groups[$0] }
    }

    public func alignedTime(ofFrame frame: Int64, in occurrence: SourceOccurrenceID) throws(TimeMapError) -> ForwardMapping {
        guard let map = group(containing: occurrence) else { throw .unknownOccurrence(occurrence) }
        return try map.alignedTime(ofFrame: frame, in: occurrence)
    }

    public func sourceFrame(at instant: ExactRational, in occurrence: SourceOccurrenceID) throws(TimeMapError) -> InverseMapping {
        guard let map = group(containing: occurrence) else { throw .unknownOccurrence(occurrence) }
        return try map.sourceFrame(at: instant, in: occurrence)
    }

    public static func == (lhs: AlignedTimelineMap, rhs: AlignedTimelineMap) -> Bool {
        lhs.reference == rhs.reference && lhs.groups == rhs.groups
    }
}

extension AlignedTimelineMap: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case timeMapSchemaVersion, reference, groups }

    /// Strict: refuses unknown-newer versions first, then unknown keys, then re-validates.
    public init(from decoder: any Decoder) throws {
        try decoder.checkTimeMapSchemaVersion()
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "AlignedTimelineMap")
        try self.init(
            reference: c.decode(TimelineReference.self, forKey: .reference),
            groups: c.decode([GroupTimeMap].self, forKey: .groups)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(TimeMapSchema.currentVersion, forKey: .timeMapSchemaVersion)
        try c.encode(reference, forKey: .reference)
        try c.encode(groups, forKey: .groups)
    }
}
