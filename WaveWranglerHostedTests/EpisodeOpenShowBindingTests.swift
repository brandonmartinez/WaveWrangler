import AppKit
import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDerived
import WWEpisodeSetup
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

    @Test func equalModelAfterReloadDoesNotRestoreAnOldBinding() async throws {
        let opened = try open()
        defer { opened.close() }
        let binding = try OpenShowSourceBinding.capture(for: opened.document)
        var other = opened.document.store.model
        other.show.title = "Other synthetic title"
        opened.document.store.replaceLoadedModel(other)
        opened.document.store.replaceLoadedModel(try #require(opened.document.verifiedModel))
        #expect(opened.document.currentSourcePublication != nil)
        await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
            try await binding.current()
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

    @Test func issuerRefusesAnUnregisteredWindowWithoutOpeningAnySource() async throws {
        let opened = try open()
        defer { opened.close() }
        let unrelatedWindow = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        await #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try await SelectedPrimarySourceReadIssuer.requireSourceReadAuthority(
                for: opened.document, in: unrelatedWindow, startingAt: 0
            )
        }
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await SelectedPrimarySourceReadIssuer.requireSourceReadAuthority(
                for: opened.document, in: unrelatedWindow, startingAt: 0
            )
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}

@MainActor
@Suite("App-owned selected Primary intent")
struct SelectedPrimarySourceIntentTests {
    private func setup() -> (
        EpisodeSetupModel, EpisodeID, SpeakerID, SourceID, SourceID
    ) {
        let speaker = Speaker(name: "Synthetic speaker")
        let epoch = RecordingEpoch(label: "Synthetic take")
        let group = RecorderGroup(name: "Synthetic recorder", epochs: [epoch])
        let primary = SourceRecord(
            displayNameHint: "generated-primary", observations: .init(channelCount: .known(2)),
            placement: .init(recorderGroupID: group.id, epochID: epoch.id),
            role: .primary, roleConfirmation: .userConfirmed
        )
        let backup = SourceRecord(
            displayNameHint: "generated-backup", observations: .init(channelCount: .known(1)),
            role: .backup, roleConfirmation: .userConfirmed
        )
        let episode = Episode(
            title: "Synthetic", recorderGroups: [group], sources: [primary, backup],
            speakerAssignments: [SpeakerAssignment(
                speakerID: speaker.id,
                primary: ChannelReference(sourceID: primary.id, statedChannel: 1),
                primaryConfirmation: .userConfirmed,
                backups: [ChannelReference(sourceID: backup.id, statedChannel: 0)]
            )]
        )
        let document = ShowDocumentModel(
            show: Show(title: "Synthetic"), speakers: [speaker], episodes: [episode]
        )
        let engine = WWSourcesSetupEngine(
            showID: document.show.id, store: InMemoryDeviceAccessStore()
        )
        let setup = EpisodeSetupModel(
            store: ShowDocumentStore(model: document), episodeID: episode.id,
            engine: engine, preference: AppSettingsDownloadPreference.shared
        )
        setup.isOnScreen = true
        setup.speakerSelection = [speaker.id]
        setup.selection = [.source(primary.id)]
        return (setup, episode.id, speaker.id, primary.id, backup.id)
    }

    @Test func selectionDoesNotReplayAfterSpeakerOrSourceABA() throws {
        let (setup, episode, speaker, primary, backup) = setup()
        let first = try setup.captureSelectedPrimarySource()
        #expect(first.episode == episode)
        #expect(first.speaker == speaker)
        #expect(first.channel == ChannelReference(sourceID: primary, statedChannel: 1))
        #expect(setup.isCurrentSelectedPrimarySource(first))

        setup.speakerSelection = []
        setup.speakerSelection = [speaker]
        #expect(!setup.isCurrentSelectedPrimarySource(first))
        let second = try setup.captureSelectedPrimarySource()
        setup.selection = [.source(backup)]
        setup.selection = [.source(primary)]
        #expect(!setup.isCurrentSelectedPrimarySource(second))
        let third = try setup.captureSelectedPrimarySource()
        setup.isOnScreen = false
        setup.isOnScreen = true
        #expect(!setup.isCurrentSelectedPrimarySource(third))
    }

    @Test func sidebarAndDestinationABACannotRestoreWindowIntent() throws {
        let (setup, episode, _, _, _) = setup()
        let windowState = ShowWindowState(store: setup.store)
        let initial = try #require(windowState.captureSourceReadGeneration())
        windowState.sidebarSelection = .showInfo
        windowState.sidebarSelection = .episode(episode)
        #expect(!windowState.isCurrentSourceReadGeneration(initial))
        let returned = try #require(windowState.captureSourceReadGeneration())
        windowState.destination = .alignment
        windowState.destination = .setup
        #expect(!windowState.isCurrentSourceReadGeneration(returned))
    }

    @Test func backupAndUnconfirmedSelectionsNeverProduceIntent() throws {
        let (setup, _, _, primary, backup) = setup()
        setup.selection = [.source(backup)]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.selection = [.source(primary)]
        var changed = setup.store.model
        changed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        setup.store.replaceLoadedModel(changed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
    }

    @Test func primaryRequiresConfirmedRoleAndInRangeChannel() throws {
        let (setup, _, speaker, primary, _) = setup()
        let original = setup.store.model
        for channel in [-1, 2] {
            var changed = original
            changed.episodes[0].speakerAssignments[0].primary =
                ChannelReference(sourceID: primary, statedChannel: channel)
            setup.store.replaceLoadedModel(changed)
            #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                try setup.captureSelectedPrimarySource()
            }
        }
        var unconfirmed = original
        unconfirmed.episodes[0].sources[0].roleConfirmation = .provisional
        setup.store.replaceLoadedModel(unconfirmed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.store.replaceLoadedModel(original)
        setup.speakerSelection = [SpeakerID()]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.speakerSelection = [speaker]
        #expect(try setup.captureSelectedPrimarySource().channel.statedChannel == 1)
    }

    @Test func sourceRemovalAndAlignmentDocumentABANeverRestoreOldGeneration() throws {
        let (setup, _, _, primary, _) = setup()
        let intent = try setup.captureSelectedPrimarySource()
        let original = setup.store.model
        let beforeRemoval = try #require(setup.store.captureMutationGeneration())
        var removed = original
        removed.episodes[0].sources.removeAll { $0.id == primary }
        setup.store.replaceLoadedModel(removed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.store.replaceLoadedModel(original)
        #expect(!setup.store.isCurrentMutationGeneration(beforeRemoval))
        #expect(setup.isCurrentSelectedPrimarySource(intent),
                "intent alone cannot attest to document or access-store generation")

        let beforeAlignment = try #require(setup.store.captureMutationGeneration())
        var changed = original
        changed.episodes[0].alignment = EpisodeAlignment()
        setup.store.replaceLoadedModel(changed)
        setup.store.replaceLoadedModel(original)
        #expect(!setup.store.isCurrentMutationGeneration(beforeAlignment))
    }

    @Test func multipleReferencesRequireTheSpecificPrimaryChannelRow() throws {
        let (setup, _, speaker, primary, _) = setup()
        var changed = setup.store.model
        let other = Speaker(name: "Other synthetic speaker")
        changed.speakers.append(other)
        changed.episodes[0].speakerAssignments.append(SpeakerAssignment(
            speakerID: other.id,
            backups: [ChannelReference(sourceID: primary, statedChannel: 0)]
        ))
        setup.store.replaceLoadedModel(changed)
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
        setup.selection = [.channel(primary, speaker)]
        #expect(try setup.captureSelectedPrimarySource().channel
                == ChannelReference(sourceID: primary, statedChannel: 1))
        setup.speakerSelection = [other.id]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
    }

    @Test func sameSpeakerDuplicateChannelRowsAreAmbiguous() {
        let (setup, _, speaker, primary, _) = setup()
        var changed = setup.store.model
        changed.episodes[0].speakerAssignments[0].backups.append(
            ChannelReference(sourceID: primary, statedChannel: 0)
        )
        setup.store.replaceLoadedModel(changed)
        setup.selection = [.channel(primary, speaker)]
        #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
            try setup.captureSelectedPrimarySource()
        }
    }

    @Test func portableMapWindowChecksAreNotContentGrants() throws {
        let (setup, episodeID, _, primary, _) = setup()
        let episode = try #require(setup.store.model.episode(episodeID))
        let group = try #require(episode.recorderGroups.first)
        let epoch = try #require(group.epochs.first)
        let occurrence = try SourceOccurrence(
            source: primary, nominalRate: NominalRate(16_000), frameCount: 40_000
        )
        let reference = TimelineReference(
            group: group.id, epoch: epoch.id, occurrence: occurrence.id
        )
        let clock = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(Int64(3)),
            rateRatio: .one, alignedOffset: .zero
        )
        let groupMap = try GroupTimeMap(
            group: group.id, reference: reference,
            epochs: [EpochClockMap(epoch: epoch.id, mapping: .mapped(
                segments: [clock], provenance: .timelineReference
            ))],
            placements: [OccurrencePlacement(
                occurrence: occurrence,
                spans: [EpochSpan(
                    startFrame: 0, endFrame: 40_000, epoch: epoch.id, groupClockOffset: .zero
                )]
            )]
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [groupMap])
        let recorded = try setup.store.model.recordingMap(map, in: episodeID)
        let accepted = try recorded.model.acceptingMap(
            revision: recorded.revision.revision, in: episodeID
        )
        setup.store.replaceLoadedModel(accepted)
        let intent = try setup.captureSelectedPrimarySource()
        try SelectedPrimarySourceReadIssuer.validatePortableMapWindow(
            model: accepted, selection: intent, startingAt: 0
        )
        try SelectedPrimarySourceReadIssuer.validatePortableMapWindow(
            model: accepted, selection: intent, startingAt: 8_000
        )
        for start in [-1, 8_001, Int64.max] {
            #expect(throws: SelectedPrimarySourceReadRefusal.windowOutsideMappedEpoch) {
                try SelectedPrimarySourceReadIssuer.validatePortableMapWindow(
                    model: accepted, selection: intent, startingAt: start
                )
            }
        }
        var stale = accepted
        stale.episodes[0].alignment?.acceptedRevision = nil
        #expect(throws: SelectedPrimarySourceReadRefusal.acceptedMapUnavailable) {
            try SelectedPrimarySourceReadIssuer.validatePortableMapWindow(
                model: stale, selection: intent, startingAt: 0
            )
        }
    }
}
