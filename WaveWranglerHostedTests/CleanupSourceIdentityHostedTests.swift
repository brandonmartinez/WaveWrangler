import CryptoKit
import Foundation
import Testing
import WWCore
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Durable review identity across source remounts", .serialized)
struct CleanupSourceIdentityHostedTests {
    @Test func remountedOriginalKeepsSavedTranscriptAndReviewIdentityWithoutRebasing() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2, durationSeconds: 4)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (f.model.isWorking || f.document.verifiedModel != f.document.store.model
            || f.model.waveformNeedsRefreshAfterSave), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!f.model.isWorking && f.document.verifiedModel == f.document.store.model)
        let snapshot = f.document.store.model
        let store = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        let key = DeviceAccessKey(showID: snapshot.show.id, sourceID: f.target)
        var record = try #require(try await store.record(for: key))
        let witness = try #require(record.recordedIdentity?.rawWitness)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(witness)) as? [String: Any])
        json["device"] = witness.device + 1
        json["fileSystemID0"] = (witness.fileSystemID0 ?? 0) + 1
        json["fileSystemID1"] = (witness.fileSystemID1 ?? 0) + 1
        let oldMount = try JSONDecoder().decode(RawSourceIdentity.self,
            from: JSONSerialization.data(withJSONObject: json))
        let expected = SHA256.hash(data: try encoder.encode(oldMount)).map { String(format: "%02x", $0) }.joined()
        record.recordedIdentity?.rawWitness = oldMount
        try await store.save(record)
        let prepared = try await f.runtime.prepareCleanup(model: snapshot, episode: f.model.episodeID)
        #expect(prepared.identities[f.target] == expected)
        let lane = try #require(prepared.plan.lanes.first { $0.primary.sourceID == f.target })
        let revision = try #require(prepared.plan.alignmentRevision)
        let frames = try #require(lane.sourceRange(start: 1, end: 1.3))
        let transcript = SpeakerTranscript(speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
            sourceIdentity: expected, alignmentRevision: revision,
            model: "synthetic-remount", workingRange: nil, words: [
                TranscriptWord(text: "um", sourceStartFrame: frames.lowerBound, sourceEndFrame: frames.upperBound,
                    alignedStart: 1, alignedEnd: 1.3)
            ])
        let seeded = f.document.store.apply("Seed synthetic saved review") { model throws(DomainError) in
            try model.settingCleanup(EpisodeCleanup(transcripts: [transcript]).proposingFillers(), in: f.model.episodeID)
        }
        try #require(seeded)
        let saved = f.document.store.model
        let runtime = try await AlignmentRuntime.make(showID: saved.show.id, accessStore: store,
            access: SourceAccessContext())
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: runtime)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let review = try #require(cleanup.fillerReviews.first)
        #expect(cleanup.fillerIssue(review) == nil)
        #expect(cleanup.transcript(for: lane) == transcript)
        #expect(f.document.store.model == saved, "Readiness must not rewrite a saved origin or timing revision")
        #expect(try await store.record(for: key) == record, "Mount-local changes must not rewrite source authorization")

        json["inode"] = witness.inode + 1
        record.recordedIdentity?.rawWitness = try JSONDecoder().decode(RawSourceIdentity.self,
            from: JSONSerialization.data(withJSONObject: json))
        try await store.save(record)
        await cleanup.refresh()
        #expect(cleanup.fillerIssue(review) != nil, "A different persistent file identity must remain inactive")
        #expect(f.document.store.model == saved)
    }
}
