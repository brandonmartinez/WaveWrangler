import AppKit
import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDecode
import WWPersistence
import WWSources
import WWTimeMap
import WWEpisodeSetup
@testable import WaveWrangler

@MainActor
@Suite("Open selected-Primary PCM issuer (synthetic only)", .serialized)
struct PrimarySpeechIssuerHostedTests {
    private struct Fixture {
        let folder: URL
        let media: URL
        let backup: URL
        let document: ShowDocument
        let state: ShowWindowState
        let setup: EpisodeSetupModel
        let setupController: EpisodeSetupViewController
        let accessStore: FileDeviceAccessStore
        let source: SourceRecord
        let speaker: Speaker
        let episode: Episode
        let window: NSWindow

        func close() {
            NSDocumentController.shared.removeDocument(document)
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func fixture(
        waveRate: Int = 16_000, mutate: ((inout ShowDocumentModel) -> Void)? = nil
    ) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = folder.appendingPathComponent("primary.wav")
        let backup = folder.appendingPathComponent("backup.wav")
        try Self.wave(rate: waveRate).write(to: media)
        try Self.wave().write(to: backup)
        let io = SystemSourceIO()
        guard case let .success(metadata) = io.metadata(at: media) else { throw DecodeFailure.notFound }
        let witness = try await SourceDecoder(access: SourceAccessContext(io: io))
            .captureRawIdentity(media, matching: metadata.fingerprint)
        let epoch = RecordingEpoch(label: "Synthetic")
        let group = RecorderGroup(name: "Selected Primary", epochs: [epoch])
        var source = SourceRecord(
            displayNameHint: "Synthetic Primary", placement: .init(recorderGroupID: group.id, epochID: epoch.id),
            role: .primary, roleConfirmation: .userConfirmed
        )
        source.observations.channelCount = .known(1)
        source.observations.sampleRate = .known(16_000)
        let speaker = Speaker(name: "Synthetic speaker")
        let other = SourceRecord(displayNameHint: "Synthetic Backup", role: .backup, roleConfirmation: .userConfirmed)
        let channel = ChannelReference(sourceID: source.id, statedChannel: 0)
        let episode = Episode(
            title: "Synthetic episode", recorderGroups: [group], sources: [source, other],
            speakerAssignments: [.init(
                speakerID: speaker.id, primary: channel, primaryConfirmation: .userConfirmed,
                backups: [ChannelReference(sourceID: other.id, statedChannel: 0)]
            )]
        )
        let occurrence = try SourceOccurrence(source: source.id, nominalRate: NominalRate(16_000), frameCount: 32_000)
        let reference = TimelineReference(group: group.id, epoch: epoch.id, occurrence: occurrence.id)
        let clock = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(2), rateRatio: .one, alignedOffset: .zero
        )
        let map = try AlignedTimelineMap(
            reference: reference, groups: [GroupTimeMap(
                group: group.id, reference: reference,
                epochs: [.init(epoch: epoch.id, mapping: .mapped(segments: [clock], provenance: .timelineReference))],
                placements: [.init(occurrence: occurrence, spans: [
                    .init(startFrame: 0, endFrame: 32_000, epoch: epoch.id, groupClockOffset: .zero)
                ])]
            )]
        )
        let initial = ShowDocumentModel(
            show: Show(title: "Synthetic issuer"), speakers: [speaker], episodes: [episode]
        )
        let recorded = try initial.recordingMap(
            map, in: episode.id, inputs: [.init(sourceID: source.id, formatInterpretationVersion: 1)]
        )
        var accepted = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: episode.id)
        mutate?(&accepted)
        let url = folder.appendingPathComponent("show.wwshow")
        let encoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            accepted, revision: 1, publicationID: UUID()
        )
        try encoded.data.write(to: url)
        let raw = try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show)
        let document = try #require(raw as? ShowDocument)
        NSDocumentController.shared.addDocument(document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: .titled, backing: .buffered, defer: false
        )
        let state = ShowWindowState(store: document.store)
        state.attach(to: window)
        let setup = EpisodeSetupModel(
            store: document.store, episodeID: episode.id,
            engine: InMemorySourceSetupEngine(),
            preference: UserDefaultsSourceDownloadPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        setup.isOnScreen = true
        setup.speakerSelection = [speaker.id]
        let setupController = EpisodeSetupViewController(model: setup)
        setupController.attach(to: window)
        let accessStore = FileDeviceAccessStore(fileURL: folder.appendingPathComponent("access.json"))
        try await accessStore.save(DeviceAccessRecord(
            showID: accepted.show.id, sourceID: source.id,
            bookmark: try io.makeReadOnlyBookmark(for: media), lastKnownPath: media.path,
            recordedIdentity: RecordedIdentity(
                fingerprint: metadata.fingerprint, confirmation: .userConfirmed,
                recordedAt: Date(), rawWitness: witness
            ), createdAt: Date()
        ))
        return Fixture(
            folder: folder, media: media, backup: backup, document: document, state: state,
            setup: setup, setupController: setupController,
            accessStore: accessStore, source: source, speaker: speaker, episode: episode, window: window
        )
    }

    private static func wave(rate: Int = 16_000) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        put(UInt32(36 + 32_000 * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(rate))
        put(UInt32(rate * 2))
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: "data".utf8)
        put(UInt32(32_000 * 2))
        for _ in 0..<32_000 { put(Int16(8_192)) }
        return data
    }

    @Test func currentRegisteredShowIssuesOnlyItsConfirmedPrimary() async throws {
        let f = try await fixture()
        defer { f.close() }
        let window = try await OpenSelectedPrimaryPCMSource.issueSynthetic(
            for: f.setup, accessStore: f.accessStore
        )
        #expect(window.source == f.source.id)
        #expect(window.samples.count == 32_000)
        #expect(window.samples.allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(f.setup.captureSelectedPrimaryTranscriptReviewBinding() != nil)
    }

    @Test func replacedSourceRefusesInsteadOfReadingAPathSubstitute() async throws {
        let f = try await fixture()
        defer { f.close() }
        try Self.wave().write(to: f.media, options: [.atomic])
        await #expect(throws: PrimaryPCMRefusal.sourceChanged) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
    }

    @Test func backupPromotionAndEpisodeSwitchRefuseWithoutBackupAccess() async throws {
        let f = try await fixture()
        defer { f.close() }
        var changed = f.document.store.model
        changed.episodes[0].sources[0].role = .backup
        f.document.store.replaceLoadedModel(changed)
        await #expect(throws: PrimaryPCMRefusal.selectionChanged) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
        f.document.store.replaceLoadedModel(try #require(f.document.verifiedModel))
        f.state.sidebarSelection = .showInfo
        await #expect(throws: PrimaryPCMRefusal.selectionChanged) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
    }

    @Test func recordABAAndCancellationRefuse() async throws {
        let f = try await fixture()
        defer { f.close() }
        let key = DeviceAccessKey(showID: f.document.store.model.show.id, sourceID: f.source.id)
        let original = try #require(try await f.accessStore.record(for: key))
        let store = MutatingSnapshotStore(base: f.accessStore, replacement: original)
        await #expect(throws: PrimaryPCMRefusal.accessChanged) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: store)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func replacedSetupAfterStoreAwaitCannotIssueEvenForSameSpeakerAndModel() async throws {
        let f = try await fixture()
        defer { f.close() }
        let originalGeneration = f.document.store.modelGeneration
        let replacement = EpisodeSetupModel(
            store: f.document.store, episodeID: f.episode.id,
            engine: InMemorySourceSetupEngine(),
            preference: UserDefaultsSourceDownloadPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        replacement.isOnScreen = true
        replacement.speakerSelection = [f.speaker.id]
        let replacementController = EpisodeSetupViewController(model: replacement)
        let store = MutatingSnapshotStore(base: f.accessStore) {
            f.setup.isOnScreen = false
            replacementController.attach(to: f.window)
            f.state.setupModelDidAttach(replacement)
        }
        await #expect(throws: PrimaryPCMRefusal.selectionChanged) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: store)
        }
        #expect(f.document.store.modelGeneration == originalGeneration)
    }

    @Test func changedMapEpochCannotIssuePCM() async throws {
        let f = try await fixture {
            let later = RecordingEpoch(label: "Later synthetic epoch")
            $0.episodes[0].recorderGroups[0].epochs.append(later)
            $0.episodes[0].sources[0].placement.epochID = later.id
        }
        defer { f.close() }
        await #expect(throws: PrimaryPCMRefusal.unmappedPrimary) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
    }

    @Test func mismatchedDecodeInterpretationCannotIssueMappedPCM() async throws {
        let f = try await fixture {
            $0.episodes[0].alignment?.maps[0].inputs.sources[0].formatInterpretationVersion = 2
        }
        defer { f.close() }
        await #expect(throws: PrimaryPCMRefusal.unmappedPrimary) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
    }

    @Test func mismatchedObservedRateCannotIssueMappedPCM() async throws {
        let f = try await fixture {
            $0.episodes[0].sources[0].observations.sampleRate = .known(48_000)
        }
        defer { f.close() }
        await #expect(throws: PrimaryPCMRefusal.unmappedPrimary) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
    }

    @Test func unsupportedDecodedRateReportsMissingConversion() async throws {
        let f = try await fixture(waveRate: 48_000)
        defer { f.close() }
        await #expect(throws: WitnessBoundPCMWindowFailure.unsupportedSampleRate(48_000)) {
            _ = try await OpenSelectedPrimaryPCMSource.issueSynthetic(for: f.setup, accessStore: f.accessStore)
        }
    }
}

private actor MutatingSnapshotStore: DeviceAccessSnapshotStore {
    let base: FileDeviceAccessStore
    let replacement: DeviceAccessRecord?
    let onFirstSnapshot: (@MainActor @Sendable () -> Void)?
    var first = true

    init(
        base: FileDeviceAccessStore, replacement: DeviceAccessRecord? = nil,
        onFirstSnapshot: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.base = base
        self.replacement = replacement
        self.onFirstSnapshot = onFirstSnapshot
    }

    func snapshot(for key: DeviceAccessKey) async throws -> DeviceAccessSnapshot? {
        let previous = try await base.snapshot(for: key)
        if first {
            first = false
            if let replacement { try await base.save(replacement) }
            await onFirstSnapshot?()
        }
        return previous
    }
    func record(for key: DeviceAccessKey) async throws -> DeviceAccessRecord? { try await base.record(for: key) }
    func records(in showID: ShowID) async throws -> [DeviceAccessRecord] { try await base.records(in: showID) }
    func allRecords() async throws -> [DeviceAccessRecord] { try await base.allRecords() }
    func save(_ record: DeviceAccessRecord) async throws { try await base.save(record) }
    func save(_ records: [DeviceAccessRecord]) async throws { try await base.save(records) }
    func removeRecord(for key: DeviceAccessKey) async throws { try await base.removeRecord(for: key) }
    func removeRecords(in showID: ShowID) async throws { try await base.removeRecords(in: showID) }
}
