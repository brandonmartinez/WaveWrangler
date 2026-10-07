import Foundation
import Testing
import WWAlignEstimate
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Multi-recorder cycle, restart and gap outcomes")
struct CycleTests {
    static func groups(
        first: Signal = .scene(seed: TwoRecorder.seed, rate: 1.0001, offset: 1.25),
        second: Signal = .scene(seed: TwoRecorder.seed, rate: 0.99995, offset: -0.5)
    ) -> [GroupSpec] {
        [
            GroupSpec(name: "Reference", sources: [SourceSpec(name: "ref", seconds: 30, signal: .scene(seed: TwoRecorder.seed))]),
            GroupSpec(name: "Field A", sources: [SourceSpec(name: "a", seconds: 24, signal: first)]),
            GroupSpec(name: "Field B", sources: [SourceSpec(name: "b", seconds: 24, signal: second)]),
        ]
    }

    @Test("Three recorders close a measured cycle, persist peer revisions and support proposals")
    func consistent() async throws {
        let fixture = try await PipelineFixture(Self.groups(), label: "cycle-consistent")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)
        for epoch in fixture.epochs.dropFirst() {
            let record = try #require(report.records[epoch])
            #expect(record.proposal != nil)
            #expect(record.cycleTriangles > 0)
            #expect((record.cycleMaximumMilliseconds ?? .infinity) < 2)
            #expect(record.coverage.eligibleCount >= 5)
            #expect(record.medianPeakScore > 0)
            let result = try #require(report.analyses[epoch])
            #expect(Set(result.key.sources.map(\.source)) == Set(["ref", "a", "b"].map(fixture.id)))
            #expect(try EpochAnalysisRecord.decode(try #require(fixture.store.payload(for: result.key))) == record)
            #expect(await fixture.states(report)[epoch]?.status.proposal != nil)
        }
    }

    @Test("Injected peer-pair offset conflicts with both reference fits; both epochs abstain with manual remedies")
    func conflicting() async throws {
        let seed = TwoRecorder.seed
        let groups = Self.groups(
            first: .dualScene(seed: seed, secondSeed: 771, rate: 1.0001, offset: 1.25, secondDelay: 0),
            second: .dualScene(seed: seed, secondSeed: 771, rate: 0.99995, offset: -0.5, secondDelay: 0.02)
        )
        let fixture = try await PipelineFixture(groups, label: "cycle-conflict")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)
        for epoch in fixture.epochs.dropFirst() {
            let record = try #require(report.records[epoch])
            #expect(record.proposal == nil)
            #expect(record.abstention?.abstentionReason == .cycleInconsistent)
            #expect(record.flags.contains(EstimateFlag.cycleInconsistent.rawValue))
            #expect(record.cycleTriangles > 0)
            #expect((record.cycleMaximumMilliseconds ?? 0) > 2)
            let state = try #require(await fixture.states(report)[epoch])
            #expect(state.remedies == [.editNumerically, .placeAnchors])
            #expect(state.status.proposal == nil)
        }
        let accepted = try await fixture.pipeline.accept(
            model: fixture.model, episode: fixture.episodeID, report: report,
            decisions: [fixture.epochs[1]: .unmapped, fixture.epochs[2]: .unmapped]
        )
        for epoch in fixture.epochs.dropFirst() {
            let mapping = accepted.map.groups.flatMap(\.epochs).first { $0.epoch == epoch }?.mapping
            #expect(mapping == .unsupported(.estimatorAbstained))
        }
    }

    @Test("A weak third recorder cannot leave an unverified cycle presented as supported")
    func weakPeer() async throws {
        let fixture = try await PipelineFixture(
            Self.groups(second: .scene(seed: 13)), label: "cycle-weak"
        )
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)
        let first = try #require(report.records[fixture.epochs[1]])
        #expect(first.cycleTriangles == 0)
        #expect(first.proposal == nil)
        #expect(first.abstention?.abstentionReason == .insufficientCoverage)
        let weak = try #require(report.records[fixture.epochs[2]])
        #expect(weak.proposal == nil)
        #expect(weak.abstention?.abstentionReason == .weak)
    }

    @Test("A failed third-recorder probe blocks the planned cycle rather than estimating two recorders")
    func missingPeerProbe() async throws {
        let fixture = try await PipelineFixture(Self.groups(), label: "cycle-missing-probe")
        try fixture.rewrite("b")
        let report = try await fixture.analyse(preferredReference: "ref")
        let missing = fixture.id("b")
        #expect(report.sourceFailures[missing] == .sourceChangedSinceRegistration)
        #expect(report.records[fixture.epochs[1]] == nil)
        #expect(report.analyses[fixture.epochs[1]] == nil)
        #expect(report.epochFailures[fixture.epochs[1]] == .cyclePeerUnavailable(missing))
        let state = try #require(await fixture.states(report)[fixture.epochs[1]])
        #expect(state.status == .sourceBlocked(missing, .readFailed(.sourceChangedSinceRegistration)))
        #expect(state.remedies == [.retryAnalysis, .goToSetup])
        let accepted = try await fixture.pipeline.accept(
            model: fixture.model, episode: fixture.episodeID, report: report, decisions: [:]
        )
        #expect(AcceptanceTests.provenances(accepted.map)[fixture.epochs[1]] == nil)
    }

    @Test("Three targets decode each peer excerpt once per analysis run")
    func peerExcerptsAreLinear() async throws {
        var specs = Self.groups()
        specs.append(GroupSpec(name: "Field C", sources: [
            SourceSpec(name: "c", seconds: 24, signal: .scene(seed: TwoRecorder.seed, rate: 1.00002, offset: 0.3))
        ]))
        let fixture = try await PipelineFixture(specs, label: "cycle-peer-cache")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)
        #expect(fixture.content.total.opens == 12, "4 probes + 3 reference decodes + 3 targets + 2 one-time peer excerpts")
        #expect(fixture.content.record(fixture.url("a")).opens == 2, "first target provides its own peer excerpt")
        for name in ["b", "c"] {
            #expect(fixture.content.record(fixture.url(name)).opens == 3, "probe + target + one peer excerpt: \(name)")
        }
        #expect(fixture.content.total.readsOnMainThread == 0)
    }

    @Test("Declared recorder restart is flagged; a further in-recording step remains unsupported")
    func restarted() async throws {
        var groups = Self.groups(first: .scene(seed: TwoRecorder.seed, rate: 1.0001, offset: 1.25, stepAt: 12, stepBy: 0.4))
        groups[1].sources.append(SourceSpec(name: "a-restart", seconds: 24, signal: .scene(seed: TwoRecorder.seed, rate: 1.0001, offset: 1.65)))
        let fixture = try await PipelineFixture(groups, label: "cycle-restart")
        let newEpoch = try fixture.moveToNewEpoch("a-restart")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)
        let original = try #require(report.records[fixture.epochs[1]])
        let restarted = try #require(report.records[newEpoch])
        #expect(original.flags.contains(EstimateFlag.restartedEpoch.rawValue))
        #expect(restarted.flags.contains(EstimateFlag.restartedEpoch.rawValue))
        #expect(original.proposal == nil)
        #expect(original.abstention?.abstentionReason == .discontinuous)
        #expect(await fixture.states(report)[fixture.epochs[1]]?.remedies == [.editNumerically, .placeAnchors])
        #expect(restarted.proposal != nil)
    }

    @Test("An internal coverage gap is explicit, unsupported and has no inverse")
    func gap() async throws {
        let fixture = try await PipelineFixture(
            Self.groups(first: .gap(seed: TwoRecorder.seed, rate: 1.0001, offset: 1.25, start: 10, end: 15)),
            label: "cycle-gap"
        )
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.epochFailures.isEmpty)
        let epoch = fixture.epochs[1]
        let record = try #require(report.records[epoch])
        #expect(record.flags.contains(EstimateFlag.coverageGap.rawValue))
        #expect(record.proposal == nil)
        #expect(record.abstention?.abstentionReason == .discontinuous)
        #expect(record.abstention?.detail.contains("Internal coverage gap") == true)
        let state = try #require(await fixture.states(report)[epoch])
        #expect(state.remedies == [.editNumerically, .placeAnchors])
        let accepted = try await fixture.pipeline.accept(
            model: fixture.model, episode: fixture.episodeID, report: report, decisions: [epoch: .unmapped]
        )
        let mapping = try #require(accepted.map.groups.flatMap(\.epochs).first { $0.epoch == epoch }?.mapping)
        guard case .unsupported = mapping else {
            Issue.record("gap must not have a mapped segment or inverse")
            return
        }
        let group = try #require(accepted.map.group(containing: alignmentOccurrenceID(for: fixture.id("a"))))
        let inverse = try group.sourceFrame(at: ExactRational(12), in: alignmentOccurrenceID(for: fixture.id("a")))
        guard case .unsupported = inverse else {
            Issue.record("the gap must have no supported inverse, got \(inverse)")
            return
        }
    }
}
