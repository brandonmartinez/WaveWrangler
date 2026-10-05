import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Fault-injection harness (WW-005/WW-049 gate: ≥100 interruptions per publication boundary).
///
/// Every iteration publishes a new candidate over a coherent document with a prior checkpoint, interrupts at
/// one boundary (crash before/after, partial write, torn non-atomic publish, stale read-back), then recovers
/// in a fresh "process" (new file operations, no in-memory state) and classifies the result:
///
/// - `old`: the previous valid revision is current;
/// - `new`: the complete new revision is current;
/// - `recoveredOld`: the current file is damaged (torn publish) and the newest whole validated checkpoint
///   (or byte-identical migration backup) is the previous revision.
///
/// `mixed` (any other value) and `zeroValid` (nothing valid anywhere) must be zero. Every iteration also
/// audits that no write targeted the synthetic source folder and that source bytes are unchanged.
///
/// Evidence label: **simulated/local, not provider-observed**. Exceptions model process death at a point;
/// they do not model power loss, kernel crashes or provider transport.
@Suite("Fault-injection harness", .serialized)
struct FaultInjectionHarnessTests {
    static let iterationsPerBoundary = 120

    struct Tally: CustomStringConvertible {
        var runs = 0, fired = 0, old = 0, new = 0, recoveredOld = 0, mixed = 0, zeroValid = 0
        var sourceWrites = 0, sourceChanges = 0, retried = 0
        var description: String {
            "runs=\(runs) faultsFired=\(fired) old=\(old) new=\(new) recoveredOld=\(recoveredOld) mixed=\(mixed) zeroValid=\(zeroValid) sourceWrites=\(sourceWrites) sourceChanges=\(sourceChanges)" + (retried > 0 ? " retriedOK=\(retried)" : "")
        }
    }

    static func variants(for boundary: PublicationBoundary) -> [(Double) -> Fault] {
        let crashes: [(Double) -> Fault] = [{ _ in .crash(boundary, .before) }, { _ in .crash(boundary, .after) }]
        switch boundary {
        case .stageWrite, .retainPrior, .acknowledge, .migrationStage:
            return crashes + [{ .partialWrite(boundary, fraction: $0) }]
        case .publish, .migrationPublish:
            return crashes + [{ .tornPublish(fraction: $0) }]
        case .readBackVerify:
            return crashes + [{ _ in .staleReadBack }]
        case .baseCheck, .stagedChecksum:
            return crashes
        }
    }

    static func cleanStaging(_ faults: FaultState) {
        for url in faults.writes where url.path.contains("TemporaryItems") || url.lastPathComponent.hasPrefix("NSIRD") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func audit(_ faults: FaultState, sourcesDir: URL, digests: [URL: String], into tally: inout Tally) {
        let prefix = sourcesDir.standardizedFileURL.path
        tally.sourceWrites += faults.writes.filter { $0.path.hasPrefix(prefix) }.count
        if !Fixtures.sourcesUnchanged(digests) { tally.sourceChanges += 1 }
    }

    // MARK: - Show document boundaries

    @Test(arguments: [PublicationBoundary.baseCheck, .stageWrite, .stagedChecksum, .retainPrior, .publish, .readBackVerify])
    func showPublicationBoundary(_ boundary: PublicationBoundary) throws {
        var tally = Tally()
        let variants = Self.variants(for: boundary)
        for index in 0..<Self.iterationsPerBoundary {
            var rng = SeededGenerator(seed: UInt64(index) &* 7919 &+ UInt64(boundary.rawValue.utf8.reduce(0) { $0 &+ Int($1) }))
            let fraction = Double.random(in: 0.05...0.95, using: &rng)
            let dir = TempDirectory("harness")
            let sourcesDir = dir.sub("Sources")
            let digests = try Fixtures.makeSources(in: sourcesDir, count: 3, seed: UInt64(index))
            let clean = Rig(dir: dir)
            let model = Fixtures.show(seed: UInt64(index), episodes: 1 + index % 4, sourcesPerEpisode: 1 + index % 5)
            let key = DocumentKey.show(model.show.id)
            let url = clean.url()
            let (old, base) = try clean.seedTwoRevisions(model, at: url)
            let new = try old.renamingShow(to: "New \(index)").addingEpisode(Episode(title: "Added \(index)"))

            let faults = FaultState(variants[index % variants.count](fraction))
            let faulty = Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: dir)
            do {
                _ = try faulty.publisher.publish(new, revision: 3, key: key, to: url, target: .inPlace(expectedBase: base))
            } catch is SimulatedCrash {
            } catch is PublicationError {
            }
            tally.runs += 1
            if faults.fired { tally.fired += 1 }

            // Recovery in a fresh process.
            let after = Rig(dir: dir)
            after.recovery.removeStagingLeftovers()
            switch after.opener.open(url, key: key) {
            case let .editable(document, _):
                if document.payload == old, document.revision == 2 { tally.old += 1 }
                else if document.payload == new, document.revision == 3 { tally.new += 1 }
                else { tally.mixed += 1 }
            case let .damaged(_, candidates):
                if let first = candidates.first, first.document.payload == old, first.document.revision == 2 { tally.recoveredOld += 1 }
                else if candidates.isEmpty { tally.zeroValid += 1 }
                else { tally.mixed += 1 }
            default:
                tally.zeroValid += 1
            }
            Self.audit(faults, sourcesDir: sourcesDir, digests: digests, into: &tally)
            Self.cleanStaging(faults)
        }
        Evidence.record("harness show boundary=\(boundary.rawValue) \(tally) [simulated/local, not provider-observed]")
        #expect(tally.runs >= 100)
        #expect(tally.fired == tally.runs, "every injected fault must actually fire")
        #expect(tally.mixed == 0 && tally.zeroValid == 0)
        #expect(tally.old + tally.new + tally.recoveredOld == tally.runs)
        #expect(tally.sourceWrites == 0 && tally.sourceChanges == 0)
    }

    // MARK: - Migration boundaries

    @Test(arguments: [PublicationBoundary.migrationStage, .migrationPublish])
    func migrationBoundary(_ boundary: PublicationBoundary) throws {
        var tally = Tally()
        let variants = Self.variants(for: boundary)
        for index in 0..<Self.iterationsPerBoundary {
            var rng = SeededGenerator(seed: UInt64(index) &+ 104_729)
            let fraction = Double.random(in: 0.05...0.95, using: &rng)
            let dir = TempDirectory("migration")
            let sourcesDir = dir.sub("Sources")
            let digests = try Fixtures.makeSources(in: sourcesDir, count: 2, seed: UInt64(index))
            let clean = Rig(dir: dir)
            let url = clean.url("Legacy.wwshow")
            let original = try SyntheticV0.bytes(seed: UInt64(index))
            try original.write(to: url)
            let key = DocumentKey(rawValue: "legacy-\(index)")

            let faults = FaultState(variants[index % variants.count](fraction))
            let faulty = Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: dir)
            do {
                _ = try DocumentMigrator(publisher: faulty.publisher, steps: [SyntheticV0.step]).migrate(url, key: key)
            } catch is SimulatedCrash {
            } catch is PublicationError {
            }
            tally.runs += 1
            if faults.fired { tally.fired += 1 }

            let after = Rig(dir: dir)
            after.recovery.removeStagingLeftovers()
            switch after.opener.open(url, key: key) {
            case .needsMigration:
                if try Data(contentsOf: url) == original {
                    tally.old += 1
                    // Retry from the untouched original succeeds.
                    let receipt = try DocumentMigrator(publisher: after.publisher, steps: [SyntheticV0.step]).migrate(url, key: key)
                    if try Data(contentsOf: receipt.backup) == original { tally.retried += 1 }
                } else {
                    tally.mixed += 1
                }
            case let .editable(document, _):
                if SyntheticV0.step.expectations(original, document.payload).isEmpty, document.revision == 5 { tally.new += 1 }
                else { tally.mixed += 1 }
            case .damaged:
                let backups = try after.recovery.migrationBackups(for: key)
                if backups.contains(where: { (try? Data(contentsOf: $0)) == original }) { tally.recoveredOld += 1 }
                else { tally.zeroValid += 1 }
            default:
                tally.zeroValid += 1
            }
            Self.audit(faults, sourcesDir: sourcesDir, digests: digests, into: &tally)
            Self.cleanStaging(faults)
        }
        Evidence.record("harness migration boundary=\(boundary.rawValue) \(tally) [simulated/local, not provider-observed]")
        #expect(tally.runs >= 100)
        #expect(tally.fired == tally.runs)
        #expect(tally.mixed == 0 && tally.zeroValid == 0)
        #expect(tally.retried == tally.old)
        #expect(tally.sourceWrites == 0 && tally.sourceChanges == 0)
    }

    // MARK: - Library publication + index acknowledgement

    @Test(arguments: [PublicationBoundary.stageWrite, .retainPrior, .publish, .readBackVerify, .acknowledge])
    func libraryBoundary(_ boundary: PublicationBoundary) async throws {
        var tally = Tally()
        let variants = Self.variants(for: boundary)
        for index in 0..<Self.iterationsPerBoundary {
            var rng = SeededGenerator(seed: UInt64(index) &+ 15_485_863)
            let fraction = Double.random(in: 0.05...0.95, using: &rng)
            let dir = TempDirectory("library")
            let sourcesDir = dir.sub("Sources")
            let digests = try Fixtures.makeSources(in: sourcesDir, count: 2, seed: UInt64(index))
            let settings = InMemoryLibrarySettings()
            func store(ops: any FileOperations, hooks: any PublicationHooks) -> LibraryStore {
                LibraryStore(
                    containerFolder: dir.sub("Container"), settings: settings, bookmarks: PlainFolderBookmarks(),
                    recovery: RecoveryStore(root: dir.sub("Recovery"), ops: ops),
                    indexCache: LibraryIndexCache(url: dir.sub("Caches").appending(path: "index.json"), ops: ops),
                    ops: ops, hooks: hooks
                )
            }
            let shows = (0..<(3 + index % 5)).map { Fixtures.show(seed: UInt64(index * 10 + $0)) }
            let clean = store(ops: LocalFileOperations(), hooks: NoPublicationHooks())
            #expect(await clean.load() == .created)
            _ = try await clean.update { _ in Fixtures.library(shows: shows, seed: UInt64(index)) }
            let old = try #require(await clean.library)
            let new = LibraryReconciler.reconcile(
                LibraryReconciler.registering(ShowID(), title: "New \(index)", revision: 1, in: old),
                observations: [shows[0].show.id: .missing], at: Date(timeIntervalSince1970: 1_000)
            )

            let faults = FaultState(variants[index % variants.count](fraction))
            let faultyStore = store(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            _ = await faultyStore.load()
            _ = try? await faultyStore.update { _ in new }
            tally.runs += 1
            if faults.fired { tally.fired += 1 }

            let after = store(ops: LocalFileOperations(), hooks: NoPublicationHooks())
            switch await after.load() {
            case .ready:
                let library = await after.library
                if library == old { tally.old += 1 } else if library == new { tally.new += 1 } else { tally.mixed += 1 }
                // The derived index must agree with the canonical library whatever happened to the cache.
                let index = await after.index
                let digest = try RevisionFingerprint.digest(Data(contentsOf: try #require(await after.currentLibraryURL())))
                if let library, index != LibraryIndex.build(from: library, libraryDigest: digest) { tally.mixed += 1 }
            case let .damaged(_, revisions):
                if revisions.first == 2 {
                    tally.recoveredOld += 1
                    if case .success = await after.recoverAsNewCopy(revision: 2), await after.library == old { tally.retried += 1 }
                } else {
                    tally.zeroValid += 1
                }
            default:
                tally.zeroValid += 1
            }
            Self.audit(faults, sourcesDir: sourcesDir, digests: digests, into: &tally)
            Self.cleanStaging(faults)
        }
        Evidence.record("harness library boundary=\(boundary.rawValue) \(tally) [simulated/local, not provider-observed]")
        #expect(tally.runs >= 100)
        #expect(tally.fired == tally.runs)
        #expect(tally.mixed == 0 && tally.zeroValid == 0)
        #expect(tally.retried == tally.recoveredOld)
        #expect(tally.sourceWrites == 0 && tally.sourceChanges == 0)
    }
}
