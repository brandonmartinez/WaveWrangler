import Foundation
import Testing
import WWCore
import WWDerived
import WWSources
@testable import WWAlignPipeline

@Suite("Episode source-access witness (metadata only)")
struct EpisodeSourceAccessTests {
    fileprivate static let publication = PublicationStamp(
        revision: 1, publicationID: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
        checksum: "synthetic-publication"
    )

    private static func document(_ model: ShowDocumentModel) -> EpisodeSourceDocument {
        EpisodeSourceDocument(model: model, publication: publication)
    }

    private func fixture() async throws -> (PipelineFixture, InMemoryDeviceAccessStore, EpisodeSourceAccessVerifier) {
        let fixture = try await PipelineFixture([
            .init(name: "Primary", sources: [.init(name: "primary", seconds: 4, signal: .scene(seed: 81))]),
            .init(name: "Backup", sources: [.init(name: "backup", seconds: 4, signal: .scene(seed: 81))]),
        ], label: "source-access")
        let report = try await fixture.analyse(preferredReference: "primary")
        _ = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0)])
        let io = SystemSourceIO()
        let show = fixture.model.show.id
        var records: [DeviceAccessRecord] = []
        for name in ["primary", "backup"] {
            let url = fixture.url(name)
            guard case let .success(metadata) = io.metadata(at: url) else { throw POSIXError(.ENOENT) }
            records.append(DeviceAccessRecord(
                showID: show, sourceID: fixture.id(name),
                bookmark: try io.makeReadOnlyBookmark(for: url), lastKnownPath: url.path,
                recordedIdentity: RecordedIdentity(fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()),
                createdAt: Date()
            ))
        }
        let store = InMemoryDeviceAccessStore(records)
        for i in fixture.model.episodes[0].sources.indices {
            fixture.model.episodes[0].sources[i].observations.channelCount = .known(2)
        }
        return (fixture, store, EpisodeSourceAccessVerifier(
            showID: show, coordinator: fixture.coordinator, accessStore: store, access: SourceAccessContext(io: io)
        ))
    }

    @Test func exhaustiveAuthorizedWitnessNeverAdmitsACut() async throws {
        let (fixture, _, verifier) = try await fixture()
        let opens = fixture.content.total.opens
        let witness = try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        #expect(witness.lanes.count == 4)
        #expect(Set(witness.lanes.map(\.source)).count == 2)
        #expect(witness.protectionSurvey == .absent)
        #expect(witness.completeCutPreparation == .refused([
            .protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified
        ]))
        try await verifier.reverify(witness) { Self.document(fixture.model) }
        #expect(fixture.content.total.opens == opens, "verification and recheck open no audio beyond fixture analysis")
    }

    @Test func missingOrDuplicateSourceAndUnknownChannelRefuse() async throws {
        let (fixture, _, verifier) = try await fixture()
        let original = fixture.model
        fixture.model.episodes[0].sources.removeLast()
        await #expect(throws: EpisodeSourceAccessRefusal.self) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        fixture.model.episodes[0].sources.append(original.episodes[0].sources[0])
        await #expect(throws: EpisodeSourceAccessRefusal.self) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        fixture.model.episodes[0].sources[0].observations.channelCount = .unknown
        await #expect(throws: EpisodeSourceAccessRefusal.undeclaredChannels(fixture.id("primary"))) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
    }

    @Test func mismatchedBookmarkAndUnconfirmedIdentityRefuse() async throws {
        let (fixture, store, verifier) = try await fixture()
        let key = DeviceAccessKey(showID: fixture.model.show.id, sourceID: fixture.id("backup"))
        let original = try #require(await store.record(for: key))
        var wrong = original
        wrong.bookmark = try SystemSourceIO().makeReadOnlyBookmark(for: fixture.url("primary"))
        try await store.save(wrong)
        await #expect(throws: EpisodeSourceAccessRefusal.accessUnverified(key.sourceID)) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        var unconfirmed = original
        unconfirmed.recordedIdentity?.confirmation = .provisional
        try await store.save(unconfirmed)
        await #expect(throws: EpisodeSourceAccessRefusal.accessUnverified(key.sourceID)) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        try await store.save(original)
        var wrongPath = original
        wrongPath.lastKnownPath = fixture.url("primary").path
        try await store.save(wrongPath)
        await #expect(throws: EpisodeSourceAccessRefusal.accessUnverified(key.sourceID)) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
    }

    @Test func changedMapBytesOrRegisteredRevisionRefuse() async throws {
        let (fixture, _, verifier) = try await fixture()
        let original = fixture.model
        fixture.model.episodes[0].alignment?.maps[0].inputs.recipe = RecipeReference(name: "different-content", revision: 1)
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapStale) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        await fixture.coordinator.updateSource(SourceRevision(source: fixture.id("backup"), token: "stale"))
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapStale) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model.episodes[0].alignment?.acceptedRevision = nil
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapMissing) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
    }

    @Test func unsupportedEpochAndPublicationChangeRefuse() async throws {
        let (fixture, _, verifier) = try await fixture()
        let unsupported = try await fixture.pipeline.reviseAcceptedMap(
            model: fixture.model, episode: fixture.episodeID, decisions: [fixture.epochs[1]: .unmapped]
        )
        fixture.model = unsupported.model
        try await fixture.pipeline.activate(unsupported)
        await #expect(throws: EpisodeSourceAccessRefusal.unsupportedEpoch(fixture.epochs[1])) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        let fresh = try await self.fixture()
        let prior = try await fresh.2.verify(episode: fresh.0.episodeID) { Self.document(fresh.0.model) }
        let newer = PublicationStamp(revision: 2, publicationID: UUID(), checksum: "changed-generation")
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await fresh.2.reverify(prior) {
                EpisodeSourceDocument(model: fresh.0.model, publication: newer)
            }
        }
        let sequence = DocumentSequence(model: fresh.0.model, after: newer)
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await fresh.2.verify(episode: fresh.0.episodeID) { await sequence.next() }
        }
    }

    @Test func grantRevokedBetweenSamplesRefusesBeforeReturningWitness() async throws {
        let (fixture, store, verifier) = try await fixture()
        let key = DeviceAccessKey(showID: fixture.model.show.id, sourceID: fixture.id("backup"))
        let calls = Box(0)
        await #expect(throws: EpisodeSourceAccessRefusal.accessMissing(key.sourceID)) {
            try await verifier.verify(episode: fixture.episodeID) {
                if calls.update({ $0 += 1; return $0 }) == 3 {
                    try await store.removeRecord(for: key)
                }
                return Self.document(fixture.model)
            }
        }
    }

    @Test func missingGrantAndReplacedFileRefuseWithoutOpeningContent() async throws {
        let (episode, store, verifier) = try await fixture()
        let key = DeviceAccessKey(showID: episode.model.show.id, sourceID: episode.id("backup"))
        try await store.removeRecord(for: key)
        await #expect(throws: EpisodeSourceAccessRefusal.self) {
            try await verifier.verify(episode: episode.episodeID) { Self.document(episode.model) }
        }

        let original = try await fixture()
        let opens = original.0.content.total.opens
        try original.0.rewrite("backup")
        await #expect(throws: EpisodeSourceAccessRefusal.self) {
            try await original.2.verify(episode: original.0.episodeID) { Self.document(original.0.model) }
        }
        #expect(original.0.content.total.opens == opens)
    }
}

private actor DocumentSequence {
    let model: ShowDocumentModel
    let after: PublicationStamp
    var calls = 0

    init(model: ShowDocumentModel, after: PublicationStamp) {
        self.model = model
        self.after = after
    }

    func next() -> EpisodeSourceDocument {
        calls += 1
        return EpisodeSourceDocument(
            model: model, publication: calls == 1 ? EpisodeSourceAccessTests.publication : after
        )
    }
}
