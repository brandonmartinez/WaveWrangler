import AppKit
import Foundation
import Testing
import WWCore
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Alignment source-access presentation", .serialized)
struct AlignmentSourceAccessHostedTests {
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
