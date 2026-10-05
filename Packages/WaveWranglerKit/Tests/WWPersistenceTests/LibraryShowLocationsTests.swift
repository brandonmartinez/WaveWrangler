import Foundation
import Synchronization
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

    // MARK: - #97 review

    private struct AdoptFailed: Error {}

    @Test func openVerifiedReleasesTheScopeExactlyOnceOnEveryPath() async throws {
        let dir = TempDirectory("show-locations-open")
        let folder = dir.sub("Shows")
        let bookmarks = CountingBookmarks()
        let store = LibraryShowLocations(root: dir.sub("Device"), bookmarks: bookmarks)
        let opener = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: nil)

        // Mismatched ShowID: a different show is at the recorded path.
        let (model, url) = try makeShow(in: folder, seed: 93, title: "Mismatch")
        try store.record(model.show.id, at: url)
        try coder.encode(Fixtures.show(seed: 94, title: "Mismatch"), revision: 1).write(to: url)
        await #expect(throws: ShowOpenError.self) {
            _ = try await store.openVerified(model.show.id, opener: opener) { _ in Issue.record("must not adopt a different show") }
        }
        #expect(store.scopeBalance.started == 1 && store.scopeBalance.stopped == 1, "mismatch: one start, one stop")

        // adopt fails (e.g. NSDocument refused): released once.
        let (good, goodURL) = try makeShow(in: folder, seed: 95, title: "Good")
        try store.record(good.show.id, at: goodURL)
        await #expect(throws: AdoptFailed.self) {
            _ = try await store.openVerified(good.show.id, opener: opener) { _ in throw AdoptFailed() }
        }
        #expect(store.scopeBalance.started == 2 && store.scopeBalance.stopped == 2, "adopt failure: one stop")

        // Success: the caller owns the grant until it ends access.
        let grant = try await store.openVerified(good.show.id, opener: opener) { _ in }
        #expect(store.scopeBalance.started == 3 && store.scopeBalance.stopped == 2)
        store.endAccess(grant)
        #expect(store.scopeBalance.started == store.scopeBalance.stopped)
        #expect(bookmarks.started == bookmarks.stopped, "real start/stop calls balance too")
    }

    @Test func concurrentSummaryUpdatesNeverLoseNewerData() async throws {
        let dir = TempDirectory("show-locations-concurrent")
        let store = LibraryShowLocations(root: dir.sub("Device"))
        let ids = (0..<200).map { _ in ShowID() }
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { store.noteOpened(id, at: Date(timeIntervalSince1970: 1_790_000_000 + Double(index))) }
            }
        }
        let persisted = store.persistedSummaries()
        #expect(persisted.count == ids.count, "every concurrent update is in the file")
        #expect(persisted == store.allSummaries(), "file equals in-memory state")
        #expect(LibraryShowLocations(root: dir.sub("Device")).allSummaries().count == ids.count, "relaunch sees all")
    }
}

/// Real security-scoped bookmarks that also count start/stop calls.
private final class CountingBookmarks: DocumentBookmarking {
    private let base = SecurityScopedDocumentBookmarks()
    private let counts = Mutex((started: 0, stopped: 0))
    var started: Int { counts.withLock { $0.started } }
    var stopped: Int { counts.withLock { $0.stopped } }

    func bookmark(for file: URL) throws -> Data { try base.bookmark(for: file) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) { try base.resolve(bookmark) }
    func startAccessing(_ url: URL) -> Bool {
        counts.withLock { $0.started += 1 }
        return true
    }
    func stopAccessing(_ url: URL) { counts.withLock { $0.stopped += 1 } }
}
