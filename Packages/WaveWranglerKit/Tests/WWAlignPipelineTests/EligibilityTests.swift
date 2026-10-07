import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

/// Content is read only for sources that are ON, explicitly authorized, located and registered; every other
/// path is metadata only and is proven by the recording gateway (zero opens, zero decoder metadata calls).
@Suite("Consent-gated decode: OFF and other ineligible paths never touch content")
struct EligibilityTests {
    static func ineligibleEpisode() -> [GroupSpec] {
        let seed = TwoRecorder.seed
        let target = Signal.scene(seed: seed, rate: TwoRecorder.rate, offset: TwoRecorder.offset)
        return [
            GroupSpec(name: "Reference", sources: [SourceSpec(name: "ref", seconds: 30, signal: .scene(seed: seed))]),
            GroupSpec(name: "Eligible", sources: [SourceSpec(name: "ok", seconds: 24, signal: target)]),
            GroupSpec(name: "Off", sources: [SourceSpec(name: "off", seconds: 24, signal: target, availability: .off)]),
            GroupSpec(name: "Unauthorized", sources: [SourceSpec(name: "unauthorized", seconds: 24, signal: target, authorized: false)]),
            GroupSpec(name: "Unregistered", sources: [SourceSpec(name: "unregistered", seconds: 24, signal: target, registered: false)]),
            GroupSpec(name: "Unlocated", sources: [SourceSpec(name: "unlocated", seconds: 24, signal: target, located: false)]),
        ]
    }

    @Test("Each ineligible source is planned out, never opened, and shown as a Setup block")
    func ineligibleSourcesAreNeverOpened() async throws {
        let fixture = try await PipelineFixture(Self.ineligibleEpisode(), label: "eligibility")
        let expected: [String: SourceIneligibility] = [
            "off": .availabilityOff, "unauthorized": .notAuthorized, "unregistered": .notRegistered, "unlocated": .locationUnknown,
        ]
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.plan.ineligible == Dictionary(uniqueKeysWithValues: expected.map { (fixture.id($0.key), $0.value) }))
        #expect(Set(report.plan.eligiblePlacedSources) == [fixture.id("ref"), fixture.id("ok")])
        #expect(Set(report.probes.keys) == [fixture.id("ref"), fixture.id("ok")])

        let states = await fixture.states(report)
        for (name, reason) in expected {
            let url = fixture.url(name)
            #expect(fixture.content.record(url).opens == 0, "\(name) was opened")
            #expect(fixture.content.record(url).reads == 0, "\(name) was read")
            #expect(fixture.metadataIO.metadataCalls(url) == 0, "\(name) reached the decoder")
            let epoch = try #require(fixture.epochs[safe: fixture.groupIndex(of: name)])
            let planned = try #require(report.plan.epoch(epoch))
            #expect(planned.disposition == .notAttempted(.noEligibleSource))
            #expect(planned.eligibleSources.isEmpty)
            let state = try #require(states[epoch])
            #expect(state.status == .sourceBlocked(fixture.id(name), .needsSetup(.ineligible(reason))))
            #expect(state.remedies == [.goToSetup])
            #expect(report.analyses[epoch] == nil)
        }
        // Positive control: the eligible target in the same run was analysed.
        #expect(fixture.content.record(fixture.url("ok")).reads > 0)
        #expect(states[fixture.epochs[1]]?.status.proposal != nil)
    }

    @Test("With every source OFF the whole run is metadata only")
    func everySourceOffReadsNothing() async throws {
        var groups = TwoRecorder.groups()
        for g in groups.indices { for s in groups[g].sources.indices { groups[g].sources[s].availability = .off } }
        let fixture = try await PipelineFixture(groups, label: "all-off")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.plan.reference == nil)
        #expect(report.probes.isEmpty && report.analyses.isEmpty && report.records.isEmpty)
        #expect(fixture.content.total.opens == 0)
        #expect(fixture.content.total.reads == 0)
        #expect(fixture.metadataIO.totalMetadataCalls == 0)
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
        for state in await fixture.states(report).values {
            #expect(state.status.proposal == nil)
            if case .sourceBlocked(_, .needsSetup(.ineligible(.availabilityOff))) = state.status {} else {
                Issue.record("expected an OFF Setup block, got \(state.status)")
            }
        }
    }

    @Test("Turning a source OFF before rendering skips its channels without opening it")
    func offAtRenderIsNotOpened() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(referenceSeconds: 6, targetSeconds: 4), label: "off-render")
        let tgt = fixture.id("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: .numeric(ppm: 100, offsetMilliseconds: 1250)])
        let before = fixture.content.record(fixture.url("tgt"))

        let sources = fixture.sources.map { $0.id == tgt ? AlignmentSource(id: tgt, url: $0.url, availability: .off) : $0 }
        let rendered = try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID, sources: sources, authorizations: fixture.authorizations
        )
        #expect(rendered.notRendered == [tgt: .ineligible(.availabilityOff)])
        #expect(fixture.content.record(fixture.url("tgt")) == before, "an OFF source was touched while rendering")
        // The reference group still rendered.
        #expect(rendered.isComplete)
        #expect(try alignedSegments(rendered, store: fixture.store).allSatisfy { $0.key.sources.map(\.source) == [fixture.id("ref")] })
        #expect(fixture.content.record(fixture.url("ref")).reads > 0)

        // Withdrawing consent has the same effect.
        let withdrawn = try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations.filter { $0.source != tgt }
        )
        #expect(withdrawn.notRendered == [tgt: .ineligible(.notAuthorized)])
        #expect(fixture.content.record(fixture.url("tgt")) == before)
    }

    @Test("A source rewritten since registration is refused at the probe and blocks its epoch until re-registered")
    func changedBeforeAnalysis() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "changed-before")
        let tgt = fixture.id("tgt")
        try fixture.rewrite("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.sourceFailures == [tgt: .sourceChangedSinceRegistration])
        #expect(fixture.content.record(fixture.url("tgt")).reads == 0, "a changed source must not be decoded")
        #expect(report.analyses[fixture.epochs[1]] == nil)
        let state = try #require(await fixture.states(report)[fixture.epochs[1]])
        #expect(state.status == .sourceBlocked(tgt, .readFailed(.sourceChangedSinceRegistration)))
        #expect(state.remedies == [.retryAnalysis, .goToSetup])

        // The app re-registers the new revision; the retry analyses it.
        await fixture.coordinator.updateSource(try PipelineFixture.registration(tgt, fixture.url("tgt")))
        let retried = try await fixture.analyse(preferredReference: "ref")
        #expect(retried.sourceFailures.isEmpty)
        #expect(await fixture.states(retried)[fixture.epochs[1]]?.status.proposal != nil)
    }

    @Test("A source that changes after analysis drops its proposal: shown pending, never accepted")
    func changedAfterAnalysis() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "changed-after")
        let tgt = fixture.id("tgt")
        let targetEpoch = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(await fixture.states(report)[targetEpoch]?.status.proposal != nil)

        try fixture.rewrite("tgt")
        await fixture.coordinator.updateSource(try PipelineFixture.registration(tgt, fixture.url("tgt")))
        let state = try #require(await fixture.states(report)[targetEpoch])
        #expect(state.status == .unsupported(.notAttempted, .analysisPending))
        #expect(state.remedies == [.retryAnalysis, .editNumerically, .placeAnchors])
        #expect(state.analysis == nil)
        // The whole report is stale: neither its proposal nor its placements can be accepted (F3).
        let changes: [AlignmentDependencyChange] = [.sourceChanged(tgt)]
        await #expect(throws: AlignmentAcceptanceError.analysisStale(changes)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .acceptProposal()])
        }
        await #expect(throws: AlignmentAcceptanceError.analysisStale(changes)) {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .numeric(ppm: 0, offsetMilliseconds: 0)])
        }
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
    }
}

extension PipelineFixture {
    /// Index of the (single-source) group holding `name`.
    func groupIndex(of name: String) -> Int {
        epochs.indices.first { index in model.episodes[0].sources.contains { $0.id == id(name) && $0.placement.recorderGroupID == groups[index] } } ?? -1
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
