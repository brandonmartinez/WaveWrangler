import Testing
import WWWordEvaluation

@Suite("WW-027 synthetic scorer calibration")
struct WordProposalMetricsTests {
    private static let strata = EvaluationStratum.allCases

    private static func fixture() -> ([ReferenceWord], [ObservedWord], [ReferenceProposal], [ObservedProposal]) {
        var words: [ReferenceWord] = [], observed: [ObservedWord] = []
        var targets: [ReferenceProposal] = [], proposals: [ObservedProposal] = []
        for (s, stratum) in strata.enumerated() {
            for index in 0..<100 {
                let id = "\(s)-\(index)", start = Double(index * 400)
                words.append(ReferenceWord(id: id, occurrenceID: "occ-\(s)", text: "um,", stratum: stratum,
                                           startMilliseconds: start, endMilliseconds: start + 150))
                observed.append(ObservedWord(id: id, matchedReferenceID: id, occurrenceID: "occ-\(s)",
                                             stratum: stratum, text: "Um", start: .supported(milliseconds: start),
                                             end: .supported(milliseconds: start + 150)))
                if index < 60 {
                    targets.append(ReferenceProposal(id: id, stratum: stratum, wordIDs: [id]))
                    proposals.append(ObservedProposal(id: id, targetID: id, stratum: stratum, wordIDs: [id]))
                }
            }
        }
        return (words, observed, targets, proposals)
    }

    @Test func exactSyntheticFixtureMeetsNumericalScreenOnly() throws {
        let (words, observed, targets, proposals) = Self.fixture()
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: proposals, abstentions: 11)
        #expect(report.meetsNumericalThresholds)
        #expect(report.timing.values.reduce(0) { $0 + $1.referenceBoundaries } == 1_000)
        #expect(report.timing.values.reduce(0) { $0 + $1.supportedMatches } == 1_000)
        #expect(report.overallTiming.referenceBoundaries == 1_000)
        #expect(report.overallTiming.coverage == 1)
        #expect(report.p95AbsoluteErrorMilliseconds == 0)
        #expect(report.proposals.emitted == 300)
        #expect(report.proposals.truePositives == 300)
        #expect(report.proposals.abstentions == 11)
        #expect(report.proposals.recall == 1)
        #expect((report.proposals.wilsonLower95 ?? 0) > 0.95)
    }

    @Test func absentAndUnsupportedBoundariesStayInDenominator() throws {
        let (words, original, targets, proposals) = Self.fixture()
        let observed = original.map { word in
            if word.id == "0-0" {
                return ObservedWord(id: word.id, matchedReferenceID: word.matchedReferenceID,
                                    occurrenceID: word.occurrenceID, stratum: word.stratum, text: word.text,
                                    start: .missing, end: .unsupported)
            }
            return word
        }.filter { $0.id != "0-1" }
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: proposals, abstentions: 0)
        let short = try #require(report.timing[.shortClean])
        #expect(short.referenceBoundaries == 200)
        #expect(short.omitted == 3 && short.unsupported == 1 && short.supportedMatches == 196)
        #expect(short.coverage == 0.98)
        #expect(report.overallTiming.omitted == 3 && report.overallTiming.unsupported == 1)
        #expect(report.proposals.unsupported == 2)
        #expect(report.proposals.falsePositives == 2)
        #expect(report.proposals.byStratum[.shortClean]?.unsupported == 2)
        #expect(!report.meetsNumericalThresholds)
    }

    @Test func nearestRankUsesAllSupportedBoundariesNotStratumPercentiles() throws {
        let (words, original, targets, proposals) = Self.fixture()
        let observed = original.map { word in
            guard word.id.hasPrefix("0-"), let index = Int(word.id.dropFirst(2)), index < 26 else { return word }
            let start = Double(index * 400)
            return ObservedWord(id: word.id, matchedReferenceID: word.matchedReferenceID,
                                occurrenceID: word.occurrenceID, stratum: word.stratum, text: word.text,
                                start: .supported(milliseconds: start + 120),
                                end: .supported(milliseconds: start + 270))
        }
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: proposals, abstentions: 0)
        #expect(WordProposalScorer.p95([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 200]) == 200)
        #expect(report.p95AbsoluteErrorMilliseconds == 120)
        #expect(report.maximumAbsoluteErrorMilliseconds == 120)
        #expect(!report.meetsNumericalThresholds)
    }

    @Test func coverageCannotHideInAggregate() throws {
        let (words, original, targets, proposals) = Self.fixture()
        let observed = original.filter { !$0.id.hasPrefix("2-") || Int($0.id.dropFirst(2))! >= 11 }
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: proposals, abstentions: 0)
        #expect(report.timing[.noise]?.coverage == 0.89)
        #expect(report.timing.values.reduce(0) { $0 + $1.supportedMatches } == 978)
        #expect(!report.meetsNumericalThresholds)
    }

    @Test func allEmittedProposalsCountAndWilsonIsIndependentGate() throws {
        let (words, observed, targets, original) = Self.fixture()
        let proposals = original.map { proposal in
            if ["0-0", "0-1", "0-2", "0-3", "0-4", "0-5", "0-6"].contains(proposal.id) {
                return ObservedProposal(id: proposal.id, targetID: nil, stratum: proposal.stratum,
                                        wordIDs: proposal.wordIDs)
            }
            return proposal
        }
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: proposals, abstentions: 15)
        #expect(report.proposals.emitted == 300 && report.proposals.falsePositives == 7)
        #expect((report.proposals.precision ?? 1) < 0.98)
        #expect(report.proposals.recall == 293.0 / 300)
        #expect(!report.meetsNumericalThresholds)

        let small = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                  proposals: Array(original.prefix(100)), abstentions: 200)
        #expect(small.proposals.precision == 1)
        #expect((small.proposals.wilsonLower95 ?? 0) > 0.95)
        #expect(!small.meetsNumericalThresholds)
    }

    @Test func hallucinationsAndWrongOccurrenceCannotSupportProposal() throws {
        let (words, original, targets, proposals) = Self.fixture()
        let modified = original.map { word in
            guard word.id == "0-0" else { return word }
            return ObservedWord(id: word.id, matchedReferenceID: word.matchedReferenceID,
                                occurrenceID: "different", stratum: word.stratum, text: word.text,
                                start: word.start, end: word.end)
        } + [ObservedWord(id: "extra", matchedReferenceID: nil, occurrenceID: "occ-0",
                          stratum: .shortClean, text: "um", start: .supported(milliseconds: 100),
                          end: .supported(milliseconds: 200))]
        let extra = ObservedProposal(id: "extra", targetID: nil, stratum: .shortClean, wordIDs: ["extra"])
        let report = try WordProposalScorer.score(words: words, observations: modified, targets: targets,
                                                   proposals: proposals + [extra], abstentions: 0)
        #expect(report.timing[.shortClean]?.hallucinated == 2)
        #expect(report.timing[.shortClean]?.omitted == 2)
        #expect(report.proposals.unsupported == 2)
        #expect(report.proposals.falsePositives == 2)
        #expect(!report.meetsNumericalThresholds)
    }

    @Test func duplicateTargetCannotInflatePrecisionOrRecall() throws {
        let (words, observed, targets, original) = Self.fixture()
        let repeated = ObservedProposal(id: "repeat", targetID: "0-0", stratum: .shortClean, wordIDs: ["0-0"])
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: original + [repeated], abstentions: 4)
        #expect(report.proposals.emitted == 301 && report.proposals.truePositives == 300)
        #expect(report.proposals.falsePositives == 1 && report.proposals.recall == 1)
        #expect(report.proposals.abstentions == 4)
    }

    @Test func precisionAndWilsonUseSameEmittedDenominator() throws {
        let (words, observed, targets, original) = Self.fixture()
        let proposals = original.map { proposal in
            if ["0-0", "0-1", "0-2", "0-3", "0-4", "0-5"].contains(proposal.id) {
                return ObservedProposal(id: proposal.id, targetID: nil, stratum: proposal.stratum,
                                        wordIDs: proposal.wordIDs)
            }
            return proposal
        }
        let report = try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                                   proposals: proposals, abstentions: 10)
        #expect(report.proposals.truePositives == 294 && report.proposals.falsePositives == 6)
        #expect(report.proposals.precision == 0.98)
        #expect((report.proposals.wilsonLower95 ?? 0) >= 0.95)
        #expect(report.meetsNumericalThresholds)
    }

    @Test func reversedWordOrderCannotReceiveTimingCredit() throws {
        let (words, original, targets, proposals) = Self.fixture()
        var observed = original
        observed.swapAt(0, 1)
        #expect(throws: EvaluationError.invalidObservation) {
            try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                         proposals: proposals, abstentions: 0)
        }
    }

    @Test func invalidTruthAndObservationsFailExplicitly() throws {
        let (words, observed, targets, proposals) = Self.fixture()
        #expect(throws: EvaluationError.duplicateIdentifier) {
            try WordProposalScorer.score(words: words + [words[0]], observations: observed, targets: targets,
                                         proposals: proposals, abstentions: 0)
        }
        let broken = ObservedWord(id: "broken", matchedReferenceID: "0-0", occurrenceID: "occ-0",
                                  stratum: .shortClean, text: "um", start: .supported(milliseconds: .nan),
                                  end: .supported(milliseconds: 100))
        #expect(throws: EvaluationError.invalidObservation) {
            try WordProposalScorer.score(words: words, observations: observed + [broken], targets: targets,
                                         proposals: proposals, abstentions: 0)
        }
        #expect(throws: EvaluationError.invalidProposal) {
            try WordProposalScorer.score(words: words, observations: observed, targets: targets,
                                         proposals: proposals, abstentions: -1)
        }
        #expect(throws: EvaluationError.invalidReference) {
            let extra = ReferenceWord(id: "second", occurrenceID: "other-occurrence", text: "um",
                                      stratum: .shortClean, startMilliseconds: 0, endMilliseconds: 150)
            try WordProposalScorer.score(
                words: words + [extra], observations: observed,
                targets: targets + [ReferenceProposal(id: "cross-occurrence", stratum: .shortClean,
                                                      wordIDs: ["0-0", "second"])],
                proposals: proposals, abstentions: 0)
        }
    }
}
