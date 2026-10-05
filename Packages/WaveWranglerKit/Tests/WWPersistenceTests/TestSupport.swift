import Foundation
import Synchronization
import WWCore
@testable import WWPersistence

// MARK: - Temporary directories and synthetic fixtures

/// A unique temporary directory, removed when the test value is released. Synthetic fixtures only.
final class TempDirectory: Sendable {
    let url: URL

    init(_ label: String = "ww") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "WWPersistenceTests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func sub(_ path: String) -> URL {
        let child = url.appending(path: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deterministic generator so failures are reproducible from a seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    static func uuid(_ rng: inout SeededGenerator) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A synthetic show with `episodes` episodes and `sourcesPerEpisode` logical source records.
    static func show(seed: UInt64, episodes: Int = 2, sourcesPerEpisode: Int = 3, title: String? = nil) -> ShowDocumentModel {
        var rng = SeededGenerator(seed: seed)
        let showID = ShowID(uuid(&rng))
        let eps = (0..<episodes).map { index in
            Episode(
                id: EpisodeID(uuid(&rng)),
                title: "Synthetic Episode \(index + 1)",
                number: index + 1,
                sources: (0..<sourcesPerEpisode).map { source in
                    SourceRecord(id: SourceID(uuid(&rng)), displayNameHint: "synthetic-\(index)-\(source).wav")
                }
            )
        }
        return ShowDocumentModel(show: Show(id: showID, title: title ?? "Synthetic Show \(seed)"), episodes: eps)
    }

    static func library(shows: [ShowDocumentModel], seed: UInt64) -> LibraryModel {
        var rng = SeededGenerator(seed: seed)
        let entries = shows.enumerated().map { index, show in
            LibraryShowEntry(showID: show.show.id, alias: index.isMultiple(of: 3) ? "Alias \(index)" : nil,
                             lastKnownTitle: show.show.title)
        }
        let ids = shows.map(\.show.id)
        let collections = [
            LibraryCollection(id: CollectionID(uuid(&rng)), name: "Active", showIDs: Array(ids.prefix(ids.count / 2)).reversed()),
            LibraryCollection(id: CollectionID(uuid(&rng)), name: "Archive", showIDs: Array(ids.suffix(ids.count / 3))),
        ]
        return LibraryModel(entries: entries, collections: collections, recentShowIDs: Array(ids.prefix(5)))
    }

    /// Synthetic "source recordings" (random bytes) that persistence must never write.
    static func makeSources(in directory: URL, count: Int, seed: UInt64) throws -> [URL: String] {
        var rng = SeededGenerator(seed: seed)
        var digests: [URL: String] = [:]
        for index in 0..<count {
            let bytes = Data((0..<256).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let url = directory.appending(path: "synthetic-source-\(index).wav")
            try bytes.write(to: url)
            digests[url] = RevisionFingerprint.digest(bytes)
        }
        return digests
    }

    static func sourcesUnchanged(_ digests: [URL: String]) -> Bool {
        digests.allSatisfy { url, digest in (try? Data(contentsOf: url)).map(RevisionFingerprint.digest) == digest }
    }
}

// MARK: - Synthetic schema 0 (not a real WaveWrangler format) for the migration framework

enum SyntheticV0 {
    struct Payload: Codable {
        struct Episode: Codable { let id: UUID; let name: String; let sources: [Source] }
        struct Source: Codable { let id: UUID; let name: String }
        let showID: UUID
        let showTitle: String
        let episodes: [Episode]
    }

    struct Envelope: Codable {
        let checksum: String
        let format: String
        let payload: Payload
        let revision: Int
        let schemaVersion: Int
    }

    static func bytes(seed: UInt64, revision: Int = 4) throws -> Data {
        var rng = SeededGenerator(seed: seed)
        let payload = Payload(
            showID: Fixtures.uuid(&rng), showTitle: "Legacy Synthetic \(seed)",
            episodes: (0..<2).map { index in
                Payload.Episode(id: Fixtures.uuid(&rng), name: "Legacy Episode \(index)",
                                sources: (0..<2).map { Payload.Source(id: Fixtures.uuid(&rng), name: "legacy-\(index)-\($0).wav") })
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Envelope(checksum: "none", format: DocumentFormat.show.identifier, payload: payload, revision: revision, schemaVersion: 0))
    }

    static let step = MigrationStep<ShowDocumentModel>(
        fromSchema: 0,
        migrate: { data in
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let model = ShowDocumentModel(
                show: Show(id: ShowID(envelope.payload.showID), title: envelope.payload.showTitle),
                episodes: envelope.payload.episodes.map { episode in
                    // Schema 0 had no numbers, dates or media facts: they stay explicitly unknown/absent.
                    Episode(id: EpisodeID(episode.id), title: episode.name,
                            sources: episode.sources.map { SourceRecord(id: SourceID($0.id), displayNameHint: $0.name) })
                }
            )
            return (model, envelope.revision)
        },
        expectations: { original, migrated in
            // Independently specified expectations read straight from the original JSON, not the migration.
            guard let object = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let episodes = payload["episodes"] as? [[String: Any]]
            else { return ["original unreadable"] }
            var failures: [String] = []
            if migrated.show.title != payload["showTitle"] as? String { failures.append("title") }
            if migrated.show.id.rawValue.uuidString != (payload["showID"] as? String)?.uppercased() { failures.append("show id") }
            if migrated.episodes.map(\.title) != episodes.compactMap({ $0["name"] as? String }) { failures.append("episode names") }
            let sourceCount = episodes.reduce(0) { $0 + (($1["sources"] as? [Any])?.count ?? 0) }
            if migrated.episodes.flatMap(\.sources).count != sourceCount { failures.append("source count") }
            if migrated.episodes.flatMap(\.sources).contains(where: { $0.observations != SourceObservations() }) {
                failures.append("invented media facts")
            }
            if migrated.episodes.contains(where: { $0.number != nil || $0.recordedOn != nil }) { failures.append("invented dates/numbers") }
            return failures
        }
    )
}

// MARK: - Fault injection

struct SimulatedCrash: InjectedInterruption, Equatable {
    let boundary: PublicationBoundary?
    let detail: String
}

/// One injected fault. File-level faults fire on the first matching operation after boundary `after`.
enum Fault: Sendable, Equatable {
    /// Process death exactly at a boundary.
    case crash(at: PublicationBoundary)
    /// Crash part-way through writing a new file in the step that follows `after`.
    case partialWrite(after: PublicationBoundary, fraction: Double)
    /// Provider-like non-atomic publication after P4: destination overwritten in place with a prefix, then crash.
    case tornPublish(fraction: Double)
    /// After P5, read-back observes other bytes (stale provider read); no crash.
    case staleReadBack
    /// A write in the step after `after` fails with an errno (disk full, permission, offline); no crash.
    case failWrite(after: PublicationBoundary, errno: Int32)
}

/// Shared fault state for `FaultInjectingFileOperations` + `FaultHooks`, plus a write audit log.
final class FaultState: Sendable {
    struct State {
        var fault: Fault?
        var lastReached: PublicationBoundary?
        var dead = false
        var fired = false
        var writes: [URL] = []
    }

    let state = Mutex(State())

    init(_ fault: Fault? = nil) {
        state.withLock { $0.fault = fault }
    }

    var fired: Bool { state.withLock { $0.fired } }
    var writes: [URL] { state.withLock { $0.writes } }

    func crash(_ boundary: PublicationBoundary?, _ detail: String) -> SimulatedCrash {
        state.withLock {
            $0.dead = true
            $0.fired = true
        }
        return SimulatedCrash(boundary: boundary, detail: detail)
    }
}

struct FaultHooks: PublicationHooks {
    let faults: FaultState

    func reached(_ boundary: PublicationBoundary) throws {
        let fault = faults.state.withLock { state -> Fault? in
            state.lastReached = boundary
            return state.fault
        }
        if fault == .crash(at: boundary) { throw faults.crash(boundary, "at boundary") }
    }
}

/// Wraps real file operations: injects faults, models process death (every call after a crash fails, so no
/// cleanup can run) and records every write target for the zero-source-writes audit.
struct FaultInjectingFileOperations: FileOperations {
    let base = LocalFileOperations()
    let faults: FaultState

    private func checkAlive() throws {
        if faults.state.withLock({ $0.dead }) { throw SimulatedCrash(boundary: nil, detail: "process is dead") }
    }

    private func record(_ url: URL) {
        faults.state.withLock { $0.writes.append(url.standardizedFileURL) }
    }

    func read(_ url: URL) throws -> Data {
        try checkAlive()
        let data = try base.read(url)
        let (fault, boundary, fired) = faults.state.withLock { ($0.fault, $0.lastReached, $0.fired) }
        if fault == .staleReadBack, boundary == .published, !fired {
            faults.state.withLock { $0.fired = true }
            return data.dropLast(7) + Data("STALE!}".utf8)
        }
        return data
    }

    func exists(_ url: URL) -> Bool { base.exists(url) }

    func createDirectory(_ url: URL) throws {
        try checkAlive()
        try base.createDirectory(url)
    }

    func writeNew(_ data: Data, to url: URL) throws {
        try checkAlive()
        record(url)
        let (fault, boundary) = faults.state.withLock { ($0.fault, $0.lastReached) }
        switch fault {
        case let .partialWrite(after, fraction) where after == boundary:
            try base.writeNew(data.prefix(Int(Double(data.count) * fraction)), to: url)
            throw faults.crash(boundary, "partial write \(fraction)")
        case let .failWrite(after, code) where after == boundary:
            faults.state.withLock { $0.fired = true }
            throw POSIXError(POSIXErrorCode(rawValue: code)!)
        default:
            try base.writeNew(data, to: url)
        }
    }

    func replace(_ destination: URL, withStaged staged: URL) throws {
        try checkAlive()
        record(destination)
        let (fault, boundary) = faults.state.withLock { ($0.fault, $0.lastReached) }
        switch fault {
        case let .tornPublish(fraction) where boundary == .stagedFlushed:
            let data = try base.read(staged)
            if base.exists(destination) {
                let handle = try FileHandle(forWritingTo: destination)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data.prefix(max(1, Int(Double(data.count) * fraction))))
                try handle.close()
            } else {
                try base.writeNew(data.prefix(max(1, Int(Double(data.count) * fraction))), to: destination)
            }
            throw faults.crash(boundary, "torn publish \(fraction)")
        case let .failWrite(after, code) where after == boundary:
            faults.state.withLock { $0.fired = true }
            throw POSIXError(POSIXErrorCode(rawValue: code)!)
        default:
            try base.replace(destination, withStaged: staged)
        }
    }

    func moveNew(_ source: URL, to destination: URL) throws {
        try checkAlive()
        record(destination)
        try base.moveNew(source, to: destination)
    }

    func remove(_ url: URL) throws {
        try checkAlive()
        record(url)
        try base.remove(url)
    }

    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try checkAlive()
        return try base.contentsOfDirectory(url)
    }

    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        try checkAlive()
        let url = try base.makeStagingDirectory(appropriateFor: destination)
        record(url)
        return url
    }
}

/// Path-based "bookmarks" for headless tests (no security scope involved).
struct PlainFolderBookmarks: FolderBookmarking {
    func bookmark(for folder: URL) throws -> Data { Data(folder.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true), false)
    }
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

final class InMemoryLibrarySettings: LibraryLocationSettingsStoring {
    private let setting = Mutex(LibraryLocationSetting())
    func load() -> LibraryLocationSetting { setting.withLock { $0 } }
    func save(_ value: LibraryLocationSetting) throws { setting.withLock { $0 = value } }
}

// MARK: - Statistics

enum Stats {
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func summary(_ values: [Double]) -> String {
        String(format: "n=%d p50=%.4fs p95=%.4fs max=%.4fs", values.count, percentile(values, 50), percentile(values, 95), values.max() ?? .nan)
    }
}

/// Appends a line to the evidence log used for the PR report (under the package build directory).
enum Evidence {
    static func record(_ line: String) {
        print("[evidence] \(line)")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/persistence-evidence.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("\(Date().ISO8601Format()) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
