import Foundation
import Testing
import WWAlignEstimate
import WWCore
@testable import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

/// One synthetic way for the estimator (or the pipeline) to decline to propose.
struct AbstentionCase: Sendable, CustomTestStringConvertible {
    let name: String
    let reason: AbstentionReason
    let groups: [GroupSpec]
    var configuration = PipelineFixture.smallConfiguration
    /// The pipeline decided without running the estimator (and so without decoding any sample).
    var decidedWithoutDecode = false

    var testDescription: String { name }

    static let all: [AbstentionCase] = {
        let seed = TwoRecorder.seed
        var periodic = TwoRecorder.groups(targetSignal: .sine(hz: 440))
        periodic[0].sources[0].signal = .sine(hz: 440)
        var ambiguous = TwoRecorder.groups()
        ambiguous[0].sources[0].signal = .echo(seed: seed, delay: 1.2)
        return [
            AbstentionCase(name: "silent target", reason: .silent, groups: TwoRecorder.groups(targetSignal: .silence)),
            AbstentionCase(name: "periodic content", reason: .periodic, groups: periodic),
            AbstentionCase(name: "unrelated content", reason: .weak, groups: TwoRecorder.groups(targetSignal: .scene(seed: 77))),
            AbstentionCase(name: "reference heard twice (echo)", reason: .ambiguous, groups: ambiguous),
            AbstentionCase(
                name: "offset step mid-excerpt", reason: .discontinuous,
                groups: TwoRecorder.groups(targetSignal: .scene(seed: seed, rate: TwoRecorder.rate, offset: TwoRecorder.offset, stepAt: 12, stepBy: 0.4))
            ),
            AbstentionCase(name: "reference ends before most of the excerpt", reason: .disconnected, groups: TwoRecorder.groups(referenceSeconds: 8)),
            AbstentionCase(
                name: "search range cannot reach the reference", reason: .insufficientCoverage, groups: TwoRecorder.groups(),
                configuration: AlignmentPipelineConfiguration(concurrency: 2, targetExcerptSeconds: 20, searchDeviationSeconds: 3, searchCenterSeconds: -100, renderSegmentSeconds: 2),
                decidedWithoutDecode: true
            ),
        ]
    }()
}

@Suite("Abstentions surface as WW-014 states with remedies, stored with full evidence")
struct AbstentionTests {
    @Test(arguments: AbstentionCase.all)
    func abstains(_ scenario: AbstentionCase) async throws {
        let fixture = try await PipelineFixture(scenario.groups, configuration: scenario.configuration, label: "abstain")
        let (ref, tgt) = (fixture.id("ref"), fixture.id("tgt"))
        let targetEpoch = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)

        // Stored as a derived result under the full key, with its evidence.
        let analysis = try #require(report.analyses[targetEpoch])
        #expect(analysis.outcome == .published(analysis.key))
        let record = try #require(report.records[targetEpoch])
        #expect(try EpochAnalysisRecord.decode(try #require(fixture.store.payload(for: analysis.key))) == record)
        #expect(record.proposal == nil)
        #expect(record.abstention?.abstentionReason == scenario.reason)
        #expect(record.abstention?.detail.isEmpty == false)
        #expect(record.reference.source == ref && record.target.source == tgt)
        #expect(record.estimator == AlignmentAssetKinds.estimatorIdentifier)
        #expect(record.searchDeviationSeconds == Double(scenario.configuration.searchDeviationSeconds))
        if scenario.decidedWithoutDecode {
            #expect(record.windows.isEmpty)
            #expect(fixture.content.total.reads == 0, "no sample may be decoded when the search cannot reach the reference")
        } else {
            #expect(!record.windows.isEmpty)
            #expect(record.coverage.windowCount == record.windows.count)
            #expect(fixture.content.record(fixture.url("tgt")).reads > 0)
        }

        // The state the inspection UI shows, with its remedies (never a proposal).
        let state = try #require(await fixture.states(report)[targetEpoch])
        let cause = UnsupportedCause.abstained(scenario.reason, detail: record.abstention?.detail ?? "")
        let expected: EpochAlignmentStatus = scenario.reason.unsupportedReason == .disconnected
            ? .disconnected(cause)
            : .unsupported(scenario.reason.unsupportedReason, cause)
        #expect(state.status == expected)
        #expect(state.remedies == [.editNumerically, .placeAnchors])
        #expect(state.status.proposal == nil)

        // Nothing to accept; leaving it unmapped records the abstention's reason in the map.
        await #expect(throws: AlignmentAcceptanceError.noCurrentProposal(targetEpoch)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .acceptProposal()])
        }
        let unmapped = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .unmapped])
        let mapping = unmapped.map.groups.flatMap(\.epochs).first { $0.epoch == targetEpoch }?.mapping
        #expect(mapping == .unsupported(scenario.reason.unsupportedReason))
    }
}
