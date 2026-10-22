import Foundation
import Testing
import WWCore
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Global tracks alignment review", .serialized)
struct TracksWorkflowTests {
    @Test func allSpeakerPairsShareOneReviewAndAcceptanceRemainsExplicit() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [.init(name: "reference", seconds: 24, signal: .scene(seed: 19))]),
            GroupSpec(name: "Second", sources: [.init(name: "second", seconds: 24, signal: .scene(seed: 19, offset: 0.2))]),
            GroupSpec(name: "Third", sources: [.init(name: "third", seconds: 24, signal: .scene(seed: 19, offset: 0.4))]),
            GroupSpec(name: "Unassigned", sources: [.init(name: "unassigned", seconds: 24, signal: .scene(seed: 91))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("reference"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("second"), statedChannel: 0),
                          .init(sourceID: fixture.id("third"), statedChannel: 0)]),
        ]
        let original = fixture.model
        let report = try await fixture.pipeline.analyzeTracks(
            model: original, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        #expect(fixture.model == original && original.episodes[0].alignment == nil)
        #expect(report.records.count == 2 && report.references.count == 2)
        #expect(report.records.values.allSatisfy { $0.proposal != nil })
        #expect(report.epochFailures[fixture.epochs[3]] != nil, "Missing assignments are unresolved, never mixed-channel matches")
        var changedAssignments = original
        changedAssignments.episodes[0].speakerAssignments = []
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(model: changedAssignments, episode: fixture.episodeID,
                report: report, decisions: [fixture.epochs[1]: .acceptProposal()], replacingAlignment: true)
        }
        let accepted = try await fixture.pipeline.accept(model: original, episode: fixture.episodeID,
            report: report, decisions: [fixture.epochs[1]: .acceptProposal(), fixture.epochs[2]: .acceptProposal()],
            replacingAlignment: true)
        #expect(await fixture.pipeline.coordinator.inputs.acceptedMaps[fixture.episodeID] == nil,
                "Acceptance alone must not activate timing before verified save")
        #expect(accepted.map.groups.first { $0.group == fixture.groups[3] }?.epochs.first?.mapping == .unsupported(.notAttempted))
        for index in [1, 2] {
            let proposal = try #require(report.records[fixture.epochs[index]]?.proposal)
            let group = try #require(accepted.map.groups.first { $0.group == fixture.groups[index] })
            guard case let .mapped(segments, _) = group.epochs.first?.mapping else {
                Issue.record("Accepted measured proposal missing")
                continue
            }
            #expect(segments == [proposal.segment], "Never extend into unmeasured audio")
        }
        try await fixture.pipeline.activate(accepted)
        fixture.model = accepted.model
        let replacement = try await fixture.pipeline.analyzeTracks(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(fixture.model == accepted.model, "New analysis keeps prior accepted work live")
        let replaced = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID,
            report: replacement, decisions: [fixture.epochs[2]: .acceptProposal()], replacingAlignment: true)
        #expect(replaced.map.reference == accepted.map.reference)
        #expect(replaced.model.episodes[0].alignment?.maps.count == 2)
        #expect(replaced.map.groups.first { $0.group == fixture.groups[1] }?.epochs.first?.mapping == .unsupported(.notAttempted),
                "Unselected proposals do not silently carry old timing")
    }

    @Test func unknownChannelsDoNotUseTheLegacyWholeTrackAnalyzer() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "one", seconds: 22, signal: .scene(seed: 2))]),
            GroupSpec(name: "Two", sources: [.init(name: "two", seconds: 22, signal: .scene(seed: 2))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("one"), statedChannel: nil),
                backups: [.init(sourceID: fixture.id("two"), statedChannel: 0)]),
        ]
        let report = try await fixture.pipeline.analyzeTracks(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(report.records.isEmpty && report.epochFailures[fixture.epochs[1]] != nil)
        #expect(fixture.content.total.reads == 0, "Metadata probes are not authorization to decode unassigned channels")
    }

    @Test func missingAuthorizationLeavesAnExplicitSetupBlockWithoutOpeningContent() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "one", seconds: 22, signal: .scene(seed: 2))]),
            GroupSpec(name: "Two", sources: [.init(name: "two", seconds: 22, signal: .scene(seed: 2))]),
        ])
        let report = try await fixture.pipeline.analyzeTracks(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: [])
        #expect(report.plan.reference == nil && report.records.isEmpty)
        #expect(report.plan.ineligible.values.allSatisfy { $0 == .notAuthorized })
        #expect(report.plan.ineligible.count == 2)
        #expect(fixture.content.total.opens == 0 && fixture.content.total.reads == 0)
        let states = await fixture.pipeline.states(model: fixture.model, episode: fixture.episodeID,
            report: report, reviewingAnalysis: true)
        #expect(states.count == 2 && states.allSatisfy { $0.remedies.contains(.goToSetup) })
    }

    @Test func alignedRelayReferencesUseCapturedAcceptedTimingWithoutRebasing() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [.init(name: "reference", seconds: 24, signal: .scene(seed: 19))]),
            GroupSpec(name: "Relay", sources: [.init(name: "relay", seconds: 24, signal: .scene(seed: 19, offset: 0.2))]),
            GroupSpec(name: "Third", sources: [.init(name: "third", seconds: 24, signal: .scene(seed: 19, offset: 0.4))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("reference"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("relay"), statedChannel: 0)]),
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("relay"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("third"), statedChannel: 0)]),
        ]
        let initial = try await fixture.pipeline.prepareManual(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        let prior = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID,
            report: initial, decisions: [
                fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 200),
                fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: 400),
            ])
        try await fixture.pipeline.activate(prior)
        let report = try await fixture.pipeline.analyzeTracks(model: prior.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(report.references[fixture.epochs[2]]?.source == fixture.id("relay"))
        #expect(report.referenceRevision == prior.revision.revision)
        let proposal = try #require(report.records[fixture.epochs[2]]?.proposal)
        let accepted = try await fixture.pipeline.accept(model: prior.model, episode: fixture.episodeID,
            report: report, decisions: [fixture.epochs[2]: .acceptProposal()], replacingAlignment: true)
        let third = try #require(accepted.map.groups.first { $0.group == fixture.groups[2] })
        guard case let .mapped(segments, _) = third.epochs.first?.mapping else {
            Issue.record("Relay proposal was not accepted")
            return
        }
        #expect(segments == [proposal.segment], "Measured absolute timing stays anchored to the captured reference, not another proposal")
        #expect(accepted.map.reference == prior.map.reference)
        #expect(accepted.map.groups.first { $0.group == fixture.groups[1] }?.epochs.first?.mapping == .unsupported(.notAttempted))
    }
}
