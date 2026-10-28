import Foundation
import Testing
import WWCore
import WWDerived
@testable import WWAlignPipeline

@Suite("Pure accepted-map context reuse")
struct AcceptedMapContextCacheTests {
    @Test func unchangedReadsAndPersistedActivationsReuseOneCalculationAcrossMixEdits() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "map-context-reuse")
        let report = try await fixture.analyze(preferredReference: "ref")
        let accepted = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let opens = fixture.content.total.opens
        let clock = ContinuousClock()
        let coldStart = clock.now
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID) == accepted.map)
        let cold = coldStart.duration(to: clock.now)
        let warmStart = clock.now
        for _ in 0..<50 {
            try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
            #expect(try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID) == accepted.map)
        }
        let warm = warmStart.duration(to: clock.now)
        fixture.model.episodes[0].title = "Renamed without changing timing"
        fixture.model.episodes[0].mix = EpisodeMixState()
        fixture.model.episodes[0].mix?.master.gainDB = -6
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID) == accepted.map)
        #expect(await fixture.pipeline.mapContexts.preparationCount == 1)
        #expect(fixture.content.total.opens == opens)
        print("MAP_CONTEXT_REUSE cold=\(cold) warmReadAndActivationPairs=50 warm=\(warm) calculations=1")
        await fixture.pipeline.shutdown()
    }

    @Test(arguments: ["source", "format", "placement", "publication", "shutdown"])
    func aWarmContextNeverReplacesCurrentDependencyOrPublicationChecks(_ change: String) async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "map-context-\(change)")
        let report = try await fixture.analyze(preferredReference: "ref")
        let accepted = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        _ = try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID)
        #expect(await fixture.pipeline.mapContexts.preparationCount == 1)
        switch change {
        case "source":
            await fixture.coordinator.updateSource(SourceRevision(source: fixture.id("tgt"), token: "changed"))
        case "format":
            var format = FormatRevision.current
            format.envelopeVersion += 1
            await fixture.coordinator.setFormat(format)
        case "placement":
            _ = try fixture.moveToNewEpoch("tgt")
        case "publication":
            await fixture.coordinator.invalidate(accepted.identity.slot)
        case "shutdown":
            await fixture.pipeline.shutdown()
        default:
            Issue.record("Unknown synthetic context change")
        }
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.self) {
            try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID)
        }
        #expect(fixture.content.total.opens == opens)
        await fixture.pipeline.shutdown()
    }

    @Test func sameRevisionDifferentCanonicalContentRequiresItsOwnLiveIdentityAndRestoresWithUndo() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "map-context-content")
        let report = try await fixture.analyze(preferredReference: "ref")
        let accepted = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let original = fixture.model
        _ = try await fixture.pipeline.verifiedAcceptedMap(model: original, episode: fixture.episodeID)
        var changed = original
        let index = try #require(changed.episodes[0].alignment?.maps.firstIndex { $0.revision == accepted.revision.revision })
        let recipe = try #require(changed.episodes[0].alignment?.maps[index].inputs.recipe)
        changed.episodes[0].alignment?.maps[index].inputs.recipe = RecipeReference(
            name: recipe.name + ";accepted=synthetic:" + String(repeating: "b", count: 64), revision: recipe.revision)
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await fixture.pipeline.verifiedAcceptedMap(model: changed, episode: fixture.episodeID)
        }
        try await fixture.pipeline.activate(model: changed, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: changed, episode: fixture.episodeID) == accepted.map)
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await fixture.pipeline.verifiedAcceptedMap(model: original, episode: fixture.episodeID)
        }
        try await fixture.pipeline.activate(model: original, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: original, episode: fixture.episodeID) == accepted.map)
        #expect(await fixture.coordinator.state(of: accepted.identity.slot) == .ready(accepted.identity.key))
        await fixture.pipeline.shutdown()
    }

    @Test func adaptiveCurveChangesInvalidateTheSameRevisionContext() async throws {
        let (fixture, correction) = try await AdaptiveAudioCacheTests.fixture()
        let original = fixture.model
        _ = try await fixture.pipeline.verifiedAcceptedMap(model: original, episode: fixture.episodeID)
        let originalKey = try #require(await fixture.coordinator.state(of:
            PipelineSlots.acceptedMapIdentity(fixture.episodeID)).key)
        let before = await fixture.pipeline.mapContexts.preparationCount
        var shifted = correction
        shifted.segments = shifted.segments.map {
            var segment = $0
            segment.alignedStart += 0.125
            return segment
        }
        fixture.model.episodes[0].alignment?.maps[0].sourceCorrections = [shifted]
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID)
        }
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        _ = try await fixture.pipeline.verifiedAcceptedMap(model: fixture.model, episode: fixture.episodeID)
        #expect(await fixture.pipeline.mapContexts.preparationCount == before + 1)
        #expect(await fixture.coordinator.state(of: PipelineSlots.acceptedMapIdentity(fixture.episodeID)).key != originalKey)
        try await fixture.pipeline.activate(model: original, episode: fixture.episodeID)
        #expect(await fixture.coordinator.state(of: PipelineSlots.acceptedMapIdentity(fixture.episodeID)) == .ready(originalKey))
        await fixture.pipeline.shutdown()
    }

    @Test func signedZeroCannotAliasADifferentCanonicalMapIdentity() async throws {
        let (fixture, _) = try await AdaptiveAudioCacheTests.fixture()
        let original = fixture.model
        let episode = try #require(original.episode(fixture.episodeID))
        let version = try #require(episode.alignment?.acceptedMap)
        let revision = MapRevisionReference(episode: fixture.episodeID, revision: version.revision)
        let map = try await fixture.pipeline.verifiedAcceptedMap(model: original, episode: fixture.episodeID)
        let registered = await fixture.coordinator.inputs.sources
        let originalIdentity = try AcceptedMapIdentity(revision: revision, version: version, map: map, registered: registered)
        var changed = original
        changed.episodes[0].alignment?.maps[0].sourceCorrections?[0].segments[0].alignedStart = -0.0
        let changedVersion = try #require(changed.episode(fixture.episodeID)?.alignment?.acceptedMap)
        #expect(changedVersion == version, "Ordinary floating-point equality treats signed zeros as equal.")
        let changedIdentity = try AcceptedMapIdentity(
            revision: revision, version: changedVersion, map: map, registered: registered)
        #expect(changedIdentity != originalIdentity, "Canonical persisted bytes still distinguish signed zero.")
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await fixture.pipeline.verifiedAcceptedMap(model: changed, episode: fixture.episodeID)
        }
        await fixture.pipeline.shutdown()
    }
}
