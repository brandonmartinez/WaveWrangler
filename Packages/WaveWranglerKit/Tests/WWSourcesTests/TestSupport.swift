import CryptoKit
import Darwin
import Foundation
import WWCore
@testable import WWSources

// MARK: - Seeds (registry derivation: sha256("ww-m1-fixture|v1|" + id + "|" + split + "|" + index) -> first 8 bytes BE)

enum FixtureSeed {
    static func derive(fixtureID: String, split: String, caseIndex: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m1-fixture|v1|\(fixtureID)|\(split)|\(caseIndex)".utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Recording / fault-injecting / simulated-provider gateway

/// Simulated iCloud item. Each metadata poll after a download request advances one script step.
final class SimulatedCloudItem: @unchecked Sendable {
    enum Step: Equatable {
        case progress(Double?)
        case stall
        case error(SourceErrorDescriptor)
        case complete
    }

    enum Kind { case iCloud, datalessUnknownProvider, unreported }

    let kind: Kind
    var script: [Step]
    var status: UbiquitousDownloadingStatus
    var isDownloading = false
    var requested = false
    var fraction: Knowledge<Double> = .unknown
    var error: SourceErrorDescriptor?
    var stepIndex = 0
    var requestError: SourceErrorDescriptor?

    init(kind: Kind = .iCloud, status: UbiquitousDownloadingStatus = .notDownloaded, script: [Step] = [.complete], requestError: SourceErrorDescriptor? = nil) {
        self.kind = kind
        self.status = status
        self.script = script
        self.requestError = requestError
    }

    /// Simulates the provider evicting the item again (harness action, not app action).
    func evictAgain(script newScript: [Step]) {
        status = .notDownloaded
        isDownloading = false
        requested = false
        fraction = .unknown
        error = nil
        stepIndex = 0
        script = newScript
    }

    func advance() {
        guard requested, isDownloading, stepIndex < script.count else { return }
        let step = script[stepIndex]
        stepIndex += 1
        switch step {
        case let .progress(value):
            fraction = Knowledge(value)
        case .stall:
            break
        case let .error(descriptor):
            error = descriptor
            isDownloading = false
        case .complete:
            status = .current
            isDownloading = false
            fraction = .known(1)
        }
    }
}

final class HarnessIO: SourceIO, @unchecked Sendable {
    enum Op: String, CaseIterable, Sendable {
        case metadata, list, bookmarkCreate, bookmarkResolve, scopeStart, scopeStop, downloadRequest, downloadFraction
    }

    struct Faults {
        var scopeStartFails = false
        var metadataFailures: [String: MetadataFailure] = [:]
        var bookmarkCreateFails = false
        var downloadRequestError: SourceErrorDescriptor?
    }

    private let lock = NSLock()
    private let base = SystemSourceIO()
    private var counts: [Op: Int] = [:]
    private var openScopes: [String: Int] = [:]
    private var _faults = Faults()
    private var cloud: [String: SimulatedCloudItem] = [:]
    private var _provenance: ObservationProvenance = .observed
    private var gateArmed = false
    private var _gateEntered = false
    private let gateRelease = DispatchSemaphore(value: 0)

    /// Blocks the *next* metadata call (on whatever thread runs it) until `releaseGate()`, so tests can
    /// change state deterministically while an off-main evaluation is in flight.
    func armMetadataGate() { lock.withLock { gateArmed = true; _gateEntered = false } }
    var gateEntered: Bool { lock.withLock { _gateEntered } }
    func releaseGate() { gateRelease.signal() }

    var provenance: ObservationProvenance { lock.withLock { _provenance } }

    var faults: Faults {
        get { lock.withLock { _faults } }
        set { lock.withLock { _faults = newValue } }
    }

    func count(_ op: Op) -> Int { lock.withLock { counts[op, default: 0] } }
    var allCounts: [Op: Int] { lock.withLock { counts } }
    var leakedScopes: Int { lock.withLock { openScopes.values.reduce(0, +) } }

    func simulate(_ url: URL, _ item: SimulatedCloudItem) {
        lock.withLock {
            cloud[Self.key(url)] = item
            _provenance = .simulated
        }
    }

    func simulated(_ url: URL) -> SimulatedCloudItem? { lock.withLock { cloud[Self.key(url)] } }

    static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func bump(_ op: Op) { lock.withLock { counts[op, default: 0] += 1 } }

    func metadata(at url: URL) -> MetadataResult {
        bump(.metadata)
        let shouldBlock = lock.withLock { () -> Bool in
            guard gateArmed else { return false }
            gateArmed = false
            _gateEntered = true
            return true
        }
        if shouldBlock { gateRelease.wait() }
        if let failure = lock.withLock({ _faults.metadataFailures[Self.key(url)] }) { return .failure(failure) }
        let result = base.metadata(at: url)
        guard case var .success(metadata) = result, let item = simulated(url) else { return result }
        lock.withLock {
            item.advance()
            switch item.kind {
            case .iCloud:
                metadata.isDataless = .known(item.status == .notDownloaded)
                metadata.ubiquitous = UbiquitousObservation(
                    isUbiquitousItem: .known(true),
                    downloadingStatus: .known(item.status),
                    isDownloading: .known(item.isDownloading),
                    downloadRequested: .known(item.requested),
                    downloadingError: item.error
                )
            case .datalessUnknownProvider:
                metadata.isDataless = .known(true)
                metadata.ubiquitous = UbiquitousObservation()
            case .unreported:
                metadata.isDataless = .unknown
                metadata.volumeIsLocal = .unknown
                metadata.ubiquitous = UbiquitousObservation()
            }
        }
        return .success(metadata)
    }

    func listItems(under directory: URL) -> DirectoryListing {
        bump(.list)
        return base.listItems(under: directory)
    }

    func makeReadOnlyBookmark(for url: URL) throws -> Data {
        bump(.bookmarkCreate)
        if faults.bookmarkCreateFails { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError) }
        return try base.makeReadOnlyBookmark(for: url)
    }

    func resolveBookmark(_ data: Data) -> BookmarkResolution {
        bump(.bookmarkResolve)
        return base.resolveBookmark(data)
    }

    func startAccessingSecurityScope(_ url: URL) -> Bool {
        bump(.scopeStart)
        if faults.scopeStartFails { return false }
        let started = base.startAccessingSecurityScope(url)
        if started { lock.withLock { openScopes[url.absoluteString, default: 0] += 1 } }
        return started
    }

    func stopAccessingSecurityScope(_ url: URL) {
        bump(.scopeStop)
        base.stopAccessingSecurityScope(url)
        lock.withLock { openScopes[url.absoluteString, default: 0] -= 1 }
    }

    func requestDownload(of url: URL) throws {
        bump(.downloadRequest)
        if let error = faults.downloadRequestError { throw NSError(domain: error.domain, code: error.code) }
        guard let item = simulated(url) else {
            // Never call the real provider from synthetic tests.
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
        try lock.withLock {
            if let error = item.requestError { throw NSError(domain: error.domain, code: error.code) }
            item.requested = true
            item.isDownloading = item.status == .notDownloaded
            item.error = nil
        }
    }

    /// Suspends the next observation poll (after its metadata sample) until released.
    let fractionGate = AsyncGate()

    func downloadFraction(of url: URL) async -> Knowledge<Double> {
        bump(.downloadFraction)
        await fractionGate.pass()
        guard let item = simulated(url) else { return .unknown }
        return lock.withLock { item.fraction }
    }
}

/// One-shot async gate: the first `pass()` after `arm()` suspends (without blocking a thread or an
/// actor) until `release()`. Lets tests hold a transfer in flight deterministically.
actor AsyncGate {
    private var armed = false
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        armed = true
        entered = false
        opened = false
    }

    func pass() async {
        guard armed else { return }
        armed = false
        entered = true
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        opened = true
        armed = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    var isEntered: Bool { entered }

    /// Liveness wait (not a correctness timeout): returns once the gate was entered, or after `limit`.
    func waitUntilEntered(limit: Duration = .seconds(60)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !entered && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return entered
    }
}

/// Subscribes to `controller` events for `key` *before* the caller triggers work, and collects states up
/// to and including the first one matching `stop`. Driven by published events, not time; `limit` is only
/// a liveness guard so a regression fails (with the states seen so far) instead of hanging the suite.
func eventCollector(
    _ controller: SourceTransferController,
    key: DeviceAccessKey,
    limit: Duration = .seconds(60),
    until stop: @escaping @Sendable (TransferState) -> Bool
) async -> Task<[TransferState], Never> {
    let stream = await controller.events()
    let seen = StateLog()
    return Task {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream where event.key == key {
                    seen.append(event.state)
                    if stop(event.state) { break }
                }
            }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
        return seen.states
    }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [TransferState] = []
    func append(_ state: TransferState) { lock.withLock { _states.append(state) } }
    var states: [TransferState] { lock.withLock { _states } }
}

// MARK: - Synthetic trees and immutability snapshots

/// Generated random-byte files in a private temp directory. Never real audio, never user media.
final class SyntheticTree {
    let root: URL
    let sources: URL

    init(label: String = "case") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ww-sources-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int, rng: inout SplitMix64) throws -> URL {
        let url = sources.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8.random(in: 0...255, using: &rng) }
        }
        try data.write(to: url)
        return url
    }

    func directory(_ relativePath: String) throws -> URL {
        let url = sources.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanUp() {
        // Restore permissions changed by denied-access cases before removal.
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { url, _ in
            chmod(url.path, 0o755)
            return true
        }) {
            for case let url as URL in enumerator { chmod(url.path, 0o755) }
        }
        chmod(root.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    deinit { cleanUp() }
}

/// Bytes + modification date + file identifier + relative path of every file under a root. Computed by
/// the harness (outside the code under test).
struct TreeSnapshot: Equatable {
    struct Entry: Equatable {
        var bytes: Data?
        var modificationDate: Date?
        var inode: UInt64
        var mode: UInt16
    }

    var entries: [String: Entry]

    static func take(_ root: URL) -> TreeSnapshot {
        var entries: [String: Entry] = [:]
        let rootPath = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(atPath: rootPath)
        while let relative = enumerator?.nextObject() as? String {
            let path = rootPath + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let isFile = (info.st_mode & S_IFMT) == S_IFREG
            let bytes = isFile ? FileManager.default.contents(atPath: path) : nil
            let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            entries[relative] = Entry(bytes: bytes, modificationDate: isFile ? mtime : nil, inode: UInt64(info.st_ino), mode: info.st_mode)
        }
        return TreeSnapshot(entries: entries)
    }

    /// Number of entries added, removed or changed.
    func differences(from other: TreeSnapshot) -> Int {
        let keys = Set(entries.keys).union(other.entries.keys)
        return keys.filter { entries[$0] != other.entries[$0] }.count
    }
}

func inode(of url: URL) -> UInt64? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return UInt64(info.st_ino)
}

func setDates(_ url: URL, modification: Date?, creation: Date?) throws {
    var attributes: [FileAttributeKey: Any] = [:]
    if let modification { attributes[.modificationDate] = modification }
    if let creation { attributes[.creationDate] = creation }
    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
}

func appendBytes(_ url: URL, count: Int) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0x5A, count: count))
}

/// Fixed show used by single-show tests.
let testShow = ShowID(UUID(uuidString: "00000000-0000-0000-0000-00000000005E")!)

func makeContext(_ io: HarnessIO) -> SourceAccessContext {
    SourceAccessContext(io: io, ledger: SecurityScopeLedger())
}

extension Knowledge {
    static func reported(_ value: Value?) -> Knowledge { Knowledge(value) }
}
