import Foundation
import Testing
import WWCore
@testable import WWPersistence

private typealias ShowCoder = JSONEnvelopeCoder<ShowDocumentModel>

@Suite("M1 durability holdout — publication boundaries and library strata", .serialized, .enabled(if: Holdout.enabled, "WW_HOLDOUT=1"))
struct HoldoutBoundaryTests {
    // MARK: DUR-006 publisher path, P1–P7 (injected)

    @Test(arguments: PublicationBoundary.show)
    func dur006PublisherBoundary(_ boundary: PublicationBoundary) async {
        let result = await runFamily("M1-DUR-006", cell: "publisher/\(boundary.rawValue)", calibration: 10, holdout: 100,
                                     seedFixture: "M1-DUR-006/publisher/\(boundary.rawValue)") { index, seed in
            var rng = SeededGenerator(seed: seed)
            let operation = boundary == .libraryAcknowledged ? "save" : ["save", "autosave", "saveAs"][index % 3]
            let variants = FaultInjectionHarnessTests.variants(for: boundary)
            let fraction = Double.random(in: 0.05...0.95, using: &rng)
            let dir = TempDirectory("dur006")
            let sourcesDir = dir.sub("Sources")
            let digests = try Fixtures.makeSources(in: sourcesDir, count: 2, seed: seed)
            let clean = Rig(dir: dir)
            let model = HoldoutGen.show(&rng)
            let key = DocumentKey.show(model.show.id)
            let url = clean.url()
            let (old, base) = try clean.seedTwoRevisions(model, at: url)
            let oldStamp = try #require(base.publication)
            let new = try #require(HoldoutGen.edits(1...20, on: old, &rng).last)
            let saveAsURL = dir.sub("Elsewhere").appending(path: "Saved As.wwshow")
            // Library that acknowledged r2, plus a derived index.
            let libraryURL = dir.sub("Library").appending(path: "Library.wwlibrary")
            let libraryModel = LibraryReconciler.acknowledging(model.show.id, title: old.show.title, publication: oldStamp, in: LibraryModel())
            let libraryBase = try DocumentPublisher(coder: LibraryCoder.library, recovery: clean.recovery)
                .publish(libraryModel, revision: 1, key: .library, to: libraryURL, target: .newLocation).fingerprint
            let indexURL = dir.sub("Caches").appending(path: "index.json")

            // Save As retains no prior, so nothing is written right after P1: only process death applies there.
            let fault = operation == "saveAs" && boundary == .candidateValidated ? .crash(at: boundary) : variants[index % variants.count](fraction)
            let faults = FaultState(fault)
            let ops = FaultInjectingFileOperations(faults: faults)
            let faulty = Rig(ops: ops, hooks: FaultHooks(faults: faults), dir: dir)
            let libraryPublisher = DocumentPublisher(coder: LibraryCoder.library, ops: ops, recovery: faulty.recovery)
            let followUp = PublicationFollowUp(
                acknowledgeLibrary: { receipt in
                    let updated = LibraryReconciler.acknowledging(model.show.id, title: new.show.title, publication: receipt.publication, in: libraryModel)
                    _ = try libraryPublisher.publish(updated, revision: 2, key: .library, to: libraryURL, target: .inPlace(expectedBase: libraryBase))
                },
                updateIndex: { _ in
                    let bytes = try ops.read(libraryURL)
                    try LibraryIndexCache(url: indexURL, ops: ops).store(LibraryIndex.build(from: try LibraryCoder.library.decode(bytes).payload,
                                                                                            libraryDigest: RevisionFingerprint.digest(bytes)))
                }
            )
            do {
                if operation == "saveAs" {
                    _ = try faulty.publisher.publish(new, revision: 3, key: key, to: saveAsURL, target: .saveAs(replacingExisting: false), retainPrior: false, followUp: followUp)
                } else {
                    _ = try faulty.publisher.publish(new, revision: 3, key: key, to: url, target: .inPlace(expectedBase: base), followUp: followUp)
                }
            } catch is SimulatedCrash {
            } catch is PublicationError {
            }
            try check(faults.fired, "fault did not fire")
            FaultInjectionHarnessTests.cleanStaging(faults)

            // Recovery in a fresh "process".
            let after = Rig(dir: dir)
            after.recovery.removeStagingLeftovers()
            let target = operation == "saveAs" ? saveAsURL : url
            var outcome: String
            switch after.opener.open(target, key: key) {
            case let .editable(document, _):
                if document.payload == old, document.revision == 2 { outcome = "old" }
                else if document.payload == new, document.revision == 3 { outcome = "new" }
                else { throw CaseFailure(description: "mixed revision") }
            case .damaged where operation == "saveAs":
                // Torn (non-atomic) publication of a new Save As destination: refused on open; the original is intact.
                outcome = "destinationRefused"
            case let .damaged(_, candidates):
                guard let first = candidates.first, first.document.payload == old, first.document.revision == 2 else { throw CaseFailure(description: "no coherent checkpoint") }
                outcome = "recoveredOld"
            case .unreadable where operation == "saveAs":
                outcome = "absent"   // Save As destination never created
            default:
                throw CaseFailure(description: "zero valid revisions")
            }
            if operation == "saveAs" { try check(decodeShow(url)?.payload == old, "original changed by Save As") }
            // A validated coherent prior is in the recovery store.
            let priors = try after.recovery.validatedCheckpoints(for: key, coder: ShowCoder.show)
            try check(priors.contains { $0.document.payload == model || $0.document.payload == old }, "no validated prior")
            // The library never claims an unverified publication; the index always matches the library.
            let library = try #require(decodeLibrary(libraryURL), "library unreadable")
            let claimed = library.payload.entries.first?.lastKnownPublication
            if claimed != oldStamp {
                try check(outcome == "new", "library acknowledged a publication that is not on disk")
            }
            let rebuilt = LibraryIndexCache(url: indexURL).index(for: library.payload, libraryDigest: RevisionFingerprint.digest(try Data(contentsOf: libraryURL))).index
            try check(rebuilt == LibraryIndex.build(from: library.payload, libraryDigest: RevisionFingerprint.digest(try Data(contentsOf: libraryURL))), "index")
            let prefix = sourcesDir.standardizedFileURL.path
            try check(!faults.writes.contains { $0.path.hasPrefix(prefix) } && Fixtures.sourcesUnchanged(digests), "source write")
            return CaseResult("\(operation):\(outcome)")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-027 library boundaries L1–L6 × location strata (injected)

    @Test(arguments: LibraryStratum.allCases.flatMap { stratum in PublicationBoundary.library.map { (stratum, $0) } })
    func dur027LibraryBoundary(_ stratum: LibraryStratum, _ boundary: PublicationBoundary) async {
        let cell = "\(stratum.rawValue)/\(boundary.libraryLabel)"
        let result = await runFamily("M1-DUR-027", cell: cell, calibration: 10, holdout: 100,
                                     notes: stratum == .userFolder ? ["User-folder stratum reached through a real read-write security-scoped folder bookmark in an unsandboxed test process."] : [],
                                     seedFixture: "M1-DUR-027/\(cell)") { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variants = FaultInjectionHarnessTests.variants(for: boundary)
            let fraction = Double.random(in: 0.05...0.95, using: &rng)
            let rig = StratumRig(stratum, label: "dur027")
            let (_, old) = try await rig.make(HoldoutGen.library(HoldoutGen.shows(3...12, &rng), &rng))
            var new = LibraryReconciler.registering(ShowID(Fixtures.uuid(&rng)), title: "New \(index)", publication: nil, in: old)
            new.collections.append(LibraryCollection(id: CollectionID(Fixtures.uuid(&rng)), name: "Added \(index)", showIDs: [new.entries[0].showID]))
            // In the user-folder stratum the prior was already retained by the move, so nothing is written right
            // after L1: only process death applies there.
            let fault = stratum == .userFolder && boundary == .candidateValidated ? .crash(at: boundary) : variants[index % variants.count](fraction)
            let faults = FaultState(fault)
            let faulty = rig.store(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
            _ = await faulty.load()
            _ = try? await faulty.update { _ in new }
            try check(faults.fired, "fault did not fire")
            FaultInjectionHarnessTests.cleanStaging(faults)
            let outcome = await classifyLibrary(rig.store(), old: old, new: new)
            try check(["old", "new", "recoveredOld"].contains(outcome), "outcome \(outcome)")
            // Index never ahead of the canonical library.
            let after = rig.store()
            _ = await after.load()
            if let library = await after.library, let index = await after.index, let bytes = try? Data(contentsOf: try #require(await after.currentLibraryURL())) {
                try check(index == LibraryIndex.build(from: library, libraryDigest: RevisionFingerprint.digest(bytes)), "index differs from library")
            }
            return CaseResult(outcome)
        }
        expectAllPassed(result)
    }

    // MARK: DUR-019 library <-> project reconciliation interruption

    @Test(arguments: LibraryStratum.allCases)
    func dur019Reconciliation(_ stratum: LibraryStratum) async {
        let result = await runFamily("M1-DUR-019", cell: stratum.rawValue, calibration: 10, holdout: 100, seedFixture: "M1-DUR-019/\(stratum.rawValue)") { index, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = StratumRig(stratum, label: "dur019")
            let showRig = Rig(dir: rig.dir)
            let model = HoldoutGen.show(&rng)
            let showURL = showRig.url()
            let (old, base) = try showRig.seedTwoRevisions(model, at: showURL)
            let oldStamp = try #require(base.publication)
            var libraryModel = HoldoutGen.library([old] + HoldoutGen.shows(1...6, &rng), &rng)
            libraryModel = LibraryReconciler.acknowledging(old.show.id, title: old.show.title, publication: oldStamp, in: libraryModel)
            let (_, libraryBefore) = try await rig.make(libraryModel)
            let new = try #require(HoldoutGen.edits(1...20, on: old, &rng).last)
            // Interrupt: during show publication (no ack may follow), between publication and ack, or during the
            // library publication itself.
            let point = ["showP3", "beforeAck", "L1", "L2", "L3", "L4", "L5", "L6"][index % 8]
            var showPublished = false
            if point == "showP3" {
                let faults = FaultState(.crash(at: .baseChecked))
                _ = try? Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: rig.dir)
                    .publisher.publish(new, revision: 3, key: .show(model.show.id), to: showURL, target: .inPlace(expectedBase: base))
            } else {
                let receipt = try showRig.publisher.publish(new, revision: 3, key: .show(model.show.id), to: showURL, target: .inPlace(expectedBase: base))
                showPublished = true
                if point != "beforeAck" {
                    let boundary = PublicationBoundary.library[Int(point.dropFirst())! - 1]
                    let faults = FaultState(.crash(at: boundary))
                    let faulty = rig.store(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults))
                    _ = await faulty.load()
                    _ = await faulty.acknowledgeShowPublication(new.show.id, title: new.show.title, publication: receipt.publication)
                    try check(faults.fired, "fault did not fire")
                    FaultInjectionHarnessTests.cleanStaging(faults)
                }
            }
            // Fresh process: the library never claims a revision that is not coherent on disk.
            let store = rig.store()
            if case .damaged(_, let revisions) = await store.load(), let first = revisions.first { _ = await store.recoverAsNewCopy(revision: first) }
            let library = try #require(await store.library, "library unavailable")
            let onDisk = try #require(decodeShow(showURL), "show unreadable")
            let claimed = library.entries.first { $0.showID == old.show.id }?.lastKnownPublication
            try check(claimed == oldStamp || claimed == onDisk.publication, "library claims \(String(describing: claimed?.revision)) not on disk")
            try check(showPublished ? onDisk.payload == new : onDisk.payload == old, "show state")
            // Reopen reconciles; prior library state (aliases, collections, order, unavailable entries) retained.
            _ = await store.reconcile([old.show.id: .available(title: onDisk.payload.show.title, publication: onDisk.publication)])
            let reconciled = try #require(await store.library)
            try check(reconciled.entries.first { $0.showID == old.show.id }?.lastKnownPublication == onDisk.publication, "not reconciled")
            try check(reconciled.collections == libraryBefore.collections && reconciled.recentShowIDs == libraryBefore.recentShowIDs, "collections/recents")
            try check(reconciled.entries.map(\.showID) == libraryBefore.entries.map(\.showID), "entries dropped")
            try check(zip(reconciled.entries, libraryBefore.entries).allSatisfy { $0.alias == $1.alias }, "aliases")
            try check(zip(reconciled.entries, libraryBefore.entries).allSatisfy { $0.showID == old.show.id || $0.unavailable == $1.unavailable }, "unavailable entries")
            return CaseResult("\(point):\(claimed == oldStamp ? "ackOld" : "ackNew")")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-022 unknown-newer library

    @Test(arguments: LibraryStratum.allCases)
    func dur022UnknownNewerLibrary(_ stratum: LibraryStratum) async {
        let result = await runFamily("M1-DUR-022", cell: stratum.rawValue, calibration: 10, holdout: 100, seedFixture: "M1-DUR-022/\(stratum.rawValue)") { index, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = StratumRig(stratum, label: "dur022")
            let shows = HoldoutGen.shows(1...6, &rng)
            _ = try await rig.make(HoldoutGen.library(shows, &rng))
            let showRig = Rig(dir: rig.dir)
            let showURL = showRig.url()
            _ = try showRig.publisher.publish(shows[0], revision: 1, key: .show(shows[0].show.id), to: showURL, target: .newLocation)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rig.libraryFile)) as? [String: Any])
            object["schemaVersion"] = SchemaVersion.library + HoldoutGen.int(1...5, &rng)
            if index % 2 == 1 {
                var payload = try #require(object["payload"] as? [String: Any])
                payload["fromTheFuture"] = true
                object["payload"] = payload
            }
            let newer = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try newer.write(to: rig.libraryFile)
            let store = rig.store()
            guard case .refusedNewerFormat = await store.load() else { throw CaseFailure(description: "not refused") }
            try check(await store.levelState == .newerFormat, "level state")
            var refusals = 0
            if case .failed(.readOnly) = try await store.update({ var l = $0; l.collections.append(LibraryCollection(name: "X")); return l }) { refusals += 1 }
            if case .failure = await store.moveLibrary(to: rig.dir.sub("Move Target")) { refusals += 1 }
            if case .failure = await store.moveLibraryToAppContainer() { refusals += 1 }
            if case .failure = await store.useLibrary(in: rig.libraryFile.deletingLastPathComponent()) { refusals += 1 }
            try check(refusals == 4, "refused \(refusals)/4")
            try check(try Data(contentsOf: rig.libraryFile) == newer, "bytes changed")
            try check(!FileManager.default.fileExists(atPath: rig.dir.url.appending(path: "Move Target/Library.wwlibrary").path), "down-save written")
            guard case .editable = showRig.opener.open(showURL) else { throw CaseFailure(description: "show not openable") }
            return CaseResult("refused4of4+showOpenable")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-023 corrupt library and prior recovery

    @Test(arguments: LibraryStratum.allCases)
    func dur023CorruptLibrary(_ stratum: LibraryStratum) async {
        let result = await runFamily("M1-DUR-023", cell: stratum.rawValue, calibration: 10, holdout: 100, seedFixture: "M1-DUR-023/\(stratum.rawValue)") { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variant = Corruption.allCases[index % Corruption.allCases.count]
            let rig = StratumRig(stratum, label: "dur023")
            let (store, stored) = try await rig.make(HoldoutGen.library(HoldoutGen.shows(2...8, &rng), &rng))
            _ = store
            var otherRng = SeededGenerator(seed: seed &+ 7)
            let other = try LibraryCoder.library.encode(HoldoutGen.library(HoldoutGen.shows(1...3, &otherRng), &otherRng), revision: 4)
            let suspect = rig.libraryFile
            let corrupt = try variant.apply(to: try Data(contentsOf: suspect), other: other, &rng)
            try corrupt.write(to: suspect)
            let reopened = rig.store()
            let outcome = await reopened.load()
            guard case let .damaged(_, revisions) = outcome else { throw CaseFailure(description: "\(variant) → \(outcome)") }
            let first = try #require(revisions.first)
            guard case .success = await reopened.recoverAsNewCopy(revision: first) else { throw CaseFailure(description: "recover failed") }
            try check(await reopened.library?.content == stored.content, "recovered library differs from the last verified one")
            try check(try Data(contentsOf: suspect) == corrupt, "suspect file changed")
            return CaseResult("\(variant.rawValue):recoveredPrior")
        }
        expectAllPassed(result)
    }
}
