import AppKit
import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap
@testable import WaveWrangler

/// Hosted by the actual app; the existing unhosted WaveWranglerTests cannot reference ShowDocument.
/// All files and shows are synthetic. These tests must run only under a GUI-host lease.
@MainActor
@Suite("Open-show source inventory binding", .serialized)
struct EpisodeOpenShowBindingTests {
    @MainActor private struct Opened {
        let document: ShowDocument
        let url: URL
        let data: Data
        let folder: URL

        func close() {
            NSDocumentController.shared.removeDocument(document)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func open(model: ShowDocumentModel = .untitled()) throws -> Opened {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("open.wwshow")
        let encoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            model, revision: 1, publicationID: UUID()
        )
        try encoded.data.write(to: url)
        let raw = try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show)
        let document = try #require(raw as? ShowDocument)
        NSDocumentController.shared.addDocument(document)
        return Opened(document: document, url: url, data: encoded.data, folder: folder)
    }

    @Test func currentMappedOpenShowIssuesOnlyPrivateReadOnlySnapshot() async throws {
        let mediaFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaFolder) }
        let media = mediaFolder.appendingPathComponent("synthetic.wav")
        try Data(repeating: 0x5A, count: 4096).write(to: media)
        let io = SystemSourceIO()
        guard case let .success(metadata) = io.metadata(at: media) else { throw POSIXError(.ENOENT) }

        let epoch = RecordingEpoch(label: "Synthetic take")
        let group = RecorderGroup(name: "Primary", epochs: [epoch])
        var source = SourceRecord(
            displayNameHint: "synthetic.wav", placement: SourcePlacement(recorderGroupID: group.id, epochID: epoch.id)
        )
        source.observations.channelCount = .known(2)
        let occurrence = try SourceOccurrence(source: source.id, nominalRate: NominalRate(48_000), frameCount: 48_000)
        let reference = TimelineReference(group: group.id, epoch: epoch.id, occurrence: occurrence.id)
        let clock = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: .one, rateRatio: .one, alignedOffset: .zero
        )
        let mappedGroup = try GroupTimeMap(
            group: group.id, reference: reference,
            epochs: [EpochClockMap(epoch: epoch.id, mapping: .mapped(segments: [clock], provenance: .timelineReference))],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                EpochSpan(startFrame: 0, endFrame: 48_000, epoch: epoch.id, groupClockOffset: .zero)
            ])]
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [mappedGroup])
        let revision = SourceRevision.metadata(source.id, fingerprint: metadata.fingerprint)
        let format = DerivedInputs().format
        let dependency = SourceRevision(
            source: source.id,
            token: "\(revision.token)|fiv=\(format.interpretationVersion)|env=\(format.envelopeVersion)|group=\(group.id)|epochs=\(epoch.id)"
        )
        let digest = DerivedAssetKey(
            asset: AssetSpec(kind: "ww.alignment-dependencies", revision: 1), sources: [dependency]
        ).digest
        let episode = Episode(title: "Synthetic", recorderGroups: [group], sources: [source])
        let initial = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        let recorded = try initial.recordingMap(
            map, in: episode.id,
            inputs: [TimeMapSourceInput(sourceID: source.id, formatInterpretationVersion: format.interpretationVersion)],
            recipe: RecipeReference(
                name: AlignmentAssetKinds.acceptanceRecipePrefix + digest,
                revision: AlignmentAssetKinds.acceptanceRecipeRevision
            )
        )
        let accepted = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: episode.id)
        let opened = try open(model: accepted)
        defer { opened.close() }
        let key = DeviceAccessKey(showID: accepted.show.id, sourceID: source.id)
        try await SetupEngineProvider.store.save(DeviceAccessRecord(
            showID: key.showID, sourceID: key.sourceID, bookmark: try io.makeReadOnlyBookmark(for: media),
            lastKnownPath: media.path,
            recordedIdentity: RecordedIdentity(
                fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
            ), createdAt: Date()
        ))
        defer { Task { try? await SetupEngineProvider.store.removeRecord(for: key) } }
        let snapshot = try await AlignmentRuntimeProvider.sourceInventorySnapshot(
            for: opened.document, episode: episode.id
        )
        #expect(snapshot.inventory.lanes.count == 2)
        #expect(snapshot.inventory.completeCutPreparation == .refused([
            .protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified
        ]))
        try await snapshot.reverify()
        try await SetupEngineProvider.store.removeRecord(for: key)
        await #expect(throws: EpisodeSourceAccessRefusal.accessMissing(source.id)) {
            try await snapshot.reverify()
        }
        let runtime = try await AlignmentRuntimeProvider.runtime(for: opened.document, episode: episode.id)
        await runtime.coordinator.removeSource(source.id)
        await #expect(throws: EpisodeSourceAccessRefusal.acceptedMapStale) {
            try await snapshot.reverify()
        }
    }

    @Test func currentOpenShowReturnsItsActualVerifiedPublication() async throws {
        let opened = try open()
        defer { opened.close() }
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        let current = try await binding.current()
        #expect(current.model == opened.document.verifiedModel)
        #expect(current.publication == RevisionFingerprint(of: opened.data).publication)
        // An honestly open show passes the issuer's trust boundary. This empty synthetic show
        // has no episode/map, so the survey must refuse rather than issue a false-positive snapshot.
        await #expect(throws: EpisodeSourceAccessRefusal.episodeMissing) {
            try await AlignmentRuntimeProvider.sourceInventorySnapshot(
                for: opened.document, episode: EpisodeID()
            )
        }
    }

    @Test func oldCopiedShowCannotStandInForReplacedOpenShow() async throws {
        let opened = try open()
        defer { opened.close() }
        let copy = opened.folder.appendingPathComponent("old-copy.wwshow")
        try opened.data.write(to: copy)
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        let newBytes = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            opened.document.store.model, revision: 2, publicationID: UUID()
        ).data
        try newBytes.write(to: opened.url, options: [.atomic])
        #expect(RevisionFingerprint(of: try Data(contentsOf: copy)) == RevisionFingerprint(of: opened.data))
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await binding.current()
        }
        // Exercise the real app issuer as well: it must refuse *before* trusting any package survey.
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await AlignmentRuntimeProvider.sourceInventorySnapshot(
                for: opened.document, episode: EpisodeID()
            )
        }
    }

    @Test func externalSameModelReplacementCannotRebind() async throws {
        let opened = try open()
        defer { opened.close() }
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        let replaced = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            opened.document.store.model, revision: 1, publicationID: UUID()
        )
        try replaced.data.write(to: opened.url, options: [.atomic])
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await binding.current()
        }
    }

    @Test func saveAsChangesTheCanonicalURLAndInvalidatesBinding() async throws {
        let opened = try open()
        defer { opened.close() }
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        let destination = opened.folder.appendingPathComponent("saved-as.wwshow")
        let failure = await withCheckedContinuation { continuation in
            opened.document.save(
                to: destination, ofType: DocumentTypes.show, for: .saveAsOperation
            ) { continuation.resume(returning: $0) }
        }
        if let failure { throw failure }
        #expect(opened.document.fileURL?.standardizedFileURL == destination.standardizedFileURL)
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await binding.current()
        }
    }

    @Test func dirtyOrClosedShowCannotIssueOrRetainBinding() async throws {
        let opened = try open()
        defer { opened.close() }
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        opened.document.updateChangeCount(.changeDone)
        #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try OpenShowSourceBinding.capture(for: opened.document)
        }
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await binding.current()
        }
        opened.document.updateChangeCount(.changeCleared)
        let clean = try OpenShowSourceBinding.capture(for: opened.document)
        NSDocumentController.shared.removeDocument(opened.document)
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await clean.current()
        }
    }

    @Test func duplicateShowIDAcrossOpenDocumentsRefusesRatherThanChooseOne() throws {
        let opened = try open()
        defer { opened.close() }
        let other = try open(model: opened.document.store.model)
        defer { other.close() }
        #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try OpenShowSourceBinding.capture(for: opened.document)
        }
    }

    @Test func cancelledOpenShowReadNeverIssuesDocument() async throws {
        let opened = try open()
        defer { opened.close() }
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        let request = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await binding.current()
        }
        await #expect(throws: CancellationError.self) {
            try await request.value
        }
    }
}
