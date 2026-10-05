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
