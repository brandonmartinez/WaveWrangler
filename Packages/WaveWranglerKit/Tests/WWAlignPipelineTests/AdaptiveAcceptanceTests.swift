import Foundation
import Testing
import WWCore
import WWDerived
import WWPersistence
@testable import WWAlignPipeline

@Suite("Accepted file-local adaptive audio", .serialized)
struct AdaptiveAcceptanceTests {
    @Test func estimatedGapsRequireExplicitAcceptanceAndKeepAllConfirmedGeometryAndOtherFiles() async throws {
        let (fixture, speaker) = try await AdaptiveAnalysisTests.quietFixture(nativeAudio: true)
        fixture.model.speakers = [Speaker(id: speaker, name: "Shared")]
        let before = fixture.model
        let record = try await AdaptiveAnalysisTests.run(fixture, speaker)
        try #require(!record.timing.estimatedIntervals.isEmpty)
        let strict = try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
            record: record, sources: fixture.sources, authorizations: fixture.authorizations)
        let strictCorrection = try #require(strict.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(strictCorrection.segments.allSatisfy { $0.kind != .estimated })
        let accepted = try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
            record: record, sources: fixture.sources, authorizations: fixture.authorizations, includeEstimated: true)
        let correction = try #require(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(correction.version == 3 && correction.isValid)
        #expect(correction.segments.filter { $0.kind != .estimated } == strictCorrection.segments)
        #expect(accepted.map == strict.map)
        #expect(accepted.model.episodes[0].sources == before.episodes[0].sources)
        #expect(accepted.model.episodes[0].recorderGroups == before.episodes[0].recorderGroups)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let restored = try coder.decode(coder.encode(accepted.model, revision: 1)).payload
        #expect(restored == accepted.model)
        try await fixture.pipeline.activate(accepted)
        let estimate = try #require(correction.segments.first { $0.kind == .estimated && $0.sourceEnd - $0.sourceStart > 0.3 })
        let fingerprint = try await fixture.decoder.withDecodingCursor(fixture.url("backup"), source: correction.source) {
            $0.interpretation.sourceFingerprint
        }
        let witness = try await fixture.decoder.captureRawIdentity(fixture.url("backup"), matching: fingerprint)
        let audio = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: (estimate.alignedStart + estimate.alignedEnd) / 2 - 0.1, durationSeconds: 0.2)
        #expect(audio.count == 2 && audio[0].contains { abs($0) > 0.000001 })
        #expect(zip(audio[0], audio[1]).allSatisfy { abs($0 * channelGain(1) - $1) < 0.0001 })
        let removed = try await fixture.pipeline.removeAdaptiveCorrection(model: restored, episode: fixture.episodeID,
            source: correction.source)
        #expect(removed.map == accepted.map)
        try await fixture.pipeline.activate(removed)
        try await fixture.pipeline.activate(model: restored, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: restored, episode: fixture.episodeID) == accepted.map)
        #expect(fixture.content.record(fixture.url("other file")).decodedFrames == 0)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func quietTransitionsPersistPlayEveryChannelAndUndoWithoutMovingTheReference() async throws {
        let (fixture, speaker) = try await AdaptiveAnalysisTests.quietFixture(nativeAudio: true)
        fixture.model.speakers = [Speaker(id: speaker, name: "Shared")]
        let before = fixture.model
        let record = try await AdaptiveAnalysisTests.run(fixture, speaker)
        try #require(record.timing.quietSeconds > 30)
        var changed = record.timing
        changed.quietTransitions = nil
        let tampered = AdaptiveAnalysisRecord(reference: record.reference, target: record.target,
            timing: changed, windows: record.windows, referenceRevision: record.referenceRevision,
            referenceCoverageEnd: record.referenceCoverageEnd, analysisKey: record.analysisKey)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
                record: tampered, sources: fixture.sources, authorizations: fixture.authorizations)
        }
        let accepted = try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
            record: record, sources: fixture.sources, authorizations: fixture.authorizations)
        let correction = try #require(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(correction.version == 2 && correction.isValid)
        #expect(correction.segments.filter { $0.kind == nil }.count == record.timing.regions.count)
        let quiet = try #require(correction.segments.first { $0.kind == .quietTransition })
        #expect(quiet.rateRatio > 1.0005, "pause timing has its own bounded leniency, not relaxed speech fitting")
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let restored = try coder.decode(coder.encode(accepted.model, revision: 1)).payload
        #expect(restored == accepted.model)
        #expect(restored.episodes[0].sources == before.episodes[0].sources)
        #expect(restored.episodes[0].recorderGroups == before.episodes[0].recorderGroups)
        try await fixture.pipeline.activate(accepted)
        let fingerprint = try await fixture.decoder.withDecodingCursor(fixture.url("backup"), source: correction.source) {
            $0.interpretation.sourceFingerprint
        }
        let witness = try await fixture.decoder.captureRawIdentity(fixture.url("backup"), matching: fingerprint)
        let start = ceil(quiet.alignedStart + 1)
        let audio = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: start, durationSeconds: 1)
        #expect(audio.count == 2 && audio[0].contains { abs($0) > 0.000001 })
        #expect(audio.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 0.001 } })
        #expect(zip(audio[0], audio[1]).allSatisfy { abs($0 * channelGain(1) - $1) < 0.000001 })
        let repeated = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: start, durationSeconds: 1)
        #expect(repeated == audio)
        let removed = try await fixture.pipeline.removeAdaptiveCorrection(model: restored, episode: fixture.episodeID,
            source: correction.source)
        #expect(removed.map == accepted.map)
        try await fixture.pipeline.activate(removed)
        try await fixture.pipeline.activate(model: restored, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: restored, episode: fixture.episodeID) == accepted.map)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func acceptancePersistenceAudioRemovalAndDocumentHistoryKeepOtherFilesFixed() async throws {
        let (fixture, speaker) = try await AdaptiveAnalysisTests.fixture(nativeAudio: true)
        fixture.model.speakers = [Speaker(id: speaker, name: "Shared")]
        let before = fixture.model
        let record = try await AdaptiveAnalysisTests.run(fixture, speaker)
        let tampered = AdaptiveAnalysisRecord(reference: record.reference, target: record.target,
            timing: record.timing, windows: [], referenceRevision: record.referenceRevision,
            referenceCoverageEnd: record.referenceCoverageEnd, analysisKey: record.analysisKey)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
                record: tampered, sources: fixture.sources, authorizations: fixture.authorizations)
        }
        let superseded = try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
            record: record, sources: fixture.sources, authorizations: fixture.authorizations)
        let accepted = try await fixture.pipeline.acceptAdaptive(model: before, episode: fixture.episodeID,
            record: record, sources: fixture.sources, authorizations: fixture.authorizations)
        let correction = try #require(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(correction.source == fixture.id("backup"))
        #expect(correction.channelCount == 2)
        #expect(accepted.model.episodes[0].sources == before.episodes[0].sources)
        #expect(accepted.model.episodes[0].recorderGroups == before.episodes[0].recorderGroups)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let restored = try coder.decode(coder.encode(accepted.model, revision: 1)).payload
        #expect(restored == accepted.model)
        await #expect(throws: AlignmentAcceptanceError.supersededAcceptance) { try await fixture.pipeline.activate(superseded) }
        try await fixture.pipeline.activate(accepted)
        let fingerprint = try await fixture.decoder.withDecodingCursor(fixture.url("backup"), source: correction.source) {
            $0.interpretation.sourceFingerprint
        }
        let witness = try await fixture.decoder.captureRawIdentity(fixture.url("backup"), matching: fingerprint)
        let segment = try #require(correction.segments.first)
        let start = ceil(segment.alignedStart + 0.1)
        let duration = min(1, segment.alignedEnd - start - 0.1)
        try #require(duration == 1)
        let audio = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: start, durationSeconds: duration)
        #expect(audio.count == 2 && audio[0].contains { abs($0) > 0.001 })
        #expect(zip(audio[0], audio[1]).map { abs($0 * channelGain(1) - $1) }.max()! < 0.0001)
        let repeated = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: start, durationSeconds: duration)
        #expect(repeated == audio, "listening reuses exactly the same canonical multichannel tile")
        let firstFrame = Int64(start * 48_000) + 1
        func renderFrames(_ frames: Range<Int64>) async throws -> [[Float]] {
            try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
                source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
                outputFrames: frames)
        }
        let exact = try await renderFrames(firstFrame..<(firstFrame + 48_001))
        let exactHead = try await renderFrames(firstFrame..<(firstFrame + 12_347))
        let exactTail = try await renderFrames((firstFrame + 12_347)..<(firstFrame + 48_001))
        #expect(exact.allSatisfy { $0.count == 48_001 })
        #expect(exact == zip(exactHead, exactTail).map { $0 + $1 },
                "Fractional frame boundaries preserve the same pitch-preserving multichannel tiles")
        let firstHalf = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: start, durationSeconds: 0.5)
        let secondHalf = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: start + 0.5, durationSeconds: 0.5)
        #expect(audio == zip(firstHalf, secondHalf).map { $0 + $1 }, "transport chunk boundaries never change native processing")
        let gap = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: -4, durationSeconds: 1)
        #expect(gap.allSatisfy { $0.allSatisfy { $0 == 0 } })
        let render = try await fixture.pipeline.renderAlignedAssets(model: restored, episode: fixture.episodeID,
            sources: fixture.sources.filter { $0.id == correction.source }, authorizations: fixture.authorizations)
        #expect(render.groups.allSatisfy { $0.failure == nil })
        let results = render.groups.flatMap(\.results)
        try #require(!results.isEmpty)
        #expect(results.allSatisfy { $0.key.asset == AlignmentAssetKinds.adaptiveAlignedAudio })
        let published = try #require(results.first)
        let bytes = try #require(await fixture.coordinator.readyPayload(for: published.slot, matching: published.key))
        let decoded = try AlignedAudioSegment.decode(bytes)
        #expect(decoded.header.processing == PitchPreservingAudio.identifier)
        #expect(decoded.header.renderRecipeVersion == PitchPreservingAudio.renderRecipeVersion)
        let listening = try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: Double(decoded.header.firstOutputFrame) / Double(decoded.header.outputRate),
            durationSeconds: 5, outputRate: decoded.header.outputRate)
        #expect(decoded.samples == listening[decoded.header.decodedChannel], "derived audio and listening are identical, not separate SRC paths")
        let reused = try await fixture.pipeline.renderAlignedAssets(model: restored, episode: fixture.episodeID,
            sources: fixture.sources.filter { $0.id == correction.source }, authorizations: fixture.authorizations)
        #expect(reused.groups.allSatisfy { $0.failure == nil && $0.segmentsRendered == 0 && $0.segmentsReused > 0 })
        var separated = correction
        separated.segments = [
            SourceTimingSegment(sourceStart: 0, sourceEnd: 2, alignedStart: 0, rateRatio: 1),
            SourceTimingSegment(sourceStart: 80, sourceEnd: 82, alignedStart: 3, rateRatio: 1),
        ]
        var separatedModel = restored
        separatedModel.episodes[0].alignment?.maps[0].sourceCorrections = [separated]
        try await fixture.pipeline.activate(model: separatedModel, episode: fixture.episodeID)
        let separatedAudio = try await fixture.pipeline.adaptiveAudioWindow(model: separatedModel, episode: fixture.episodeID,
            source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: 0, durationSeconds: 5)
        #expect(separatedAudio[0][0..<96000].contains { abs($0) > 0.001 })
        #expect(separatedAudio[0][96000..<144000].allSatisfy { $0 == 0 })
        #expect(separatedAudio[0][144000..<240000].contains { abs($0) > 0.001 })
        try await fixture.pipeline.activate(model: restored, episode: fixture.episodeID)
        #expect(fixture.content.record(fixture.url("other file")).decodedFrames == 0)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.reviseAcceptedMap(model: restored, episode: fixture.episodeID,
                decisions: [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0)])
        }
        let removed = try await fixture.pipeline.removeAdaptiveCorrection(model: restored, episode: fixture.episodeID,
            source: correction.source)
        #expect(removed.map == accepted.map)
        #expect(removed.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == nil)
        try await fixture.pipeline.activate(removed)
        try await fixture.pipeline.activate(model: restored, episode: fixture.episodeID)
        #expect(try await fixture.pipeline.verifiedAcceptedMap(model: restored, episode: fixture.episodeID) == accepted.map)
        try await fixture.pipeline.activate(model: removed.model, episode: fixture.episodeID)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == removed.revision.revision)
        try await fixture.pipeline.activate(model: restored, episode: fixture.episodeID)
        let handle = try FileHandle(forWritingTo: fixture.url("backup"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await fixture.pipeline.adaptiveAudioWindow(model: restored, episode: fixture.episodeID,
                source: correction.source, sourceURL: fixture.url("backup"), matching: witness,
                startSeconds: start, durationSeconds: duration)
        }
        await ConcurrencyTests.expectQuiescent(fixture)
    }
}
