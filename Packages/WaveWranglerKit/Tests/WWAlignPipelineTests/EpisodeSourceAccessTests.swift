import Foundation
import Dispatch
import Testing
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Untrusted episode source inventory (metadata only)")
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
            .init(name: "Primary", sources: [.init(
                name: "primary", id: SourceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                seconds: 4, signal: .scene(seed: 81)
            )]),
            .init(name: "Backup", sources: [.init(
                name: "backup", id: SourceID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
                seconds: 4, signal: .scene(seed: 81)
            )]),
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

    @Test func exhaustiveAuthorizedInventoryNeverAdmitsACut() async throws {
        let (fixture, _, verifier) = try await fixture()
        let opens = fixture.content.total.opens
        let inventory = try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        #expect(inventory.lanes.count == 4)
        #expect(Set(inventory.lanes.map(\.source)).count == 2)
        #expect(inventory.protectionSurvey == .absent)
        #expect(inventory.completeCutPreparation == .refused([
            .protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified
        ]))
        try await verifier.resurvey(inventory) { Self.document(fixture.model) }
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
        let current: @Sendable () throws -> EpisodeSourceDocument = {
            let opener = DocumentOpener(
                coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: nil,
                identityOf: { .show($0.show.id) }
            )
            guard case let .editable(decoded, fingerprint) = opener.open(url, key: .show(fixture.model.show.id)),
                  fingerprint == base, decoded.payload == fixture.model
            else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
            return EpisodeSourceDocument(model: decoded.payload, publication: decoded.publication)
        }
        let opens = fixture.content.total.opens
        let inventory = try await verifier.verify(episode: fixture.episodeID) { try current() }
        #expect(inventory.publication == original.publication)
        #expect(fixture.content.total.opens == opens)
        let replacement = try coder.encodeDocument(fixture.model, revision: 2, publicationID: UUID())
        try replacement.data.write(to: url, options: [.atomic])
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await verifier.verify(episode: fixture.episodeID) { try current() }
        }
        try original.data.write(to: url, options: [.atomic])
        let calls = Box(0)
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await verifier.verify(episode: fixture.episodeID) {
                if calls.update({ $0 += 1; return $0 }) == 4 {
                    try replacement.data.write(to: url, options: [.atomic])
                }
                return try current()
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

    @Test func fourthAccessStoreReadCannotOutliveReadyKey() async throws {
        let (fixture, store, _) = try await fixture()
        let accessStore = FinalReadInvalidatingStore(
            backing: store, coordinator: fixture.coordinator, source: fixture.id("backup")
        )
        let verifier = EpisodeSourceInventorySurveyor(
            showID: fixture.model.show.id, coordinator: fixture.coordinator,
            accessStore: accessStore, access: SourceAccessContext(io: SystemSourceIO())
        )
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapNotActive) {
            try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        #expect(await accessStore.reads == 4)
    }

    @Test func copiedOldShowYieldsOnlyUntrustedInventory() async throws {
        let (fixture, _, verifier) = try await fixture()
        let openURL = fixture.directory.url.appendingPathComponent("open.wwshow")
        let oldCopy = fixture.directory.url.appendingPathComponent("old-copy.wwshow")
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let original = try coder.encodeDocument(fixture.model, revision: 1, publicationID: UUID())
        try original.data.write(to: openURL)
        try original.data.write(to: oldCopy)
        let replacement = try coder.encodeDocument(fixture.model, revision: 2, publicationID: UUID())
        try replacement.data.write(to: openURL, options: [.atomic])
        // Deliberately caller-forged data can only yield an UNTRUSTED inventory from this package API.
        let forged = try coder.decode(Data(contentsOf: oldCopy))
        let inventory = try await verifier.survey(episode: fixture.episodeID) {
            EpisodeSourceDocument(model: forged.payload, publication: forged.publication)
        }
        #expect(inventory.publication == original.publication)
        #expect(inventory.completeCutPreparation == .refused([
            .protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified
        ]))
    }

    @Test func cancellingFourthDocumentCallbackCannotIssueWitness() async throws {
        let (fixture, _, verifier) = try await fixture()
        let calls = Box(0)
        // Cancel the verification *task*, not Swift Testing's enclosing test task (a cancelled
        // test is skipped and cannot establish this regression).
        let request = Task.detached {
            try await verifier.survey(episode: fixture.episodeID) {
                if calls.update({ $0 += 1; return $0 }) == 4 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return Self.document(fixture.model)
            }
        }
        await #expect(throws: CancellationError.self) {
            try await request.value
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

    @Test func coherentForgedReadyFactsCannotMintDecoderReceipt() async throws {
        let (fixture, _, verifier) = try await fixture()
        let source = fixture.id("primary")
        let slot = PipelineSlots.sourceFacts(source)
        guard case let .ready(key) = await fixture.coordinator.state(of: slot) else {
            Issue.record("source facts were not ready")
            return
        }
        var forged = try SourceFacts.decode(try #require(await fixture.coordinator.readyPayload(for: slot)))
        forged.interpretation.channelCount = 1
        forged.interpretation.output.channelCount = 1
        forged.interpretation.frames.primingFrames = -1
        forged.interpretation.origin.discardedLeadingStreamFrames = -1
        let bytes = try SourceFacts.encode(forged)
        await fixture.coordinator.invalidate(slot)
        let job = await fixture.coordinator.submit(slot, key: key) { bytes }
        #expect(await job.outcome == .published(key))
        let opened = fixture.content.record(fixture.url("primary")).opens
        let receipts = try await verifier.probeSources(
            episode: fixture.episodeID, decoder: fixture.decoder,
            authorizations: fixture.authorizations
        ) { Self.document(fixture.model) }
        #expect(receipts[source]?.interpretation.channelCount == 2)
        #expect(receipts[source]?.interpretation.frames.primingFrames == 0)
        #expect(fixture.content.record(fixture.url("primary")).opens > opened)
        fixture.model.episodes[0].sources[0].observations.channelCount = .known(1)
        await #expect(throws: EpisodeSourceAccessRefusal.decoderMismatch(source)) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: fixture.authorizations
            ) { Self.document(fixture.model) }
        }
    }

    @Test func sameKeyRepublishDuringHeaderProbeRefuses() async throws {
        let (fixture, _, verifier) = try await fixture()
        let source = fixture.id("primary")
        let slot = PipelineSlots.sourceFacts(source)
        guard case let .ready(key) = await fixture.coordinator.state(of: slot) else {
            Issue.record("source facts were not ready")
            return
        }
        let calls = Box(0)
        let baseline = fixture.content.total.opens
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: fixture.authorizations
            ) {
                if calls.update({ $0 += 1; return $0 }) == 5 {
                    await fixture.coordinator.invalidate(slot)
                    let job = await fixture.coordinator.submit(slot, key: key) {
                        Data("different-payload-at-same-key".utf8)
                    }
                    #expect(await job.outcome == .published(key))
                }
                return Self.document(fixture.model)
            }
        }
        #expect(calls.value >= 5)
        #expect(fixture.content.total.opens > baseline, "the replacement lands after the first header open")
    }

    @Test func oversizedSurveyInputsRefuseBeforeDecodeOrWholeShowTraversal() async throws {
        let (fixture, _, verifier) = try await fixture()
        let baseline = fixture.content.total.opens
        let original = fixture.model
        fixture.model.episodes += Array(repeating: Episode(title: "unrelated"), count: 65)
        await #expect(throws: EpisodeSourceAccessRefusal.inspectionLimit) {
            try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        fixture.model.episodes[0].alignment?.maps += Array(
            repeating: try #require(original.episodes[0].alignment?.maps[0]), count: 65
        )
        await #expect(throws: EpisodeSourceAccessRefusal.inspectionLimit) {
            try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        fixture.model.episodes[0].alignment?.maps[0].inputs.sources = Array(
            repeating: try #require(original.episodes[0].alignment?.maps[0].inputs.sources[0]), count: 257
        )
        await #expect(throws: EpisodeSourceAccessRefusal.inspectionLimit) {
            try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        fixture.model.episodes[0].alignment?.maps[0].map = .string(String(repeating: "x", count: 1_048_577))
        await #expect(throws: EpisodeSourceAccessRefusal.inspectionLimit) {
            try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        fixture.model = original
        fixture.model.episodes[0].alignment?.maps[0].inputs.sources[0].contentDigest = String(
            repeating: "x", count: 1_048_577
        )
        await #expect(throws: EpisodeSourceAccessRefusal.inspectionLimit) {
            try await verifier.survey(episode: fixture.episodeID) { Self.document(fixture.model) }
        }
        #expect(fixture.content.total.opens == baseline)
    }

    @Test func noBackupAuthorizationOrGrantNeverOpensBackup() async throws {
        let (fixture, store, verifier) = try await fixture()
        let backup = fixture.id("backup")
        let before = fixture.content.record(fixture.url("backup")).opens
        await #expect(throws: EpisodeSourceAccessRefusal.contentNotAuthorized(backup)) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: [.explicitUserRequest(for: fixture.id("primary"))]
            ) { Self.document(fixture.model) }
        }
        #expect(fixture.content.record(fixture.url("backup")).opens == before)
        try await store.removeRecord(for: DeviceAccessKey(showID: fixture.model.show.id, sourceID: backup))
        await #expect(throws: EpisodeSourceAccessRefusal.accessMissing(backup)) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: fixture.authorizations
            ) { Self.document(fixture.model) }
        }
        #expect(fixture.content.record(fixture.url("backup")).opens == before)
        await #expect(throws: EpisodeSourceAccessRefusal.inspectionLimit) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: Array(repeating: .explicitUserRequest(for: backup), count: 257)
            ) { Self.document(fixture.model) }
        }
        #expect(fixture.content.record(fixture.url("backup")).opens == before)
    }

    @Test func decodedHeaderLengthMustMatchAcceptedMapOccurrence() async throws {
        let (fixture, _, verifier) = try await fixture()
        let source = fixture.id("primary")
        fixture.content.register(fixture.url("primary"), .init(
            channels: 2, frames: 48_000, signal: .scene(seed: 81)
        ))
        await #expect(throws: EpisodeSourceAccessRefusal.decoderMismatch(source)) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: fixture.authorizations
            ) { Self.document(fixture.model) }
        }
    }

    @Test func headerOnlyOpenRejectsSourceReplacedInsideCursorBody() async throws {
        let (fixture, _, _) = try await fixture()
        let source = fixture.id("primary")
        let url = fixture.url("primary")
        let before = fixture.content.record(url).opens
        await #expect(throws: DecodeFailure.sourceChangedDuringDecode) {
            try await fixture.decoder.withDecodingCursor(url, source: source) { cursor in
                try fixture.rewrite("primary")
                return cursor.interpretation
            }
        }
        #expect(fixture.content.record(url).opens == before + 1)
        #expect(fixture.content.openReaders == 0)
    }

    @Test(arguments: ["revoke", "replace"])
    func postHeaderGrantOrSourceChangeRefuses(_ action: String) async throws {
        let (fixture, store, verifier) = try await fixture()
        let backup = fixture.id("backup")
        let calls = Box(0)
        let opened = fixture.content.total.opens
        let expected: EpisodeSourceAccessRefusal = action == "revoke"
            ? .accessMissing(backup) : .accessUnverified(backup)
        await #expect(throws: expected) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: fixture.authorizations
            ) {
                if calls.update({ $0 += 1; return $0 }) == 5 {
                    if action == "revoke" {
                        await store.removeRecord(for: DeviceAccessKey(
                            showID: fixture.model.show.id, sourceID: backup
                        ))
                    } else {
                        try fixture.rewrite("backup")
                    }
                }
                return Self.document(fixture.model)
            }
        }
        #expect(calls.value >= 5)
        #expect(fixture.content.total.opens > opened)
    }

    @Test(arguments: ["revoke", "relink"])
    func backupChangedWhileFirstHeaderProbeSuspendsNeverOpensBackup(_ action: String) async throws {
        let (fixture, store, verifier) = try await fixture()
        let firstURL = fixture.url("primary")
        let laterURL = fixture.url("backup")
        let later = fixture.id("backup")
        let key = DeviceAccessKey(showID: fixture.model.show.id, sourceID: later)
        var updated = try #require(await store.record(for: key))
        updated.bookmark = try SystemSourceIO().makeReadOnlyBookmark(for: firstURL)
        updated.lastKnownPath = firstURL.path
        let relinked = updated
        let completed = Box(false)
        let mutationError = Box<String?>(nil)
        let openedBefore = fixture.content.record(laterURL).opens
        fixture.content.setOnOpen { path in
            guard path == ProceduralContentIO.path(firstURL) else { return }
            // Only the decoder's private Dispatch worker waits; no cooperative-pool thread is blocked.
            let mutation = DispatchSemaphore(value: 0)
            Task.detached {
                if action == "revoke" {
                    await store.removeRecord(for: key)
                } else {
                    do {
                        try await store.save(relinked)
                    } catch {
                        mutationError.value = String(describing: error)
                    }
                }
                completed.value = true
                mutation.signal()
            }
            if mutation.wait(timeout: .now() + 10) == .timedOut {
                mutationError.value = "source mutation timed out"
            }
        }
        defer { fixture.content.setOnOpen(nil) }
        await #expect(throws: EpisodeSourceAccessRefusal.self) {
            try await verifier.probeSources(
                episode: fixture.episodeID, decoder: fixture.decoder,
                authorizations: fixture.authorizations
            ) { Self.document(fixture.model) }
        }
        #expect(completed.value)
        #expect(mutationError.value == nil)
        #expect(fixture.content.record(firstURL).opens > 0)
        #expect(fixture.content.record(laterURL).opens == openedBefore,
                "the stale Backup grant must be caught before any second source content open")
    }
}

private actor FinalReadInvalidatingStore: DeviceAccessStore {
    let backing: InMemoryDeviceAccessStore
    let coordinator: DerivedJobCoordinator
    let source: SourceID
    private(set) var reads = 0

    init(backing: InMemoryDeviceAccessStore, coordinator: DerivedJobCoordinator, source: SourceID) {
        self.backing = backing
        self.coordinator = coordinator
        self.source = source
    }

    func record(for key: DeviceAccessKey) async throws -> DeviceAccessRecord? {
        await backing.record(for: key)
    }

    func records(in showID: ShowID) async throws -> [DeviceAccessRecord] {
        let unchanged = await backing.records(in: showID)
        reads += 1
        if reads == 4 { await coordinator.removeSource(source) }
        return unchanged
    }

    func allRecords() async throws -> [DeviceAccessRecord] { await backing.allRecords() }
    func save(_ record: DeviceAccessRecord) async throws { await backing.save(record) }
    func save(_ records: [DeviceAccessRecord]) async throws { await backing.save(records) }
    func removeRecord(for key: DeviceAccessKey) async throws { await backing.removeRecord(for: key) }
    func removeRecords(in showID: ShowID) async throws { await backing.removeRecords(in: showID) }
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
