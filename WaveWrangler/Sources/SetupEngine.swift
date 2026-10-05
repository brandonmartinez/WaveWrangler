import Foundation
import UniformTypeIdentifiers
import WWCore
import WWEpisodeSetup

/// Chooses the source engine behind the Setup UI's `SourceSetupEngine` seam.
///
/// - `WW_SETUP_ENGINE=fixture-states` (UI tests only): scripted in-memory engine with simulated provider
///   states; it never touches the file system. Results are labelled "simulated provider state".
/// - Otherwise: `SessionSourceEngine`, an interim metadata-only engine used until the WWSources engine
///   (device access records, security-scoped ledger, observation, downloads) is integrated.
@MainActor
enum SetupEngineProvider {
    static let shared: any SourceSetupEngine = makeEngine(ProcessInfo.processInfo.environment)

    static func makeEngine(_ environment: [String: String]) -> any SourceSetupEngine {
        if environment["WW_SETUP_ENGINE"] == "fixture-states" {
            return SetupFixtures.statesEngine()
        }
        return SessionSourceEngine()
    }
}

/// Interim engine: metadata-only import scans and session-scoped location hints.
///
/// It reads only URL resource values (names, folder structure, extension, size, dates, file-system
/// identifiers, ubiquitous status keys); it never opens, previews, hashes, decodes or downloads files and
/// never writes to them. It does **not** persist device-local access records, so after relaunch sources
/// honestly read "Permission unknown" until the WWSources engine is integrated. Downloads are not
/// connected here and report that reason instead of pretending to work.
final class SessionSourceEngine: SourceSetupEngine, @unchecked Sendable {
    private struct Record {
        var url: URL
        var resourceID: AnyHashable?
        var details: FileDetails
        var identity: IdentityStatus
    }

    private let lock = NSLock()
    private var records: [SourceID: Record] = [:]
    private var lastScan: [UUID: (URL, AnyHashable?, FileDetails)] = [:]
    private var relinkUndo: [UUID: Record?] = [:]
    private var transfers: [SourceID: TransferStatus] = [:]
    private var observers: [UUID: (Set<SourceID>, AsyncStream<[SourceID: SourceStatusSnapshot]>.Continuation)] = [:]

    static let notConnectedReason = "source access isn't connected in this build yet"

    let pauseSupported = false

    private static let keys: Set<URLResourceKey> = [
        .nameKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .fileResourceIdentifierKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    @concurrent
    func scanForImport(_ urls: [URL], episodeSourceIDs: [SourceID]) async throws(SourceEngineError) -> ImportScan {
        var candidates: [ImportCandidate] = []
        var scanned: [UUID: (URL, AnyHashable?, FileDetails)] = [:]
        var folders = 0
        let existing = lock.withLock { Set(episodeSourceIDs.compactMap { records[$0]?.resourceID }) }

        func add(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Self.keys) else { return }
            if values.isDirectory == true { return }
            let details = Self.details(url, values)
            let kind: ImportCandidate.Kind
            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                kind = .hidden
            } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) {
                kind = .recording(typeFromNameOnly: true)
            } else {
                kind = .notRecording
            }
            let resourceID = values.fileResourceIdentifier.map { AnyHashable($0 as! NSObject) }
            let candidate = ImportCandidate(
                details: details,
                kind: kind,
                alreadyInEpisode: resourceID.map(existing.contains) ?? false,
                residency: Self.residency(values)
            )
            scanned[candidate.id] = (url, resourceID, details)
            candidates.append(candidate)
        }

        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDirectory else { add(url); continue }
            folders += 1
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(Self.keys), options: [.skipsPackageDescendants]) else { continue }
            while let child = enumerator.nextObject() as? URL {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    folders += 1
                } else {
                    add(child)
                }
            }
        }
        lock.withLock { lastScan = scanned }
        let chosen = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        return ImportScan(candidates: candidates, chosenDisplayName: chosen, folderCount: folders, fileCount: candidates.count)
    }

    func commitImport(_ accepted: [UUID: SourceID]) async throws(SourceEngineError) {
        lock.withLock {
            for (candidateID, sourceID) in accepted {
                guard let (url, resourceID, details) = lastScan[candidateID] else { continue }
                records[sourceID] = Record(url: url, resourceID: resourceID, details: details, identity: .notChecked)
            }
        }
        await publish()
    }

    func forget(_ sourceIDs: [SourceID]) async {
        lock.withLock { for id in sourceIDs { records[id] = nil } }
    }

    func recordedDetails(for sourceID: SourceID) async -> FileDetails? {
        lock.withLock { records[sourceID]?.details }
    }

    func lastKnownFolder(for sourceID: SourceID) async -> URL? {
        lock.withLock { records[sourceID]?.url.deletingLastPathComponent() }
    }

    @concurrent
    func compare(candidate url: URL, for sourceID: SourceID) async -> RelinkComparison {
        let recorded = lock.withLock { records[sourceID]?.details } ?? FileDetails()
        let values = try? url.resourceValues(forKeys: Self.keys)
        let chosen = values.map { Self.details(url, $0) } ?? FileDetails(name: url.lastPathComponent)
        return .compare(recorded: recorded, chosen: chosen, unknownReason: recorded == FileDetails() ? "WaveWrangler has no recorded file details for this source on this Mac" : nil)
    }

    @concurrent
    func commitRelink(_ sourceID: SourceID, to url: URL, identity: IdentityStatus) async throws(SourceEngineError) -> RelinkReceipt {
        let values = try? url.resourceValues(forKeys: Self.keys)
        let receipt = RelinkReceipt(sourceID: sourceID)
        lock.withLock {
            relinkUndo[receipt.id] = records[sourceID]
            let details = values.map { Self.details(url, $0) } ?? FileDetails(name: url.lastPathComponent)
            let resourceID = values?.fileResourceIdentifier.map { AnyHashable($0 as! NSObject) }
            records[sourceID] = Record(url: url, resourceID: resourceID, details: details, identity: identity)
        }
        await publish()
        return receipt
    }

    func revertRelink(_ receipt: RelinkReceipt) async throws(SourceEngineError) {
        lock.withLock {
            if let previous = relinkUndo.removeValue(forKey: receipt.id) { records[receipt.sourceID] = previous }
        }
        await publish()
    }

    func observe(_ sourceIDs: Set<SourceID>) -> AsyncStream<[SourceID: SourceStatusSnapshot]> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<[SourceID: SourceStatusSnapshot]>.makeStream()
        lock.withLock { observers[token] = (sourceIDs, continuation) }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.observers.removeValue(forKey: token) }
        }
        Task.detached { [weak self] in
            guard let self else { return }
            continuation.yield(await self.snapshots(for: sourceIDs))
        }
        return stream
    }

    func perform(_ action: TransferAction, on sourceID: SourceID) async {
        lock.withLock {
            switch action {
            case .cancel: transfers[sourceID] = .cancelled
            default: transfers[sourceID] = .failed(reason: "downloads aren't connected in this build yet")
            }
        }
        await publish()
    }

    // MARK: Observation (metadata-only, off the main thread)

    @concurrent
    private func snapshots(for ids: Set<SourceID>) async -> [SourceID: SourceStatusSnapshot] {
        let (known, transfers) = lock.withLock { (records.filter { ids.contains($0.key) }, self.transfers) }
        var result: [SourceID: SourceStatusSnapshot] = [:]
        let now = Date()
        for id in ids {
            guard let record = known[id] else {
                result[id] = SourceStatusSnapshot(
                    location: .unknown(reason: Self.notConnectedReason),
                    access: .unknown(reason: Self.notConnectedReason),
                    residency: .unknown,
                    transfer: transfers[id] ?? .idle,
                    identity: .notChecked,
                    checkedAt: Dictionary(uniqueKeysWithValues: SourceDimension.allCases.map { ($0, now) })
                )
                continue
            }
            let values = try? record.url.resourceValues(forKeys: Self.keys)
            let probe = SourceReachability.probe(record.url)
            let reachable = probe.location == .known
            var snapshot = SourceStatusSnapshot(
                location: probe.location,
                access: probe.access,
                residency: reachable ? (values.map(Self.residency) ?? .unknown) : .unknown,
                transfer: transfers[id] ?? .idle,
                identity: record.identity,
                checkedAt: Dictionary(uniqueKeysWithValues: SourceDimension.allCases.map { ($0, now) })
            )
            if reachable, let values, let currentID = values.fileResourceIdentifier.map({ AnyHashable($0 as! NSObject) }),
               let recordedID = record.resourceID, currentID != recordedID {
                snapshot.identity = .mismatch(differences: "file-system identifier differs")
            }
            result[id] = snapshot
        }
        return result
    }

    private func publish() async {
        let targets = lock.withLock { Array(observers.values) }
        for (ids, continuation) in targets {
            continuation.yield(await snapshots(for: ids))
        }
    }

    private static func details(_ url: URL, _ values: URLResourceValues) -> FileDetails {
        FileDetails(
            name: values.name ?? url.lastPathComponent,
            size: values.fileSize.map(Int64.init),
            created: values.creationDate,
            modified: values.contentModificationDate,
            kind: UTType(filenameExtension: url.pathExtension)?.localizedDescription,
            folderName: url.deletingLastPathComponent().lastPathComponent
        )
    }

    private static func residency(_ values: URLResourceValues) -> ResidencyStatus {
        guard values.isUbiquitousItem == true else { return values.isUbiquitousItem == false ? .local : .unknown }
        switch values.ubiquitousItemDownloadingStatus {
        case .current?, .downloaded?: return .local
        case .notDownloaded?: return .cloudOnly
        default: return .unknown
        }
    }
}
