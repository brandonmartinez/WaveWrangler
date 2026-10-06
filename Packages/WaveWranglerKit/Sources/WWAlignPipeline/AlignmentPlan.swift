import Foundation
import WWCore
import WWDerived
import WWSources
import WWTimeMap

/// Why the pipeline will not read a source's content. Every case means zero gateway calls for that source.
public enum SourceIneligibility: Sendable, Hashable {
    /// The caller supplied no location for the source.
    case locationUnknown
    /// Setup availability is OFF: metadata-only, never opened.
    case availabilityOff
    /// No explicit, user-initiated `ContentWorkAuthorization` for this source.
    case notAuthorized
    /// The derived-job coordinator has no current revision for the source (nothing could be keyed to it).
    case notRegistered
}

/// Why a grouped source has no place in the alignment (metadata only; nothing was read).
public enum UnplacedReason: Error, Sendable, Hashable {
    /// Its recorder group no longer exists in the episode.
    case groupMissing
    /// The source names an epoch the group does not have.
    case epochMissing
    /// The group has several epochs and the source names none of them.
    case epochNotStated
}

/// The timeline reference: the epoch every other epoch is measured against.
public struct AlignmentReferenceChoice: Sendable, Hashable {
    public let group: RecorderGroupID
    public let epoch: RecordingEpochID
    public let source: SourceID

    public var occurrence: SourceOccurrenceID { alignmentOccurrenceID(for: source) }
}

/// Why an epoch gets no analysis in this run.
public enum NotAttemptedReason: Sendable, Hashable {
    /// No source in the episode is eligible to be the timeline reference.
    case noReference
    /// A restart of the reference recorder: it cannot overlap the reference epoch, so audio evidence can't
    /// time it. Set it manually.
    case sameRecorderAsReference
    /// The epoch has sources, but none is eligible (see `AlignmentPlan.ineligible`).
    case noEligibleSource
    /// No source is placed in this epoch.
    case noSources
}

public enum PlannedDisposition: Sendable, Hashable {
    case reference
    /// Analyse `target` (the epoch's first eligible source) against the reference.
    case analyse(target: SourceID)
    case notAttempted(NotAttemptedReason)
}

public struct PlannedEpoch: Sendable, Hashable {
    public let group: RecorderGroupID
    public let epoch: RecordingEpochID
    /// Every source placed in this epoch, in episode order.
    public let sources: [SourceID]
    /// The subset whose content may be read.
    public let eligibleSources: [SourceID]
    public let disposition: PlannedDisposition
}

/// Which epochs are analysed against which reference, decided from metadata only.
public struct AlignmentPlan: Sendable, Hashable {
    public let episode: EpisodeID
    public let reference: AlignmentReferenceChoice?
    /// Every epoch of every recorder group, in episode order.
    public let epochs: [PlannedEpoch]
    public let ineligible: [SourceID: SourceIneligibility]
    public let unplaced: [SourceID: UnplacedReason]

    public func epoch(_ id: RecordingEpochID) -> PlannedEpoch? {
        epochs.first { $0.epoch == id }
    }

    /// Every eligible, placed source (reference first), each once.
    public var eligiblePlacedSources: [SourceID] {
        var seen = Set<SourceID>()
        var result: [SourceID] = []
        if let reference, seen.insert(reference.source).inserted { result.append(reference.source) }
        for epoch in epochs {
            for source in epoch.eligibleSources where seen.insert(source).inserted { result.append(source) }
        }
        return result
    }
}

/// Decides whether the pipeline may read a source: the user explicitly asked for content work on it, its
/// availability is ON, its location is known and the coordinator holds a current revision for it.
struct ContentEligibility: Sendable {
    let locations: [SourceID: AlignmentSource]
    let authorized: Set<SourceID>
    let registered: [SourceID: String]

    init(sources: [AlignmentSource], authorizations: [ContentWorkAuthorization], registered: [SourceID: String]) {
        var locations: [SourceID: AlignmentSource] = [:]
        for source in sources where locations[source.id] == nil { locations[source.id] = source }
        self.locations = locations
        authorized = Set(authorizations.map(\.source))
        self.registered = registered
    }

    /// Metadata-only inspection planning: a registered ON source may participate in the structural plan,
    /// but no content authorization value is created and callers still cannot run a decode with this value.
    init(metadataPlanning sources: [AlignmentSource], registered: [SourceID: String]) {
        var locations: [SourceID: AlignmentSource] = [:]
        for source in sources where locations[source.id] == nil { locations[source.id] = source }
        self.locations = locations
        authorized = Set(sources.filter { $0.availability == .on }.map(\.id))
        // Inspection needs only the structural plan. A private sentinel makes ON locations eligible for
        // planning without registering a source revision or creating a content-work authorization.
        self.registered = Dictionary(
            uniqueKeysWithValues: locations.values
                .filter { $0.availability == .on }
                .map { ($0.id, registered[$0.id] ?? "metadata-planning-only") }
        )
    }

    func check(_ id: SourceID) -> SourceIneligibility? {
        guard let location = locations[id] else { return .locationUnknown }
        guard location.availability == .on else { return .availabilityOff }
        guard authorized.contains(id) else { return .notAuthorized }
        guard registered[id] != nil else { return .notRegistered }
        return nil
    }

    /// The location and revision of an eligible source; `nil` for every ineligible one.
    func admitted(_ id: SourceID) -> (source: AlignmentSource, token: String)? {
        guard check(id) == nil, let location = locations[id], let token = registered[id] else { return nil }
        return (location, token)
    }
}

extension Episode {
    /// The (group, epoch) a source is placed in, or why it has none. `nil` for an ungrouped source.
    func alignmentPlacement(of record: SourceRecord) -> Result<(RecorderGroupID, RecordingEpochID), UnplacedReason>? {
        guard let groupID = record.placement.recorderGroupID else { return nil }
        guard let group = recorderGroup(groupID) else { return .failure(.groupMissing) }
        if let epochID = record.placement.epochID {
            return group.epochs.contains(where: { $0.id == epochID }) ? .success((groupID, epochID)) : .failure(.epochMissing)
        }
        if group.epochs.count == 1 { return .success((groupID, group.epochs[0].id)) }
        return .failure(.epochNotStated)
    }
}

enum AlignmentPlanner {
    static func plan(
        episode: Episode,
        eligibility: ContentEligibility,
        preferredReference: SourceID?,
        priorReference: SourceID?
    ) -> AlignmentPlan {
        var placed: [RecordingEpochID: [SourceID]] = [:]
        var ineligible: [SourceID: SourceIneligibility] = [:]
        var unplaced: [SourceID: UnplacedReason] = [:]
        var placementOf: [SourceID: (RecorderGroupID, RecordingEpochID)] = [:]
        for record in episode.sources {
            guard let placement = episode.alignmentPlacement(of: record) else { continue }
            switch placement {
            case .failure(let reason):
                unplaced[record.id] = reason
            case .success(let (group, epoch)):
                placed[epoch, default: []].append(record.id)
                placementOf[record.id] = (group, epoch)
                if let reason = eligibility.check(record.id) { ineligible[record.id] = reason }
            }
        }

        func referenceCandidate(_ source: SourceID?) -> AlignmentReferenceChoice? {
            guard let source, ineligible[source] == nil, let (group, epoch) = placementOf[source] else { return nil }
            return AlignmentReferenceChoice(group: group, epoch: epoch, source: source)
        }
        var reference = referenceCandidate(preferredReference) ?? referenceCandidate(priorReference)
        if reference == nil {
            search: for group in episode.recorderGroups {
                for epoch in group.epochs {
                    if let first = placed[epoch.id]?.first(where: { ineligible[$0] == nil }) {
                        reference = AlignmentReferenceChoice(group: group.id, epoch: epoch.id, source: first)
                        break search
                    }
                }
            }
        }

        var epochs: [PlannedEpoch] = []
        for group in episode.recorderGroups {
            for epoch in group.epochs {
                let sources = placed[epoch.id] ?? []
                let eligible = sources.filter { ineligible[$0] == nil }
                let disposition: PlannedDisposition
                // An epoch whose sources are all ineligible says so first: its remedy is in Setup.
                if let reference, reference.epoch == epoch.id {
                    disposition = .reference
                } else if sources.isEmpty {
                    disposition = .notAttempted(.noSources)
                } else if eligible.isEmpty {
                    disposition = .notAttempted(.noEligibleSource)
                } else if reference == nil {
                    disposition = .notAttempted(.noReference)
                } else if reference?.group == group.id {
                    disposition = .notAttempted(.sameRecorderAsReference)
                } else {
                    disposition = .analyse(target: eligible[0])
                }
                epochs.append(PlannedEpoch(group: group.id, epoch: epoch.id, sources: sources, eligibleSources: eligible, disposition: disposition))
            }
        }
        return AlignmentPlan(episode: episode.id, reference: reference, epochs: epochs, ineligible: ineligible, unplaced: unplaced)
    }
}
