import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Design L2/L3: organizing edits while the library location is unreachable are queued in a device-local
/// journal ("Edits waiting") and applied through the normal base check — ST-36 combine on divergence —
/// when the location is reachable again. Never dropped silently.
@Suite("Pending library edits (L2/L3 journal)")
struct PendingLibraryEditsTests {
    /// A library moved to a folder, which is then taken "offline" by renaming it away.
    struct OfflineRig {
        let rig = LibraryRig("pending")
        let folder: URL
        let away: URL
        let shows = (0..<4).map { Fixtures.show(seed: 900 + UInt64($0)) }

        init() async throws {
            folder = rig.dir.url.appending(path: "Cloud Folder", directoryHint: .isDirectory)
            away = rig.dir.url.appending(path: "Cloud Folder (offline)", directoryHint: .isDirectory)
            let store = rig.store()
            _ = await store.load()
            _ = try await store.update { _ in Fixtures.library(shows: self.shows, seed: 9) }
            guard case .success(.moved) = await store.moveLibrary(to: folder) else { throw CocoaError(.fileWriteUnknown) }
        }

        var libraryFile: URL { folder.appending(path: LibraryLocationSetting.defaultFileName) }
        func goOffline() throws { try FileManager.default.moveItem(at: folder, to: away) }
        func comeBack() throws { try FileManager.default.moveItem(at: away, to: folder) }
    }

    static func addCollection(_ name: String) -> @Sendable (LibraryModel) -> LibraryModel {
        { var library = $0; library.collections.append(LibraryCollection(name: name, showIDs: library.entries.prefix(2).map(\.showID))); return library }
    }

    @Test func queuedWhileUnreachableThenAppliedWhenBack() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        guard case .unavailableShowingPrior = await store.load() else { Issue.record("expected L2"); return }
        guard case .unreachable = await store.levelState else { Issue.record("expected unreachable"); return }
        #expect(try await store.update(Self.addCollection("Queued 1")) == .queued(pendingEdits: 1))
        #expect(try await store.update(Self.addCollection("Queued 2")) == .queued(pendingEdits: 2))
        #expect(await store.pendingEditCount == 2)
        let queued = try #require(await store.library)
        #expect(queued.collections.suffix(2).map(\.name) == ["Queued 1", "Queued 2"])
        #expect(await store.index?.showsByCollection.count == queued.collections.count)

        // The journal survives relaunch.
        let relaunched = offline.rig.store()
        _ = await relaunched.load()
        #expect(await relaunched.pendingEditCount == 2)
        #expect(await relaunched.library == queued)
        // Still offline: nothing applied, nothing dropped.
        #expect(await relaunched.retryPendingEdits() == .stillWaiting(reason: "The folder cannot be reached."))
        #expect(await relaunched.pendingEditCount == 2)

        try offline.comeBack()
        guard case let .applied(receipt) = await relaunched.retryPendingEdits() else { Issue.record("not applied"); return }
        #expect(await relaunched.pendingEditCount == 0)
        #expect(offline.rig.recovery.pendingLibraryEdits() == nil, "journal cleared only after verification")
        let onDisk = try LibraryCoder.library.decode(Data(contentsOf: offline.libraryFile))
        #expect(onDisk.payload.collections.map(\.name) == queued.collections.map(\.name))
        #expect(onDisk.publication == receipt.publication)
        #expect(await relaunched.levelState == .ready)
    }

    @Test func divergedLibraryIsCombinedNothingDropped() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        #expect(try await store.update(Self.addCollection("Mine")) == .queued(pendingEdits: 1))
        // Meanwhile another Mac changes the library at the (unreachable to us) location.
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        let bytes = try Data(contentsOf: file)
        let theirs = try LibraryCoder.library.decode(bytes)
        var other = theirs.payload
        other.collections.append(LibraryCollection(name: "Theirs"))
        other.collections[0].showIDs.reverse()
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(other, revision: theirs.revision + 1, key: .library, to: file, target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        try offline.comeBack()

        // Reconnection on load applies automatically.
        _ = await store.load()
        guard case let .combined(_, summary) = await store.lastPendingOutcome else { Issue.record("not combined"); return }
        let combined = try #require(await store.library)
        let names = combined.collections.map(\.name)
        #expect(names.contains("Theirs") && names.contains("Mine"))
        #expect(names.contains("\(other.collections[0].name) (from this Mac)"), "differing order kept as a separate copy")
        #expect(summary.collectionsKeptAsCopies == 1 && summary.collectionsAdded == 1)
        #expect(await store.pendingEditCount == 0)
    }

    @Test func newerFormatAtReconnectKeepsQueueAndFile() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        _ = try await store.update(Self.addCollection("Waiting"))
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["schemaVersion"] = SchemaVersion.library + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: file)
        try offline.comeBack()
        guard case .refused(.readOnly) = await store.retryPendingEdits() else { Issue.record("expected refusal"); return }
        #expect(await store.pendingEditCount == 1)
        #expect(try Data(contentsOf: offline.libraryFile) == newer)
        #expect(await store.levelState == .newerFormat)
    }

    @Test func acknowledgementsQueueButReconciliationDoesNot() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        let stamp = PublicationStamp(revision: 4, publicationID: UUID(), checksum: "sha256:synthetic")
        let ack = await store.acknowledgeShowPublication(offline.shows[0].show.id, title: "Saved while offline", publication: stamp)
        #expect(ack == .queued(pendingEdits: 1))
        #expect(await store.reconcile([offline.shows[1].show.id: .missing]) == nil)
        #expect(await store.pendingEditCount == 1)
    }

    @Test func damagedJournalIsReportedNeverOverwritten() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let journal = offline.rig.recovery.root.appending(path: "library-journal/pending-edits.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{damaged".utf8).write(to: journal)
        let store = offline.rig.store()
        _ = await store.load()
        #expect(await store.pendingJournalDamaged)
        guard case .failed(.readOnly) = try await store.update(Self.addCollection("X")) else { Issue.record("queued over damage"); return }
        #expect(await store.retryPendingEdits() == .journalDamaged)
        #expect(try Data(contentsOf: journal) == Data("{damaged".utf8))
    }

    /// Interrupting the replay at every library boundary never loses a queued edit: the journal stays until a
    /// verified publication contains every edit, and the next load finishes the job.
    @Test(arguments: PublicationBoundary.library)
    func replayInterruptionsNeverDropEdits(_ boundary: PublicationBoundary) async throws {
        let runs = 100
        var included = 0, lost = 0, mixed = 0, fired = 0
        // After L1 the prior is already retained (the move kept it), so there is no retention write to tear:
        // only process death applies there.
        let variants: [(Double) -> Fault] = boundary == .candidateValidated
            ? [{ _ in .crash(at: boundary) }]
            : FaultInjectionHarnessTests.variants(for: boundary)
        for index in 0..<runs {
            let offline = try await OfflineRig()
            try offline.goOffline()
            let queueing = offline.rig.store()
            _ = await queueing.load()
            _ = try await queueing.update(Self.addCollection("Queued \(index)"))
            try offline.comeBack()

            let faults = FaultState(variants[index % variants.count](FaultInjectionHarnessTests.fraction(index, 31)))
            let ops = FaultInjectingFileOperations(faults: faults)
            let faulty = LibraryStore(
                containerFolder: offline.rig.container, settings: offline.rig.settings, bookmarks: PlainFolderBookmarks(),
                recovery: RecoveryStore(root: offline.rig.recovery.root, ops: ops),
                indexCache: LibraryIndexCache(url: offline.rig.cacheURL, ops: ops), ops: ops, hooks: FaultHooks(faults: faults)
            )
            _ = await faulty.load()
            if faults.fired { fired += 1 }
            FaultInjectionHarnessTests.cleanStaging(faults)

            // Recovery: a fresh store finishes any interrupted replay.
            let after = offline.rig.store()
            let outcome = await after.load()
            if case .damaged = outcome { _ = await after.recoverAsNewCopy(revision: 2); _ = await after.load() }
            let names = await after.library?.collections.map(\.name) ?? []
            let pending = await after.pendingEditCount
            if names.contains("Queued \(index)"), pending == 0 { included += 1 }
            else if pending > 0 { mixed += 1 } else { lost += 1 }
        }
        Evidence.record("pending-edits replay interrupted at \(boundary.libraryLabel) runs=\(runs) faultsFired=\(fired) editsIncludedAfterRecovery=\(included) stillPending=\(mixed) lost=\(lost) [simulated/local, not provider-observed]")
        #expect(fired == runs && included == runs && lost == 0)
    }
}
