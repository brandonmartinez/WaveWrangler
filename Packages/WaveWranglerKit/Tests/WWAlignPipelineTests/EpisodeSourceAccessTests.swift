import Foundation
import Testing
import WWCore
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap
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

    @Test(arguments: ["primary", "backup"])
    func confirmedRelinkWithoutCoordinatorUpdateRefuses(_ name: String) async throws {
        let (fixture, store, verifier) = try await fixture()
        try fixture.rewrite(name)
        let key = DeviceAccessKey(showID: fixture.model.show.id, sourceID: fixture.id(name))
        var record = try #require(await store.record(for: key))
        let io = SystemSourceIO()
        guard case let .success(metadata) = io.metadata(at: fixture.url(name)) else { throw POSIXError(.ENOENT) }
        record.bookmark = try io.makeReadOnlyBookmark(for: fixture.url(name))
        record.recordedIdentity = RecordedIdentity(
            fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
        )
        await store.save(record)
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapStale) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
    }

    @Test(arguments: ["revoke", "relink"])
    func finalDocumentCallbackCannotOutliveGrant(_ action: String) async throws {
        let (fixture, store, verifier) = try await fixture()
        let key = DeviceAccessKey(showID: fixture.model.show.id, sourceID: fixture.id("backup"))
        let calls = Box(0)
        let expected: EpisodeSourceAccessRefusal = action == "revoke"
            ? .accessMissing(key.sourceID) : .changedDuringVerification
        await #expect(throws: expected) {
            try await verifier.verify(episode: fixture.episodeID) {
                if calls.update({ $0 += 1; return $0 }) == 4 {
                    if action == "revoke" {
                        await store.removeRecord(for: key)
                    } else {
                        let replacement = fixture.directory.url.appendingPathComponent("replacement.wav")
                        try Data(repeating: 0x31, count: 4096).write(to: replacement)
                        var record = try #require(await store.record(for: key))
                        let io = SystemSourceIO()
                        guard case let .success(metadata) = io.metadata(at: replacement) else {
                            throw POSIXError(.ENOENT)
                        }
                        record.bookmark = try io.makeReadOnlyBookmark(for: replacement)
                        record.lastKnownPath = replacement.path
                        record.recordedIdentity = RecordedIdentity(
                            fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
                        )
                        await store.save(record)
                    }
                }
                return Self.document(fixture.model)
            }
        }
        #expect(calls.value >= 4)
    }

    @Test func externalShowReplacementRefusesWithUnchangedInMemoryModel() async throws {
        let (fixture, _, verifier) = try await fixture()
        let url = fixture.directory.url.appendingPathComponent("synthetic.wwshow")
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let original = try coder.encodeDocument(fixture.model, revision: 1, publicationID: UUID())
        try original.data.write(to: url)
        let base = RevisionFingerprint(of: original.data)
        let cached = try EpisodeSourceDocument.current(
            at: url, expectedModel: fixture.model, expectedBase: base
        )
        let opens = fixture.content.total.opens
        let witness = try await verifier.verify(episode: fixture.episodeID) { cached }
        #expect(witness.publication == original.publication)
        #expect(fixture.content.total.opens == opens)
        let replacement = try coder.encodeDocument(fixture.model, revision: 2, publicationID: UUID())
        try replacement.data.write(to: url, options: [.atomic])
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await verifier.verify(episode: fixture.episodeID) { cached }
        }
        try original.data.write(to: url, options: [.atomic])
        let calls = Box(0)
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await verifier.verify(episode: fixture.episodeID) {
                if calls.update({ $0 += 1; return $0 }) == 4 {
                    try replacement.data.write(to: url, options: [.atomic])
                }
                return cached
            }
        }
        #expect(calls.value >= 4)
    }

    @Test func finalDocumentCallbackCannotOutliveReadyKey() async throws {
        let (fixture, _, verifier) = try await fixture()
        let calls = Box(0)
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapNotActive) {
            try await verifier.verify(episode: fixture.episodeID) {
                if calls.update({ $0 += 1; return $0 }) == 4 {
                    await fixture.coordinator.removeSource(fixture.id("backup"))
                }
                return Self.document(fixture.model)
            }
        }
        #expect(calls.value >= 4)
    }

    @Test func partialPlacementRefusesUnmappedTail() async throws {
        let (fixture, _, verifier) = try await fixture()
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let groups = try map.groups.map { group in
            try GroupTimeMap(group: group.group, reference: group.reference, epochs: group.epochs,
                             placements: group.placements.map { placement in
                guard placement.occurrence.source == fixture.id("backup") else { return placement }
                let span = placement.spans[0]
                return OccurrencePlacement(occurrence: placement.occurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: placement.occurrence.frameCount / 2,
                              epoch: span.epoch, groupClockOffset: span.groupClockOffset)
                ])
            })
        }
        let partial = try AlignedTimelineMap(reference: map.reference, groups: groups)
        fixture.model.episodes[0].alignment?.maps[0].map = try EmbeddedTimeMapCodec.encode(partial)
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        await #expect(throws: EpisodeSourceAccessRefusal.incompleteOccurrences) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
    }

    @Test func unusedGroupEpochRefusesUnrepresentedLane() async throws {
        let (fixture, _, verifier) = try await fixture()
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let unused = RecordingEpochID()
        let groups = try map.groups.map { group in
            try GroupTimeMap(group: group.group, reference: group.reference,
                             epochs: group.group == fixture.groups[1]
                                 ? group.epochs + [EpochClockMap(epoch: unused, mapping: .unsupported(.notAttempted))]
                                 : group.epochs,
                             placements: group.placements)
        }
        let extra = try AlignedTimelineMap(reference: map.reference, groups: groups)
        fixture.model.episodes[0].recorderGroups[1].epochs.append(RecordingEpoch(id: unused, label: "Unused"))
        fixture.model.episodes[0].alignment?.maps[0].map = try EmbeddedTimeMapCodec.encode(extra)
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        await #expect(throws: EpisodeSourceAccessRefusal.incompleteOccurrences) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
    }

    @Test func twoLogicalSourcesRelinkedToSamePhysicalFileRefuse() async throws {
        let (fixture, store, verifier) = try await fixture()
        let key = DeviceAccessKey(showID: fixture.model.show.id, sourceID: fixture.id("backup"))
        var backup = try #require(await store.record(for: key))
        let io = SystemSourceIO()
        guard case let .success(metadata) = io.metadata(at: fixture.url("primary")) else { throw POSIXError(.ENOENT) }
        backup.bookmark = try io.makeReadOnlyBookmark(for: fixture.url("primary"))
        backup.lastKnownPath = fixture.url("primary").path
        backup.recordedIdentity = RecordedIdentity(
            fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
        )
        await store.save(backup)
        await #expect(throws: EpisodeSourceAccessRefusal.physicalAlias(fixture.id("primary"), key.sourceID)) {
            try await verifier.verify(episode: fixture.episodeID) { Self.document(fixture.model) }
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
