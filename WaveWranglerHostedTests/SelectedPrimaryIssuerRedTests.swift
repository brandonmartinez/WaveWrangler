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

/// RED: the app-private entry point is fail-closed and its DEBUG observers never fire.
/// Run only with the hosted test scheme's isolated UI-test storage and a GUI-host lease.
@MainActor
@Suite("RED app-owned selected Primary issuer", .serialized)
struct SelectedPrimaryIssuerRedTests {
    @Test func boundedSelectedPrimaryWindowNeverOpensBackup() async throws {
        try await withFixture { fixture in
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            defer { SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil }

            let result = try await fixture.read(startingAt: 4_000)
            #expect(result.channel == 1)
            #expect(result.sourceFrames == 4_000..<36_000)
            #expect(result.samples.count == 32_000)
            let allFinite = result.samples.allSatisfy { $0.isFinite }
            #expect(allFinite)
            #expect(result.samples == Array(fixture.primaryChannel1[4_000..<36_000]))
            #expect(opened == [fixture.primaryID])
            try fixture.assertMediaUnchanged()
        }
    }

    @Test(arguments: [false, true])
    func failClosedIntentCaptureRechecksSelectionOrDocumentABA(documentMutation: Bool) async throws {
        try await withFixture { fixture in
            var reached = false
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            SelectedPrimarySourceReadIssuer.debugPhaseObserver = { phase in
                guard phase == .afterIntentCapture else { return }
                reached = true
                if documentMutation {
                    let original = fixture.document.store.model
                    var changed = original
                    changed.show.title = "Transient synthetic title"
                    fixture.document.store.replaceLoadedModel(changed)
                    fixture.document.store.replaceLoadedModel(original)
                } else {
                    fixture.setup.selection = [.source(fixture.backupID)]
                    fixture.setup.selection = [.source(fixture.primaryID)]
                }
            }
            defer {
                SelectedPrimarySourceReadIssuer.debugPhaseObserver = nil
                SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil
            }

            if documentMutation {
                await #expect(throws: EpisodeSourceAccessRefusal.changedDuringVerification) {
                    try await fixture.read(startingAt: 0)
                }
            } else {
                await #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                    try await fixture.read(startingAt: 0)
                }
            }
            #expect(reached)
            #expect(opened.isEmpty)
            try fixture.assertMediaUnchanged()
        }
    }

    @Test(arguments: [false, true])
    func accessRemoveRestoreABACannotRegainAuthority(beforePublication: Bool) async throws {
        try await withFixture { fixture in
            var reached = false
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            SelectedPrimarySourceReadIssuer.debugPhaseObserver = { phase in
                guard phase == (beforePublication ? .beforePublication : .beforeDescriptorOpen) else { return }
                reached = true
                let store = SetupEngineProvider.store
                let record = try #require(await store.record(for: fixture.primaryKey))
                try await store.removeRecord(for: fixture.primaryKey)
                try await store.save(record)
            }
            defer {
                SelectedPrimarySourceReadIssuer.debugPhaseObserver = nil
                SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil
            }

            await #expect(throws: SelectedPrimarySourceReadRefusal.accessChanged) {
                try await fixture.read(startingAt: 0)
            }
            #expect(reached, "a generic refusal before the captured authority is not this RED case")
            #expect(opened == (beforePublication ? [fixture.primaryID] : []))
            try fixture.assertMediaUnchanged()
        }
    }

    @Test(arguments: [false, true], [false, true])
    func selectionAwayAndBackCannotRegainAuthority(
        beforePublication: Bool, speaker: Bool
    ) async throws {
        try await withFixture { fixture in
            var reached = false
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            SelectedPrimarySourceReadIssuer.debugPhaseObserver = { phase in
                guard phase == (beforePublication ? .beforePublication : .beforeDescriptorOpen) else { return }
                reached = true
                if speaker {
                    let original = fixture.setup.speakerSelection
                    fixture.setup.speakerSelection = [SpeakerID()]
                    fixture.setup.speakerSelection = original
                } else {
                    fixture.setup.selection = [.source(fixture.backupID)]
                    fixture.setup.selection = [.source(fixture.primaryID)]
                }
            }
            defer {
                SelectedPrimarySourceReadIssuer.debugPhaseObserver = nil
                SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil
            }

            await #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                try await fixture.read(startingAt: 0)
            }
            #expect(reached, "a refusal before the selected phase does not prove ABA revalidation")
            #expect(opened == (beforePublication ? [fixture.primaryID] : []))
            try fixture.assertMediaUnchanged()
        }
    }

    @Test(arguments: [false, true], [false, true])
    func acceptedMapAndDocumentABACannotRegainAuthority(
        beforePublication: Bool, oldMap: Bool
    ) async throws {
        try await withFixture { fixture in
            var reached = false
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            SelectedPrimarySourceReadIssuer.debugPhaseObserver = { phase in
                guard phase == (beforePublication ? .beforePublication : .beforeDescriptorOpen) else { return }
                reached = true
                let original = fixture.document.store.model
                var changed = original
                if oldMap {
                    changed.episodes[0].alignment?.acceptedRevision = nil
                } else {
                    changed.show.title = "Transient synthetic title"
                }
                fixture.document.store.replaceLoadedModel(changed)
                fixture.document.store.replaceLoadedModel(original)
            }
            defer {
                SelectedPrimarySourceReadIssuer.debugPhaseObserver = nil
                SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil
            }

            await #expect(throws: SelectedPrimarySourceReadRefusal.changedDuringVerification) {
                try await fixture.read(startingAt: 0)
            }
            #expect(reached, "a refusal before the selected phase does not prove ABA revalidation")
            #expect(opened == (beforePublication ? [fixture.primaryID] : []))
            try fixture.assertMediaUnchanged()
        }
    }

    @Test(arguments: [false, true])
    func cancellationAtOpenOrBeforePublicationNeverReturnsPCM(atPublication: Bool) async throws {
        try await withFixture { fixture in
            var reached = false
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            SelectedPrimarySourceReadIssuer.debugPhaseObserver = { phase in
                guard phase == (atPublication ? .beforePublication : .beforeDescriptorOpen) else { return }
                reached = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
            defer {
                SelectedPrimarySourceReadIssuer.debugPhaseObserver = nil
                SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil
            }

            await #expect(throws: CancellationError.self) {
                try await fixture.read(startingAt: 0)
            }
            #expect(reached, "a cancellation before the requested boundary is not this RED case")
            #expect(opened == (atPublication ? [fixture.primaryID] : []))
            try fixture.assertMediaUnchanged()
        }
    }

    @Test func backupRowAndWrongSpeakerRefuseBeforeAnyContentOpen() async throws {
        try await withFixture { fixture in
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            defer { SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil }
            fixture.setup.selection = [.source(fixture.backupID)]
            await #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                try await fixture.read(startingAt: 0)
            }
            fixture.setup.selection = [.source(fixture.primaryID)]
            fixture.setup.speakerSelection = [SpeakerID()]
            await #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                try await fixture.read(startingAt: 0)
            }
            #expect(opened.isEmpty)
            try fixture.assertMediaUnchanged()
        }
    }

    @Test func invalidChannelAndOutOfMapWindowRefuseBeforeContentOpen() async throws {
        try await withFixture { fixture in
            var opened: [SourceID] = []
            SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = { opened.append($0) }
            defer { SelectedPrimarySourceReadIssuer.debugSourceOpenObserver = nil }
            for start in [-1, 8_001, Int64.max] {
                await #expect(throws: SelectedPrimarySourceReadRefusal.windowOutsideMappedEpoch) {
                    try await fixture.read(startingAt: start)
                }
            }
            let original = fixture.document.store.model
            for channel in [-1, 2] {
                var invalid = original
                invalid.episodes[0].speakerAssignments[0].primary =
                    ChannelReference(sourceID: fixture.primaryID, statedChannel: channel)
                fixture.document.store.replaceLoadedModel(invalid)
                await #expect(throws: SelectedPrimarySourceReadRefusal.selectionUnavailable) {
                    try await fixture.read(startingAt: 0)
                }
            }
            fixture.document.store.replaceLoadedModel(original)
            #expect(opened.isEmpty)
            try fixture.assertMediaUnchanged()
        }
    }

    private func withFixture(
        _ test: @MainActor (SelectedPrimaryIssuerFixture) async throws -> Void
    ) async throws {
        let fixture = try await SelectedPrimaryIssuerFixture()
        do {
            try await test(fixture)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}

@MainActor
private final class SelectedPrimaryIssuerFixture {
    let document: ShowDocument
    let window: NSWindow
    let setup: EpisodeSetupModel
    let primaryID: SourceID
    let backupID: SourceID
    let primaryKey: DeviceAccessKey
    let primaryChannel1: [Float]

    private let folder: URL
    private let primary: URL
    private let backup: URL
    private let primaryBytes: Data
    private let backupBytes: Data
    private let backupKey: DeviceAccessKey

    init() async throws {
        // The hosted scheme must have enabled isolation at process launch, before the store's static init.
        guard PersistenceEnvironment.isUITestRun else {
            throw FixtureFailure.unisolatedStore
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("selected-primary-issuer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let primary = folder.appendingPathComponent("primary.wav")
        let backup = folder.appendingPathComponent("backup.wav")
        let primaryChannel1 = Self.samples(seed: 37)
        try Self.writeWAV(primary, channels: [Self.samples(seed: 11), primaryChannel1])
        try Self.writeWAV(backup, channels: [Self.samples(seed: 211)])
        let primaryBytes = try Data(contentsOf: primary)
        let backupBytes = try Data(contentsOf: backup)

        let io = SystemSourceIO()
        guard case let .success(primaryMetadata) = io.metadata(at: primary),
              case let .success(backupMetadata) = io.metadata(at: backup)
        else { throw FixtureFailure.metadata }
        let speaker = Speaker(name: "Synthetic speaker")
        let epoch = RecordingEpoch(label: "Synthetic take")
        let group = RecorderGroup(name: "Synthetic recorder", epochs: [epoch])
        let primarySource = SourceRecord(
            displayNameHint: "primary.wav", observations: .init(channelCount: .known(2)),
            placement: .init(recorderGroupID: group.id, epochID: epoch.id),
            role: .primary, roleConfirmation: .userConfirmed
        )
        let backupSource = SourceRecord(
            displayNameHint: "backup.wav", observations: .init(channelCount: .known(1)),
            placement: .init(recorderGroupID: group.id, epochID: epoch.id),
            role: .backup, roleConfirmation: .userConfirmed
        )
        let primaryID = primarySource.id
        let backupID = backupSource.id
        let primaryOccurrence = try SourceOccurrence(
            source: primaryID, nominalRate: NominalRate(16_000), frameCount: 40_000
        )
        let backupOccurrence = try SourceOccurrence(
            source: backupID, nominalRate: NominalRate(16_000), frameCount: 40_000
        )
        let reference = TimelineReference(
            group: group.id, epoch: epoch.id, occurrence: primaryOccurrence.id
        )
        let clock = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(Int64(3)),
            rateRatio: .one, alignedOffset: .zero
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [
            GroupTimeMap(
                group: group.id, reference: reference,
                epochs: [EpochClockMap(epoch: epoch.id, mapping: .mapped(
                    segments: [clock], provenance: .timelineReference
                ))],
                placements: [primaryOccurrence, backupOccurrence].map { occurrence in
                    OccurrencePlacement(occurrence: occurrence, spans: [
                        EpochSpan(
                            startFrame: 0, endFrame: 40_000, epoch: epoch.id,
                            groupClockOffset: .zero
                        )
                    ])
                }
            )
        ])
        let episode = Episode(
            title: "Synthetic", recorderGroups: [group], sources: [primarySource, backupSource],
            speakerAssignments: [SpeakerAssignment(
                speakerID: speaker.id,
                primary: ChannelReference(sourceID: primaryID, statedChannel: 1),
                primaryConfirmation: .userConfirmed,
                backups: [ChannelReference(sourceID: backupID, statedChannel: 0)]
            )]
        )
        let show = ShowDocumentModel(
            show: Show(title: "Synthetic"), speakers: [speaker], episodes: [episode]
        )
        let format = DerivedInputs().format
        let dependencies = [
            (primaryID, primaryMetadata.fingerprint), (backupID, backupMetadata.fingerprint)
        ].map { source, fingerprint in
            let revision = SourceRevision.metadata(source, fingerprint: fingerprint)
            return SourceRevision(
                source: source,
                token: "\(revision.token)|fiv=\(format.interpretationVersion)|env=\(format.envelopeVersion)|group=\(group.id)|epochs=\(epoch.id)"
            )
        }
        let digest = DerivedAssetKey(
            asset: AssetSpec(kind: "ww.alignment-dependencies", revision: 1), sources: dependencies
        ).digest
        let recorded = try show.recordingMap(
            map, in: episode.id,
            inputs: [primaryID, backupID].map {
                TimeMapSourceInput(sourceID: $0, formatInterpretationVersion: format.interpretationVersion)
            },
            recipe: RecipeReference(
                name: AlignmentAssetKinds.acceptanceRecipePrefix + digest,
                revision: AlignmentAssetKinds.acceptanceRecipeRevision
            )
        )
        let accepted = try recorded.model.acceptingMap(
            revision: recorded.revision.revision, in: episode.id
        )
        let showURL = folder.appendingPathComponent("open.wwshow")
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            accepted, revision: 1, publicationID: UUID()
        ).data
        try bytes.write(to: showURL)
        let raw = try NSDocumentController.shared.makeDocument(
            withContentsOf: showURL, ofType: DocumentTypes.show
        )
        let document = try #require(raw as? ShowDocument)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        document.showWindows()
        window.makeKeyAndOrderFront(nil)

        var ready: EpisodeSetupViewController?
        for _ in 0..<500 {
            if window.isKeyWindow,
               let state = ShowWindowRegistry.state(for: window),
               state.store === document.store, state.destination == .setup,
               state.selectedEpisodeID == episode.id,
               let controller = EpisodeSetupViewController.controller(for: window),
               controller.model.store === document.store,
               controller.model.episodeID == episode.id {
                ready = controller
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let setup = try #require(ready?.model, "real keyed Setup lifecycle did not attach")
        setup.speakerSelection = [speaker.id]
        setup.selection = [.source(primaryID)]
        _ = try setup.captureSelectedPrimarySource()

        let showID = accepted.show.id
        let primaryKey = DeviceAccessKey(showID: showID, sourceID: primaryID)
        let backupKey = DeviceAccessKey(showID: showID, sourceID: backupID)
        for (key, url, fingerprint) in [
            (primaryKey, primary, primaryMetadata.fingerprint),
            (backupKey, backup, backupMetadata.fingerprint)
        ] {
            try await SetupEngineProvider.store.save(DeviceAccessRecord(
                showID: key.showID, sourceID: key.sourceID,
                bookmark: try io.makeReadOnlyBookmark(for: url), lastKnownPath: url.path,
                recordedIdentity: RecordedIdentity(
                    fingerprint: fingerprint, confirmation: .userConfirmed, recordedAt: Date()
                ), createdAt: Date()
            ))
        }
        self.folder = folder
        self.primary = primary
        self.backup = backup
        self.primaryBytes = primaryBytes
        self.backupBytes = backupBytes
        self.primaryChannel1 = primaryChannel1
        self.primaryID = primaryID
        self.backupID = backupID
        self.document = document
        self.window = window
        self.setup = setup
        self.primaryKey = primaryKey
        self.backupKey = backupKey
    }

    func read(startingAt start: Int64) async throws -> SelectedPrimaryPCMWindow {
        try await SelectedPrimarySourceReadIssuer.readCheckedPrimaryWindow(
            for: document, in: window, startingAt: start
        )
    }

    func assertMediaUnchanged() throws {
        #expect(try Data(contentsOf: primary) == primaryBytes)
        #expect(try Data(contentsOf: backup) == backupBytes)
    }

    func close() async throws {
        window.close()
        NSDocumentController.shared.removeDocument(document)
        try await SetupEngineProvider.store.removeRecord(for: primaryKey)
        try await SetupEngineProvider.store.removeRecord(for: backupKey)
        try FileManager.default.removeItem(at: folder)
    }

    private static func samples(seed: Int) -> [Float] {
        (0..<40_000).map { frame in Float((frame &* 31 &+ seed) % 50_000 - 25_000) / 32_768 }
    }

    private static func writeWAV(_ url: URL, channels: [[Float]]) throws {
        let count = channels[0].count
        let channelCount = channels.count
        let dataSize = count * channelCount * 2
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        text("RIFF"); u32(UInt32(36 + dataSize)); text("WAVEfmt ")
        u32(16); u16(1); u16(UInt16(channelCount)); u32(16_000)
        u32(UInt32(16_000 * channelCount * 2)); u16(UInt16(channelCount * 2)); u16(16)
        text("data"); u32(UInt32(dataSize))
        for frame in 0..<count {
            for channel in channels {
                u16(UInt16(bitPattern: Int16(channel[frame] * 32_768)))
            }
        }
        try bytes.write(to: url)
    }

    private enum FixtureFailure: Error {
        case unisolatedStore
        case metadata
    }
}
