import Darwin
import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

private typealias ShowCoder = JSONEnvelopeCoder<ShowDocumentModel>
private typealias ShowSession = CanonicalDocumentSession<ShowCoder>

/// M1-DUR-024 — OBSERVED iCloud Drive trial on this Mac (grant C, 2026-10-04): synthetic documents only, only in
/// `~/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/persistence/`, which is
/// recreated at the start and deleted at the end (deletion recorded). Opt-in: `WW_HOLDOUT=1 WW_ICLOUD_TRIAL=1`.
/// Results describe what iCloud Drive was observed to do here; nothing is generalized to other providers.
@Suite("M1 durability holdout — iCloud Drive observed trial", .serialized,
       .enabled(if: Holdout.enabled && Holdout.iCloudEnabled,
                "Live iCloud/two-device test: skipped by default; set WW_LIVE_PROVIDER_TESTS=1 to opt in (#146), with WW_HOLDOUT=1 WW_ICLOUD_TRIAL=1"))
struct HoldoutICloudTrialTests {
    static let trialRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial", directoryHint: .isDirectory)
    static let folder = trialRoot.appending(path: "persistence", directoryHint: .isDirectory)
    static let label = "OBSERVED: iCloud Drive on this Mac (grant C); not generalized to other providers or devices"

    static func values(_ url: URL) -> URLResourceValues? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey])
    }

    static func waitUploaded(_ url: URL, timeout: Double = 90) async -> Double? {
        let start = ContinuousClock.now
        while Stats.seconds(.now - start) < timeout {
            if values(url)?.ubiquitousItemIsUploaded == true { return Stats.seconds(.now - start) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    static func brctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func dur024ICloudObservedTrial() async throws {
        let fm = FileManager.default
        try check(fm.fileExists(atPath: Self.trialRoot.path), "trial folder missing")
        if fm.fileExists(atPath: Self.folder.path) { try fm.removeItem(at: Self.folder) }
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let recoveryDir = TempDirectory("dur024-recovery")   // device-local recovery store stays on this Mac
        let recovery = RecoveryStore(root: recoveryDir.url)
        let publisher = DocumentPublisher(coder: ShowCoder.show, recovery: recovery)
        let opener = DocumentOpener<ShowCoder>.show(recovery: recovery)
        var conflictVersionsSeen = 0
        defer {
            // Delete only the persistence subfolder and record it.
            try? FileManager.default.removeItem(at: Self.folder)
            let deleted = !FileManager.default.fileExists(atPath: Self.folder.path)
            Holdout.write(FamilyResult(fixture: "M1-DUR-024", cell: "cleanup", split: Holdout.split, planned: 1, executed: 1, passed: deleted ? 1 : 0,
                                       outcomeCounts: [deleted ? "persistenceSubfolderDeleted" : "deleteFailed": 1], outcomes: [deleted ? "persistenceSubfolderDeleted" : "deleteFailed"],
                                       failures: [:], timing: nil, label: Self.label, notes: ["Deleted \(Self.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) at \(Date().ISO8601Format())"]))
        }

        // 100 save/autosave publications (read-back verified + independent decode).
        let saves = await runFamily("M1-DUR-024", cell: "save-autosave", calibration: 4, holdout: 100, label: Self.label) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let model = HoldoutGen.show(&rng, episodes: 1...4, sources: 0...8)
            let url = Self.folder.appending(path: "Save \(index).wwshow")
            let first = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            let automatic = index % 2 == 1
            let gate = AutosaveGate(AutosavePreference(enabled: true, delaySeconds: 1))
            let session = ShowSession(key: .show(model.show.id), url: url, payload: model, base: first.fingerprint, revision: 1, publisher: publisher, gate: gate)
            let expected = try #require(HoldoutGen.edits(1...5, on: model, &rng).last)
            await session.edit { _ in expected }
            let start = ContinuousClock.now
            if automatic {
                let scheduler = QuiescenceScheduler(gate: gate, queue: DispatchQueue(label: "dur024.\(index)")) { work in
                    if work == .publish { Task { _ = await session.save(automatic: true) } }
                }
                scheduler.noteEdit()
                while decodeShow(url)?.payload != expected, Stats.seconds(.now - start) < 10 { try await Task.sleep(for: .milliseconds(10)) }
            } else {
                guard case .success = await session.save() else { throw CaseFailure(description: "save failed") }
            }
            try check(decodeShow(url)?.payload == expected, "read-back")
            return CaseResult(automatic ? "autosavePublished" : "explicitSaved", seconds: Stats.seconds(.now - start))
        }

        // 100 conflict attempts: two processes (60) and two document instances (40).
        let conflicts = await runFamily("M1-DUR-024", cell: "conflict", calibration: 4, holdout: 100, label: Self.label) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let model = HoldoutGen.show(&rng, episodes: 1...3, sources: 0...4)
            let url = Self.folder.appending(path: "Conflict \(index).wwshow")
            let first = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            if index % 5 < 3 {
                let barrier = TempDirectory("dur024-barrier")
                let go = barrier.url.appending(path: "go")
                var running: [(Process, Pipe)] = []
                for writer in ["A", "B"] {
                    running.append(try MultiProcessTests.launch(["save", "--file", url.path, "--title", "Process \(writer)", "--recovery", recoveryDir.url.path,
                                                                 "--ready", barrier.url.appending(path: "ready-\(writer)").path, "--go", go.path]))
                }
                for writer in ["A", "B"] {
                    let deadline = Date().addingTimeInterval(30)
                    while !FileManager.default.fileExists(atPath: barrier.url.appending(path: "ready-\(writer)").path), Date() < deadline { usleep(2_000) }
                }
                FileManager.default.createFile(atPath: go.path, contents: Data())
                let outputs = running.map { process, pipe in let output = MultiProcessTests.output(pipe); process.waitUntilExit(); return output }
                let results = outputs.compactMap { $0["result"] as? String }.sorted()
                try check(results == ["conflict", "saved"], "two-process outcomes \(results)")
                try check(decodeShow(url) != nil, "not a whole valid revision")
            } else {
                let a = ShowSession(key: .show(model.show.id), url: url, payload: model, base: first.fingerprint, revision: 1, publisher: publisher)
                let b = ShowSession(key: .show(model.show.id), url: url, payload: model, base: first.fingerprint, revision: 1, publisher: publisher)
                try await a.edit { try $0.renamingShow(to: "Instance A") }
                try await b.edit { try $0.renamingShow(to: "Instance B") }
                guard case .success = await a.save(), case let .failure(.conflict(conflict)) = await b.save() else { throw CaseFailure(description: "two-instance outcomes") }
                try check(decodeShow(url)?.payload.show.title == "Instance A", "overwritten")
                try check(conflict.preservedCandidate.flatMap(decodeShow)?.payload.show.title == "Instance B", "loser not preserved")
            }
            let versions = ProviderConflictReport.inspect(url).unresolvedVersionCount
            return CaseResult("\(index % 5 < 3 ? "twoProcess" : "twoInstance"):conflictDetected:providerConflictVersions=\(versions)")
        }

        // 50 evict/download cycles.
        let evictions = await runFamily("M1-DUR-024", cell: "evict-download", calibration: 2, holdout: 50, label: Self.label) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let model = HoldoutGen.show(&rng, episodes: 1...3, sources: 0...4)
            let url = Self.folder.appending(path: "Evict \(index).wwshow")
            _ = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            guard let upload = await Self.waitUploaded(url) else { throw CaseFailure(description: "not uploaded within 90 s") }
            let evict = Self.brctl(["evict", url.path])
            try check(evict.status == 0, "brctl evict failed: \(evict.output)")
            var evictedStatus = "unknown"
            for _ in 0..<40 {
                if let status = Self.values(url)?.ubiquitousItemDownloadingStatus, status == .notDownloaded { evictedStatus = "notDownloaded"; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let start = ContinuousClock.now
            guard case let .editable(document, _) = opener.open(url, key: .show(model.show.id)) else { throw CaseFailure(description: "reopen after evict failed") }
            let reopen = Stats.seconds(.now - start)
            try check(document.payload == model, "downloaded content differs")
            let after = Self.values(url)?.ubiquitousItemDownloadingStatus == .current ? "current" : "notCurrent"
            return CaseResult("upload<=\(Int(upload.rounded(.up)))s:evicted=\(evictedStatus):reopened:\(after)", seconds: reopen)
        }

        // 20 recovery cases: SIGKILL at publisher boundaries in the iCloud folder, then recovery.
        let recoveries = await runFamily("M1-DUR-024", cell: "recovery", calibration: 2, holdout: 20, label: Self.label) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let model = HoldoutGen.show(&rng, episodes: 1...3, sources: 0...4)
            let url = Self.folder.appending(path: "Recovery \(index).wwshow")
            let first = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            let r2 = try model.renamingShow(to: model.show.title + " r2")
            _ = try publisher.publish(r2, revision: 2, key: .show(model.show.id), to: url, target: .inPlace(expectedBase: first.fingerprint))
            let boundary = ["P3", "P4", "P5", "P6"][index % 4]
            let run = try ProbeProcess.run(["kill-at", "--file", url.path, "--boundary", boundary, "--recovery", recoveryDir.url.path])
            try check(run.signaled, "helper not killed")
            switch opener.open(url, key: .show(model.show.id)) {
            case let .editable(document, _):
                if document.payload == r2 { return CaseResult("\(boundary):old") }
                try check(document.payload.show.title == "Killed at \(boundary)", "mixed")
                return CaseResult("\(boundary):new")
            case let .damaged(_, candidates):
                try check(candidates.first?.document.payload == r2 || candidates.first?.document.payload == model, "no coherent checkpoint")
                return CaseResult("\(boundary):recovered")
            default:
                throw CaseFailure(description: "zero valid")
            }
        }

        // 20 library-at-iCloud publications/moves: move in, 18 publications there, move back out.
        let libraryDir = TempDirectory("dur024-library")
        let settings = InMemoryLibrarySettings()
        let library = LibraryStore(containerFolder: libraryDir.sub("Container"), settings: settings, bookmarks: SecurityScopedFolderBookmarks(),
                                   recovery: recovery, indexCache: LibraryIndexCache(url: libraryDir.sub("Caches").appending(path: "index.json")))
        _ = await library.load()
        let libraryFolder = Self.folder.appending(path: "Library", directoryHint: .isDirectory)
        let total = Holdout.count(calibration: 3, holdout: 20)
        let libraryOps = await runFamily("M1-DUR-024", cell: "library", calibration: 3, holdout: 20, label: Self.label) { index, _ in
            switch index {
            case 0:
                guard case .success(.moved) = await library.moveLibrary(to: libraryFolder) else { throw CaseFailure(description: "move into iCloud failed") }
                return CaseResult("movedIn")
            case total - 1:
                guard case .success = await library.moveLibraryToAppContainer() else { throw CaseFailure(description: "move out failed") }
                return CaseResult("movedOut")
            default:
                guard case .published = try await library.update({ var l = $0; l.collections.append(LibraryCollection(name: "iCloud \(index)")); return l })
                else { throw CaseFailure(description: "publication failed") }
                let file = libraryFolder.appending(path: settings.load().fileName)
                try check(decodeLibrary(file)?.payload.collections.last?.name == "iCloud \(index)", "read-back")
                return CaseResult("published")
            }
        }
        for url in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] {
            conflictVersionsSeen += ProviderConflictReport.inspect(url).unresolvedVersionCount
        }
        Holdout.write(FamilyResult(fixture: "M1-DUR-024", cell: "provider-conflict-versions", split: Holdout.split, planned: 1, executed: 1, passed: 1,
                                   outcomeCounts: ["unresolvedConflictVersionsAtEnd=\(conflictVersionsSeen)": 1], outcomes: ["\(conflictVersionsSeen)"],
                                   failures: [:], timing: nil, label: Self.label, notes: ["NSFileVersion unresolved conflict versions across all trial files at the end."]))
        for result in [saves, conflicts, evictions, recoveries, libraryOps] { expectAllPassed(result) }
    }
}
