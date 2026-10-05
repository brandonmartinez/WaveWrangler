import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Fault-injection harness (WW-005/WW-049 gate: ≥100 interruptions per publication boundary; WW-009 C3
/// boundaries P1–P7 for shows, L1–L6 for the library, plus migration M1–M3).
///
/// Every iteration publishes a new candidate over a coherent document that already has a prior checkpoint,
/// interrupts at one boundary (process death at the boundary, a partial write in the following step, a torn
/// non-atomic publish after P4, or a stale read-back after P5), then recovers in a fresh "process" (new file
/// operations, no in-memory state) and classifies the result:
///
/// - `old`: the previous valid revision is current;
/// - `new`: the complete new revision is current;
/// - `recoveredOld`: the current file is damaged (torn publish) and the newest whole validated checkpoint
///   (or byte-identical migration backup) is the previous revision.
///
/// `mixed` (any other value, or a library acknowledgement ahead of the verified show) and `zeroValid`
/// (nothing valid anywhere) must be zero. Every iteration also audits that no write targeted the synthetic
/// source folder and that source bytes are unchanged.
///
/// Evidence label: **simulated/local, not provider-observed**. Injected exceptions model process death at a
/// point on this host's APFS volume; they do not model power loss, kernel crashes or provider transport.
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

    /// Fault variants applied round-robin at each boundary.
    static func variants(for boundary: PublicationBoundary) -> [(Double) -> Fault] {
        let crash: (Double) -> Fault = { _ in .crash(at: boundary) }
        let partial: (Double) -> Fault = { .partialWrite(after: boundary, fraction: $0) }
        switch boundary {
        case .candidateValidated, .baseChecked, .readBackVerified, .libraryAcknowledged, .migrationOriginalRead:
            return [crash, partial]
        case .stagedFlushed:
            return [crash, { .tornPublish(fraction: $0) }]
        case .published:
            return [crash, { _ in .staleReadBack }]
        case .migrationValidated:
            return [crash, { .tornPublish(fraction: $0) }, { .partialWrite(after: .baseChecked, fraction: $0) }]
        case .priorRetained, .migrationBackupPreserved:
            return [crash]
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

    static func fraction(_ index: Int, _ salt: UInt64) -> Double {
        var rng = SeededGenerator(seed: UInt64(index) &* 7919 &+ salt)
        return Double.random(in: 0.05...0.95, using: &rng)
    }

    // MARK: - Show document P1–P7 (with library acknowledgement and derived index)

    @Test(arguments: PublicationBoundary.show)
    func showBoundary(_ boundary: PublicationBoundary) throws {
        var tally = Tally()
        let variants = Self.variants(for: boundary)
        let libraryCoder = JSONEnvelopeCoder<LibraryModel>.library
        for index in 0..<Self.iterationsPerBoundary {
            let dir = TempDirectory("harness")
            let sourcesDir = dir.sub("Sources")
            let digests = try Fixtures.makeSources(in: sourcesDir, count: 3, seed: UInt64(index))
            let clean = Rig(dir: dir)
            let model = Fixtures.show(seed: UInt64(index), episodes: 1 + index % 4, sourcesPerEpisode: 1 + index % 5)
            let key = DocumentKey.show(model.show.id)
            let url = clean.url()
            let (old, base) = try clean.seedTwoRevisions(model, at: url)
            let oldStamp = try #require(base.publication)
            let new = try old.renamingShow(to: "New \(index)").addingEpisode(Episode(title: "Added \(index)"))

            // A library that has acknowledged r2.
            let libraryURL = dir.sub("Library").appending(path: "Library.wwlibrary")
            let libraryModel = LibraryReconciler.acknowledging(model.show.id, title: old.show.title, publication: oldStamp, in: LibraryModel())
            let libraryBase = try DocumentPublisher(coder: libraryCoder, recovery: clean.recovery)
                .publish(libraryModel, revision: 1, key: .library, to: libraryURL, target: .newLocation).fingerprint
            let indexURL = dir.sub("Caches").appending(path: "index.json")

            let faults = FaultState(variants[index % variants.count](Self.fraction(index, UInt64(boundary.rawValue.utf8.first!))))
            let ops = FaultInjectingFileOperations(faults: faults)
            let faulty = Rig(ops: ops, hooks: FaultHooks(faults: faults), dir: dir)
            let libraryPublisher = DocumentPublisher(coder: libraryCoder, ops: ops, recovery: faulty.recovery)
            let cache = LibraryIndexCache(url: indexURL, ops: ops)
            var acknowledgedLibrary: (LibraryModel, String)?
            let followUp = PublicationFollowUp(
                acknowledgeLibrary: { receipt in
                    let updated = LibraryReconciler.acknowledging(model.show.id, title: new.show.title, publication: receipt.publication, in: libraryModel)
                    let libraryReceipt = try libraryPublisher.publish(updated, revision: 2, key: .library, to: libraryURL,
                                                                      target: .inPlace(expectedBase: libraryBase))
                    acknowledgedLibrary = (updated, libraryReceipt.fingerprint.byteDigest)
                },
                updateIndex: { _ in
                    if let (library, digest) = acknowledgedLibrary { try cache.store(LibraryIndex.build(from: library, libraryDigest: digest)) }
                }
            )
            do {
                _ = try faulty.publisher.publish(new, revision: 3, key: key, to: url, target: .inPlace(expectedBase: base), followUp: followUp)
            } catch is SimulatedCrash {
            } catch is PublicationError {
            }
            tally.runs += 1
            if faults.fired { tally.fired += 1 }

            // Recovery in a fresh process.
            let after = Rig(dir: dir)
            after.recovery.removeStagingLeftovers()
            var showIsNew = false
            switch after.opener.open(url, key: key) {
            case let .editable(document, _):
                if document.payload == old, document.revision == 2 { tally.old += 1 }
                else if document.payload == new, document.revision == 3 { tally.new += 1; showIsNew = true }
                else { tally.mixed += 1 }
            case let .damaged(_, candidates):
                if let first = candidates.first, first.document.payload == old, first.document.revision == 2 { tally.recoveredOld += 1 }
                else if candidates.isEmpty { tally.zeroValid += 1 }
                else { tally.mixed += 1 }
            default:
                tally.zeroValid += 1
            }
            // The library is coherent and never acknowledges a publication that is not verified on disk.
            let libraryOpener = DocumentOpener(coder: libraryCoder, recovery: after.recovery)
            if case let .editable(library, libraryFingerprint) = libraryOpener.open(libraryURL, key: .library),
               let stamp = library.payload.entries.first?.lastKnownPublication {
                if stamp != oldStamp, !showIsNew { tally.mixed += 1 }
                let derived = LibraryIndexCache(url: indexURL).index(for: library.payload, libraryDigest: libraryFingerprint.byteDigest).index
                if derived != LibraryIndex.build(from: library.payload, libraryDigest: libraryFingerprint.byteDigest) { tally.mixed += 1 }
            } else {
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

    // MARK: - Migration M1–M3

    @Test(arguments: PublicationBoundary.migration)
    func migrationBoundary(_ boundary: PublicationBoundary) throws {
        var tally = Tally()
        let variants = Self.variants(for: boundary)
        for index in 0..<Self.iterationsPerBoundary {
            let dir = TempDirectory("migration")
            let sourcesDir = dir.sub("Sources")
            let digests = try Fixtures.makeSources(in: sourcesDir, count: 2, seed: UInt64(index))
            let clean = Rig(dir: dir)
            let url = clean.url("Legacy.wwshow")
            let original = try SyntheticV0.bytes(seed: UInt64(index))
            try original.write(to: url)
            let key = DocumentKey(rawValue: "legacy-\(index)")

            let faults = FaultState(variants[index % variants.count](Self.fraction(index, 104_729)))
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

    // MARK: - Library L1–L6 (+ derived index after L6)

    @Test(arguments: PublicationBoundary.library)
    func libraryBoundary(_ boundary: PublicationBoundary) async throws {
        var tally = Tally()
        let variants = Self.variants(for: boundary)
        for index in 0..<Self.iterationsPerBoundary {
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
                LibraryReconciler.registering(ShowID(), title: "New \(index)", publication: nil, in: old),
                observations: [shows[0].show.id: .missing], at: Date(timeIntervalSince1970: 1_000)
            )

            let faults = FaultState(variants[index % variants.count](Self.fraction(index, 15_485_863)))
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
        Evidence.record("harness library boundary=\(boundary.libraryLabel) \(tally) [simulated/local, not provider-observed]")
        #expect(tally.runs >= 100)
        #expect(tally.fired == tally.runs)
        #expect(tally.mixed == 0 && tally.zeroValid == 0)
        #expect(tally.retried == tally.recoveredOld)
        #expect(tally.sourceWrites == 0 && tally.sourceChanges == 0)
    }
}
