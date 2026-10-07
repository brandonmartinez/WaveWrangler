import Darwin
import Foundation
import Testing
import WWCore
@testable import WWPersistence

private typealias ShowCoder = JSONEnvelopeCoder<ShowDocumentModel>

@Suite("M1 durability holdout — real processes", .serialized, .enabled(if: Holdout.enabled, "WW_HOLDOUT=1"))
struct HoldoutProcessTests {
    // MARK: DUR-009 two-process competing writers

    @Test func dur009TwoProcessRaces() async {
        let result = await runFamily("M1-DUR-009", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = Rig(label: "dur009")
            let model = HoldoutGen.show(&rng)
            let url = rig.url()
            _ = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            let delays = [HoldoutGen.int(0...20, &rng), HoldoutGen.int(0...20, &rng)]
            var running: [MultiProcessTests.GatedProbe] = []
            defer { for probe in running { probe.cancelIfRunning() } }
            for (writer, delay) in zip(["A", "B"], delays) {
                running.append(try MultiProcessTests.launchGated(writer: writer, [
                    "save", "--file", url.path, "--title", "Process \(writer) \(index)", "--recovery", rig.recovery.root.path,
                    "--delay-ms", String(delay),
                ]))
            }
            for probe in running { try probe.waitUntilReady() }
            for probe in running { try probe.releaseToSave() }
            let outputs = running.map { $0.finish() }
            let saved = outputs.filter { $0["result"] as? String == "saved" }
            let conflicts = outputs.filter { $0["result"] as? String == "conflict" }
            try check(saved.count == 1 && conflicts.count == 1, "outcomes \(outputs.map { $0["result"] ?? "?" })")
            let onDisk = try #require(decodeShow(url), "on-disk state is not a whole valid revision")
            try check(onDisk.payload.show.title == saved[0]["title"] as? String, "winner not on disk")
            let candidate = try #require((conflicts[0]["preservedCandidate"] as? String).map(URL.init(fileURLWithPath:)))
            try check(decodeShow(candidate)?.payload.show.title == conflicts[0]["title"] as? String, "loser's work not recoverable")
            return CaseResult("oneSavedOneConflict")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-021 SIGKILL at show publication boundaries P1–P7 (publisher path)

    @Test(arguments: PublicationBoundary.show)
    func dur021ShowKill(_ boundary: PublicationBoundary) async {
        let result = await runFamily("M1-DUR-021", cell: "publisher/\(boundary.rawValue)", calibration: 5, holdout: 100,
                                     notes: ["Owned helper process killed with SIGKILL exactly at the boundary (publisher path). The separate NSDocument-path random-kill set is reported with the native runner."],
                                     seedFixture: "M1-DUR-021/publisher/\(boundary.rawValue)") { _, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = Rig(label: "dur021")
            let model = HoldoutGen.show(&rng)
            let url = rig.url()
            let (old, base) = try rig.seedTwoRevisions(model, at: url)
            let oldStamp = try #require(base.publication)
            let libraryURL = rig.dir.sub("Library").appending(path: "Library.wwlibrary")
            _ = try DocumentPublisher(coder: LibraryCoder.library, recovery: rig.recovery).publish(
                LibraryReconciler.acknowledging(model.show.id, title: old.show.title, publication: oldStamp, in: LibraryModel()),
                revision: 1, key: .library, to: libraryURL, target: .newLocation
            )
            let indexURL = rig.dir.sub("Caches").appending(path: "index.json")
            let run = try ProbeProcess.run(["kill-at", "--file", url.path, "--boundary", boundary.rawValue, "--recovery", rig.recovery.root.path,
                                            "--library", libraryURL.path, "--index", indexURL.path])
            try check(run.signaled && run.status == SIGKILL, "helper not SIGKILLed at \(boundary.rawValue) (status \(run.status))")
            rig.recovery.removeStagingLeftovers()
            let outcome: String
            switch rig.opener.open(url, key: .show(model.show.id)) {
            case let .editable(document, _):
                if document.payload == old, document.revision == 2 { outcome = "old" }
                else if document.payload.show.title == "Killed at \(boundary.rawValue)", document.revision == 3 { outcome = "new" }
                else { throw CaseFailure(description: "mixed") }
            case let .damaged(_, candidates):
                guard candidates.first?.document.payload == old else { throw CaseFailure(description: "zero valid") }
                outcome = "recoveredOld"
            default: throw CaseFailure(description: "zero valid")
            }
            let priors = try rig.recovery.validatedCheckpoints(for: .show(model.show.id), coder: ShowCoder.show)
            try check(!priors.isEmpty, "recovery store has no coherent prior")
            let library = try #require(decodeLibrary(libraryURL), "library unreadable")
            let claimed = library.payload.entries.first?.lastKnownPublication
            if claimed != oldStamp { try check(outcome == "new" && claimed == decodeShow(url)?.publication, "library claims an unverified publication") }
            let bytes = try Data(contentsOf: libraryURL)
            let index = LibraryIndexCache(url: indexURL).index(for: library.payload, libraryDigest: RevisionFingerprint.digest(bytes)).index
            try check(index == LibraryIndex.build(from: library.payload, libraryDigest: RevisionFingerprint.digest(bytes)), "index")
            return CaseResult("\(outcome)\(claimed == oldStamp ? "" : "+acked")")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-028 SIGKILL at library publication boundaries L1–L6 (user-chosen folder)

    @Test(arguments: PublicationBoundary.library)
    func dur028LibraryKill(_ boundary: PublicationBoundary) async {
        let result = await runFamily("M1-DUR-028", cell: boundary.libraryLabel, calibration: 5, holdout: 100,
                                     notes: ["User-chosen-folder stratum; the helper and the test use path bookmarks (no sandbox extension)."],
                                     seedFixture: "M1-DUR-028/\(boundary.libraryLabel)") { index, seed in
            var rng = SeededGenerator(seed: seed)
            let dir = TempDirectory("dur028")
            let settingsURL = dir.url.appending(path: "settings.json")
            let settings = FileLibrarySettingsForTests(url: settingsURL)
            let container = dir.sub("Container"), folder = dir.sub("User Folder"), cache = dir.sub("Caches").appending(path: "index.json")
            let recovery = RecoveryStore(root: dir.sub("Recovery"))
            func store() -> LibraryStore {
                LibraryStore(containerFolder: container, settings: settings, bookmarks: PlainFolderBookmarks(), recovery: recovery, indexCache: LibraryIndexCache(url: cache))
            }
            let setup = store()
            _ = await setup.load()
            _ = try await setup.update { var model = HoldoutGen.library(HoldoutGen.shows(2...8, &rng), &rng); model.libraryID = $0.libraryID; return model }
            guard case .success(.moved) = await setup.moveLibrary(to: folder) else { throw CaseFailure(description: "move") }
            let old = try #require(await setup.library)
            let name = "Killed \(index)"
            let run = try ProbeProcess.run(["library-kill-at", "--file", settingsURL.path, "--container", container.path, "--recovery", recovery.root.path,
                                            "--cache", cache.path, "--boundary", boundary.rawValue, "--collection", name])
            try check(run.signaled && run.status == SIGKILL, "helper not SIGKILLed (status \(run.status) \(run.output))")
            var new = old
            new.collections.append(LibraryCollection(name: name))
            let after = store()
            switch await after.load() {
            case .ready:
                let library = try #require(await after.library)
                if library.content == old.content { return CaseResult("old") }
                try check(library.collections.map(\.name) == old.collections.map(\.name) + [name] && library.entries == old.entries, "mixed library")
                return CaseResult("new")
            case let .damaged(_, revisions):
                guard let first = revisions.first, case .success = await after.recoverAsNewCopy(revision: first),
                      await after.library?.content == old.content else { throw CaseFailure(description: "zero valid") }
                return CaseResult("recoveredOld")
            case let other:
                throw CaseFailure(description: "\(other)")
            }
        }
        expectAllPassed(result)
    }

    // MARK: DUR-029 reopen from the library after relaunch, then Save

    @Test func dur029ReopenAfterRelaunch() async {
        let result = await runFamily("M1-DUR-029", calibration: 10, holdout: 100,
                                     notes: [
                                         "New-process cycles via wwpersist-probe using real read-write security-scoped document bookmarks in an unsandboxed process (no sandbox extension).",
                                         "'revoked' is modelled by an unusable bookmark or permission-denied file; sandbox grant revocation and read-only source scopes are not evidenced headlessly.",
                                     ]) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variant = ["normal", "staleBookmark", "movedDocument", "revokedBookmark", "revokedPermission", "libraryInUserFolder"][index % 6]
            let dir = TempDirectory("dur029")
            let rig = Rig(dir: dir)
            let model = HoldoutGen.show(&rng)
            let url = rig.url("Show \(index).wwshow")
            let first = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            // The record is created by the same executable that later resolves it (as the app does).
            let locations = ShowLocationStore(root: dir.sub("ShowLocations"))
            let recorded = try ProbeProcess.run(["record-location", "--file", locations.root.path, "--show", model.show.id.rawValue.uuidString, "--doc", url.path])
            try check(recorded.output["result"] as? String == "recorded", "record-location \(recorded.output)")
            if variant == "staleBookmark" {
                // A later safe-save replaced the file: the recorded bookmark is now stale.
                _ = try rig.publisher.publish(try model.renamingShow(to: model.show.title + " r2"), revision: 2, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: first.fingerprint))
            }
            var libraryArguments: [String] = []
            var library: (store: LibraryStore, settings: URL)?
            if variant == "libraryInUserFolder" {
                let settingsURL = dir.url.appending(path: "library-settings.json")
                let store = LibraryStore(containerFolder: dir.sub("Container"), settings: FileLibrarySettingsForTests(url: settingsURL), bookmarks: PlainFolderBookmarks(),
                                         recovery: rig.recovery, indexCache: LibraryIndexCache(url: dir.sub("Caches").appending(path: "index.json")))
                _ = await store.load()
                _ = await store.acknowledgeShowPublication(model.show.id, title: model.show.title, publication: first.publication)
                guard case .success(.moved) = await store.moveLibrary(to: dir.sub("Library Folder")) else { throw CaseFailure(description: "library move") }
                library = (store, settingsURL)
                libraryArguments = ["--library-settings", settingsURL.path, "--container", dir.sub("Container").path, "--cache", dir.sub("Caches").appending(path: "index.json").path]
            }
            let movedURL = dir.sub("Moved").appending(path: "Show \(index).wwshow")
            let before = try Data(contentsOf: url)   // captured before any variant makes it unreadable
            switch variant {
            case "movedDocument": try FileManager.default.moveItem(at: url, to: movedURL)
            case "revokedBookmark":
                var record = try #require(locations.record(for: model.show.id))
                record.bookmark = Data("revoked".utf8)
                try ShowLocationStore.encoder.encode(record).write(to: dir.url.appending(path: "ShowLocations/show-\(model.show.id.rawValue.uuidString).json"))
            case "revokedPermission": chmod(url.path, 0o000)
            default: break
            }
            let watched = variant == "movedDocument" ? movedURL : url
            let listing = { (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))?.sorted() ?? [] }
            let filesBefore = listing()
            let title = "Reopened \(index)"
            let run = try ProbeProcess.run(["reopen-save", "--file", dir.url.appending(path: "ShowLocations").path, "--show", model.show.id.rawValue.uuidString,
                                            "--title", title, "--recovery", rig.recovery.root.path] + libraryArguments)
            if variant == "revokedPermission" { chmod(url.path, 0o644) }
            let output = run.output
            try check((output["scopesStarted"] as? Int) == (output["scopesStopped"] as? Int), "scopes unbalanced \(output)")
            switch variant {
            case "normal", "staleBookmark", "libraryInUserFolder":
                try check(output["outcome"] as? String == "opened" && output["result"] as? String == "saved", "\(output)")
                let onDisk = try #require(decodeShow(url))
                try check(onDisk.payload.show.title == title && onDisk.revision == (variant == "staleBookmark" ? 3 : 2), "read-back")
                if variant == "staleBookmark" { try check(output["refreshedStaleBookmark"] as? Bool == true, "stale bookmark not refreshed") }
                if let library {
                    try check(output["libraryAck"] as? String == "published", "library ack \(output)")
                    let reloaded = LibraryStore(containerFolder: dir.sub("Container"), settings: FileLibrarySettingsForTests(url: library.settings), bookmarks: PlainFolderBookmarks(),
                                                recovery: rig.recovery, indexCache: LibraryIndexCache(url: dir.sub("Caches").appending(path: "index.json")))
                    _ = await reloaded.load()
                    try check(await reloaded.library?.entries.first?.lastKnownPublication == onDisk.publication, "library entry")
                }
                return CaseResult("\(variant):saved")
            default:
                let outcome = output["outcome"] as? String ?? "?"
                try check(outcome == "regrantRequired" || outcome == "relinkRequired", "\(variant) → \(output)")
                try check((try? Data(contentsOf: watched)) == before, "document written")
                try check(listing() == filesBefore || variant == "movedDocument", "wrote elsewhere")
                if variant == "movedDocument" { try check(!FileManager.default.fileExists(atPath: url.path), "recreated at the old location") }
                return CaseResult("\(variant):\(outcome)")
            }
        }
        expectAllPassed(result)
    }
}
