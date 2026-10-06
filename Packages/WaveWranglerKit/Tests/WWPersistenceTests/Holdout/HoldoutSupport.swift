import CryptoKit
import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

// MARK: - Split, seeds and recording (WW-003 protocol, registry m1-freeze-1)

/// Post-freeze holdout harness controls. Holdout families run only with `WW_HOLDOUT=1`; the split is
/// `calibration` unless `WW_HOLDOUT_SPLIT=holdout`, so development never consumes holdout seeds.
enum Holdout {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["WW_HOLDOUT"] == "1"
    static let split = environment["WW_HOLDOUT_SPLIT"] == "holdout" ? "holdout" : "calibration"
    static var isHoldout: Bool { split == "holdout" }
    /// Live-provider tests (real iCloud Drive, `brctl`) run only with the explicit opt-in WW_LIVE_PROVIDER_TESTS=1
    /// (#146); WW_ICLOUD_TRIAL=1 still selects the iCloud pass within a holdout run.
    static let liveProviderTests = environment["WW_LIVE_PROVIDER_TESTS"] == "1"
    static let iCloudEnabled = liveProviderTests && environment["WW_ICLOUD_TRIAL"] == "1"

    /// `sha256("ww-m1-fixture|v1|" + fixtureId + "|" + split + "|" + caseIndex)` → first 8 bytes big-endian.
    static func seed(_ fixture: String, _ index: Int, split: String = Holdout.split) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m1-fixture|v1|\(fixture)|\(split)|\(index)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func count(calibration: Int, holdout: Int) -> Int { isHoldout ? holdout : calibration }

    static var resultsURL: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appending(path: ".build/holdout/results-\(split).jsonl")
    }

    static let writeLock = Mutex(())

    static func write(_ result: FamilyResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = try? encoder.encode(result) else { return }
        writeLock.withLock { _ in
            try? FileManager.default.createDirectory(at: resultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: resultsURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line + Data("\n".utf8))
                try? handle.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: resultsURL)
            }
        }
        print("[holdout] \(result.fixture)\(result.cell.map { " \($0)" } ?? "") split=\(result.split) executed=\(result.executed)/\(result.planned) passed=\(result.passed) outcomes=\(result.outcomeCounts) failures=\(result.failures.count)\(result.timing.map { " p95=\($0.p95) max=\($0.max)" } ?? "")")
    }
}

struct FamilyResult: Codable, Sendable {
    struct Timing: Codable, Sendable {
        var n: Int
        var p50: Double
        var p95: Double
        var max: Double
        var unit = "s"
        var gate: String?
        var gateMet: Bool?
    }

    var fixture: String
    var cell: String?
    var split: String
    var planned: Int
    var executed: Int
    var passed: Int
    var outcomeCounts: [String: Int]
    /// Every case, in index order: its outcome code, or `FAIL`.
    var outcomes: [String]
    var failures: [String: String]
    var timing: Timing?
    var label: String
    var notes: [String]
}

struct CaseFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CaseFailure(description: message) }
}

struct CaseResult: Sendable {
    var code: String
    var seconds: Double?

    init(_ code: String, seconds: Double? = nil) {
        self.code = code
        self.seconds = seconds
    }
}

/// Runs every case of one family cell and records the result. `body` returns an outcome code (and an optional
/// timing sample) or throws; any thrown error is a failed case, reported with its index.
@discardableResult
func runFamily(
    _ fixture: String,
    cell: String? = nil,
    calibration: Int,
    holdout: Int,
    label: String = "simulated/local, not provider-observed",
    notes: [String] = [],
    concurrency: Int = 1,
    timingGate: (description: String, limit: Double)? = nil,
    seedFixture: String? = nil,
    _ body: @escaping @Sendable (_ index: Int, _ seed: UInt64) async throws -> CaseResult
) async -> FamilyResult {
    let planned = Holdout.count(calibration: calibration, holdout: holdout)
    var codes = [String](repeating: "NOT-RUN", count: planned)
    var failures: [String: String] = [:]
    var samples: [Double] = []
    let seedName = seedFixture ?? fixture
    var next = 0
    await withTaskGroup(of: (Int, Result<CaseResult, any Error>).self) { group in
        func launch(_ index: Int) {
            let seed = Holdout.seed(seedName, index)
            group.addTask {
                do { return (index, .success(try await body(index, seed))) } catch { return (index, .failure(error)) }
            }
        }
        while next < min(max(concurrency, 1), planned) { launch(next); next += 1 }
        for await (index, result) in group {
            switch result {
            case let .success(value):
                codes[index] = value.code
                if let seconds = value.seconds { samples.append(seconds) }
            case let .failure(error):
                codes[index] = "FAIL"
                failures[String(index)] = "\(error)"
            }
            if next < planned { launch(next); next += 1 }
        }
    }
    var counts: [String: Int] = [:]
    for code in codes { counts[code, default: 0] += 1 }
    var timing: FamilyResult.Timing?
    if !samples.isEmpty {
        let p95 = Stats.percentile(samples, 95), maxValue = samples.max() ?? .nan
        timing = .init(n: samples.count, p50: Stats.percentile(samples, 50), p95: p95, max: maxValue,
                       gate: timingGate?.description, gateMet: timingGate.map { p95 <= $0.limit })
    }
    let result = FamilyResult(
        fixture: fixture, cell: cell, split: Holdout.split, planned: planned,
        executed: codes.count { $0 != "NOT-RUN" }, passed: codes.count { $0 != "FAIL" && $0 != "NOT-RUN" },
        outcomeCounts: counts, outcomes: codes, failures: failures, timing: timing, label: label, notes: notes
    )
    Holdout.write(result)
    return result
}

func expectAllPassed(_ result: FamilyResult, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.executed == result.planned, "executed \(result.executed)/\(result.planned)", sourceLocation: sourceLocation)
    let firstFailures = result.failures.sorted { Int($0.key)! < Int($1.key)! }.prefix(5).map { "\($0.key): \($0.value)" }
    #expect(result.failures.isEmpty, "\(firstFailures)", sourceLocation: sourceLocation)
    if let gateMet = result.timing?.gateMet {
        #expect(gateMet, "timing gate \(result.timing?.gate ?? "")", sourceLocation: sourceLocation)
    }
}

// MARK: - Generators (recipes from the frozen registry)

enum HoldoutGen {
    static func int(_ range: ClosedRange<Int>, _ rng: inout SeededGenerator) -> Int { Int.random(in: range, using: &rng) }

    /// A show with 1-12 episodes, 0-40 logical sources, recorder groups and speakers (M1-DUR-001 recipe).
    static func show(_ rng: inout SeededGenerator, episodes: ClosedRange<Int> = 1...12, sources: ClosedRange<Int> = 0...40) -> ShowDocumentModel {
        var model = ShowDocumentModel(show: Show(id: ShowID(Fixtures.uuid(&rng)), title: "Synthetic Show \(int(1...9_999, &rng))"))
        let episodeCount = int(episodes, &rng)
        for index in 0..<episodeCount {
            let episode = Episode(id: EpisodeID(Fixtures.uuid(&rng)), title: "Synthetic Episode \(index + 1)", number: index + 1)
            model = try! model.addingEpisode(episode)
            if Bool.random(using: &rng) {
                model = try! model.addingRecorderGroup(RecorderGroup(id: RecorderGroupID(Fixtures.uuid(&rng)), name: "Recorder \(index)"), to: episode.id)
            }
        }
        for index in 0..<int(0...6, &rng) {
            model = try! model.addingSpeaker(Speaker(id: SpeakerID(Fixtures.uuid(&rng)), name: "Speaker \(index)"))
        }
        for index in 0..<int(sources, &rng) {
            let episode = model.episodes[int(0...(model.episodes.count - 1), &rng)]
            model = try! model.addingSource(SourceRecord(id: SourceID(Fixtures.uuid(&rng)), displayNameHint: "synthetic-\(index).wav"), to: episode.id)
        }
        return model
    }

    /// 1-20 seeded edits (renames, additions, removals). Returns the expected model (truth) after each edit.
    static func edits(_ count: ClosedRange<Int>, on start: ShowDocumentModel, _ rng: inout SeededGenerator) -> [ShowDocumentModel] {
        var model = start
        var states: [ShowDocumentModel] = []
        for step in 0..<int(count, &rng) {
            let next: ShowDocumentModel?
            switch int(0...4, &rng) {
            case 0: next = try? model.renamingShow(to: "Synthetic Show edit \(step) \(int(0...999, &rng))")
            case 1:
                next = model.episodes.isEmpty ? nil
                    : try? model.renamingEpisode(model.episodes[int(0...(model.episodes.count - 1), &rng)].id, to: "Renamed Episode \(step)")
            case 2: next = try? model.addingEpisode(Episode(id: EpisodeID(Fixtures.uuid(&rng)), title: "Added Episode \(step)"))
            case 3: next = try? model.addingSpeaker(Speaker(id: SpeakerID(Fixtures.uuid(&rng)), name: "Added Speaker \(step)"))
            default:
                next = model.episodes.count > 1 ? try? model.removingEpisode(model.episodes[int(0...(model.episodes.count - 1), &rng)].id) : nil
            }
            model = next ?? (try! model.renamingShow(to: "Synthetic Show fallback \(step)"))
            states.append(model)
        }
        return states
    }

    /// A library over `shows` with aliases, collections, recents and at least one unavailable entry.
    static func library(_ shows: [ShowDocumentModel], _ rng: inout SeededGenerator) -> LibraryModel {
        var entries = shows.map { LibraryShowEntry(showID: $0.show.id, lastKnownTitle: $0.show.title) }
        for index in entries.indices where Bool.random(using: &rng) { entries[index].alias = "Alias \(index)" }
        let unavailable = int(0...(entries.count - 1), &rng)
        entries[unavailable].unavailable = UnavailableRecord(note: "Synthetic folder offline", recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let ids = entries.map(\.showID)
        let collections = (0..<int(1...4, &rng)).map { index in
            LibraryCollection(id: CollectionID(Fixtures.uuid(&rng)), name: "Collection \(index)",
                              showIDs: Array(ids.shuffled(using: &rng).prefix(int(0...ids.count, &rng))))
        }
        return LibraryModel(entries: entries, collections: collections,
                            recentShowIDs: Array(ids.shuffled(using: &rng).prefix(int(0...min(5, ids.count), &rng))))
    }

    static func shows(_ count: ClosedRange<Int>, _ rng: inout SeededGenerator) -> [ShowDocumentModel] {
        (0..<int(count, &rng)).map { _ in show(&rng, episodes: 1...3, sources: 0...4) }
    }
}

// MARK: - Library location strata

enum LibraryStratum: String, CaseIterable, Sendable {
    case container = "app-container"
    case userFolder = "user-chosen-folder"
}

/// A library store in one location stratum. The user-folder stratum uses real read-write security-scoped
/// folder bookmarks (in this unsandboxed test process the bookmark is created, resolved and its access
/// started/stopped, but no sandbox extension is involved — recorded as a limit).
struct StratumRig: Sendable {
    let dir: TempDirectory
    let stratum: LibraryStratum
    let settings = InMemoryLibrarySettings()
    let container: URL
    let folder: URL
    let recovery: RecoveryStore
    let cacheURL: URL

    init(_ stratum: LibraryStratum, label: String) {
        self.stratum = stratum
        dir = TempDirectory(label)
        container = dir.sub("Container")
        folder = dir.sub("User Folder")
        recovery = RecoveryStore(root: dir.sub("Recovery"))
        cacheURL = dir.sub("Caches").appending(path: "index.json")
    }

    func store(ops: any FileOperations = LocalFileOperations(), hooks: any PublicationHooks = NoPublicationHooks()) -> LibraryStore {
        LibraryStore(
            containerFolder: container, settings: settings, bookmarks: SecurityScopedFolderBookmarks(),
            recovery: RecoveryStore(root: recovery.root, ops: ops),
            indexCache: LibraryIndexCache(url: cacheURL, ops: ops), ops: ops, hooks: hooks
        )
    }

    /// Creates the library with `model`'s content in this stratum; returns the loaded store and the stored value.
    func make(_ model: LibraryModel) async throws -> (LibraryStore, LibraryModel) {
        let store = store()
        guard await store.load() == .created else { throw CaseFailure(description: "library not created") }
        guard case .published = try await store.update({ current in var library = model; library.libraryID = current.libraryID; return library })
        else { throw CaseFailure(description: "library seed not published") }
        if stratum == .userFolder {
            guard case .success(.moved) = await store.moveLibrary(to: folder) else { throw CaseFailure(description: "move to user folder failed") }
        }
        guard let stored = await store.library else { throw CaseFailure(description: "library not loaded") }
        return (store, stored)
    }

    var libraryFile: URL {
        (stratum == .container ? container : folder).appending(path: settings.load().fileName)
    }
}

/// Classification of a library after recovery in a fresh store, against the old/new truth.
func classifyLibrary(_ store: LibraryStore, old: LibraryModel, new: LibraryModel) async -> String {
    switch await store.load() {
    case .ready:
        guard let library = await store.library else { return "zeroValid" }
        if library.content == old.content { return "old" }
        if library.content == new.content { return "new" }
        return "mixed"
    case let .damaged(_, revisions):
        guard let first = revisions.first, case .success = await store.recoverAsNewCopy(revision: first),
              let library = await store.library else { return "zeroValid" }
        return library.content == old.content ? "recoveredOld" : (library.content == new.content ? "recoveredNew" : "mixed")
    default:
        return "zeroValid"
    }
}

/// File-backed library location settings shared with `wwpersist-probe` (same JSON format).
final class FileLibrarySettingsForTests: LibraryLocationSettingsStoring {
    let url: URL
    init(url: URL) { self.url = url }
    func load() -> LibraryLocationSetting {
        (try? JSONDecoder().decode(LibraryLocationSetting.self, from: Data(contentsOf: url))) ?? LibraryLocationSetting()
    }
    func save(_ setting: LibraryLocationSetting) throws {
        try JSONEncoder().encode(setting).write(to: url, options: .atomic)
    }
}

// MARK: - Probe processes

enum ProbeProcess {
    /// Runs `wwpersist-probe` to completion: its JSON output and how it ended.
    static func run(_ arguments: [String]) throws -> (output: [String: Any], status: Int32, signaled: Bool) {
        let (process, pipe) = try MultiProcessTests.launch(arguments)
        let output = MultiProcessTests.output(pipe)
        process.waitUntilExit()
        return (output, process.terminationStatus, process.terminationReason == .uncaughtSignal)
    }
}

func decodeShow(_ url: URL) -> DecodedDocument<ShowDocumentModel>? {
    (try? Data(contentsOf: url)).flatMap { try? JSONEnvelopeCoder<ShowDocumentModel>.show.decode($0) }
}

func decodeLibrary(_ url: URL) -> DecodedDocument<LibraryModel>? {
    (try? Data(contentsOf: url)).flatMap { try? LibraryCoder.library.decode($0) }
}

/// A Sendable reference to a `Mutex`, so escaping `Task` closures can share it (older compilers reject
/// capturing the non-copyable `Mutex` itself in a `sending` closure).
final class LockedBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout sending Value) throws -> sending R) rethrows -> R { try mutex.withLock(body) }
}
