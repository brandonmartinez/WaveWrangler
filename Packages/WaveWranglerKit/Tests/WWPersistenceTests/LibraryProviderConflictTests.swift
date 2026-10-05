import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

/// #117: iCloud keeps the losing copy of two concurrent library publications as an unresolved conflict version.
/// The library must detect it (L4), combine it, and back it up before marking it resolved; versions it can't use
/// are reported and never resolved silently.
@Suite("Library provider conflict versions (#117)")
struct LibraryProviderConflictTests {
    /// Simulated provider version store: conflict versions per file, and the order of backups vs. resolution.
    final class FakeProviderVersions: ProviderVersionInspecting, @unchecked Sendable {
        private let state = Mutex<(versions: [String: [ProviderConflictVersion]], resolved: [String], backedUpAtResolve: [Bool])>(([:], [], []))
        let recovery: RecoveryStore
        var failResolve = false

        init(recovery: RecoveryStore) { self.recovery = recovery }

        func add(_ bytes: Data?, to url: URL, from computer: String = "Other Mac") -> String {
            let id = "version-\(UUID().uuidString)"
            state.withLock { $0.versions[url.standardizedFileURL.path, default: []].append(
                ProviderConflictVersion(id: id, savingComputer: computer, modified: Date(), bytes: bytes)) }
            return id
        }

        func unresolvedConflictVersions(of url: URL) -> [ProviderConflictVersion] {
            state.withLock { $0.versions[url.standardizedFileURL.path] ?? [] }
        }

        func markResolved(_ ids: Set<String>, of url: URL) throws {
            if failResolve { throw CocoaError(.fileWriteNoPermission) }
            // The library must have backed every one of these up before resolving it.
            let backups = (try? recovery.conflictCandidates(for: .library)) ?? []
            let backed = backups.compactMap { try? Data(contentsOf: $0) }
            state.withLock { state in
                let versions = state.versions[url.standardizedFileURL.path] ?? []
                for version in versions where ids.contains(version.id) {
                    state.backedUpAtResolve.append(version.bytes.map(backed.contains) ?? false)
                }
                state.resolved.append(contentsOf: ids.sorted())
                state.versions[url.standardizedFileURL.path] = versions.filter { !ids.contains($0.id) }
            }
        }

        var resolved: [String] { state.withLock { $0.resolved } }
        var everyResolutionWasBackedUpFirst: Bool { state.withLock { !$0.backedUpAtResolve.isEmpty && $0.backedUpAtResolve.allSatisfy { $0 } } }
    }

    struct Rig {
        let rig = LibraryRig("provider")
        let provider: FakeProviderVersions

        init() { provider = FakeProviderVersions(recovery: rig.recovery) }

        func store(provider: FakeProviderVersions? = nil, recovery: RecoveryStore? = nil) -> LibraryStore {
            LibraryStore(containerFolder: rig.container, settings: rig.settings, bookmarks: PlainFolderBookmarks(),
                         recovery: recovery ?? rig.recovery, indexCache: LibraryIndexCache(url: rig.cacheURL),
                         providerVersions: provider ?? self.provider)
        }

        func disk() throws -> DecodedDocument<LibraryModel> { try LibraryCoder.library.decode(Data(contentsOf: rig.containerFile)) }

        /// This Mac published `base + "Mine"`; the other Mac's concurrent `base + "Theirs"` is the conflict version.
        func concurrentCopies() async throws -> (store: LibraryStore, theirs: Data, versionID: String) {
            let store = self.store()
            #expect(await store.load() == .created)
            _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Shared")); return l }
            let base = try disk()
            var theirsModel = base.payload
            theirsModel.collections.append(LibraryCollection(name: "Theirs"))
            let theirs = try LibraryCoder.library.encode(theirsModel, revision: base.revision + 1)
            guard case .published = try await store.update({ var l = $0; l.collections.append(LibraryCollection(name: "Mine")); return l }) else {
                Issue.record("publish failed")
                return (store, theirs, "")
            }
            let id = provider.add(theirs, to: rig.containerFile)
            return (store, theirs, id)
        }
    }

    @Test func conflictVersionEntersL4AndCombineKeepsBothAfterBackingItUp() async throws {
        let rig = Rig()
        let (_, theirs, id) = try await rig.concurrentCopies()
        let store = rig.store()
        #expect(await store.load() == .ready(revision: 3))
        #expect(await store.levelState == .changedElsewhere, "the other Mac's concurrent copy is detected")
        #expect(await store.providerConflicts.map(\.id) == [id])
        // Edits are refused until the user combines or chooses; nothing is published over the unseen copy.
        let refused = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Blocked")); return l }
        guard case .failed(.readOnly) = refused else { Issue.record("expected L4 refusal, got \(refused)"); return }
        #expect(try rig.disk().revision == 3)

        guard case let .success(summary) = await store.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        #expect(summary.collectionsAdded == 1)
        let names = try rig.disk().payload.collections.map(\.name)
        #expect(Set(names) == ["Shared", "Mine", "Theirs"])
        #expect(await store.levelState == .ready)
        #expect(rig.provider.resolved == [id])
        #expect(rig.provider.everyResolutionWasBackedUpFirst, "backed up before marked resolved")
        let backups = try rig.rig.recovery.conflictCandidates(for: .library).map { try Data(contentsOf: $0) }
        #expect(backups.contains(theirs))
    }

    @Test func unreadableOrUndecodableVersionIsReportedAndNeverResolved() async throws {
        let rig = Rig()
        let (_, _, _) = try await rig.concurrentCopies()
        let unreadable = rig.provider.add(nil, to: rig.rig.containerFile)
        let undecodable = rig.provider.add(Data("{\"format\":\"com.brandonmartinez.wavewrangler.library\",\"schemaVersion\":2,".utf8), to: rig.rig.containerFile)
        let store = rig.store()
        _ = await store.load()
        #expect(Set(await store.unusableProviderConflicts.map(\.id)) == [unreadable, undecodable])
        guard case .success = await store.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        #expect(!rig.provider.resolved.contains(unreadable) && !rig.provider.resolved.contains(undecodable))
        _ = await store.reload()
        #expect(Set(await store.unusableProviderConflicts.map(\.id)) == [unreadable, undecodable], "still reported after a reload")
        #expect(await store.levelState == .ready, "unusable versions never block editing")
    }

    @Test func versionOfADifferentLibraryIsReportedNotCombined() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Mine")); return l }
        var other = LibraryModel()
        other.collections.append(LibraryCollection(name: "Another library"))
        let id = rig.provider.add(try LibraryCoder.library.encode(other, revision: 5), to: rig.rig.containerFile)
        _ = await store.reload()
        #expect(await store.unusableProviderConflicts.map(\.id) == [id])
        #expect(await store.levelState == .ready)
        #expect(!(try rig.disk().payload.collections.map(\.name).contains("Another library")))
        #expect(rig.provider.resolved.isEmpty)
    }

    @Test func versionWhoseChangesAreAlreadyIncludedIsBackedUpAndResolvedWithoutL4() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Shared")); return l }
        let older = try rig.disk()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Later")); return l }
        let id = rig.provider.add(try LibraryCoder.library.encode(older.payload, revision: older.revision), to: rig.rig.containerFile)
        _ = await store.reload()
        #expect(await store.levelState == .ready)
        #expect(rig.provider.resolved == [id])
        #expect(rig.provider.everyResolutionWasBackedUpFirst)
    }

    @Test func versionArrivingBeforeAnEditBlocksThatEdit() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Shared")); return l }
        var theirs = try rig.disk().payload
        theirs.collections.append(LibraryCollection(name: "Theirs"))
        rig.provider.add(try LibraryCoder.library.encode(theirs, revision: 3), to: rig.rig.containerFile)
        let before = try rig.disk().publication
        let result = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Mine")); return l }
        guard case .failed(.readOnly) = result else { Issue.record("expected refusal, got \(result)"); return }
        #expect(await store.levelState == .changedElsewhere)
        #expect(try rig.disk().publication == before, "nothing published over the unseen copy")
    }

    @Test func useOtherVersionBacksUpTheConflictVersionAndKeepsTheCurrentLibrary() async throws {
        let rig = Rig()
        let (_, theirs, id) = try await rig.concurrentCopies()
        let store = rig.store()
        _ = await store.load()
        let current = try rig.disk().payload
        _ = await store.resolveConflictUsingOtherVersion()
        #expect(await store.levelState == .ready)
        #expect(try rig.disk().payload == current)
        #expect(rig.provider.resolved == [id])
        #expect(rig.provider.everyResolutionWasBackedUpFirst)
        #expect(try rig.rig.recovery.conflictCandidates(for: .library).map { try Data(contentsOf: $0) }.contains(theirs))
    }

    // MARK: Review findings (#118)

    /// The other Mac renamed the same show differently. That is not "already included": L4, and Combine reports
    /// the rename it can't carry instead of dropping it.
    @Test func sameEntryRenamedDifferentlyGoesToL4AndCombineReportsIt() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        let show = ShowID()
        _ = try await store.update { LibraryReconciler.registering(show, title: "Episode Show", publication: nil, in: $0) }
        _ = try await store.update { var l = $0; l.entries[0].alias = "Old"; return l }
        let base = try rig.disk()
        var theirs = base.payload
        theirs.entries[0].alias = "Renamed on the other Mac"
        _ = try await store.update { var l = $0; l.entries[0].alias = "Renamed here"; return l }
        let id = rig.provider.add(try LibraryCoder.library.encode(theirs, revision: base.revision + 1), to: rig.rig.containerFile)
        _ = await store.reload()
        #expect(await store.levelState == .changedElsewhere, "not silently resolved as included")
        #expect(rig.provider.resolved.isEmpty)
        guard case let .success(summary) = await store.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        #expect(summary.entryChangesNotCarried.contains { $0.contains("Renamed on the other Mac") })
        #expect(summary.message.contains("Renamed on the other Mac"), "surfaced in the message bar text")
        #expect(rig.provider.resolved == [id] && rig.provider.everyResolutionWasBackedUpFirst)
        #expect(try rig.disk().payload.entries[0].alias == "Renamed here")
    }

    /// The other Mac recorded a newer verified save of a show: L4, and Combine carries it (with its title).
    @Test func newerShowPublicationInTheOtherCopyIsCarried() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        let show = ShowID()
        let r1 = PublicationStamp(revision: 1, publicationID: UUID(), checksum: "sha256:1")
        _ = try await store.update { LibraryReconciler.registering(show, title: "Show r1", publication: r1, in: $0) }
        let base = try rig.disk()
        var theirs = base.payload
        let r2 = PublicationStamp(revision: 2, publicationID: UUID(), checksum: "sha256:2")
        theirs = LibraryReconciler.acknowledging(show, title: "Show r2", publication: r2, in: theirs)
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Here")); return l }
        rig.provider.add(try LibraryCoder.library.encode(theirs, revision: base.revision + 1), to: rig.rig.containerFile)
        _ = await store.reload()
        #expect(await store.levelState == .changedElsewhere)
        guard case .success = await store.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        let entry = try #require(try rig.disk().payload.entries.first { $0.showID == show })
        #expect(entry.lastKnownPublication == r2 && entry.lastKnownTitle == "Show r2")
    }

    /// A version that can't be marked resolved (or backed up) is never left unreported.
    @Test func versionThatCannotBeResolvedIsReportedAsUnusable() async throws {
        let rig = Rig()
        let (_, _, id) = try await rig.concurrentCopies()
        rig.provider.failResolve = true
        let store = rig.store()
        _ = await store.load()
        guard case .success = await store.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        #expect(Set(try rig.disk().payload.collections.map(\.name)) == ["Shared", "Mine", "Theirs"])
        #expect(await store.unusableProviderConflicts.map(\.id) == [id], "reported after Combine and its reload")
        #expect(await store.levelState == .ready)
    }

    @Test func includedVersionIsReportedAsResolved() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Shared")); return l }
        let older = try rig.disk()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Later")); return l }
        let id = rig.provider.add(try LibraryCoder.library.encode(older.payload, revision: older.revision), to: rig.rig.containerFile)
        _ = await store.reload()
        #expect(await store.resolvedProviderConflicts.map(\.id) == [id])
    }

    /// Edits queued while the location was unreachable are never published over a concurrent copy the user
    /// hasn't seen: L4 with the journal kept; Combine then carries both.
    @Test func queuedEditsAndAConflictVersionWaitForCombine() async throws {
        let rig = Rig()
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { var l = $0; l.collections.append(LibraryCollection(name: "Shared")); return l }
        let disk = try rig.disk()
        let diskBytes = try Data(contentsOf: rig.rig.containerFile)
        var queued = disk.payload
        queued.collections.append(LibraryCollection(name: "Queued offline"))
        try rig.rig.recovery.writePendingLibraryEdits(PendingLibraryEdits(
            base: RevisionFingerprint(of: diskBytes), baseSnapshot: diskBytes, editCount: 1, firstQueuedAt: Date(), lastQueuedAt: Date(),
            snapshot: try LibraryCoder.library.encode(queued, revision: disk.revision + 1)))
        var theirs = disk.payload
        theirs.collections.append(LibraryCollection(name: "Theirs"))
        rig.provider.add(try LibraryCoder.library.encode(theirs, revision: disk.revision + 1), to: rig.rig.containerFile)

        let relaunched = rig.store()
        _ = await relaunched.load()
        guard case .needsDecision? = await relaunched.lastPendingOutcome else { Issue.record("expected L4 decision"); return }
        #expect(await relaunched.levelState == .changedElsewhere)
        #expect(await relaunched.pendingEditCount == 1, "journal kept")
        #expect(try rig.disk().publication == disk.publication, "nothing published")
        // The 30 s retry doesn't publish either.
        guard case .needsDecision = await relaunched.retryPendingEdits() else { Issue.record("retry published"); return }
        #expect(try rig.disk().publication == disk.publication)

        guard case .success = await relaunched.resolveConflictByCombining() else { Issue.record("combine failed"); return }
        #expect(Set(try rig.disk().payload.collections.map(\.name)) == ["Shared", "Queued offline", "Theirs"])
        #expect(await relaunched.pendingEditCount == 0)
    }

    /// Both Macs see the conflict and combine; the second combine finds everything already present (or loses
    /// the publication race and combines again). Either way both converge on a library with both changes.
    @Test func concurrentCombinesOnTwoMacsConverge() async throws {
        let rig = Rig()
        let (_, theirs, _) = try await rig.concurrentCopies()
        let providerB = FakeProviderVersions(recovery: rig.rig.recovery)
        providerB.add(theirs, to: rig.rig.containerFile, from: "This Mac")
        let macA = rig.store()
        let macB = rig.store(provider: providerB, recovery: RecoveryStore(root: rig.rig.dir.sub("RecoveryB")))
        _ = await macA.load()
        _ = await macB.load()
        let levelA = await macA.levelState, levelB = await macB.levelState
        #expect(levelA == .changedElsewhere && levelB == .changedElsewhere)
        guard case .success = await macA.resolveConflictByCombining() else { Issue.record("A combine failed"); return }
        var outcome = await macB.resolveConflictByCombining()
        if case .failure(.conflict) = outcome {
            _ = await macB.reload()
            if await macB.levelState == .changedElsewhere { outcome = await macB.resolveConflictByCombining() } else { outcome = .success(LibraryMergeSummary()) }
        }
        guard case .success = outcome else { Issue.record("B didn't converge: \(outcome)"); return }
        _ = await macA.reload()
        _ = await macB.reload()
        #expect(Set(try rig.disk().payload.collections.map(\.name)) == ["Shared", "Mine", "Theirs"])
        let finalA = await macA.levelState, finalB = await macB.levelState
        #expect(finalA == .ready && finalB == .ready)
        let libraryA = await macA.library, libraryB = await macB.library
        #expect(libraryA == libraryB)
    }
}

@Suite("Library containment (#117 review)")
struct LibraryContainmentTests {
    func base() -> LibraryModel {
        var library = LibraryModel()
        let ids = [ShowID(), ShowID()]
        library = LibraryReconciler.registering(ids[0], title: "A", publication: PublicationStamp(revision: 2, publicationID: UUID(), checksum: "sha256:a"), in: library)
        library = LibraryReconciler.registering(ids[1], title: "B", publication: nil, in: library)
        library.collections = [LibraryCollection(name: "C", showIDs: ids)]
        library.recentShowIDs = [ids[0]]
        return library
    }

    @Test func fieldForField() {
        let current = base()
        #expect(LibraryMerge.isContained(current, in: current))
        var renamed = current; renamed.entries[0].alias = "Other"
        #expect(!LibraryMerge.isContained(renamed, in: current), "alias")
        var reordered = current; reordered.collections[0].showIDs.reverse()
        #expect(!LibraryMerge.isContained(reordered, in: current), "member order")
        var recent = current; recent.recentShowIDs.append(current.entries[1].showID)
        #expect(!LibraryMerge.isContained(recent, in: current), "recents")
        var newer = current; newer.entries[0].lastKnownPublication = PublicationStamp(revision: 3, publicationID: UUID(), checksum: "sha256:n")
        #expect(!LibraryMerge.isContained(newer, in: current), "newer publication")
        var sameRevisionOther = current; sameRevisionOther.entries[0].lastKnownPublication = PublicationStamp(revision: 2, publicationID: UUID(), checksum: "sha256:o")
        #expect(!LibraryMerge.isContained(sameRevisionOther, in: current), "different save of the same revision")
        var older = current; older.entries[0].lastKnownPublication = PublicationStamp(revision: 1, publicationID: UUID(), checksum: "sha256:o")
        #expect(LibraryMerge.isContained(older, in: current), "an older recorded publication is contained")
        var unavailable = current; unavailable.entries[1].unavailable = UnavailableRecord(note: "missing", recordedAt: Date())
        #expect(!LibraryMerge.isContained(unavailable, in: current), "unavailable record")
        var fewer = current; fewer.collections = []
        #expect(LibraryMerge.isContained(fewer, in: current), "a subset is contained (ST-36 keeps everything)")
    }
}
