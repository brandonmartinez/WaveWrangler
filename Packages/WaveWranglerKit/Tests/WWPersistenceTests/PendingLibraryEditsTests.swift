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
        guard case .merged = await store.lastPendingOutcome else { Issue.record("not merged"); return }
        let combined = try #require(await store.library)
        let names = combined.collections.map(\.name)
        #expect(names.contains("Theirs") && names.contains("Mine"))
        #expect(combined.collections[0].showIDs == other.collections[0].showIDs, "the other Mac's reorder is kept (this Mac didn't touch it)")
        #expect(await store.pendingEditCount == 0)
        let onDisk = try LibraryCoder.library.decode(Data(contentsOf: offline.libraryFile)).payload
        #expect(onDisk == combined)
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

    /// Review repro: alias "Old" on disk, renamed to "New" while offline, recents published elsewhere meanwhile.
    @Test func queuedAliasRenameSurvivesConcurrentRecentsPublish() async throws {
        let offline = try await OfflineRig()
        let show = offline.shows[1].show.id
        let setup = offline.rig.store()
        _ = await setup.load()
        _ = try await setup.update { var l = $0; l.entries[l.entries.firstIndex { $0.showID == show }!].alias = "Old"; return l }
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        #expect(try await store.update { var l = $0; l.entries[l.entries.firstIndex { $0.showID == show }!].alias = "New"; return l } == .queued(pendingEdits: 1))
        // Another Mac publishes a recents change.
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        let bytes = try Data(contentsOf: file)
        let theirs = try LibraryCoder.library.decode(bytes)
        let other = LibraryReconciler.recordingRecent(offline.shows[3].show.id, in: theirs.payload)
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(other, revision: theirs.revision + 1, key: .library, to: file, target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        try offline.comeBack()

        guard case .merged = await store.retryPendingEdits() else { Issue.record("expected merge"); return }
        let onDisk = try LibraryCoder.library.decode(Data(contentsOf: offline.libraryFile)).payload
        #expect(onDisk.entries.first { $0.showID == show }?.alias == "New", "the queued rename is present")
        #expect(onDisk.recentShowIDs.first == offline.shows[3].show.id, "the other Mac's recents change is kept")
        #expect(await store.pendingEditCount == 0)
    }

    /// Re-review repro: both Macs add members to the same collection while this one is offline.
    @Test func bothSidesAddMembersAcrossReplay() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        let active = try #require(await store.library?.collections.first { $0.name == "Active" })
        _ = try await store.update { var l = $0; l.collections[l.collections.firstIndex { $0.id == active.id }!].showIDs.append(offline.shows[3].show.id); return l }
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        let bytes = try Data(contentsOf: file)
        let theirs = try LibraryCoder.library.decode(bytes)
        var other = theirs.payload
        other.collections[other.collections.firstIndex { $0.id == active.id }!].showIDs.append(offline.shows[2].show.id)
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(other, revision: theirs.revision + 1, key: .library, to: file, target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        try offline.comeBack()
        guard case .merged = await store.retryPendingEdits() else { Issue.record("expected merge"); return }
        let onDisk = try LibraryCoder.library.decode(Data(contentsOf: offline.libraryFile)).payload
        let members = Set(try #require(onDisk.collections.first { $0.id == active.id }).showIDs)
        #expect(members.isSuperset(of: [offline.shows[2].show.id, offline.shows[3].show.id]), "both Macs' additions are kept")
        #expect(await store.pendingEditCount == 0)
    }

    /// Re-review finding 2: L4 "Combine (Keep Everything)" after a replay conflict keeps the queued edits in a
    /// backup copy and reports what the combine couldn't carry.
    @Test func combineAfterConflictBacksUpQueuedEdits() async throws {
        let offline = try await OfflineRig()
        let show = offline.shows[1].show.id
        let setup = offline.rig.store()
        _ = await setup.load()
        _ = try await setup.update { var l = $0; l.entries[l.entries.firstIndex { $0.showID == show }!].alias = "Old"; return l }
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        _ = try await store.update { var l = $0; l.entries[l.entries.firstIndex { $0.showID == show }!].alias = "Mine"; return l }
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        let bytes = try Data(contentsOf: file)
        let theirs = try LibraryCoder.library.decode(bytes)
        var other = theirs.payload
        other.entries[other.entries.firstIndex { $0.showID == show }!].alias = "Theirs"
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(other, revision: theirs.revision + 1, key: .library, to: file, target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        try offline.comeBack()

        guard case .needsDecision = await store.retryPendingEdits() else { Issue.record("expected L4"); return }
        #expect(await store.pendingEditCount == 1)
        guard case let .success(summary) = await store.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        #expect(summary.queuedChangesNotCarried.contains { $0.contains("name") }, "the uncarried alias edit is reported")
        #expect(await store.pendingEditCount == 0)
        let backups = try offline.rig.recovery.conflictCandidates(for: .library)
        #expect(backups.contains { url in
            (try? LibraryCoder.library.decode(Data(contentsOf: url)))?.payload.entries.first { $0.showID == show }?.alias == "Mine"
        }, "queued edits kept as a backup copy")
    }

    @Test func queuedRecentRemovalIsCarried() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        let removed = try #require(await store.library?.recentShowIDs.first)
        _ = try await store.update { var l = $0; l.recentShowIDs.removeAll { $0 == removed }; return l }
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        let bytes = try Data(contentsOf: file)
        let theirs = try LibraryCoder.library.decode(bytes)
        var other = theirs.payload
        other.collections.append(LibraryCollection(name: "Elsewhere"))
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(other, revision: theirs.revision + 1, key: .library, to: file, target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        try offline.comeBack()
        guard case .merged = await store.retryPendingEdits() else { Issue.record("expected merge"); return }
        let onDisk = try LibraryCoder.library.decode(Data(contentsOf: offline.libraryFile)).payload
        #expect(!onDisk.recentShowIDs.contains(removed))
        #expect(onDisk.collections.contains { $0.name == "Elsewhere" })
    }

    @Test func uncarriableQueuedChangeKeepsJournalAndRaisesL4() async throws {
        let offline = try await OfflineRig()
        try offline.goOffline()
        let store = offline.rig.store()
        _ = await store.load()
        // Remove "Archive" here while another Mac changes its members.
        _ = try await store.update { var l = $0; l.collections.removeAll { $0.name == "Archive" }; return l }
        let file = offline.away.appending(path: LibraryLocationSetting.defaultFileName)
        let bytes = try Data(contentsOf: file)
        let theirs = try LibraryCoder.library.decode(bytes)
        var other = theirs.payload
        other.collections[other.collections.firstIndex { $0.name == "Archive" }!].showIDs.append(offline.shows[0].show.id)
        _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: nil)
            .publish(other, revision: theirs.revision + 1, key: .library, to: file, target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
        try offline.comeBack()
        let diskBefore = try Data(contentsOf: offline.libraryFile)

        guard case let .needsDecision(problems) = await store.retryPendingEdits() else { Issue.record("expected L4"); return }
        #expect(problems.contains { $0.contains("Archive") })
        #expect(await store.pendingEditCount == 1, "journal kept")
        #expect(await store.levelState == .changedElsewhere)
        #expect(try Data(contentsOf: offline.libraryFile) == diskBefore, "nothing overwritten")
        guard case .failed(.readOnly) = try await store.update(Self.addCollection("Blocked")) else { Issue.record("L4 must be read-only"); return }

        // "Use Other Mac's Version": the queued edits are kept as a backup copy, then the journal is retired.
        _ = await store.resolveConflictUsingOtherVersion()
        #expect(await store.pendingEditCount == 0)
        #expect(try offline.rig.recovery.conflictCandidates(for: .library).isEmpty == false)
        #expect(await store.library?.collections.contains { $0.name == "Archive" } == true)
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
