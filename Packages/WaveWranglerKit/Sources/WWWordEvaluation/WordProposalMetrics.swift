import Foundation

/// Disjoint truth strata, assigned before inference by the protocol's priority rule.
public enum EvaluationStratum: String, CaseIterable, Hashable, Sendable {
    case shortClean, longClean, noise, overlap, meaningfulToken
}

public struct ReferenceWord: Sendable {
    public let id: String
    public let occurrenceID: String
    public let text: String
    public let stratum: EvaluationStratum
    public let startMilliseconds: Double
    public let endMilliseconds: Double

    public init(id: String, occurrenceID: String, text: String, stratum: EvaluationStratum,
                startMilliseconds: Double, endMilliseconds: Double) {
        self.id = id
        self.occurrenceID = occurrenceID
        self.text = text
        self.stratum = stratum
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}

/// Only an independently validated boundary may be marked supported. Raw engine timestamps,
/// recognition confidence, and inferred/interpolated times must be marked unsupported.
public enum BoundaryObservation: Sendable {
    case supported(milliseconds: Double)
    case unsupported
    case missing
}

public struct ObservedWord: Sendable {
    public let id: String
    public let matchedReferenceID: String?
    public let occurrenceID: String
    public let stratum: EvaluationStratum
    public let text: String
    public let start: BoundaryObservation
    public let end: BoundaryObservation

    public init(id: String, matchedReferenceID: String?, occurrenceID: String, stratum: EvaluationStratum, text: String,
                start: BoundaryObservation, end: BoundaryObservation) {
        self.id = id
        self.matchedReferenceID = matchedReferenceID
        self.occurrenceID = occurrenceID
        self.stratum = stratum
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A truth target is independently annotated as safe to suggest, NOT safe to cut.
public struct ReferenceProposal: Sendable {
    public let id: String
    public let stratum: EvaluationStratum
    public let wordIDs: [String]
    public init(id: String, stratum: EvaluationStratum, wordIDs: [String]) {
        self.id = id
        self.stratum = stratum
        self.wordIDs = wordIDs
    }
}

/// Every emitted proposal is scored, even when its boundary is unsupported or its target is unknown.
/// An abstention is a separate non-proposal outcome; it is never counted as a correct proposal.
public struct ObservedProposal: Sendable {
    public let id: String
    public let targetID: String?
    public let stratum: EvaluationStratum
    public let wordIDs: [String]
    public init(id: String, targetID: String?, stratum: EvaluationStratum, wordIDs: [String]) {
        self.id = id
        self.targetID = targetID
        self.stratum = stratum
        self.wordIDs = wordIDs
    }
}

public struct StratumMetrics: Sendable {
    public let referenceBoundaries: Int
    public let supportedMatches: Int
    public let omitted: Int
    public let unsupported: Int
    public let hallucinated: Int
    public let p95AbsoluteErrorMilliseconds: Double?
    public let maximumAbsoluteErrorMilliseconds: Double?
    public var coverage: Double? {
        referenceBoundaries == 0 ? nil : Double(supportedMatches) / Double(referenceBoundaries)
    }
}

public struct ProposalMetrics: Sendable {
    public let emitted: Int
    public let truePositives: Int
    public let falsePositives: Int
    public let unsupported: Int
    public let abstentions: Int
    public let referenceTargets: Int
    public let byStratum: [EvaluationStratum: (emitted: Int, truePositives: Int, unsupported: Int)]
    public var precision: Double? { emitted == 0 ? nil : Double(truePositives) / Double(emitted) }
    public var recall: Double? { referenceTargets == 0 ? nil : Double(truePositives) / Double(referenceTargets) }
    /// One-sided 95% Wilson lower confidence bound (z = 1.6448536269514722).
    public var wilsonLower95: Double? {
        guard let precision else { return nil }
        let z = 1.6448536269514722
        let n = Double(emitted)
        return (precision + z * z / (2 * n) - z * sqrt(precision * (1 - precision) / n + z * z / (4 * n * n)))
            / (1 + z * z / n)
    }
}

public struct WordProposalReport: Sendable {
    public let timing: [EvaluationStratum: StratumMetrics]
    public let overallTiming: StratumMetrics
    public let proposals: ProposalMetrics
    public var p95AbsoluteErrorMilliseconds: Double? { overallTiming.p95AbsoluteErrorMilliseconds }
    public var maximumAbsoluteErrorMilliseconds: Double? { overallTiming.maximumAbsoluteErrorMilliseconds }
    /// Numeric screening only; NEVER grants cut acceptance or establishes actual-media qualification.
    public var meetsNumericalThresholds: Bool {
        return overallTiming.referenceBoundaries >= 1_000
            && (overallTiming.coverage ?? 0) >= 0.95
            && EvaluationStratum.allCases.allSatisfy { stratum in
                guard let score = timing[stratum] else { return false }
                return score.referenceBoundaries >= 100 && (score.coverage ?? 0) >= 0.90
            }
            && (p95AbsoluteErrorMilliseconds ?? .infinity) <= 100
            && proposals.emitted >= 300 && proposals.unsupported == 0
            && EvaluationStratum.allCases.allSatisfy { (proposals.byStratum[$0]?.emitted ?? 0) >= 40 }
            && (proposals.precision ?? 0) >= 0.98 && (proposals.wilsonLower95 ?? 0) >= 0.95
    }
}

public enum EvaluationError: Error, Equatable {
    case invalidReference
    case duplicateIdentifier
    case invalidObservation
    case invalidProposal
}

public enum WordProposalScorer {
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
    }

    /// Nearest-rank p95 of supported, independently matched boundaries; nil for no support.
    public static func p95(_ errors: [Double]) -> Double? {
        guard !errors.isEmpty else { return nil }
        let ordered = errors.sorted()
        return ordered[Int(ceil(0.95 * Double(ordered.count))) - 1]
    }

    public static func score(words references: [ReferenceWord], observations: [ObservedWord],
                             targets: [ReferenceProposal], proposals: [ObservedProposal],
                             abstentions: Int) throws -> WordProposalReport {
        guard abstentions >= 0 else { throw EvaluationError.invalidProposal }
        var referenceByID: [String: ReferenceWord] = [:]
        var ordinalByID: [String: Int] = [:]
        var lastReferenceStart: [String: Double] = [:]
        var referencesByOccurrenceCount: [String: Int] = [:]
        for word in references {
            guard !word.id.isEmpty, !word.occurrenceID.isEmpty, !Self.normalized(word.text).isEmpty,
                  word.startMilliseconds.isFinite, word.endMilliseconds.isFinite,
                  word.startMilliseconds >= 0, word.endMilliseconds > word.startMilliseconds
            else { throw EvaluationError.invalidReference }
            guard referenceByID[word.id] == nil else { throw EvaluationError.duplicateIdentifier }
            if let previous = lastReferenceStart[word.occurrenceID], word.startMilliseconds < previous {
                throw EvaluationError.invalidReference
            }
            lastReferenceStart[word.occurrenceID] = word.startMilliseconds
            ordinalByID[word.id] = referencesByOccurrenceCount[word.occurrenceID, default: 0]
            referencesByOccurrenceCount[word.occurrenceID, default: 0] += 1
            referenceByID[word.id] = word
        }
        var observationIDs = Set<String>()
        var claimedReferenceIDs = Set<String>()
        var matched: [String: ObservedWord] = [:]
        var validObservedIDs = Set<String>()
        var hallucinations: [EvaluationStratum: Int] = [:]
        var lastObservedOrdinal: [String: Int] = [:]
        for word in observations {
            guard !word.id.isEmpty, !word.occurrenceID.isEmpty, !Self.normalized(word.text).isEmpty
            else { throw EvaluationError.invalidObservation }
            guard observationIDs.insert(word.id).inserted else { throw EvaluationError.duplicateIdentifier }
            for boundary in [word.start, word.end] {
                if case .supported(let ms) = boundary {
                    guard ms.isFinite, ms >= 0 else { throw EvaluationError.invalidObservation }
                }
            }
            if case .supported(let start) = word.start, case .supported(let end) = word.end, end <= start {
                throw EvaluationError.invalidObservation
            }
            guard let id = word.matchedReferenceID else {
                hallucinations[word.stratum, default: 0] += 1
                continue
            }
            guard claimedReferenceIDs.insert(id).inserted else { throw EvaluationError.duplicateIdentifier }
            guard let reference = referenceByID[id] else {
                hallucinations[word.stratum, default: 0] += 1
                continue
            }
            guard reference.occurrenceID == word.occurrenceID,
                  reference.stratum == word.stratum,
                  Self.normalized(reference.text) == Self.normalized(word.text) else {
                hallucinations[word.stratum, default: 0] += 1
                continue
            }
            guard let ordinal = ordinalByID[id],
                  ordinal > lastObservedOrdinal[word.occurrenceID, default: -1] else {
                throw EvaluationError.invalidObservation
            }
            lastObservedOrdinal[word.occurrenceID] = ordinal
            matched[id] = word
            if case .supported = word.start, case .supported = word.end { validObservedIDs.insert(word.id) }
        }
        var timing: [EvaluationStratum: StratumMetrics] = [:]
        var allErrors: [Double] = []
        for stratum in EvaluationStratum.allCases {
            var errors: [Double] = []
            var omitted = 0, unsupported = 0
            for reference in references where reference.stratum == stratum {
                for (truth, boundary) in [
                    (reference.startMilliseconds, matched[reference.id]?.start),
                    (reference.endMilliseconds, matched[reference.id]?.end),
                ] {
                    switch boundary {
                    case .supported(let ms)?: errors.append(abs(ms - truth))
                    case .unsupported?: unsupported += 1
                    case .missing?, nil: omitted += 1
                    }
                }
            }
            allErrors += errors
            timing[stratum] = StratumMetrics(referenceBoundaries: references.filter { $0.stratum == stratum }.count * 2,
                                              supportedMatches: errors.count, omitted: omitted, unsupported: unsupported,
                                              hallucinated: hallucinations[stratum, default: 0],
                                              p95AbsoluteErrorMilliseconds: p95(errors),
                                              maximumAbsoluteErrorMilliseconds: errors.max())
        }
        var truth: [String: ReferenceProposal] = [:]
        var targetSequences = Set<[String]>()
        for target in targets {
            let ordinals = target.wordIDs.compactMap { ordinalByID[$0] }
            guard !target.id.isEmpty, !target.wordIDs.isEmpty,
                  Set(target.wordIDs).count == target.wordIDs.count,
                  ordinals.count == target.wordIDs.count,
                  zip(ordinals, ordinals.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
                  target.wordIDs.allSatisfy({ referenceByID[$0]?.stratum == target.stratum }),
                  Set(target.wordIDs.compactMap { referenceByID[$0]?.occurrenceID }).count == 1
            else { throw EvaluationError.invalidReference }
            guard truth.updateValue(target, forKey: target.id) == nil else { throw EvaluationError.duplicateIdentifier }
            guard targetSequences.insert(target.wordIDs).inserted else { throw EvaluationError.duplicateIdentifier }
        }
        let observedByID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        var proposalIDs = Set<String>(), credited = Set<String>()
        var correct = 0, unsupported = 0
        var strata: [EvaluationStratum: (emitted: Int, truePositives: Int, unsupported: Int)] = [:]
        for proposal in proposals {
            guard !proposal.id.isEmpty else { throw EvaluationError.invalidProposal }
            guard proposalIDs.insert(proposal.id).inserted else { throw EvaluationError.duplicateIdentifier }
            var count = strata[proposal.stratum, default: (0, 0, 0)]
            count.emitted += 1
            let supported = !proposal.wordIDs.isEmpty
                && Set(proposal.wordIDs).count == proposal.wordIDs.count
                && proposal.wordIDs.allSatisfy { validObservedIDs.contains($0) && observedByID[$0]?.stratum == proposal.stratum }
                && Set(proposal.wordIDs.compactMap { observedByID[$0]?.occurrenceID }).count == 1
            if !supported {
                unsupported += 1
                count.unsupported += 1
            }
            if supported, let targetID = proposal.targetID, let target = truth[targetID],
               target.stratum == proposal.stratum,
               proposal.wordIDs.compactMap({ observedByID[$0]?.matchedReferenceID }) == target.wordIDs,
               credited.insert(targetID).inserted {
                correct += 1
                count.truePositives += 1
            }
            strata[proposal.stratum] = count
        }
        let scored = ProposalMetrics(emitted: proposals.count, truePositives: correct,
                                     falsePositives: proposals.count - correct, unsupported: unsupported,
                                     abstentions: abstentions, referenceTargets: targets.count, byStratum: strata)
        let overall = StratumMetrics(
            referenceBoundaries: references.count * 2, supportedMatches: allErrors.count,
            omitted: timing.values.reduce(0) { $0 + $1.omitted },
            unsupported: timing.values.reduce(0) { $0 + $1.unsupported },
            hallucinated: timing.values.reduce(0) { $0 + $1.hallucinated },
            p95AbsoluteErrorMilliseconds: p95(allErrors), maximumAbsoluteErrorMilliseconds: allErrors.max())
        return WordProposalReport(timing: timing, overallTiming: overall, proposals: scored)
    }
}
