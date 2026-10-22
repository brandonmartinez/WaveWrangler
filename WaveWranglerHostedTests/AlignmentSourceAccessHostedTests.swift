import AppKit
import Foundation
import Testing
import WWCore
import WWDecode
import WWEpisodeSetup
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Alignment source-access presentation", .serialized)
struct AlignmentSourceAccessHostedTests {
    @Test func legacyApprovalListsAllSourcesAndReportsPartialAuthorizationHonestly() async throws {
        let fixture = try await fixture(corrupt: false)
        defer { fixture.close() }
        let context = SourceAccessContext(io: SystemSourceIO())
        let store = InMemoryDeviceAccessStore()
        let sources = [SourceRecord(displayNameHint: "older-one.wav"), SourceRecord(displayNameHint: "older-two.wav")]
        let episode = Episode(id: fixture.episode, title: "Older recordings", sources: sources)
        fixture.document.store.replaceLoadedModel(ShowDocumentModel(
            show: fixture.document.store.model.show, episodes: [episode]))
        for source in sources {
            let url = fixture.folder.appending(path: source.displayNameHint)
            try Data(repeating: 3, count: 64).write(to: url)
            guard case let .success(metadata) = context.io.metadata(at: url) else {
                Issue.record("Synthetic source metadata unavailable")
                return
            }
            try await store.save(DeviceAccessRecord(
                showID: fixture.document.store.model.show.id, sourceID: source.id,
                bookmark: context.io.makeReadOnlyBookmark(for: url), lastKnownPath: url.path,
                recordedIdentity: RecordedIdentity(fingerprint: metadata.fingerprint,
                    confirmation: .provisional, recordedAt: Date()), createdAt: Date()
            ))
        }
        let engine = WWSourcesSetupEngine(
            showID: fixture.document.store.model.show.id, store: store, context: context,
            captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        let setup = EpisodeSetupModel(store: fixture.document.store, episodeID: episode.id, engine: engine,
                                      preference: AppSettingsDownloadPreference.shared)
        setup.statuses = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.id, SourceStatusSnapshot(location: .known, access: .granted, residency: .local,
                                        identity: .confirmationNeeded))
        })
        setup.reviewOriginalAuthorization()
        guard case let .originalAuthorization(listed) = setup.sheet else {
            Issue.record("Bulk approval list was not presented")
            return
        }
        #expect(listed == sources)
        #expect(await store.records(in: engine.showID).allSatisfy { $0.recordedIdentity?.confirmation == .provisional })
        try Data(repeating: 4, count: 65).write(to: fixture.folder.appending(path: sources[1].displayNameHint))
        setup.authorizeOriginals(listed)
        let deadline = Date().addingTimeInterval(10)
        while setup.isAuthorizingOriginals, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!setup.isAuthorizingOriginals)
        #expect(setup.message?.contains("Authorized 1 of 2") == true)
        #expect(setup.message?.contains("older-two.wav") == true)
        let first = try await store.record(for: DeviceAccessKey(showID: engine.showID, sourceID: sources[0].id))
        let second = try await store.record(for: DeviceAccessKey(showID: engine.showID, sourceID: sources[1].id))
        #expect(first?.recordedIdentity?.confirmation == .userConfirmed)
        #expect(first?.recordedIdentity?.rawWitness != nil)
        #expect(second?.recordedIdentity?.confirmation == .provisional)
        await engine.shutdown()
    }

    @Test func ungroupedReferencesNeedNoMediaAndGroupingPreservesIdentityThroughUndoRedo() async throws {
        let fixture = try await fixture(corrupt: false)
        defer { fixture.close() }
        let original = try #require(fixture.model.ungroupedSources.first)
        #expect(original.displayNameHint == "not-opened.wav")
        #expect(fixture.model.waveformTracks.isEmpty)
        #expect(fixture.model.ungroupedSpeakerLabel(for: original.id) == "Unassigned speaker")
        let undo = try #require(fixture.document.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        fixture.model.groupUngroupedSource(original.id, newName: "Field recorder")
        undo.endUndoGrouping()
        #expect(fixture.model.ungroupedSources.isEmpty)
        let grouped = try #require(fixture.document.store.model.episode(fixture.episode)?.source(original.id))
        #expect(grouped.id == original.id)
        #expect(grouped.displayNameHint == original.displayNameHint)
        #expect(grouped.placement.recorderGroupID != nil)
        #expect(grouped.placement.epochID != nil, "Only explicit grouping creates an ordinary epoch")
        #expect(fixture.document.store.model.episode(fixture.episode)?.alignment == nil)
        undo.undo()
        #expect(fixture.model.ungroupedSources == [original])
        #expect(fixture.model.availableRecorderGroups.isEmpty)
        undo.redo()
        #expect(fixture.model.ungroupedSources.isEmpty)
        #expect(fixture.model.availableRecorderGroups.count == 1)
        undo.undo()

        let group = RecorderGroup(name: "Existing")
        undo.beginUndoGrouping()
        #expect(fixture.document.store.apply("Create Group") { model throws(DomainError) in
            try model.addingRecorderGroup(group, to: fixture.episode)
        })
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        fixture.model.groupUngroupedSource(original.id, existing: group.id)
        undo.endUndoGrouping()
        #expect(fixture.model.ungroupedSources.isEmpty)
        #expect(fixture.document.store.model.episode(fixture.episode)?.source(original.id)?.placement.recorderGroupID == group.id)
        undo.undo()
        #expect(fixture.model.ungroupedSources == [original])
        #expect(fixture.model.availableRecorderGroups == [group])
    }

    @Test func corruptAccessStorageIsVisibleAndDoesNotPublishAnInspection() async throws {
        let fixture = try await fixture(corrupt: true)
        defer { fixture.close() }
        await #expect(throws: AlignmentSourceAccessFailure.self) {
            try await fixture.runtime.inspect(model: fixture.document.store.model, episode: fixture.episode)
        }
        fixture.model.load()
        let deadline = Date().addingTimeInterval(5)
        while fixture.model.lastError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.model.lastError?.contains("could not be read") == true)
        #expect(fixture.model.message.contains("Alignment inspection failed"))
        #expect(!fixture.model.hasAnalysis)
        #expect(!fixture.model.isAuditioning)
    }

    @Test func aMissingAccessRecordStillProducesAnUnavailableSource() async throws {
        let fixture = try await fixture(corrupt: false)
        defer { fixture.close() }
        let prepared = try await fixture.runtime.inspect(
            model: fixture.document.store.model, episode: fixture.episode
        )
        #expect(prepared.sources.count == 1)
        #expect(prepared.sources.first?.availability == .off)
    }

    @MainActor private struct Fixture {
        let folder: URL
        let document: ShowDocument
        let episode: EpisodeID
        let runtime: AlignmentRuntime
        let model: EpisodeAlignmentModel

        func close() {
            model.suspend()
            document.close()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(
                at: PersistenceEnvironment.caches("Derived/\(document.store.model.show.id)")
            )
        }
    }

    private func fixture(corrupt: Bool) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let accessURL = folder.appendingPathComponent("access.json")
        if corrupt { try Data("not JSON".utf8).write(to: accessURL) }
        let episode = Episode(title: "Synthetic", sources: [SourceRecord(displayNameHint: "not-opened.wav")])
        let document = ShowDocument()
        document.store.replaceLoadedModel(ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode]))
        let runtime = try await AlignmentRuntime.make(
            showID: document.store.model.show.id, accessStore: FileDeviceAccessStore(fileURL: accessURL),
            access: SourceAccessContext(io: SystemSourceIO())
        )
        return Fixture(folder: folder, document: document, episode: episode.id, runtime: runtime,
                       model: EpisodeAlignmentModel(document: document, episodeID: episode.id, runtime: runtime))
    }
}
