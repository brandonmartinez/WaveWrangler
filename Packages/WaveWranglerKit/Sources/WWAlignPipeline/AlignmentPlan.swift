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

/// One explicitly assigned speaker channel on each of two different recorder groups. The reference
/// epoch must already be supported in the shared timeline (or be its original reference epoch).
public struct SpeakerMatchOption: Sendable, Hashable {
    public let speaker: SpeakerID
    public let reference: AlignmentReferenceChoice
    public let referenceChannel: Int
    public let target: SourceID
    public let targetChannel: Int
    public let targetEpoch: RecordingEpochID
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
    /// Analyze `target` (the epoch's first eligible source) against the reference.
    case analyze(target: SourceID)
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

/// Which epochs are analyzed against which reference, decided from metadata only.
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
    static func speakerMatches(
        episode: Episode, plan: AlignmentPlan, accepted: AlignedTimelineMap?, targetEpoch: RecordingEpochID,
        replacingReference: Bool = false, channelCounts: [SourceID: Int]? = nil
    ) -> [SpeakerMatchOption] {
        guard let target = plan.epoch(targetEpoch), target.group != plan.reference?.group else { return [] }
        let available = Set(plan.eligiblePlacedSources)
        var result: [SpeakerMatchOption] = []
        for assignment in episode.speakerAssignments {
            let channels = ([assignment.primary].compactMap { $0 } + assignment.backups)
                .filter { available.contains($0.sourceID) }
                .compactMap { reference -> ChannelReference? in
                    let count = channelCounts == nil
                        ? episode.source(reference.sourceID)?.observations.channelCount.value
                        : channelCounts?[reference.sourceID]
                    guard let index = reference.resolvedChannel(channelCount: count) else { return nil }
                    return ChannelReference(sourceID: reference.sourceID, statedChannel: index)
                }
            for targetChannel in channels where target.eligibleSources.contains(targetChannel.sourceID) {
                guard let targetIndex = targetChannel.channel.value else { continue }
                for referenceChannel in channels where referenceChannel.sourceID != targetChannel.sourceID {
                    guard replacingReference || episode.alignment?.acceptedMap?.sourceCorrections?
                        .contains(where: { $0.source == referenceChannel.sourceID }) != true else { continue }
                    guard let refIndex = referenceChannel.channel.value,
                          let refEpoch = plan.epochs.first(where: {
                              $0.group != target.group && $0.sources.contains(referenceChannel.sourceID)
                          }) else { continue }
                    let reference = AlignmentReferenceChoice(
                        group: refEpoch.group, epoch: refEpoch.epoch, source: referenceChannel.sourceID
                    )
                    if let accepted {
                        guard let group = accepted.groups.first(where: { $0.group == reference.group }),
                              group.placements.contains(where: {
                                  $0.occurrence.source == reference.source
                                      && $0.spans.contains(where: { $0.epoch == reference.epoch })
                              }),
                              let epoch = group.epochs.first(where: { $0.epoch == reference.epoch }),
                              case .mapped = epoch.mapping
                        else { continue }
                    } else {
                        guard reference.group == plan.reference?.group,
                              reference.epoch == plan.reference?.epoch else { continue }
                    }
                    result.append(SpeakerMatchOption(
                        speaker: assignment.speakerID, reference: reference,
                        referenceChannel: refIndex, target: targetChannel.sourceID,
                        targetChannel: targetIndex, targetEpoch: targetEpoch
                    ))
                }
            }
        }
        return result.sorted { left, right in
            let leftPreferred = episode.recorderGroup(left.reference.group)?.preferredAlignmentReference == true
            let rightPreferred = episode.recorderGroup(right.reference.group)?.preferredAlignmentReference == true
            if leftPreferred != rightPreferred { return leftPreferred }
            let leftPrimary = left.reference.source == episode.assignment(for: left.speaker)?.primary?.sourceID
            let rightPrimary = right.reference.source == episode.assignment(for: right.speaker)?.primary?.sourceID
            if leftPrimary != rightPrimary { return leftPrimary }
            return false
        }
    }

    static func missingSpeakerMatchDetail(
        episode: Episode, plan: AlignmentPlan, targetEpoch: RecordingEpochID,
        channelCounts: [SourceID: Int]
    ) -> String {
        guard let target = plan.epoch(targetEpoch) else {
            return "This recording segment is no longer available. Run Align Tracks again."
        }
        let assignments = episode.speakerAssignments.filter {
            ([$0.primary].compactMap { $0 } + $0.backups).contains {
                target.sources.contains($0.sourceID)
            }
        }
        guard !assignments.isEmpty else {
            return "Assign the same identified speaker to this recording and a reference recording in Recordings & Speakers, then run Align Tracks again."
        }
        var seen = Set<SourceID>()
        let available = Set(plan.eligiblePlacedSources)
        var unresolved: [String] = []
        for assignment in assignments {
            let channels = [assignment.primary].compactMap { $0 } + assignment.backups
            for reference in channels {
                guard available.contains(reference.sourceID), seen.insert(reference.sourceID).inserted,
                      reference.resolvedChannel(channelCount: channelCounts[reference.sourceID]) == nil else { continue }
                let name = episode.source(reference.sourceID)?.displayNameHint ?? "Recording"
                if let count = channelCounts[reference.sourceID] {
                    let unit = count == 1 ? "channel" : "channels"
                    unresolved.append("\(name) (\(count) \(unit))")
                } else {
                    unresolved.append("\(name) (channel count unavailable)")
                }
            }
        }
        if !unresolved.isEmpty {
            return "Choose the speaker's channel for \(unresolved.joined(separator: ", ")) in Recordings & Speakers, then run Align Tracks again. Verified mono files use their only channel automatically; multichannel files require a choice."
        }
        return "This speaker has no eligible recording with timing in the selected reference timeline. Check recording access in Recordings & Speakers. If another recorder connects this speaker to the reference, accept that recorder's timing first, then run Align Tracks again."
    }

    static func plan(
        episode: Episode,
        eligibility: ContentEligibility,
        preferredReference: SourceID?,
        priorReference: SourceID?,
        preferredRecorderGroup: RecorderGroupID? = nil
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
        var reference = referenceCandidate(preferredReference)
        if let preferredRecorderGroup {
            let prior = referenceCandidate(priorReference)
            reference = [reference, prior].compactMap { $0 }.first { $0.group == preferredRecorderGroup }
                ?? episode.sources.lazy
                    .filter { $0.placement.recorderGroupID == preferredRecorderGroup }
                    .compactMap { referenceCandidate($0.id) }.first
        } else if reference == nil {
            reference = referenceCandidate(priorReference)
        }
        if reference == nil, preferredRecorderGroup == nil {
            for group in episode.recorderGroups where group.preferredAlignmentReference == true {
                if let source = episode.sources.first(where: {
                    $0.placement.recorderGroupID == group.id && referenceCandidate($0.id) != nil
                }) {
                    reference = referenceCandidate(source.id)
                    break
                }
            }
        }
        if reference == nil, preferredRecorderGroup == nil {
            for assignment in episode.speakerAssignments {
                if let candidate = referenceCandidate(assignment.primary?.sourceID) {
                    reference = candidate
                    break
                }
            }
        }
        if reference == nil, preferredRecorderGroup == nil {
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
                    disposition = .analyze(target: eligible[0])
                }
                epochs.append(PlannedEpoch(group: group.id, epoch: epoch.id, sources: sources, eligibleSources: eligible, disposition: disposition))
            }
        }
        return AlignmentPlan(episode: episode.id, reference: reference, epochs: epochs, ineligible: ineligible, unplaced: unplaced)
    }
}
