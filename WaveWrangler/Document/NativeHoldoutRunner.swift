#if DEBUG
import AppKit
import CryptoKit
import Foundation
import Synchronization
import WWCore
import WWPersistence

/// Debug-only native holdout runner for the NSDocument path (registry m1-freeze-1):
///
/// - `M1-DUR-006` NSDocument cells P1–P3 and P5–P7 (P4 has no public hook inside AppKit's safe replace and is
///   evidenced only on the publisher path), 100 holdout interruptions each, through real `ShowDocument` saves
///   (`save(to:ofType:for:completionHandler:)` → our `writeSafely` → stock `super.writeSafely`).
/// - `M1-DUR-008` concurrent windows: one document, two window controllers, interleaved edits/undo/redo/saves.
///
/// Launched only by `scripts/holdout.sh --native` under the GUI lock:
/// `WaveWrangler -WWUITestHooks YES -WWNativeHoldout calibration|holdout` (isolated UI-test storage). Results are
/// written to `Application Support/WaveWrangler-UITests/holdout/native-results-<split>.jsonl`; the app then exits.
@MainActor
enum NativeHoldoutRunner {
    static let argumentKey = "WWNativeHoldout"
    private static var scheduled = false

    static func scheduleIfRequested() {
        guard PersistenceEnvironment.isUITestRun, !scheduled,
              let split = UserDefaults.standard.string(forKey: argumentKey), ["calibration", "holdout"].contains(split) else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                await run(split: split)
                exit(0)
            }
        }
    }

    // MARK: - Results

    struct FamilyResult: Codable {
        var fixture: String
        var cell: String?
        var split: String
        var planned: Int
        var executed: Int
        var passed: Int
        var outcomeCounts: [String: Int]
        var outcomes: [String]
        var failures: [String: String]
        var label: String
        var notes: [String]
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static var resultsURL: URL { PersistenceEnvironment.applicationSupport("holdout").appending(path: "native-results.jsonl") }

    static func write(_ result: FamilyResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = try? encoder.encode(result) else { return }
        try? FileManager.default.createDirectory(at: resultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: resultsURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: resultsURL)
        }
    }

    static func seed(_ fixture: String, _ split: String, _ index: Int) -> UInt64 {
        SHA256.hash(data: Data("ww-m1-fixture|v1|\(fixture)|\(split)|\(index)".utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func runFamily(_ fixture: String, cell: String?, seedName: String, split: String, calibration: Int, holdout: Int, notes: [String],
                          _ body: (Int, inout Generator) async throws -> String) async {
        let planned = split == "holdout" ? holdout : calibration
        var outcomes: [String] = []
        var failures: [String: String] = [:]
        for index in 0..<planned {
            var rng = Generator(seed: seed(seedName, split, index))
            do {
                outcomes.append(try await body(index, &rng))
            } catch {
                outcomes.append("FAIL")
                failures[String(index)] = "\(error)"
            }
            ShowDocument.debugPublicationHooks = nil
            ShowDocument.debugLibraryAcknowledger = nil
        }
        var counts: [String: Int] = [:]
        for outcome in outcomes { counts[outcome, default: 0] += 1 }
        write(FamilyResult(fixture: fixture, cell: cell, split: split, planned: planned, executed: outcomes.count,
                           passed: outcomes.count { $0 != "FAIL" }, outcomeCounts: counts, outcomes: outcomes, failures: failures,
                           label: "native NSDocument path, simulated/local, not provider-observed", notes: notes))
    }

    // MARK: - Generator (registry recipe: 1-12 episodes, 0-40 logical sources, speakers; 1-20 edits)

    struct Generator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
        mutating func uuid() -> UUID {
            var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &self) }
            bytes[6] = (bytes[6] & 0x0F) | 0x40
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }

    static func show(_ rng: inout Generator) -> ShowDocumentModel {
        var model = ShowDocumentModel(show: Show(id: ShowID(rng.uuid()), title: "Native Synthetic Show \(rng.int(1...9_999))"))
        for index in 0..<rng.int(1...12) {
            model = try! model.addingEpisode(Episode(id: EpisodeID(rng.uuid()), title: "Synthetic Episode \(index + 1)", number: index + 1))
        }
        for index in 0..<rng.int(0...6) { model = try! model.addingSpeaker(Speaker(id: SpeakerID(rng.uuid()), name: "Speaker \(index)")) }
        for index in 0..<rng.int(0...40) {
            let episode = model.episodes[rng.int(0...(model.episodes.count - 1))]
            model = try! model.addingSource(SourceRecord(id: SourceID(rng.uuid()), displayNameHint: "synthetic-\(index).wav"), to: episode.id)
        }
        return model
    }

    static func edit(_ model: ShowDocumentModel, step: Int, _ rng: inout Generator) -> ShowDocumentModel {
        switch rng.int(0...2) {
        case 0: return (try? model.renamingShow(to: "Native edit \(step) \(rng.int(0...999))")) ?? model
        case 1: return (try? model.addingEpisode(Episode(id: EpisodeID(rng.uuid()), title: "Added Episode \(step)"))) ?? model
        default:
            guard let episode = model.episodes.first else { return model }
            return (try? model.renamingEpisode(episode.id, to: "Renamed \(step)")) ?? model
        }
    }

    // MARK: - Document helpers

    struct Injected: InjectedInterruption, CustomStringConvertible {
        let boundary: PublicationBoundary
        var description: String { "injected interruption at \(boundary.rawValue)" }
    }

    struct InterruptAt: PublicationHooks {
        let boundary: PublicationBoundary
        func reached(_ reached: PublicationBoundary) throws {
            if reached == boundary { throw Injected(boundary: boundary) }
        }
    }

    static func open(_ url: URL) throws -> ShowDocument {
        let document = try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show)
        guard let show = document as? ShowDocument else { throw Failure(description: "not a ShowDocument") }
        return show
    }

    static func save(_ document: ShowDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async -> Error? {
        await withCheckedContinuation { continuation in
            document.save(to: url, ofType: DocumentTypes.show, for: operation) { continuation.resume(returning: $0) }
        }
    }

    static func decode(_ url: URL) -> DecodedDocument<ShowDocumentModel>? {
        (try? Data(contentsOf: url)).flatMap { try? JSONEnvelopeCoder<ShowDocumentModel>.show.decode($0) }
    }

    // MARK: - Families

    static func run(split: String) async {
        try? FileManager.default.removeItem(at: resultsURL)
        PersistenceEnvironment.autosaveGate.preference = AutosavePreference(enabled: false)   // no scheduler-driven saves during the run
        for boundary in [PublicationBoundary.candidateValidated, .priorRetained, .baseChecked, .published, .readBackVerified, .libraryAcknowledged] {
            await runFamily("M1-DUR-006", cell: "nsdocument/\(boundary.rawValue)", seedName: "M1-DUR-006/nsdocument/\(boundary.rawValue)", split: split,
                            calibration: 10, holdout: 100,
                            notes: ["Real ShowDocument saves through NSDocument (save → writeSafely → super.writeSafely) in the sandboxed Debug app; injection via the Debug-only publisher hooks. P7 = library acknowledged, derived index update interrupted (library store L6 hook)."]) { index, rng in
                try await dur006Case(boundary: boundary, index: index, &rng)
            }
        }
        await runFamily("M1-DUR-008", cell: nil, seedName: "M1-DUR-008", split: split, calibration: 10, holdout: 100,
                        notes: ["One ShowDocument with two window controllers (two windows on screen); interleaved edits, undo, redo and saves are issued programmatically on the shared document, not through per-window UI input. Per-window focus/selection independence is not evidenced here."]) { index, rng in
            try await dur008Case(index: index, &rng)
        }
    }

    static func dur006Case(boundary: PublicationBoundary, index: Int, _ rng: inout Generator) async throws -> String {
        let operation: NSDocument.SaveOperationType = boundary == .libraryAcknowledged ? .saveOperation : [.saveOperation, .autosaveInPlaceOperation, .saveAsOperation][index % 3]
        let name = operation == .saveOperation ? "save" : (operation == .autosaveInPlaceOperation ? "autosave" : "saveAs")
        let dir = FileManager.default.temporaryDirectory.appending(path: "native-holdout-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Show.wwshow")
        let saveAsURL = dir.appending(path: "Saved As.wwshow")
        let recovery = PersistenceEnvironment.recovery
        let publisher = DocumentPublisher(coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: recovery)
        let r1 = show(&rng)
        let key = DocumentKey.show(r1.show.id)
        let first = try publisher.publish(r1, revision: 1, key: key, to: url, target: .newLocation)
        let r2 = try r1.renamingShow(to: r1.show.title + " r2")
        _ = try publisher.publish(r2, revision: 2, key: key, to: url, target: .inPlace(expectedBase: first.fingerprint))

        let document = try open(url)
        var expected = r2
        for step in 0..<rng.int(1...20) {
            let next = edit(expected, step: step, &rng)
            document.store.apply("Holdout Edit") { _ in next }
            expected = next
        }
        try check(document.store.model == expected, "edits not applied")

        // Library for the acknowledgement (P7: interrupted at its L6 boundary, before the derived index update).
        let libraryDir = dir.appending(path: "Library", directoryHint: .isDirectory)
        let library = LibraryStore(containerFolder: libraryDir, settings: InMemorySettings(), bookmarks: SecurityScopedFolderBookmarks(), recovery: recovery,
                                   indexCache: LibraryIndexCache(url: dir.appending(path: "index.json")),
                                   hooks: boundary == .libraryAcknowledged ? InterruptAt(boundary: .readBackVerified) : NoPublicationHooks())
        _ = await library.load()
        let acknowledgementCount = Mutex(0)
        ShowDocument.debugLibraryAcknowledger = { id, title, stamp in
            acknowledgementCount.withLock { $0 += 1 }
            _ = await library.acknowledgeShowPublication(id, title: title, publication: stamp)
        }
        if boundary != .libraryAcknowledged { ShowDocument.debugPublicationHooks = InterruptAt(boundary: boundary) }
        let target = operation == .saveAsOperation ? saveAsURL : url
        let error = await save(document, to: target, operation)
        ShowDocument.debugPublicationHooks = nil
        try await Task.sleep(for: .milliseconds(50))   // let the acknowledgement task run
        let state = document.status.saveStatus.state
        let acknowledgements = acknowledgementCount.withLock { $0 }
        document.close()

        let opener = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: recovery)
        var outcome: String
        switch opener.open(target, key: key) {
        case let .editable(doc, _):
            if doc.payload == r2, doc.revision == 2 { outcome = "old" }
            else if doc.payload == expected, doc.revision == 3 { outcome = "new" }
            else { throw Failure(description: "mixed revision") }
        case .unreadable where operation == .saveAsOperation:
            outcome = "absent"
        default:
            throw Failure(description: "no valid revision at the canonical location")
        }
        if operation == .saveAsOperation { try check(decode(url)?.payload == r2, "original changed by Save As") }
        // The NSDocument path reopens what is on disk.
        if outcome != "absent" { _ = try open(target).close() }
        try check(!((try? recovery.validatedCheckpoints(for: key, coder: JSONEnvelopeCoder<ShowDocumentModel>.show)) ?? []).isEmpty, "no validated prior")
        if boundary == .libraryAcknowledged {
            try check(error == nil && outcome == "new", "P7 save should be verified: \(String(describing: error)) \(outcome)")
            try check(state.isVerifiedOnDisk, "status \(state)")
            try check(acknowledgements == 1, "acknowledged \(acknowledgements)×")
            let reloaded = LibraryStore(containerFolder: libraryDir, settings: InMemorySettings(), bookmarks: SecurityScopedFolderBookmarks(), recovery: recovery,
                                        indexCache: LibraryIndexCache(url: dir.appending(path: "index.json")))
            _ = await reloaded.load()
            let libraryModel = await reloaded.library
            let claimed = libraryModel?.entries.first { $0.showID == r1.show.id }?.lastKnownPublication
            try check(claimed == nil || claimed == decode(url)?.publication, "library claims an unverified publication")
            if let libraryModel, let bytes = try? Data(contentsOf: libraryDir.appending(path: LibraryLocationSetting.defaultFileName)) {
                try check(await reloaded.index == LibraryIndex.build(from: libraryModel, libraryDigest: RevisionFingerprint.digest(bytes)), "index not rebuilt")
            }
            return "save:new:ackedIndexRebuilt"
        }
        try check(error != nil, "save did not report the interruption")
        try check(!state.isVerifiedOnDisk, "status claims saved: \(state)")
        if outcome == "new" {
            guard case .acknowledgementUncertain = state else { throw Failure(description: "published but status \(state)") }
        }
        try check(acknowledgements == 0, "library advanced on a failed save")
        return "\(name):\(outcome):\(outcome == "new" ? "ackUncertain" : "failedRetained")"
    }

    static func dur008Case(index: Int, _ rng: inout Generator) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "native-holdout-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Shared.wwshow")
        let model = show(&rng)
        _ = try DocumentPublisher(coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: PersistenceEnvironment.recovery)
            .publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        let document = try open(url)
        document.makeWindowControllers()
        document.makeWindowControllers()
        document.showWindows()
        defer { document.close() }
        let windows = document.windowControllers.compactMap(\.window)
        try check(windows.count == 2 && windows[0] !== windows[1], "two windows")
        try check(document.windowControllers.allSatisfy { $0.document === document }, "windows share the document")
        guard let undo = document.undoManager else { throw Failure(description: "no undo manager") }
        undo.groupsByEvent = false
        var history = [model]
        var cursor = 0
        var saves = 0
        let operations = rng.int(5...15)
        for step in 0..<operations {
            switch rng.int(0...9) {
            case 0...4:
                let next = edit(history[cursor], step: step, &rng)
                undo.beginUndoGrouping()
                document.store.apply("Holdout Edit \(step)") { _ in next }
                undo.endUndoGrouping()
                if next != history[cursor] {
                    history = Array(history[...cursor]) + [next]
                    cursor += 1
                }
            case 5, 6:
                if undo.canUndo { undo.undo(); cursor -= 1 }
            case 7:
                if undo.canRedo { undo.redo(); cursor += 1 }
            default:
                break
            }
            try check(document.store.model == history[cursor], "shared model differs from the expected state after step \(step)")
            if step == operations - 1 || rng.int(0...2) == 0 {
                let error = await save(document, to: url, .saveOperation)
                try check(error == nil, "save failed: \(String(describing: error))")
                saves += 1
                try check(decode(url)?.payload == history[cursor], "saved revision does not contain every committed edit")
            }
        }
        _ = index
        return "twoWindows:saves=\(saves)"
    }

    final class InMemorySettings: LibraryLocationSettingsStoring {
        private let setting = Mutex(LibraryLocationSetting())
        func load() -> LibraryLocationSetting { setting.withLock { $0 } }
        func save(_ value: LibraryLocationSetting) throws { setting.withLock { $0 = value } }
    }
}
#endif
