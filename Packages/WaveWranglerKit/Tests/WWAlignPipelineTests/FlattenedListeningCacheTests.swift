import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Shared persistent flattened listening cache", .serialized)
struct FlattenedListeningCacheTests {
    @Test func affineWindowsReuseCanonicalBinaryTilesAcrossCacheInstancesAndRefuseChangedOriginals() async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 8, signal: .scene(seed: 91))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 8, signal: .scene(seed: 91))]),
        ], nativeAudio: true)
        let preparation = try await f.pipeline.prepareManual(model: f.model, episode: f.episodeID,
            sources: f.sources, authorizations: f.authorizations)
        _ = try await f.acceptAndActivate(preparation, [f.epochs[1]: .numeric(ppm: 125, offsetMilliseconds: 10)])
        let source = f.id("target"), url = f.url("target")
        let interpretation = try await f.decoder.withDecodingCursor(url, source: source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        let revision = MapRevisionReference(episode: f.episodeID,
            revision: try #require(f.model.episode(f.episodeID)?.alignment?.acceptedRevision))
        let map = try #require(try f.model.timeMap(revision: revision.revision, in: f.episodeID)
            .groups.first { $0.group == f.groups[1] })
        let original = try Data(contentsOf: url)
        let cache = AlignedAuditionPCMCache(coordinator: f.coordinator)
        let first = try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
            matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
            outputFrames: 0..<48_000, cache: cache, revision: revision)
        let replay = AlignedAuditionPCMCache(coordinator: f.coordinator)
        #expect(try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
            matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
            outputFrames: 0..<48_000, cache: replay, revision: revision) == first)
        let keys = await f.coordinator.states().values.compactMap(\.key)
            .filter { $0.asset.kind == "ww.aligned-listening-pcm" }
        #expect(keys.count == 1)
        let persistedKey = try #require(keys.first)
        let payload = try #require(f.coordinator.store.payload(for: persistedKey))
        #expect(payload.starts(with: ListeningPCM.magic))
        #expect(try ListeningPCM.decode(payload).channels[0].count == 240_000)
        #expect(try Data(contentsOf: url) == original)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
                matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
                outputFrames: 0..<48_000, cache: replay, revision: revision)
        }
        await f.pipeline.shutdown()
    }

    @Test func adaptiveLegacyJSONIsMigratedToBinaryWithoutChangingSamples() async throws {
        let (f, correction) = try await AdaptiveAudioCacheTests.fixture()
        let url = f.url("target")
        let interpretation = try await f.decoder.withDecodingCursor(url, source: correction.source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        let original = try Data(contentsOf: url)
        let first = try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000)
        let slot = DerivedSlot("adaptive-audio/\(f.episodeID)/\(correction.source)/48000/0")
        let key = try #require(await f.coordinator.state(of: slot).key)
        #expect(key.asset.kind == "ww.adaptive-audio-pcm")
        let bytes = try #require(await f.coordinator.readyPayload(for: slot, matching: key))
        let binary = try ListeningPCM.decode(bytes)
        let legacy = AdaptivePCM(firstFrame: binary.firstFrame, channels: binary.channels)
        var oldKey = key
        oldKey.asset.kind = "ww.adaptive-audio-tile"
        await f.coordinator.setAssetRevision(oldKey.asset)
        let data = try JSONEncoder().encode(legacy)
        let seeded = await f.coordinator.submit(DerivedSlot("legacy-pcm-fixture"), key: oldKey) { data }
        #expect(await seeded.outcome == .published(oldKey))
        await f.pipeline.adaptivePCMCache.removeAll()
        await f.coordinator.invalidate(slot)
        #expect(try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000) == first)
        let migrated = try #require(await f.coordinator.readyPayload(for: slot, matching: key))
        #expect(migrated.starts(with: ListeningPCM.magic))
        #expect(try ListeningPCM.decode(migrated).channels == binary.channels)
        #expect(try Data(contentsOf: url) == original)
        await f.pipeline.shutdown()
    }
}
