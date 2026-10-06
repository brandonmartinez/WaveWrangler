import Foundation
import WWAlignEstimate
import WWCore
import WWDecode
import WWDerived
import WWTimeMap

// The engineering states WW-022's Alignment panel renders (docs/m2/design/alignment-inspection-spec.md §1.1
// U1–U9 and §1.2 blocked rows). Wording is the UI's; this layer only says which row applies, why, and which
// remedies are offered. No state is ever "Supported" (U2): nothing here can create a clock approval.

/// A user action the inspection spec offers for a state.
public enum AlignmentRemedy: String, Sendable, Hashable, CaseIterable {
    case acceptAsManual
    case reject
    case editNumerically
    case placeAnchors
    case audition
    /// Only after the accepted map holds `manual(.acceptedAcousticProposal)` and a current proposal exists.
    case revertToProposal
    case goToSetup
    case retryAnalysis
}

/// Why a source feeding alignment cannot be read (§1.2). Each case means no acoustic evidence exists for it.
public enum SourceBlock: Sendable, Equatable {
    /// "Can't read this file": the format is unsupported or the content is damaged. Every action disabled.
    case cannotDecode(DecodeFailure)
    /// Availability must be resolved in Setup (missing, permission, not materialised, residency, OFF, no
    /// consent). Alignment never duplicates the Setup remedy.
    case needsSetup(SetupCause)
    /// "Can't read this file … Try again, or resolve it in Setup."
    case readFailed(AlignmentWorkFailure)

    public enum SetupCause: Sendable, Equatable {
        case decode(DecodeFailure)
        case ineligible(SourceIneligibility)
    }

    static func classify(_ failure: DecodeFailure) -> SourceBlock {
        switch failure {
        case .unsupported:
            return .cannotDecode(failure)
        case .notFound, .permissionDenied, .notMaterialized, .residencyUnknown:
            return .needsSetup(.decode(failure))
        default:
            return failure.isContentDamage ? .cannotDecode(failure) : .readFailed(.decode(failure))
        }
    }

    var remedies: [AlignmentRemedy] {
        switch self {
        case .cannotDecode: []
        case .needsSetup: [.goToSetup]
        case .readFailed: [.retryAnalysis, .goToSetup]
        }
    }
}

/// Why an epoch is unsupported (U8) or disconnected (U7), beyond the `UnsupportedReason` itself.
public enum UnsupportedCause: Sendable, Equatable {
    /// The plan did not analyse it (no reference, same recorder as the reference, no eligible source …).
    case notAttempted(NotAttemptedReason)
    /// Analysis has not produced a current result yet (never run, running, or its inputs changed).
    case analysisPending
    /// The estimator abstained; the record holds the full evidence.
    case abstained(AbstentionReason, detail: String)
    /// The accepted map itself marks the epoch unsupported.
    case acceptedMap(revision: Int)
    /// Analysis failed for a reason that is not a source read problem.
    case analysisFailed(AlignmentWorkFailure)
}

/// One epoch's engineering state.
public enum EpochAlignmentStatus: Sendable, Equatable {
    /// U1: the timeline reference epoch.
    case reference
    /// U3: a current acoustic-consistency proposal, not yet accepted. Never a clock correction.
    case proposed(ProposalRecord)
    /// U3, from the accepted map: a persisted map carries an unaccepted acoustic proposal for this epoch.
    case proposedInAcceptedMap(revision: Int)
    /// U4: set by the person (numeric entry, anchors or an accepted proposal).
    case manual(ManualCorrection.Basis, revision: Int)
    /// U5.
    case externalEvidence(ExternalClockEvidence.Kind, revision: Int)
    /// U7.
    case disconnected(UnsupportedCause)
    /// U8.
    case unsupported(WWTimeMap.UnsupportedReason, UnsupportedCause)
    /// A persisted map claims a clock approval. No holdout-qualified evaluator exists in this build, so it is
    /// never shown as Supported (U2 is unreachable); the person must re-time the epoch.
    case clockApprovalRefused(revision: Int)
    /// §1.2: a source of this epoch cannot be read, so it has no acoustic evidence.
    case sourceBlocked(SourceID, SourceBlock)
}

public struct EpochAlignmentState: Sendable, Equatable {
    public let group: RecorderGroupID
    public let epoch: RecordingEpochID
    public let status: EpochAlignmentStatus
    public let remedies: [AlignmentRemedy]
    /// The current analysis record (proposal or abstention evidence), if one exists for this epoch.
    public let analysis: EpochAnalysisRecord?
}

enum AlignmentStateResolver {
    /// - Parameters:
    ///   - acceptedMap: the episode's accepted map and revision, if any (and still applicable).
    ///   - analyses: CURRENT analysis records only (the caller drops stale ones).
    ///   - failures: per-epoch analysis failures and per-source probe failures of the latest run.
    static func resolve(
        plan: AlignmentPlan,
        acceptedMap: (map: AlignedTimelineMap, revision: Int)?,
        analyses: [RecordingEpochID: EpochAnalysisRecord],
        epochFailures: [RecordingEpochID: AlignmentWorkFailure],
        sourceFailures: [SourceID: AlignmentWorkFailure]
    ) -> [EpochAlignmentState] {
        var mappings: [RecordingEpochID: EpochClockMap.Mapping] = [:]
        if let acceptedMap {
            for group in acceptedMap.map.groups {
                for epoch in group.epochs { mappings[epoch.epoch] = epoch.mapping }
            }
        }
        return plan.epochs.map { planned in
            let record = analyses[planned.epoch]
            let status = status(
                planned, plan: plan, mapping: mappings[planned.epoch], revision: acceptedMap?.revision,
                record: record, failure: epochFailures[planned.epoch], sourceFailures: sourceFailures
            )
            let hasProposal = record?.proposal != nil
            return EpochAlignmentState(
                group: planned.group, epoch: planned.epoch, status: status,
                remedies: remedies(for: status, currentProposal: hasProposal), analysis: record
            )
        }
    }

    private static func status(
        _ planned: PlannedEpoch,
        plan: AlignmentPlan,
        mapping: EpochClockMap.Mapping?,
        revision: Int?,
        record: EpochAnalysisRecord?,
        failure: AlignmentWorkFailure?,
        sourceFailures: [SourceID: AlignmentWorkFailure]
    ) -> EpochAlignmentStatus {
        if case .reference = planned.disposition { return .reference }
        // 1. The accepted map is the person's decision of record (a rejected proposal stays U8).
        if let revision, let mapping {
            switch mapping {
            case let .mapped(_, provenance):
                switch provenance {
                case .timelineReference: return .reference
                case .clockApproved: return .clockApprovalRefused(revision: revision)
                case .acousticConsistentProposal: return .proposedInAcceptedMap(revision: revision)
                case let .manual(correction): return .manual(correction.basis, revision: revision)
                case let .externalEvidence(evidence): return .externalEvidence(evidence.kind, revision: revision)
                }
            case let .unsupported(reason):
                return reason == .disconnected ? .disconnected(.acceptedMap(revision: revision)) : .unsupported(reason, .acceptedMap(revision: revision))
            }
        }
        // 2. A current analysis record.
        if let record {
            if let proposal = record.proposal { return .proposed(proposal) }
            if let abstention = record.abstention, let reason = abstention.abstentionReason {
                let cause = UnsupportedCause.abstained(reason, detail: abstention.detail)
                return reason.unsupportedReason == .disconnected ? .disconnected(cause) : .unsupported(reason.unsupportedReason, cause)
            }
        }
        // 3. A source of this epoch (or the reference) could not be read.
        let involved = involvedSources(planned, plan: plan)
        for source in involved {
            if let failure = sourceFailures[source], let block = block(for: failure) { return .sourceBlocked(source, block) }
        }
        if let failure {
            if let block = block(for: failure), let source = involved.first { return .sourceBlocked(source, block) }
            return .unsupported(.notAttempted, .analysisFailed(failure))
        }
        // 4. The plan.
        if case let .notAttempted(reason) = planned.disposition {
            if reason == .noEligibleSource, let source = planned.sources.first, let ineligibility = plan.ineligible[source] {
                return .sourceBlocked(source, .needsSetup(.ineligible(ineligibility)))
            }
            return .unsupported(.notAttempted, .notAttempted(reason))
        }
        return .unsupported(.notAttempted, .analysisPending)
    }

    private static func involvedSources(_ planned: PlannedEpoch, plan: AlignmentPlan) -> [SourceID] {
        guard case let .analyse(target) = planned.disposition else { return [] }
        return [plan.reference?.source, target].compactMap { $0 }
    }

    /// Source read problems become blocked rows; everything else (estimator, budget, encoding …) does not.
    private static func block(for failure: AlignmentWorkFailure) -> SourceBlock? {
        switch failure {
        case let .decode(decode): SourceBlock.classify(decode)
        case .sourceChangedSinceRegistration, .sourceFactsMismatch, .formatRevisionMismatch: .readFailed(failure)
        case let .sourceRateBelowAnalysisMinimum(rate, _): .cannotDecode(.unsupported(.sampleRate(Double(rate))))
        default: nil
        }
    }

    static func remedies(for status: EpochAlignmentStatus, currentProposal: Bool) -> [AlignmentRemedy] {
        switch status {
        case .reference: []
        case .proposed: [.acceptAsManual, .reject, .editNumerically, .placeAnchors, .audition]
        case .proposedInAcceptedMap: (currentProposal ? [.acceptAsManual] : []) + [.reject, .editNumerically, .placeAnchors, .audition]
        case let .manual(basis, _):
            [.editNumerically, .placeAnchors, .audition] + (basis == .acceptedAcousticProposal && currentProposal ? [.revertToProposal] : [])
        case .externalEvidence: [.editNumerically, .audition]
        case .unsupported(_, .analysisPending), .unsupported(_, .analysisFailed): [.retryAnalysis, .editNumerically, .placeAnchors]
        // A proposal measured since the map left (or set) this epoch unsupported can still be accepted.
        case .unsupported(_, .acceptedMap), .disconnected(.acceptedMap): (currentProposal ? [.acceptAsManual] : []) + [.editNumerically, .placeAnchors]
        case .disconnected, .unsupported: [.editNumerically, .placeAnchors]
        case .clockApprovalRefused: [.editNumerically, .placeAnchors]
        case let .sourceBlocked(_, block): block.remedies
        }
    }
}
