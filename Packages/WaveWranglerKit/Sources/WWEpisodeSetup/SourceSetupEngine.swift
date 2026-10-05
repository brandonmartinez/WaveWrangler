import Foundation
import WWCore

/// Opaque handle for undoing a device-local relink.
public struct RelinkReceipt: Hashable, Sendable {
    public var id: UUID
    public var sourceID: SourceID

    public init(id: UUID = UUID(), sourceID: SourceID) {
        self.id = id
        self.sourceID = sourceID
    }
}

public enum SourceEngineError: Error, Hashable, Sendable {
    /// The operation needs a capability this engine doesn't provide (reason is user-facing).
    case unavailable(reason: String)
    case failed(reason: String)

    public var reason: String {
        switch self {
        case let .unavailable(reason), let .failed(reason): reason
        }
    }
}

/// The Setup UI's seam to the source engine (import enumeration, device-local access records, relink and
/// downloads). The UI is engine-agnostic: every engine call goes through this protocol.
///
/// Invariants for every conforming engine: originals are never written, moved, renamed or substituted;
/// paths/names/bookmarks are hints, never identity; with downloads Off the import, observation and
/// relink paths make zero content/hash/header/preview/decode/download requests; no provider I/O happens
/// on the main thread.
public protocol SourceSetupEngine: AnyObject, Sendable {
    /// Whether a transfer can genuinely be paused and resumed without losing progress.
    var pauseSupported: Bool { get }

    /// Metadata-only scan of user-chosen files/folders. `episodeSourceIDs` lets the engine flag files that
    /// are already referenced in the episode by its own identity records (never by name).
    func scanForImport(_ urls: [URL], episodeSourceIDs: [SourceID]) async throws(SourceEngineError) -> ImportScan

    /// Creates device-local access records for imported sources from the scan identified by `token`
    /// (called after the canonical import). Throws when the scan is unknown or a record is missing.
    func commitImport(_ accepted: [UUID: SourceID], fromScan token: UUID) async throws(SourceEngineError)

    /// Forgets a scan the user cancelled.
    func discardScan(_ token: UUID) async

    /// Stops observation and background work when no window uses this engine any more.
    func shutdown() async

    /// Removes device-local records for sources no longer referenced (after removal/undo of import).
    func forget(_ sourceIDs: [SourceID]) async

    /// Details recorded when the source was added (file details only).
    func recordedDetails(for sourceID: SourceID) async -> FileDetails?

    /// Folder to pre-point the Relink/Grant Access panel at, if reachable.
    func lastKnownFolder(for sourceID: SourceID) async -> URL?

    /// Compares a user-chosen file with what was recorded. Never auto-substitutes.
    func compare(candidate url: URL, for sourceID: SourceID) async -> RelinkComparison

    /// Points the source's device-local record at the user-confirmed file. Never touches either file.
    func commitRelink(_ sourceID: SourceID, to url: URL, identity: IdentityStatus) async throws(SourceEngineError) -> RelinkReceipt

    func revertRelink(_ receipt: RelinkReceipt) async throws(SourceEngineError)

    /// Current observations for the given sources; yields again whenever any of them changes.
    func observe(_ sourceIDs: Set<SourceID>) -> AsyncStream<[SourceID: SourceStatusSnapshot]>

    /// Explicit user download command (allowed even when automatic downloads are Off).
    func perform(_ action: TransferAction, on sourceID: SourceID) async

    /// Re-observes the given sources (Try Again).
    func refresh(_ sourceIDs: [SourceID]) async
}

extension SourceSetupEngine {
    public func refresh(_ sourceIDs: [SourceID]) async {}
    public func discardScan(_ token: UUID) async {}
    public func shutdown() async {}
}

/// Shares one engine per key (show) among the windows showing it; shuts it down when the last releases.
@MainActor
public final class SetupEngineRegistry<Key: Hashable> {
    private var entries: [Key: (engine: any SourceSetupEngine, count: Int)] = [:]
    private let make: (Key) -> any SourceSetupEngine

    public init(make: @escaping (Key) -> any SourceSetupEngine) {
        self.make = make
    }

    public func acquire(_ key: Key) -> any SourceSetupEngine {
        if let entry = entries[key] {
            entries[key] = (entry.engine, entry.count + 1)
            return entry.engine
        }
        let engine = make(key)
        entries[key] = (engine, 1)
        return engine
    }

    /// Releases one use; the last release removes the engine and awaits its shutdown.
    public func release(_ key: Key) async {
        guard let entry = entries[key] else { return }
        if entry.count > 1 {
            entries[key] = (entry.engine, entry.count - 1)
            return
        }
        entries[key] = nil
        await entry.engine.shutdown()
    }

    public func count(for key: Key) -> Int { entries[key]?.count ?? 0 }
}

/// Engines leased per owner (a show window): an owner holds at most one use, re-leasing the same key is
/// free, and ending the owner releases it. Keeps a show's engine — and user-requested transfers — alive
/// while any of its windows is open, whichever destination is showing.
@MainActor
public final class SetupEngineLeases<Owner: Hashable, Key: Hashable> {
    public let registry: SetupEngineRegistry<Key>
    private var leases: [Owner: (key: Key, engine: any SourceSetupEngine)] = [:]

    public init(registry: SetupEngineRegistry<Key>) {
        self.registry = registry
    }

    public func engine(for owner: Owner, key: Key) async -> any SourceSetupEngine {
        if let lease = leases[owner] {
            if lease.key == key { return lease.engine }
            leases[owner] = nil
            await registry.release(lease.key)
        }
        let engine = registry.acquire(key)
        leases[owner] = (key, engine)
        return engine
    }

    /// The owner closed: release its use (shutting the engine down if it was the last).
    public func end(_ owner: Owner) async {
        guard let lease = leases.removeValue(forKey: owner) else { return }
        await registry.release(lease.key)
    }

    public func hasLease(_ owner: Owner) -> Bool { leases[owner] != nil }
}

/// App preference "Download sources automatically" (Settings › Sources). Default On.
public protocol SourceDownloadPreference: AnyObject {
    var downloadsAutomatically: Bool { get set }
}

public final class UserDefaultsSourceDownloadPreference: SourceDownloadPreference {
    /// Shared key with Settings (`WWDownloadSourcesAutomatically`).
    public static let key = "WWDownloadSourcesAutomatically"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var downloadsAutomatically: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Scripted, in-memory engine for tests, previews and UI-test fixtures. It never touches the file
/// system; every call is recorded so tests can assert, e.g., zero download requests on Off paths.
public final class InMemorySourceSetupEngine: SourceSetupEngine, @unchecked Sendable {
    public enum Call: Hashable, Sendable {
        case scan(count: Int)
        case commitImport(count: Int)
        case shutdown
        case forget(count: Int)
        case recordedDetails(SourceID)
        case compare(SourceID)
        case commitRelink(SourceID)
        case revertRelink(SourceID)
        case perform(TransferAction, SourceID)
    }

    private let lock = NSLock()
    private var _statuses: [SourceID: SourceStatusSnapshot]
    private var _recorded: [SourceID: FileDetails]
    private var _calls: [Call] = []
    private var continuations: [UUID: (Set<SourceID>, AsyncStream<[SourceID: SourceStatusSnapshot]>.Continuation)] = [:]
    private var relinkHistory: [UUID: SourceStatusSnapshot] = [:]

    public let pauseSupported: Bool
    public var scanResult: ImportScan
    public var candidateDetails: [URL: FileDetails]
    public var compareUnknownReason: String?
    public var importedStatus: SourceStatusSnapshot
    /// Simulated per-file states applied on import, keyed by candidate display name (fixtures only).
    public var importedStatusByName: [String: SourceStatusSnapshot] = [:]
    /// Status a transfer action leads to (simulated provider state).
    public var transferOutcome: @Sendable (TransferAction, SourceStatusSnapshot) -> SourceStatusSnapshot

    public init(
        statuses: [SourceID: SourceStatusSnapshot] = [:],
        recorded: [SourceID: FileDetails] = [:],
        scanResult: ImportScan = ImportScan(candidates: [], chosenDisplayName: "", folderCount: 0, fileCount: 0),
        candidateDetails: [URL: FileDetails] = [:],
        pauseSupported: Bool = false,
        importedStatus: SourceStatusSnapshot = SourceStatusSnapshot(location: .known, access: .granted, residency: .local, transfer: .idle, identity: .notChecked)
    ) {
        _statuses = statuses
        _recorded = recorded
        self.scanResult = scanResult
        self.candidateDetails = candidateDetails
        self.pauseSupported = pauseSupported
        self.importedStatus = importedStatus
        transferOutcome = { action, current in
            var next = current
            switch action {
            case .download, .retry: next.transfer = .queued
            case .pause: next.transfer = .paused
            case .resume: next.transfer = .downloading(fraction: nil)
            case .cancel: next.transfer = .cancelled
            }
            return next
        }
    }

    public var calls: [Call] { lock.withLock { _calls } }

    public func status(of id: SourceID) -> SourceStatusSnapshot? { lock.withLock { _statuses[id] } }

    /// Simulates a provider/OS observation change.
    public func setStatus(_ status: SourceStatusSnapshot, for id: SourceID) {
        lock.withLock { _statuses[id] = status }
        publish()
    }

    public func scanForImport(_ urls: [URL], episodeSourceIDs: [SourceID]) async throws(SourceEngineError) -> ImportScan {
        lock.withLock { _calls.append(.scan(count: urls.count)) }
        return scanResult
    }

    public func commitImport(_ accepted: [UUID: SourceID], fromScan token: UUID) async throws(SourceEngineError) {
        lock.withLock {
            _calls.append(.commitImport(count: accepted.count))
            for (candidateID, sourceID) in accepted {
                _statuses[sourceID] = importedStatus
                if let candidate = scanResult.candidates.first(where: { $0.id == candidateID }) {
                    _recorded[sourceID] = candidate.details
                    if candidate.residency == .cloudOnly { _statuses[sourceID]?.residency = .cloudOnly }
                    if let scripted = importedStatusByName[candidate.displayName] { _statuses[sourceID] = scripted }
                }
            }
        }
        publish()
    }

    public func forget(_ sourceIDs: [SourceID]) async {
        lock.withLock { _calls.append(.forget(count: sourceIDs.count)) }
    }

    public func shutdown() async {
        lock.withLock { _calls.append(.shutdown) }
    }

    public func recordedDetails(for sourceID: SourceID) async -> FileDetails? {
        lock.withLock {
            _calls.append(.recordedDetails(sourceID))
            return _recorded[sourceID]
        }
    }

    public func lastKnownFolder(for sourceID: SourceID) async -> URL? { nil }

    public func compare(candidate url: URL, for sourceID: SourceID) async -> RelinkComparison {
        let (recorded, chosen, reason) = lock.withLock {
            _calls.append(.compare(sourceID))
            return (_recorded[sourceID] ?? FileDetails(), candidateDetails[url] ?? FileDetails(name: url.lastPathComponent), compareUnknownReason)
        }
        return .compare(recorded: recorded, chosen: chosen, unknownReason: reason)
    }

    public func commitRelink(_ sourceID: SourceID, to url: URL, identity: IdentityStatus) async throws(SourceEngineError) -> RelinkReceipt {
        let receipt = RelinkReceipt(sourceID: sourceID)
        lock.withLock {
            _calls.append(.commitRelink(sourceID))
            let previous = _statuses[sourceID] ?? .checking
            relinkHistory[receipt.id] = previous
            var next = previous
            next.location = .known
            next.access = .granted
            next.identity = identity
            _statuses[sourceID] = next
        }
        publish()
        return receipt
    }

    public func revertRelink(_ receipt: RelinkReceipt) async throws(SourceEngineError) {
        lock.withLock {
            _calls.append(.revertRelink(receipt.sourceID))
            if let previous = relinkHistory.removeValue(forKey: receipt.id) { _statuses[receipt.sourceID] = previous }
        }
        publish()
    }

    public func observe(_ sourceIDs: Set<SourceID>) -> AsyncStream<[SourceID: SourceStatusSnapshot]> {
        let token = UUID()
        return AsyncStream { continuation in
            let snapshot: [SourceID: SourceStatusSnapshot] = lock.withLock {
                continuations[token] = (sourceIDs, continuation)
                return _statuses.filter { sourceIDs.contains($0.key) }
            }
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: token) }
            }
        }
    }

    public func perform(_ action: TransferAction, on sourceID: SourceID) async {
        lock.withLock {
            _calls.append(.perform(action, sourceID))
            _statuses[sourceID] = transferOutcome(action, _statuses[sourceID] ?? .checking)
        }
        publish()
    }

    private func publish() {
        let targets = lock.withLock { () -> [(AsyncStream<[SourceID: SourceStatusSnapshot]>.Continuation, [SourceID: SourceStatusSnapshot])] in
            continuations.values.map { ids, continuation in (continuation, _statuses.filter { ids.contains($0.key) }) }
        }
        for (continuation, snapshot) in targets { continuation.yield(snapshot) }
    }
}
