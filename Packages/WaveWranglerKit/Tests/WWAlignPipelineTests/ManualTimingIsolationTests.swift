import Foundation
import Testing
import WWCore
@testable import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Manual timing beside confirmed file corrections", .serialized)
struct ManualTimingIsolationTests {
    private func fixture() async throws -> PipelineFixture {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [
                .init(name: "ref", seconds: 12, signal: .sine(hz: 211), sampleRate: 8000)
            ]),
            .init(name: "Dynamic", sources: [
                .init(name: "dynamic", seconds: 12, signal: .sine(hz: 223), sampleRate: 8000)
            ]),
            .init(name: "Unplaced", sources: [
                .init(name: "manual", seconds: 12, signal: .sine(hz: 227), sampleRate: 8000)
            ])
        ])
        let report = try await f.pipeline.prepareManual(model: f.model, episode: f.episodeID,
            sources: f.sources, authorizations: f.authorizations)
        try #require(report.plan.reference?.group == f.groups[0])
        let accepted = try await f.acceptAndActivate(report, [
            f.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0)
        ])
        let correction = SourceTimingCorrection(source: f.id("dynamic"), group: f.groups[1], epoch: f.epochs[1],
            reference: f.id("ref"), sourceRate: 8000, sourceFrames: 96_000, channelCount: 2,
            analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
            segments: [.init(sourceStart: 0, sourceEnd: 12, alignedStart: 0.125, rateRatio: 1.0001)])
        try #require(correction.isValid)
        let inputs = await f.coordinator.inputs
        let digest = try #require(MapDependencies.digest(map: accepted.map,
            tokens: inputs.sources, format: inputs.format, corrections: [correction]))
        let recorded = try f.model.recordingMap(accepted.map, in: f.episodeID,
            inputs: #require(f.model.episodes[0].alignment?.acceptedMap?.inputs.sources),
            recipe: MapDependencies.recipe(digest: digest), derivedFrom: accepted.revision.revision,
            sourceCorrections: [correction])
        f.model = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: f.episodeID)
        try await f.pipeline.activate(model: f.model, episode: f.episodeID)
        return f
    }

    @Test func unrelatedManualPlacementAnchorsAndMovesRetainDynamicTimingAcrossReopen() async throws {
        let f = try await fixture()
        let prior = f.model
        let correction = try #require(prior.episodes[0].alignment?.acceptedMap?.sourceCorrections)
        let original = try prior.timeMap(revision: #require(prior.episodes[0].alignment?.acceptedRevision), in: f.episodeID)
        let report = try await f.pipeline.prepareManual(model: prior, episode: f.episodeID,
            sources: f.sources, authorizations: f.authorizations)
        let placed = try await f.pipeline.accept(model: prior, episode: f.episodeID, report: report,
            decisions: [f.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: 250)])
        f.model = placed.model
        try await f.pipeline.activate(placed)
        let anchored = try await f.pipeline.reviseAcceptedMap(model: f.model, episode: f.episodeID,
            decisions: [f.epochs[2]: .anchorsForSource(f.id("manual"), [
                .init(sourceSeconds: 1, alignedSeconds: 1.2),
                .init(sourceSeconds: 11, alignedSeconds: 11.201)
            ])])
        f.model = anchored.model
        try await f.pipeline.activate(anchored)
        let moved = try await f.pipeline.shiftAcceptedGroup(model: f.model, episode: f.episodeID,
            group: f.groups[2], microseconds: -100_000)
        #expect(moved.map.reference == original.reference)
        #expect(moved.map.groups.first { $0.group == f.groups[0] } == original.groups.first { $0.group == f.groups[0] })
        #expect(moved.map.groups.first { $0.group == f.groups[1] } == original.groups.first { $0.group == f.groups[1] })
        for result in [placed, anchored, moved] {
            #expect(result.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == correction)
            #expect(result.model.episodes[0].sources == prior.episodes[0].sources)
        }
        f.model = moved.model
        f.reopenPipeline()
        try await f.pipeline.activate(model: f.model, episode: f.episodeID)
        #expect(try await f.pipeline.verifiedAcceptedMap(model: f.model, episode: f.episodeID) == moved.map)
        await ConcurrencyTests.expectQuiescent(f)
    }

    @Test func dynamicRecorderAndItsReferenceCannotBeEditedBeforeReset() async throws {
        let f = try await fixture()
        let prior = f.model
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await f.pipeline.shiftAcceptedGroup(model: prior, episode: f.episodeID,
                group: f.groups[1], microseconds: 10_000)
        }
        for epoch in [f.epochs[0], f.epochs[1]] {
            await #expect(throws: AlignmentAcceptanceError.self) {
                try await f.pipeline.reviseAcceptedMap(model: prior, episode: f.episodeID,
                    decisions: [epoch: .numeric(ppm: 0, offsetMilliseconds: 500)])
            }
        }
        let report = try await f.pipeline.prepareManual(model: prior, episode: f.episodeID,
            sources: f.sources, authorizations: f.authorizations)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await f.pipeline.accept(model: prior, episode: f.episodeID, report: report,
                decisions: [f.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 500)])
        }
        #expect(f.model == prior)
        let reset = try await f.pipeline.removeAdaptiveCorrection(model: prior, episode: f.episodeID,
            source: f.id("dynamic"))
        f.model = reset.model
        try await f.pipeline.activate(reset)
        let moved = try await f.pipeline.shiftAcceptedGroup(model: f.model, episode: f.episodeID,
            group: f.groups[1], microseconds: 10_000)
        #expect(moved.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == nil)
        #expect(moved.map.reference == reset.map.reference)
        await ConcurrencyTests.expectQuiescent(f)
    }
}
