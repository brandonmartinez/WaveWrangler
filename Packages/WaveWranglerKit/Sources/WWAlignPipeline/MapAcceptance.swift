import Foundation
import WWAlignEstimate
import WWCore
import WWDerived
import WWTimeMap

/// One anchor of a manual map: a time in the epoch's source (seconds from the occurrence's first frame) and
/// the aligned time the person says it belongs at.
public struct AlignmentAnchor: Sendable, Hashable {
    public var sourceSeconds: Double
    public var alignedSeconds: Double

    public init(sourceSeconds: Double, alignedSeconds: Double) {
        self.sourceSeconds = sourceSeconds
        self.alignedSeconds = alignedSeconds
    }
}

/// What the person decided for one epoch. There is deliberately no way to pass a `MapProvenance`: this layer
/// chooses provenance itself and can only ever produce `.timelineReference` (the reference epoch),
/// `.manual(...)` (a decided epoch) or the estimator's own `.acousticConsistentProposal` (an undecided epoch
/// with a current proposal). A clock approval cannot be created, forwarded or faked through it.
public enum EpochMapDecision: Sendable, Hashable {
    /// Accept the epoch's current acoustic proposal. Recorded as `manual(.acceptedAcousticProposal)`: human
    /// acceptance of a proposal is not a clock correction.
    case acceptProposal(note: String = "")
    /// Rate correction in ppm (quantised to 1 ppb) and offset in milliseconds (quantised to 1 ns).
    case numeric(ppm: Double, offsetMilliseconds: Double, note: String = "")
    /// At least two anchors; fitted by least squares, quantised like numeric entry.
    case anchors([AlignmentAnchor], note: String = "")
    /// Leave the epoch unsupported (rejecting any proposal).
    case unmapped
}

public enum AlignmentAcceptanceError: Error, Sendable, Equatable {
    case episodeNotFound(EpisodeID)
    case noReference
    /// The reference (or a decided epoch's sources) has no probed facts; analyse it first.
    case referenceFactsUnavailable(SourceID)
    case unknownEpoch(RecordingEpochID)
    /// The reference epoch is the identity by definition; it takes no decision.
    case decisionForReferenceEpoch(RecordingEpochID)
    case noCurrentProposal(RecordingEpochID)
    /// The proposal was measured against a different reference or a different revision of its sources.
    case proposalNotCurrent(RecordingEpochID)
    case invalidNumericEntry(RecordingEpochID, String)
    case insufficientAnchors(RecordingEpochID)
    case invalidAnchors(RecordingEpochID, String)
    /// No source of the epoch has probed facts, so nothing can be placed under the map.
    case noPlaceableSource(RecordingEpochID)
    /// The accepted map claims a clock approval for this epoch. It is never carried forward; decide the
    /// epoch explicitly to replace it.
    case priorMapHasClockApproval(RecordingEpochID)
    case priorMapUnreadable(MapHistoryError)
    case invalidMap(String)
    case history(MapHistoryError)
    case coordinatorShutDown
}

/// The result of accepting a map: the new document value (persist it), the new accepted revision and map.
public struct AcceptedAlignment: Sendable {
    public let model: ShowDocumentModel
    public let revision: MapRevisionReference
    public let map: AlignedTimelineMap
}

enum MapAcceptance {
    static let nanosecond: Int64 = 1_000_000_000

    struct Built {
        let map: AlignedTimelineMap
        let inputs: [TimeMapSourceInput]
    }

    /// Builds the full aligned map from the plan, probed facts, current analysis records, the person's
    /// decisions and (for undecided epochs) the prior accepted map. Pure.
    static func build(
        plan: AlignmentPlan,
        facts: [SourceID: SourceFacts],
        analyses: [RecordingEpochID: EpochAnalysisRecord],
        decisions: [RecordingEpochID: EpochMapDecision],
        prior: AlignedTimelineMap?
    ) throws(AlignmentAcceptanceError) -> Built {
        guard let reference = plan.reference else { throw .noReference }
        guard facts[reference.source] != nil else { throw .referenceFactsUnavailable(reference.source) }
        for epoch in decisions.keys {
            guard plan.epoch(epoch) != nil else { throw .unknownEpoch(epoch) }
            if epoch == reference.epoch { throw .decisionForReferenceEpoch(epoch) }
            if case .acceptProposal = decisions[epoch], analyses[epoch]?.proposal == nil { throw .noCurrentProposal(epoch) }
        }
        let timelineReference = TimelineReference(group: reference.group, epoch: reference.epoch, occurrence: reference.occurrence)
        var priorMappings: [RecordingEpochID: EpochClockMap.Mapping] = [:]
        if let prior, prior.reference == timelineReference {
            for group in prior.groups {
                for epoch in group.epochs { priorMappings[epoch.epoch] = epoch.mapping }
            }
        }

        var groupOrder: [RecorderGroupID] = []
        var epochsByGroup: [RecorderGroupID: [PlannedEpoch]] = [:]
        for planned in plan.epochs {
            if epochsByGroup[planned.group] == nil { groupOrder.append(planned.group) }
            epochsByGroup[planned.group, default: []].append(planned)
        }

        var groups: [GroupTimeMap] = []
        var inputs: [TimeMapSourceInput] = []
        for groupID in groupOrder {
            let planned = epochsByGroup[groupID] ?? []
            var placements: [OccurrencePlacement] = []
            var epochEnd: [RecordingEpochID: ExactRational] = [:]
            for epoch in planned {
                for source in epoch.sources {
                    guard let sourceFacts = facts[source] else { continue }
                    let placement = try placement(source, facts: sourceFacts, epoch: epoch.epoch)
                    placements.append(placement)
                    inputs.append(TimeMapSourceInput(sourceID: source, formatInterpretationVersion: sourceFacts.formatInterpretationVersion))
                    let end = try exact(sourceFacts.frameCount, Int64(sourceFacts.sampleRate))
                    if let current = epochEnd[epoch.epoch], current >= end { continue }
                    epochEnd[epoch.epoch] = end
                }
            }
            guard !placements.isEmpty else {
                for epoch in planned where decisions[epoch.epoch] != nil { throw .noPlaceableSource(epoch.epoch) }
                continue
            }
            var epochMaps: [EpochClockMap] = []
            for epoch in planned {
                let mapping = try mapping(
                    for: epoch.epoch, reference: reference, end: epochEnd[epoch.epoch],
                    decision: decisions[epoch.epoch], analysis: analyses[epoch.epoch], facts: facts,
                    prior: priorMappings[epoch.epoch]
                )
                epochMaps.append(EpochClockMap(epoch: epoch.epoch, mapping: mapping))
            }
            do throws(TimeMapError) {
                groups.append(try GroupTimeMap(group: groupID, reference: timelineReference, epochs: epochMaps, placements: placements))
            } catch {
                throw .invalidMap(String(describing: error))
            }
        }
        do throws(TimeMapError) {
            return Built(map: try AlignedTimelineMap(reference: timelineReference, groups: groups), inputs: inputs)
        } catch {
            throw .invalidMap(String(describing: error))
        }
    }

    private static func placement(_ source: SourceID, facts: SourceFacts, epoch: RecordingEpochID) throws(AlignmentAcceptanceError) -> OccurrencePlacement {
        do throws(TimeMapError) {
            let occurrence = try SourceOccurrence(
                id: alignmentOccurrenceID(for: source), source: source,
                nominalRate: NominalRate(Int64(facts.sampleRate)), frameCount: facts.frameCount
            )
            return OccurrencePlacement(occurrence: occurrence, spans: [EpochSpan(startFrame: 0, endFrame: facts.frameCount, epoch: epoch, groupClockOffset: .zero)])
        } catch {
            throw .invalidMap(String(describing: error))
        }
    }

    private static func mapping(
        for epoch: RecordingEpochID,
        reference: AlignmentReferenceChoice,
        end: ExactRational?,
        decision: EpochMapDecision?,
        analysis: EpochAnalysisRecord?,
        facts: [SourceID: SourceFacts],
        prior: EpochClockMap.Mapping?
    ) throws(AlignmentAcceptanceError) -> EpochClockMap.Mapping {
        if epoch == reference.epoch {
            guard let end else { throw .referenceFactsUnavailable(reference.source) }
            return .mapped(segments: [try segment(end: end, rate: .one, offset: .zero)], provenance: .timelineReference)
        }
        guard let decision else {
            if let prior {
                if case let .mapped(_, provenance) = prior, provenance.kind.isClockApproved {
                    throw .priorMapHasClockApproval(epoch)
                }
                return prior
            }
            // Undecided with a current proposal: persisted as the unaccepted proposal it is (U3), so
            // accepting another epoch never silently rejects this one.
            if let analysis, let proposal = analysis.proposal, let end,
               isCurrent(analysis, epoch: epoch, reference: reference, facts: facts),
               let segment = try? segment(end: end, rate: proposal.segment.rateRatio, offset: proposal.segment.alignedOffset) {
                return .mapped(segments: [segment], provenance: .acousticConsistentProposal(proposal.provenance))
            }
            return .unsupported(analysis?.abstention?.abstentionReason?.unsupportedReason ?? .notAttempted)
        }
        let rate: ExactRational
        let offset: ExactRational
        let basis: ManualCorrection.Basis
        let note: String
        switch decision {
        case .unmapped:
            // Reject: back to U8. A rejected proposal records `notAttempted`; an abstention keeps its reason.
            return .unsupported(analysis?.abstention?.abstentionReason?.unsupportedReason ?? .notAttempted)
        case let .acceptProposal(text):
            guard let analysis, let proposal = analysis.proposal else { throw .noCurrentProposal(epoch) }
            guard isCurrent(analysis, epoch: epoch, reference: reference, facts: facts) else { throw .proposalNotCurrent(epoch) }
            rate = proposal.segment.rateRatio
            offset = proposal.segment.alignedOffset
            basis = .acceptedAcousticProposal
            note = text
        case let .numeric(ppm, offsetMilliseconds, text):
            (rate, offset) = try numeric(epoch, ppm: ppm, offsetSeconds: offsetMilliseconds / 1000)
            basis = .numericEntry
            note = text
        case let .anchors(anchors, text):
            (rate, offset) = try fit(epoch, anchors: anchors)
            basis = .anchors
            note = text
        }
        guard let end else { throw .noPlaceableSource(epoch) }
        let segment: AffineClockSegment
        do throws(AlignmentAcceptanceError) {
            segment = try Self.segment(end: end, rate: rate, offset: offset)
        } catch {
            if case .invalidMap(let detail) = error, decision != .unmapped {
                if case .anchors = decision { throw .invalidAnchors(epoch, detail) }
                throw .invalidNumericEntry(epoch, detail)
            }
            throw error
        }
        return .mapped(segments: [segment], provenance: .manual(ManualCorrection(basis: basis, note: note)))
    }

    /// The record was measured against this reference and the sources' current revisions.
    private static func isCurrent(_ analysis: EpochAnalysisRecord, epoch: RecordingEpochID, reference: AlignmentReferenceChoice, facts: [SourceID: SourceFacts]) -> Bool {
        analysis.reference.source == reference.source && analysis.reference.epoch == reference.epoch
            && analysis.reference.group == reference.group && analysis.target.epoch == epoch
            && facts[analysis.reference.source]?.revisionToken == analysis.reference.revisionToken
            && facts[analysis.target.source]?.revisionToken == analysis.target.revisionToken
    }

    /// One segment over the whole placed span `[0, end)` (every source of the epoch starts at group-clock 0).
    private static func segment(end: ExactRational, rate: ExactRational, offset: ExactRational) throws(AlignmentAcceptanceError) -> AffineClockSegment {
        do throws(TimeMapError) {
            return try AffineClockSegment(groupClockStart: .zero, groupClockEnd: end, rateRatio: rate, alignedOffset: offset)
        } catch {
            throw .invalidMap(String(describing: error))
        }
    }

    private static func exact(_ numerator: Int64, _ denominator: Int64) throws(AlignmentAcceptanceError) -> ExactRational {
        do throws(TimeMapError) {
            return try ExactRational(numerator, denominator)
        } catch {
            throw .invalidMap(String(describing: error))
        }
    }

    /// `a = 1 + ppb/1e9`, `b = ns/1e9`, both rounded half away from zero from the typed values.
    static func numeric(_ epoch: RecordingEpochID, ppm: Double, offsetSeconds: Double) throws(AlignmentAcceptanceError) -> (ExactRational, ExactRational) {
        guard ppm.isFinite, offsetSeconds.isFinite else { throw .invalidNumericEntry(epoch, "values must be finite") }
        let ppb = (ppm * 1000).rounded()
        let ns = (offsetSeconds * 1e9).rounded()
        // The rate envelope is [1/2, 2] (|ppm| <= 1e6) and times are bounded by 2^31 s.
        guard abs(ppb) <= 1e9 else { throw .invalidNumericEntry(epoch, "rate correction outside ±1,000,000 ppm") }
        guard abs(ns) < 2.1e18 else { throw .invalidNumericEntry(epoch, "offset outside the supported time range") }
        let rate: ExactRational
        let offset: ExactRational
        do throws(TimeMapError) {
            rate = try ExactRational(nanosecond + Int64(ppb), nanosecond)
            offset = try ExactRational(Int64(ns), nanosecond)
        } catch {
            throw .invalidNumericEntry(epoch, String(describing: error))
        }
        guard rate > .zero else { throw .invalidNumericEntry(epoch, "rate must be positive") }
        return (rate, offset)
    }

    /// Least-squares `aligned = a * source + b` through the anchors, then quantised like numeric entry.
    static func fit(_ epoch: RecordingEpochID, anchors: [AlignmentAnchor]) throws(AlignmentAcceptanceError) -> (ExactRational, ExactRational) {
        guard anchors.count >= 2 else { throw .insufficientAnchors(epoch) }
        guard anchors.allSatisfy({ $0.sourceSeconds.isFinite && $0.alignedSeconds.isFinite && $0.sourceSeconds >= 0 }) else {
            throw .invalidAnchors(epoch, "anchor times must be finite and source times non-negative")
        }
        guard Set(anchors.map { ($0.sourceSeconds * 1e9).rounded() }).count == anchors.count else {
            throw .invalidAnchors(epoch, "two anchors share a source time")
        }
        let n = Double(anchors.count)
        let meanU = anchors.reduce(0) { $0 + $1.sourceSeconds } / n
        let meanT = anchors.reduce(0) { $0 + $1.alignedSeconds } / n
        var suu = 0.0
        var sut = 0.0
        for anchor in anchors {
            let du = anchor.sourceSeconds - meanU
            suu += du * du
            sut += du * (anchor.alignedSeconds - meanT)
        }
        guard suu > 0 else { throw .invalidAnchors(epoch, "anchors must span time") }
        let a = sut / suu
        guard a.isFinite, a > 0 else { throw .invalidAnchors(epoch, "the anchors do not describe a forward-running clock") }
        let b = meanT - a * meanU
        do throws(AlignmentAcceptanceError) {
            return try numeric(epoch, ppm: (a - 1) * 1e6, offsetSeconds: b)
        } catch {
            if case let .invalidNumericEntry(_, detail) = error { throw .invalidAnchors(epoch, detail) }
            throw error
        }
    }
}
