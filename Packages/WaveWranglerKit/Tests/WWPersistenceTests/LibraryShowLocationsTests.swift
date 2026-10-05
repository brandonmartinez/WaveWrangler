import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// #88 regression: the library must remember where shows are across relaunches. Each "launch" builds fresh
/// stores that only read the persisted device-local data. Synthetic shows in temporary folders only.
@Suite("Library show locations survive relaunch (#88)")
struct LibraryShowLocationsTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    private func makeShow(in folder: URL, seed: UInt64, title: String) throws -> (ShowDocumentModel, URL) {
        let model = Fixtures.show(seed: seed, episodes: 3, title: title)
        let url = folder.appending(path: "\(title).wwshow")
        _ = try DocumentPublisher(coder: coder, recovery: nil).publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        return (model, url)
    }

    private func summary(of model: ShowDocumentModel) -> ShowLastOpenSummary {
        ShowLastOpenSummary(
            showID: model.show.id,
            episodes: model.episodes.map { .init(id: $0.id, number: $0.number, title: $0.title) },
            sourceReferenceCount: model.episodes.reduce(0) { $0 + $1.sources.count }
        )
    }

    @Test func createRecordRelaunchReopenAndSave() async throws {
        let dir = TempDirectory("show-locations-relaunch")
        let shows = dir.sub("Synthetic Shows")
        let (model, url) = try makeShow(in: shows, seed: 88, title: "Relaunch Show")
        let opened = Date(timeIntervalSince1970: 1_790_000_000)

        // Launch 1: the show window opens and the library records it (real read-write bookmark).
        do {
            let launch1 = LibraryShowLocations(root: dir.sub("Device"))
            try launch1.record(model.show.id, at: url, summary: summary(of: model), openedAt: opened)
        }

        // Launch 2: fresh store reading only the persisted data.
        let launch2 = LibraryShowLocations(root: dir.sub("Device"))
        let restored = try #require(launch2.summary(for: model.show.id))
        #expect(restored.folderDisplayName == "Synthetic Shows")
        #expect(restored.lastOpened == opened)
        #expect(restored.episodes?.count == 3)
        #expect(launch2.check(model.show.id) == .reachable(folderDisplayName: "Synthetic Shows"))

        // Reopen through the recorded bookmark, verify the ShowID, edit and save in place.
        let grant = try launch2.beginAccess(model.show.id)
        #expect(!grant.followedMove)
        let recovery = RecoveryStore(root: dir.sub("Recovery"))
        guard case let .editable(document, fingerprint) = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: recovery)
            .open(grant.url, key: .show(model.show.id)) else {
            Issue.record("expected the same show to open editable")
            return
        }
        let edited = try document.payload.renamingShow(to: "Relaunch Show (edited)")
        _ = try DocumentPublisher(coder: coder, recovery: recovery)
            .publish(edited, revision: document.revision + 1, key: .show(model.show.id), to: grant.url, target: .inPlace(expectedBase: fingerprint))
        launch2.endAccess(grant)
        let balance = launch2.scopeBalance
        #expect(balance.started == balance.stopped, "scopes balance")

        // Launch 3: the saved change is on disk at the recorded location.
        let launch3 = LibraryShowLocations(root: dir.sub("Device"))
        let grant3 = try launch3.beginAccess(model.show.id)
        defer { launch3.endAccess(grant3) }
        let decoded = try coder.decode(Data(contentsOf: grant3.url))
        #expect(decoded.payload.show.title == "Relaunch Show (edited)")
        #expect(decoded.payload.show.id == model.show.id)
    }

    @Test func distinctStatesInsteadOfCheckingForever() throws {
        let dir = TempDirectory("show-locations-states")
        let store = LibraryShowLocations(root: dir.sub("Device"))
        #expect(store.check(ShowID()) == .unknown, "no record is its own state, not Checking")

        let (model, url) = try makeShow(in: dir.sub("Gone"), seed: 89, title: "Gone Show")
        try store.record(model.show.id, at: url, openedAt: Date())
        try FileManager.default.removeItem(at: url)
        #expect(LibraryShowLocations(root: dir.sub("Device")).check(model.show.id) == .notFound(folderDisplayName: "Gone"))
        #expect(throws: ShowAccessError.notFound(folderDisplayName: "Gone")) {
            _ = try LibraryShowLocations(root: dir.sub("Device")).beginAccess(model.show.id)
        }
        #expect(throws: ShowAccessError.noRecord) { _ = try store.beginAccess(ShowID()) }
        let balance = store.scopeBalance
        #expect(balance.started == balance.stopped)
    }

    @Test func aDifferentShowAtTheRecordedPathIsRefusedByIdentity() throws {
        let dir = TempDirectory("show-locations-identity")
        let folder = dir.sub("Shows")
        let (model, url) = try makeShow(in: folder, seed: 90, title: "Original")
        let store = LibraryShowLocations(root: dir.sub("Device"))
        try store.record(model.show.id, at: url)
        // Replace the file content with a different show at the same path (same file name).
        let other = Fixtures.show(seed: 91, title: "Original")
        try coder.encode(other, revision: 1).write(to: url)

        let grant = try store.beginAccess(model.show.id)
        defer { store.endAccess(grant) }
        let outcome = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: nil).open(grant.url, key: .show(model.show.id))
        guard case .damaged(.identityMismatch, _) = outcome else {
            Issue.record("a different show must not be trusted at the recorded location, got \(outcome)")
            return
        }
    }

    @Test func locationOnlyRecordKeepsTheLastSavedSummary() throws {
        let dir = TempDirectory("show-locations-summary")
        let (model, url) = try makeShow(in: dir.sub("Shows"), seed: 92, title: "Summary Show")
        let store = LibraryShowLocations(root: dir.sub("Device"))
        try store.record(model.show.id, at: url, summary: summary(of: model))
        // Reopened with unsaved edits: only the location and last-opened time are refreshed.
        let later = Date(timeIntervalSince1970: 1_790_000_500)
        try store.record(model.show.id, at: url, openedAt: later)
        let restored = try #require(LibraryShowLocations(root: dir.sub("Device")).summary(for: model.show.id))
        #expect(restored.episodes?.count == model.episodes.count)
        #expect(restored.lastOpened == later)
    }
}
