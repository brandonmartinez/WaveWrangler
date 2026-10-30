import Foundation
import Testing
import WWCore
import WWDerived
@testable import WWAlignPipeline

@Suite("Pure accepted-map context reuse")
struct AcceptedMapContextCacheTests {
    @Test func assetRevisionAndArrangementEditsPreserveExactRecordingContextAndTranscripts() async throws {
        let f = try await PipelineFixture(ConcurrencyTests.short(), label: "asset-map-context")
        let report = try await f.analyze(preferredReference: "ref")
        let accepted = try await f.acceptAndActivate(report, [f.epochs[1]: ConcurrencyTests.truth])
        f.model.episodes[0].cleanup = .init(transcripts: [.init(
            speaker: SpeakerID(), primary: .init(sourceID: f.id("ref"), statedChannel: 0),
            sourceRate: 48_000, sourceIdentity: String(repeating: "a", count: 64),
            alignmentRevision: accepted.revision.revision, model: "synthetic", workingRange: nil,
            words: [.init(text: "Retained words", sourceStartFrame: 0, sourceEndFrame: 4800,
                          alignedStart: 0, alignedEnd: 0.1)])])
        _ = try await f.pipeline.verifiedAcceptedMap(model: f.model, episode: f.episodeID)
        let before = f.model
        let source = SourceRecord(displayNameHint: "Generated asset", purpose: .supplementalAudio)
        let track = AudioTrack(name: "Music")
        let mapVersion = try #require(before.episodes[0].alignment?.acceptedMap)
        let clip = AudioClip(track: track.id, source: source.id, trim: .init(startFrame: 0, endFrame: 8000),
            anchor: .dialogue(try .init(map: mapVersion, frame: 48_000)))
        let arrangement = AudioArrangement(
            assets: [.init(source: source.id, frameCount: 8000, sampleRate: 8000, channelCount: 2)],
            tracks: [track], clips: [clip])
        f.model = try before.settingAudioState(arrangement, mix: before.episodes[0].mix,
            sources: before.episodes[0].sources + [source], in: f.episodeID)
        await f.coordinator.updateSource(.init(source: source.id, token: "asset-original"))
        for token in ["asset-original", "asset-relinked"] {
            await f.coordinator.updateSource(.init(source: source.id, token: token))
            try await f.pipeline.activate(model: f.model, episode: f.episodeID)
            #expect(try await f.pipeline.verifiedAcceptedMap(model: f.model, episode: f.episodeID) == accepted.map)
            #expect(await f.coordinator.state(of: accepted.identity.slot) == .ready(accepted.identity.key))
        }
        var edited = clip
        edited.anchor = .absolute(frame: 96_000)
        edited.envelope.points = [.init(frame: 0, amplitude: 1), .init(frame: 48_000, amplitude: 0)]
        f.model = try f.model.replacingAudioClip(edited, in: f.episodeID)
        #expect(f.model.hasSameMediaInputs(as: before, in: f.episodeID))
        #expect(f.model.episodes[0].alignment == before.episodes[0].alignment)
        #expect(f.model.episodes[0].cleanup == before.episodes[0].cleanup)
        #expect(!f.model.hasSameProcessingInputs(as: before, in: f.episodeID))
        #expect(try await f.pipeline.verifiedAcceptedMap(model: f.model, episode: f.episodeID) == accepted.map)
        #expect(await f.pipeline.mapContexts.preparationCount == 1)
        await f.coordinator.invalidate(accepted.identity.slot)
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await f.pipeline.verifiedAcceptedMap(model: f.model, episode: f.episodeID)
        }
        await f.pipeline.shutdown()
    }

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
