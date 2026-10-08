/// All frame ranges are half-open. Source frames and pre-edit aligned output frames
/// are different coordinates; the mapping adapter is the only bridge between them.
public struct FrameSpan: Sendable, Equatable {
    public let start: Int64
    public let end: Int64

    public init(_ start: Int64, _ end: Int64) throws {
        guard start >= 0, end > start else { throw CutRefusal.invalidRange }
        self.start = start
        self.end = end
    }

    public func contains(_ other: FrameSpan) -> Bool {
        start <= other.start && other.end <= end
    }

    public func intersects(_ other: FrameSpan) -> Bool {
        start < other.end && other.start < end
    }
}

public struct SourceOccurrence: Sendable, Hashable {
    public let source: String
    public let channel: Int
    public let occurrence: String
    public let epoch: String

    public init(source: String, channel: Int, occurrence: String, epoch: String) {
        self.source = source
        self.channel = channel
        self.occurrence = occurrence
        self.epoch = epoch
    }
}

/// Captured at analysis time and compared at admission time. No path, media or transcript text is stored.
public struct EvidenceKey: Sendable, Equatable {
    public let primary: SourceOccurrence
    public let primaryAuthorization: PrimaryAuthorization
    public let sourceRevision: String
    public let modelRevision: String
    public let transcriptRevision: String
    public let correctionRevision: String
    public let alignmentRevision: String
    public let assetRevision: String
    public let formatRevision: String
    public let protectionRevision: String
    public let outputRecipeRevision: String
    public let otherCutsRevision: String
    public let laneManifestRevision: String

    public init(primary: SourceOccurrence, primaryAuthorization: PrimaryAuthorization,
                sourceRevision: String, modelRevision: String,
                transcriptRevision: String, correctionRevision: String, alignmentRevision: String,
                assetRevision: String, formatRevision: String, protectionRevision: String,
                outputRecipeRevision: String, otherCutsRevision: String,
                laneManifestRevision: String) {
        self.primary = primary
        self.primaryAuthorization = primaryAuthorization
        self.sourceRevision = sourceRevision
        self.modelRevision = modelRevision
        self.transcriptRevision = transcriptRevision
        self.correctionRevision = correctionRevision
        self.alignmentRevision = alignmentRevision
        self.assetRevision = assetRevision
        self.formatRevision = formatRevision
        self.protectionRevision = protectionRevision
        self.outputRecipeRevision = outputRecipeRevision
        self.otherCutsRevision = otherCutsRevision
        self.laneManifestRevision = laneManifestRevision
    }

    public var hasCompleteIdentity: Bool {
        primary.channel >= 0 && !primary.source.isEmpty &&
        !primary.occurrence.isEmpty && !primary.epoch.isEmpty &&
        [sourceRevision, modelRevision, transcriptRevision, correctionRevision,
         alignmentRevision, assetRevision, formatRevision, protectionRevision,
         outputRecipeRevision, otherCutsRevision, laneManifestRevision].allSatisfy { !$0.isEmpty }
    }
}

public enum PrimaryAuthorization: Sendable, Equatable {
    case authorizedSelectedPrimary
    case notAuthorized
}

public enum LaneKind: Sendable, Equatable {
    case selectedPrimary, backup, otherSpeaker, intentionalSilence
}

public struct LaneRevision: Sendable, Equatable {
    public let id: String
    public let kind: LaneKind
    public let origin: SourceOccurrence?
    public let backingRevision: String
    public let mapRevision: String
    public let protectionRevision: String

    public init(id: String, kind: LaneKind, origin: SourceOccurrence?, backingRevision: String,
                mapRevision: String, protectionRevision: String) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.backingRevision = backingRevision
        self.mapRevision = mapRevision
        self.protectionRevision = protectionRevision
    }
}

/// Only a trusted organizer adapter inside this module may mint the complete episode lane set.
/// A caller's subset of lanes or revision strings cannot certify episode completeness.
public struct EpisodeLaneManifest: Sendable {
    public let revision: String
    public let lanes: [LaneRevision]

    internal init(revision: String, lanes: [LaneRevision]) {
        self.revision = revision
        self.lanes = lanes
    }
}

public struct VerifiedEpisodeState: Sendable {
    public let key: EvidenceKey
    public let manifest: EpisodeLaneManifest

    internal init(key: EvidenceKey, manifest: EpisodeLaneManifest) {
        self.key = key
        self.manifest = manifest
    }
}

public enum WordTiming: Sendable, Equatable {
    case supported(start: Int64, end: Int64)
    case absent
    case unsupported
    case hallucinated
}

public struct CandidateWord: Sendable, Equatable {
    public let tokenID: String
    public let timing: WordTiming

    public init(tokenID: String, timing: WordTiming) {
        self.tokenID = tokenID
        self.timing = timing
    }
}

public enum CandidateContext: Sendable, Equatable {
    case contextualFiller
    case meaningful
    case overlap
    case uncertain
    case transcriptEmpty
}

public enum CutMode: Sendable, Equatable { case shorten, lift }

public struct CutRequest: Sendable, Equatable {
    public let sourceFrames: FrameSpan
    public let mode: CutMode
    public let fadeOutFrames: Int64
    public let fadeInFrames: Int64

    public init(sourceFrames: FrameSpan, mode: CutMode = .shorten,
                fadeOutFrames: Int64 = 0, fadeInFrames: Int64 = 0) {
        self.sourceFrames = sourceFrames
        self.mode = mode
        self.fadeOutFrames = fadeOutFrames
        self.fadeInFrames = fadeInFrames
    }
}

public struct CutProposal: Sendable, Equatable {
    public let id: String
    public let key: EvidenceKey
    public let words: [CandidateWord]
    public let context: CandidateContext
    public let request: CutRequest

    public init(id: String, key: EvidenceKey, words: [CandidateWord],
                context: CandidateContext, request: CutRequest) {
        self.id = id
        self.key = key
        self.words = words
        self.context = context
        self.request = request
    }
}

public enum CutRefusal: Error, Sendable, Equatable {
    case invalidRange
    case invalidIdentity
    case staleEvidence
    case unauthorizedPrimary
    case unsupportedWord
    case notContextualFiller
    case invalidAdjustment
    case invalidGrid
    case incompleteLanes
    case missingLaneAuthority
    case missingHumanReview
    case uninspectableLane(String)
    case protectedFrame(String)
    case unsupportedFade(String)
    case invalidTransition
}

/// Alignment supplies the same pre-edit qStart/qEnd rounded once at output rate R
/// as WWCommonEdit. It must prove every affected lane, not just transcribed primaries.
public protocol CutFootprintMapping {
    func footprint(for request: CutRequest, primary: SourceOccurrence) throws -> CutFootprint
}

public struct CutFootprint: Sendable, Equatable {
    public let key: EvidenceKey
    public let manifestRevision: String
    public let grid: FrameSpan
    public let outputRate: Int64
    public let effect: CutEffect
    public let lanes: [LaneFootprint]

    public init(key: EvidenceKey, manifestRevision: String, grid: FrameSpan, outputRate: Int64,
                effect: CutEffect, lanes: [LaneFootprint]) {
        self.key = key
        self.manifestRevision = manifestRevision
        self.grid = grid
        self.outputRate = outputRate
        self.effect = effect
        self.lanes = lanes
    }
}

public enum CutEffect: Sendable, Equatable {
    case shorten(removedOutputFrames: Int64)
    case lift(reservedOutputFrames: Int64)
}

public struct ProtectionProof: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case verifiedPrimary, verifiedIndependentLane, unknown, overlap
        case backupWithoutIndependentProof, unsupportedBoundary
    }

    public let status: Status
    public let origin: SourceOccurrence?
    public let revision: String?
    public let protected: [FrameSpan]

    private init(_ status: Status, origin: SourceOccurrence? = nil,
                 revision: String? = nil, protected: [FrameSpan] = []) {
        self.status = status
        self.origin = origin
        self.revision = revision
        self.protected = protected
    }

    public static let unknown = Self(.unknown)
    public static let overlap = Self(.overlap)
    public static let backupWithoutIndependentProof = Self(.backupWithoutIndependentProof)
    public static let unsupportedBoundary = Self(.unsupportedBoundary)

    internal static func verifiedPrimary(_ origin: SourceOccurrence, revision: String,
                                         protected: [FrameSpan]) -> Self {
        Self(.verifiedPrimary, origin: origin, revision: revision, protected: protected)
    }

    internal static func verifiedIndependentLane(_ origin: SourceOccurrence, revision: String,
                                                 protected: [FrameSpan]) -> Self {
        Self(.verifiedIndependentLane, origin: origin, revision: revision, protected: protected)
    }
}

public enum BoundarySupport: Sendable, Equatable {
    case supported, unsupported, ambiguousInverse, crossesOccurrenceOrEpoch
}

public struct FadeFootprint: Sendable, Equatable {
    public let fadeOut: FrameSpan?
    public let fadeIn: FrameSpan?
    public let mergedFinal: [FrameSpan]

    public init(fadeOut: FrameSpan? = nil, fadeIn: FrameSpan? = nil,
                mergedFinal: [FrameSpan] = []) {
        self.fadeOut = fadeOut
        self.fadeIn = fadeIn
        self.mergedFinal = mergedFinal
    }
}

/// An audio lane must have independently reviewed COMPLETE protection coverage.
/// Fade spans contain the final merged envelope footprint, including neighboring cuts.
public enum LaneFootprint: Sendable, Equatable {
    case audio(id: String, origin: SourceOccurrence, coverage: FrameSpan,
               removal: FrameSpan, fades: FadeFootprint,
               protection: ProtectionProof, backed: Bool, boundary: BoundarySupport,
               fadeOutOutputFrames: Int64, fadeInOutputFrames: Int64,
               endpointErrorOutputFrames: Int64)
    case intentionalSilence(id: String, gridCoverage: FrameSpan)
    case unsupported(id: String)

    public var id: String {
        switch self {
        case let .audio(id, _, _, _, _, _, _, _, _, _, _), let .intentionalSilence(id, _),
             let .unsupported(id): id
        }
    }
}

public struct ApprovedCut: Sendable, Equatable {
    public let request: CutRequest
    public let footprint: CutFootprint
    public let key: EvidenceKey
    public let review: HumanReviewAction
}

/// Minted only by a future native person-action adapter, not by proposal generation.
public struct HumanReviewAction: Sendable, Equatable {
    public let actionID: String
    public let proposalID: String
    public let request: CutRequest
    public let key: EvidenceKey
    public let manifestRevision: String

    internal init(actionID: String, proposalID: String, request: CutRequest,
                  key: EvidenceKey, manifestRevision: String) {
        self.actionID = actionID
        self.proposalID = proposalID
        self.request = request
        self.key = key
        self.manifestRevision = manifestRevision
    }
}

public enum CutPolicy {
    public static func admit(
        _ proposal: CutProposal, request: CutRequest, current: VerifiedEpisodeState?,
        review: HumanReviewAction?, mapping: any CutFootprintMapping
    ) throws -> ApprovedCut {
        guard let current else { throw CutRefusal.missingLaneAuthority }
        guard let review else { throw CutRefusal.missingHumanReview }
        let currentKey = current.key
        guard proposal.key == currentKey else { throw CutRefusal.staleEvidence }
        guard current.manifest.revision == currentKey.laneManifestRevision,
              !current.manifest.revision.isEmpty else { throw CutRefusal.staleEvidence }
        guard !review.actionID.isEmpty, review.proposalID == proposal.id,
              review.request == request, review.key == currentKey,
              review.manifestRevision == current.manifest.revision else {
            throw CutRefusal.missingHumanReview
        }
        guard !proposal.id.isEmpty, currentKey.hasCompleteIdentity,
              proposal.words.allSatisfy({ !$0.tokenID.isEmpty }) else {
            throw CutRefusal.invalidIdentity
        }
        guard currentKey.primaryAuthorization == .authorizedSelectedPrimary else {
            throw CutRefusal.unauthorizedPrimary
        }
        guard proposal.context == .contextualFiller else { throw CutRefusal.notContextualFiller }
        guard request.fadeOutFrames >= 0, request.fadeInFrames >= 0 else { throw CutRefusal.invalidRange }
        guard supportsWords(proposal) else { throw CutRefusal.unsupportedWord }
        guard proposal.request.sourceFrames.contains(request.sourceFrames) else {
            throw CutRefusal.invalidAdjustment
        }

        let proof = try mapping.footprint(for: request, primary: currentKey.primary)
        guard proof.key == currentKey,
              proof.manifestRevision == current.manifest.revision else {
            throw CutRefusal.staleEvidence
        }
        let duration = proof.grid.end - proof.grid.start
        guard proof.outputRate > 0 else { throw CutRefusal.invalidGrid }
        switch (request.mode, proof.effect) {
        case let (.shorten, .shorten(removed)) where removed == duration:
            break
        case let (.lift, .lift(reserved)) where reserved == duration:
            break
        default:
            throw CutRefusal.invalidGrid
        }
        let affectedLanes = current.manifest.lanes
        guard Set(affectedLanes.map(\.id)).count == affectedLanes.count,
              affectedLanes.allSatisfy({ lane in
                  !lane.id.isEmpty && !lane.backingRevision.isEmpty &&
                  !lane.mapRevision.isEmpty && !lane.protectionRevision.isEmpty &&
                  (lane.origin.map { !$0.source.isEmpty && !$0.occurrence.isEmpty &&
                      !$0.epoch.isEmpty && $0.channel >= 0 } ?? true) &&
                  ((lane.kind == .intentionalSilence) == (lane.origin == nil))
              }),
              affectedLanes.filter({ $0.kind == .selectedPrimary }).count == 1,
              affectedLanes.contains(where: {
                  $0.kind == .selectedPrimary && $0.origin == currentKey.primary
              }),
              !affectedLanes.contains(where: {
                  $0.kind != .selectedPrimary && $0.origin == currentKey.primary
              }) else {
            throw CutRefusal.incompleteLanes
        }
        let expected = Dictionary(uniqueKeysWithValues: affectedLanes.map { ($0.id, $0) })
        guard !expected.isEmpty,
              Set(proof.lanes.map(\.id)) == Set(expected.keys),
              proof.lanes.count == affectedLanes.count else { throw CutRefusal.incompleteLanes }

        for lane in proof.lanes {
            guard let expectedLane = expected[lane.id] else { throw CutRefusal.incompleteLanes }
            switch lane {
            case let .unsupported(id):
                throw CutRefusal.uninspectableLane(id)
            case let .intentionalSilence(id, gridCoverage):
                guard expectedLane.kind == .intentionalSilence,
                      gridCoverage.contains(proof.grid) else {
                    throw CutRefusal.uninspectableLane(id)
                }
            case let .audio(id, origin, coverage, removal, fades, protection, backed, boundary, fadeOut, fadeIn, endpointError):
                guard expectedLane.kind != .intentionalSilence,
                      expectedLane.origin == origin, backed, boundary == .supported,
                      origin.channel >= 0,
                      coverage.contains(removal), endpointError >= 0,
                      endpointError <= 1 else { throw CutRefusal.uninspectableLane(id) }
                if origin == currentKey.primary && removal != request.sourceFrames {
                    throw CutRefusal.uninspectableLane(id)
                }
                let requiredStatus: ProtectionProof.Status =
                    expectedLane.kind == .selectedPrimary ? .verifiedPrimary : .verifiedIndependentLane
                guard protection.status == requiredStatus,
                      protection.origin == origin,
                      protection.revision == expectedLane.protectionRevision else {
                    throw CutRefusal.uninspectableLane(id)
                }
                let protected = protection.protected
                guard protected.allSatisfy({ coverage.contains($0) }) else {
                    throw CutRefusal.uninspectableLane(id)
                }
                guard !protected.contains(where: { $0.intersects(removal) }) else {
                    throw CutRefusal.protectedFrame(id)
                }
                guard fadeOut == request.fadeOutFrames, fadeIn == request.fadeInFrames else {
                    throw CutRefusal.unsupportedFade(id)
                }
                guard (fadeOut > 0) == (fades.fadeOut != nil),
                      (fadeIn > 0) == (fades.fadeIn != nil) else {
                    throw CutRefusal.unsupportedFade(id)
                }
                for requested in [fades.fadeOut, fades.fadeIn].compactMap({ $0 }) {
                    guard fades.mergedFinal.contains(where: { $0.contains(requested) }) else {
                        throw CutRefusal.unsupportedFade(id)
                    }
                }
                for fade in fades.mergedFinal {
                    guard coverage.contains(fade), !fade.intersects(removal) else {
                        throw CutRefusal.unsupportedFade(id)
                    }
                    guard !protected.contains(where: { $0.intersects(fade) }) else {
                        throw CutRefusal.protectedFrame(id)
                    }
                }
            }
        }
        return ApprovedCut(request: request, footprint: proof, key: currentKey, review: review)
    }

    public static func supportsWords(_ proposal: CutProposal) -> Bool {
        guard !proposal.words.isEmpty,
              Set(proposal.words.map(\.tokenID)).count == proposal.words.count else { return false }
        var previousEnd: Int64?
        for word in proposal.words {
            guard case let .supported(start, end) = word.timing,
                  start >= proposal.request.sourceFrames.start,
                  end <= proposal.request.sourceFrames.end, start < end,
                  previousEnd.map({ $0 <= start }) ?? true
            else { return false }
            previousEnd = end
        }
        guard case let .supported(firstStart, _) = proposal.words[0].timing else { return false }
        return firstStart == proposal.request.sourceFrames.start &&
            previousEnd == proposal.request.sourceFrames.end
    }
}

public enum ReviewDecision: Sendable, Equatable {
    case pending
    case adjusted
    case accepted(ApprovedCut)
    case rejected
    case restored(ApprovedCut)
    case abstained
    case blocked(CutRefusal)

    public var activeCut: ApprovedCut? {
        if case let .accepted(cut) = self { return cut }
        return nil
    }
}

public struct ReviewEntry: Sendable, Equatable {
    public let proposal: CutProposal
    public private(set) var request: CutRequest
    public private(set) var decision: ReviewDecision

    public init(proposal: CutProposal) {
        self.proposal = proposal
        self.request = proposal.request
        if proposal.context != .contextualFiller {
            self.decision = .blocked(.notContextualFiller)
        } else if !CutPolicy.supportsWords(proposal) {
            self.decision = .blocked(.unsupportedWord)
        } else {
            self.decision = .pending
        }
    }

    fileprivate init(proposal: CutProposal, request: CutRequest, decision: ReviewDecision) {
        self.proposal = proposal
        self.request = request
        self.decision = decision
    }
}

public struct ReviewTransition: Sendable, Equatable {
    public let id: Int
    public let parentHead: Int?
    public let branchID: Int
    public let actionName: String
    public let before: ReviewEntry
    public let after: ReviewEntry
}

/// Per-proposal history only. The application must publish an accepted cut to
/// WWCommonEdit atomically and invalidate preview/render on every map change.
public struct ReviewJournal: Sendable, Equatable {
    public private(set) var current: ReviewEntry
    public private(set) var transitions: [ReviewTransition] = []
    public private(set) var head: Int?
    public private(set) var branchID = 0
    private var actionPath: [Int] = []
    public private(set) var cursor = 0

    public init(proposal: CutProposal) { current = ReviewEntry(proposal: proposal) }

    public mutating func accept(current state: VerifiedEpisodeState?, review: HumanReviewAction?,
                                mapping: any CutFootprintMapping) throws {
        guard current.decision == .pending || current.decision == .adjusted else {
            throw CutRefusal.invalidTransition
        }
        if let review, transitions.contains(where: { transition in
            if case let .accepted(cut) = transition.after.decision {
                return cut.review.actionID == review.actionID
            }
            return false
        }) {
            throw CutRefusal.missingHumanReview
        }
        let cut = try CutPolicy.admit(current.proposal, request: current.request,
                                      current: state, review: review, mapping: mapping)
        record("Accept \(current.proposal.id)", decision: .accepted(cut))
    }

    public mutating func adjust(_ request: CutRequest) throws {
        guard current.decision == .pending || current.decision == .adjusted else {
            throw CutRefusal.invalidTransition
        }
        guard current.proposal.request.sourceFrames.contains(request.sourceFrames) else {
            throw CutRefusal.invalidAdjustment
        }
        record("Adjust \(current.proposal.id)", request: request, decision: .adjusted)
    }

    public mutating func reject() throws {
        guard current.decision == .pending || current.decision == .adjusted else {
            throw CutRefusal.invalidTransition
        }
        record("Reject \(current.proposal.id)", decision: .rejected)
    }

    public mutating func abstain() throws {
        switch current.decision {
        case .pending, .adjusted, .blocked:
            break
        default:
            throw CutRefusal.invalidTransition
        }
        record("Abstain \(current.proposal.id)", decision: .abstained)
    }

    public mutating func restore() throws {
        guard case let .accepted(cut) = current.decision else { throw CutRefusal.invalidTransition }
        record("Restore \(current.proposal.id)", decision: .restored(cut))
    }

    public mutating func undo(current state: VerifiedEpisodeState?,
                              mapping: any CutFootprintMapping) throws {
        guard cursor > 0 else { throw CutRefusal.invalidTransition }
        let action = transitions[actionPath[cursor - 1]]
        let previous = action.before
        try validateReactivation(previous, current: state, mapping: mapping)
        append("Undo \(action.actionName)", after: previous)
        cursor -= 1
    }

    public mutating func redo(current state: VerifiedEpisodeState?,
                              mapping: any CutFootprintMapping) throws {
        guard cursor < actionPath.count else { throw CutRefusal.invalidTransition }
        let action = transitions[actionPath[cursor]]
        let next = action.after
        try validateReactivation(next, current: state, mapping: mapping)
        append("Redo \(action.actionName)", after: next)
        cursor += 1
    }

    private func validateReactivation(_ entry: ReviewEntry, current state: VerifiedEpisodeState?,
                                      mapping: any CutFootprintMapping) throws {
        guard case let .accepted(previous) = entry.decision else { return }
        let fresh = try CutPolicy.admit(entry.proposal, request: entry.request,
                                        current: state, review: previous.review, mapping: mapping)
        guard fresh == previous else { throw CutRefusal.staleEvidence }
    }

    private mutating func record(_ name: String, request: CutRequest? = nil,
                                 decision: ReviewDecision) {
        let after = ReviewEntry(proposal: current.proposal, request: request ?? current.request,
                                decision: decision)
        if cursor < actionPath.count {
            actionPath = Array(actionPath.prefix(cursor))
            branchID = transitions.count
        }
        let id = transitions.count
        append(name, after: after)
        actionPath.append(id)
        cursor += 1
    }

    private mutating func append(_ name: String, after: ReviewEntry) {
        let id = transitions.count
        transitions.append(ReviewTransition(id: id, parentHead: head, branchID: branchID,
                                            actionName: name, before: current, after: after))
        head = id
        current = after
    }
}
