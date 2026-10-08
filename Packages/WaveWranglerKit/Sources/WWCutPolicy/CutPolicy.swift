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
    public let lanes: [LaneRevision]

    public init(primary: SourceOccurrence, primaryAuthorization: PrimaryAuthorization,
                sourceRevision: String, modelRevision: String,
                transcriptRevision: String, correctionRevision: String, alignmentRevision: String,
                assetRevision: String, formatRevision: String, protectionRevision: String,
                outputRecipeRevision: String, otherCutsRevision: String, lanes: [LaneRevision]) {
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
        self.lanes = lanes
    }

    public var hasCompleteIdentity: Bool {
        primary.channel >= 0 && !primary.source.isEmpty &&
        !primary.occurrence.isEmpty && !primary.epoch.isEmpty &&
        [sourceRevision, modelRevision, transcriptRevision, correctionRevision,
         alignmentRevision, assetRevision, formatRevision, protectionRevision,
         outputRecipeRevision, otherCutsRevision].allSatisfy { !$0.isEmpty } &&
        lanes.allSatisfy { lane in
            !lane.id.isEmpty && !lane.backingRevision.isEmpty && !lane.mapRevision.isEmpty &&
            !lane.protectionRevision.isEmpty &&
            (lane.origin.map { !$0.source.isEmpty && !$0.occurrence.isEmpty &&
                !$0.epoch.isEmpty && $0.channel >= 0 } ?? true)
        }
    }
}

public enum PrimaryAuthorization: Sendable, Equatable {
    case authorizedSelectedPrimary
    case notAuthorized
}

public struct LaneRevision: Sendable, Equatable {
    public let id: String
    public let origin: SourceOccurrence?
    public let backingRevision: String
    public let mapRevision: String
    public let protectionRevision: String

    public init(id: String, origin: SourceOccurrence?, backingRevision: String,
                mapRevision: String, protectionRevision: String) {
        self.id = id
        self.origin = origin
        self.backingRevision = backingRevision
        self.mapRevision = mapRevision
        self.protectionRevision = protectionRevision
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
    public let grid: FrameSpan
    public let outputRate: Int64
    public let effect: CutEffect
    public let lanes: [LaneFootprint]

    public init(key: EvidenceKey, grid: FrameSpan, outputRate: Int64,
                effect: CutEffect, lanes: [LaneFootprint]) {
        self.key = key
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

public enum ProtectionProof: Sendable, Equatable {
    case complete([FrameSpan])
    case unknown
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
               protection: ProtectionProof, backed: Bool,
               fadeOutOutputFrames: Int64, fadeInOutputFrames: Int64,
               endpointErrorOutputFrames: Int64)
    case intentionalSilence(id: String, gridCoverage: FrameSpan)
    case unsupported(id: String)

    public var id: String {
        switch self {
        case let .audio(id, _, _, _, _, _, _, _, _, _), let .intentionalSilence(id, _),
             let .unsupported(id): id
        }
    }
}

public struct ApprovedCut: Sendable, Equatable {
    public let request: CutRequest
    public let footprint: CutFootprint
    public let key: EvidenceKey
}

public enum CutPolicy {
    public static func admit(
        _ proposal: CutProposal, request: CutRequest, currentKey: EvidenceKey,
        affectedLanes: [LaneRevision], mapping: any CutFootprintMapping
    ) throws -> ApprovedCut {
        guard proposal.key == currentKey else { throw CutRefusal.staleEvidence }
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
        guard proof.key == currentKey else { throw CutRefusal.staleEvidence }
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
        guard Set(affectedLanes.map(\.id)).count == affectedLanes.count else {
            throw CutRefusal.incompleteLanes
        }
        let expected = Dictionary(uniqueKeysWithValues: affectedLanes.map { ($0.id, $0) })
        guard !expected.isEmpty, affectedLanes == currentKey.lanes,
              Set(proof.lanes.map(\.id)) == Set(expected.keys),
              proof.lanes.count == affectedLanes.count else { throw CutRefusal.incompleteLanes }
        guard affectedLanes.contains(where: { $0.origin == currentKey.primary }) else {
            throw CutRefusal.incompleteLanes
        }

        for lane in proof.lanes {
            guard let expectedLane = expected[lane.id] else { throw CutRefusal.incompleteLanes }
            switch lane {
            case let .unsupported(id):
                throw CutRefusal.uninspectableLane(id)
            case let .intentionalSilence(id, gridCoverage):
                guard expectedLane.origin == nil, gridCoverage.contains(proof.grid) else {
                    throw CutRefusal.uninspectableLane(id)
                }
            case let .audio(id, origin, coverage, removal, fades, protection, backed, fadeOut, fadeIn, endpointError):
                guard expectedLane.origin == origin, backed, origin.channel >= 0,
                      coverage.contains(removal), endpointError >= 0,
                      endpointError <= 1 else { throw CutRefusal.uninspectableLane(id) }
                if origin == currentKey.primary && removal != request.sourceFrames {
                    throw CutRefusal.uninspectableLane(id)
                }
                guard case let .complete(protected) = protection else {
                    throw CutRefusal.uninspectableLane(id)
                }
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
        return ApprovedCut(request: request, footprint: proof, key: currentKey)
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
    public let actionName: String
    public let before: ReviewEntry
    public let after: ReviewEntry
}

/// Per-proposal history only. The application must publish an accepted cut to
/// WWCommonEdit atomically and invalidate preview/render on every map change.
public struct ReviewJournal: Sendable, Equatable {
    public private(set) var current: ReviewEntry
    public private(set) var transitions: [ReviewTransition] = []
    public private(set) var cursor = 0

    public init(proposal: CutProposal) { current = ReviewEntry(proposal: proposal) }

    public mutating func accept(currentKey: EvidenceKey, affectedLanes: [LaneRevision],
                                mapping: any CutFootprintMapping) throws {
        guard current.decision == .pending || current.decision == .adjusted else {
            throw CutRefusal.invalidTransition
        }
        let cut = try CutPolicy.admit(current.proposal, request: current.request,
                                      currentKey: currentKey, affectedLanes: affectedLanes, mapping: mapping)
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

    public mutating func undo(currentKey: EvidenceKey, affectedLanes: [LaneRevision],
                              mapping: any CutFootprintMapping) throws {
        guard cursor > 0 else { throw CutRefusal.invalidTransition }
        let previous = transitions[cursor - 1].before
        try validateReactivation(previous, currentKey: currentKey, affectedLanes: affectedLanes, mapping: mapping)
        current = previous
        cursor -= 1
    }

    public mutating func redo(currentKey: EvidenceKey, affectedLanes: [LaneRevision],
                              mapping: any CutFootprintMapping) throws {
        guard cursor < transitions.count else { throw CutRefusal.invalidTransition }
        let next = transitions[cursor].after
        try validateReactivation(next, currentKey: currentKey, affectedLanes: affectedLanes, mapping: mapping)
        current = next
        cursor += 1
    }

    private func validateReactivation(_ entry: ReviewEntry, currentKey: EvidenceKey,
                                      affectedLanes: [LaneRevision],
                                      mapping: any CutFootprintMapping) throws {
        guard case let .accepted(previous) = entry.decision else { return }
        let fresh = try CutPolicy.admit(entry.proposal, request: entry.request,
                                        currentKey: currentKey, affectedLanes: affectedLanes, mapping: mapping)
        guard fresh == previous else { throw CutRefusal.staleEvidence }
    }

    private mutating func record(_ name: String, request: CutRequest? = nil,
                                 decision: ReviewDecision) {
        let after = ReviewEntry(proposal: current.proposal, request: request ?? current.request,
                                decision: decision)
        transitions = Array(transitions.prefix(cursor)) +
            [ReviewTransition(actionName: name, before: current, after: after)]
        cursor += 1
        current = after
    }
}
