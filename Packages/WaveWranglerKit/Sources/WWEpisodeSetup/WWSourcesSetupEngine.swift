import Foundation
import Observation
import UniformTypeIdentifiers
import WWCore
import WWSources

/// Maps WWSources' device-local observations onto Design's five-dimension presentation (states §3).
/// WWSources' diagnostic text is never shown; wording comes from `SourceStatus.swift`.
public enum WWSourcesStatusMapping {
    public static func snapshot(_ observation: AvailabilityObservation?) -> SourceStatusSnapshot {
        guard let observation else { return .checking }
        let checked = Dictionary(uniqueKeysWithValues: SourceDimension.allCases.map { ($0, observation.observedAt) })
        return SourceStatusSnapshot(
            location: location(observation),
            access: access(observation),
            residency: residency(observation.residency),
            transfer: transfer(observation.transfer),
            identity: identity(observation.identity),
            checkedAt: checked
        )
    }

    static func location(_ observation: AvailabilityObservation) -> LocationStatus {
        switch observation.location {
        case .present: return .known
        case let .moved(hint): return .moved(newFolder: folderName(ofPath: hint))
        case let .missing(occupied): return .missing(sameNamedFileAtOriginalLocation: occupied.value == true)
        case .unknown:
            if observation.locationEvidence == .noAccessRecord { return .unknown(reason: "this Mac has no saved location for it") }
            if observation.access == .denied { return .unknown(reason: "access was denied, so WaveWrangler couldn't check") }
            return .unknown(reason: "WaveWrangler couldn't check where it is")
        }
    }

    static func access(_ observation: AvailabilityObservation) -> AccessStatus {
        switch observation.access {
        case .granted: .granted
        // A stale bookmark still reported after evaluation could not be refreshed automatically.
        case .staleBookmark, .needsRegrant: .needsPermission
        case .denied: .denied
        case .unknown:
            observation.accessEvidence == .noAccessRecord
                ? .unknown(reason: "this Mac has no saved permission for it")
                : .unknown(reason: "macOS didn't report it")
        }
    }

    static func residency(_ state: ResidencyState) -> ResidencyStatus {
        switch state {
        case .local: .local
        case .cloudPlaceholder, .downloading: .cloudOnly
        case .unknown: .unknown
        }
    }

    static func transfer(_ state: TransferState) -> TransferStatus {
        switch state {
        case .unknown, .idle: .idle
        case .notRequested(.availabilityOff): .downloadsOff
        case .notRequested(.unsupportedLocation): .unsupportedLocation
        case .notRequested(.awaitingAccess): .queued
        case .requested: .downloading(fraction: nil)
        case let .inProgress(fraction): .downloading(fraction: fraction.value)
        case .cancelled: .cancelled
        case let .failed(error): .failed(reason: describe(error))
        // Connection loss is not observed: say only what was observed.
        case .offlineOrUnknown: .failed(reason: "no progress was reported")
        }
    }

    static func identity(_ state: IdentityState) -> IdentityStatus {
        switch state {
        case .unknown, .unverified(.noRecordedEvidence), .unverified(.insufficientEvidence): .notChecked
        // Details equal the recorded baseline: exactly Design's "Details match" (audio not compared).
        case .matchesRecorded, .unverified(.baselineNotUserConfirmed): .detailsMatch
        case let .changed(fields): .changed(differences: differ(fields), acceptedByUser: false)
        case let .mismatch(fields): .mismatch(differences: differ(fields))
        }
    }

    public static func fieldName(_ field: FingerprintField) -> String {
        switch field {
        case .fileSize: "Size"
        case .creationDate: "Created"
        case .contentModificationDate: "Modified"
        case .fileIdentifier: "File ID"
        case .volumeUUID: "Volume"
        case .contentType: "Kind"
        }
    }

    static func differ(_ fields: [FingerprintField]) -> String {
        fields.isEmpty ? "details differ" : fields.map { fieldName($0).lowercased() }.joined(separator: ", ") + " differ"
    }

    static func describe(_ error: SourceErrorDescriptor) -> String {
        let text = NSError(domain: error.domain, code: error.code).localizedDescription
        return text.isEmpty ? "error \(error.code)" : text
    }

    static func folderName(ofPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(filePath: path).deletingLastPathComponent().lastPathComponent
    }

    public static func details(_ fingerprint: FileSystemFingerprint?, path: String?) -> FileDetails {
        FileDetails(
            name: path.map { URL(filePath: $0).lastPathComponent },
            size: fingerprint?.fileSize.value,
            created: fingerprint?.creationDate.value,
            modified: fingerprint?.contentModificationDate.value,
            kind: fingerprint?.contentType.value.map { UTType($0)?.localizedDescription ?? $0 },
            folderName: folderName(ofPath: path)
        )
    }

    /// Relink sheet comparison from the engine's identity comparison (file-system metadata only).
    public static func comparison(recorded: DeviceAccessRecord?, proposal: RelinkProposal, chosenName: String, otherSourceName: (SourceID) -> String) -> RelinkComparison {
        let recordedFingerprint = recorded?.recordedIdentity?.fingerprint
        let recordedDetails = details(recordedFingerprint, path: recorded?.lastKnownPath)
        var chosenDetails = details(proposal.candidateFingerprint, path: nil)
        chosenDetails.name = chosenName
        let (differing, unknown): ([FingerprintField], [FingerprintField]) = switch proposal.comparison {
        case .matches: ([], [])
        case let .differs(fields, unknownFields): (fields, unknownFields)
        case let .unknown(fields): ([], fields)
        }
        func result(_ fields: [FingerprintField]) -> RelinkComparison.Result {
            if fields.contains(where: differing.contains) { return .different }
            if fields.contains(where: unknown.contains) { return .unknown }
            return .same
        }
        let format = FileDetailFormatter.standard
        let nameResult: RelinkComparison.Result = recordedDetails.name.map { $0 == chosenName ? .same : .different } ?? .unknown
        let rows: [RelinkComparison.Row] = [
            .init(field: "Name", recorded: recordedDetails.name ?? "Unknown", chosen: chosenName, result: nameResult),
            .init(field: "Size", recorded: recordedDetails.size.map(format.size) ?? "Unknown", chosen: chosenDetails.size.map(format.size) ?? "Unknown", result: result([.fileSize])),
            .init(field: "Created", recorded: recordedDetails.created.map(format.date) ?? "Unknown", chosen: chosenDetails.created.map(format.date) ?? "Unknown", result: result([.creationDate])),
            .init(field: "Modified", recorded: recordedDetails.modified.map(format.date) ?? "Unknown", chosen: chosenDetails.modified.map(format.date) ?? "Unknown", result: result([.contentModificationDate])),
            .init(field: "Kind", recorded: recordedDetails.kind ?? "Unknown", chosen: chosenDetails.kind ?? "Unknown", result: result([.contentType])),
            .init(field: "File ID", recorded: recordedFingerprint == nil ? "Unknown" : "Recorded", chosen: proposal.candidateFingerprint == nil ? "Unknown" : "Read", result: result([.fileIdentifier, .volumeUUID])),
        ]
        let outcome: RelinkComparison.Outcome
        switch proposal.availability {
        case .ready:
            if let other = proposal.alreadyLinkedTo {
                outcome = .alreadyLinked(otherSource: otherSourceName(other))
            } else {
                switch proposal.comparison {
                case .matches: outcome = .match
                case let .differs(fields, _): outcome = .different(fields: fields.map(fieldName))
                case let .unknown(fields):
                    outcome = .unknown(reason: recorded?.recordedIdentity == nil
                        ? "this Mac has no recorded file details for this source"
                        : "these details aren't available: \(fields.map { fieldName($0).lowercased() }.joined(separator: ", "))")
                }
            }
        case .notAFile: outcome = .unavailable(reason: "it isn't a file")
        case .permissionDenied: outcome = .unavailable(reason: "macOS or the file's owner denied access")
        case .notFound: outcome = .unavailable(reason: "it wasn't found")
        case .bookmarkFailed, .metadataUnavailable: outcome = .unavailable(reason: "macOS couldn't save permission to reach it")
        }
        return RelinkComparison(rows: rows, outcome: outcome)
    }
}

/// `SourceSetupEngine` backed by WWSources for one show: device-local records keyed by
/// `DeviceAccessKey(showID, sourceID)`, the metadata-only importer, availability monitor, transfer
/// controller and relink evaluator. Nothing here reads content or writes to referenced files.
@MainActor
public final class WWSourcesSetupEngine: SourceSetupEngine {
    public nonisolated let pauseSupported = false
    public let showID: ShowID
    public let store: any DeviceAccessStore
    public let context: SourceAccessContext
    public let monitor: SourceAvailabilityMonitor
    private let preference: (any SourceDownloadPreference)?
    private var lastPlan: ImportPlan?
    private var proposals: [SourceID: (url: URL, proposal: RelinkProposal)] = [:]
    private var previousRecords: [UUID: DeviceAccessRecord?] = [:]
    private var defaultsObserver: NSObjectProtocol?
    /// Display names of sources in this show, for "already used for …" (set by the UI).
    public var sourceNames: (SourceID) -> String = { _ in "another source" }

    public init(showID: ShowID, store: any DeviceAccessStore, context: SourceAccessContext = SourceAccessContext(), preference: (any SourceDownloadPreference)? = nil, transferPolicy: TransferPolicy = TransferPolicy()) {
        self.showID = showID
        self.store = store
        self.context = context
        self.preference = preference
        let setting = SourceAvailabilitySetting(downloadSourcesAutomatically: preference?.downloadsAutomatically)
        monitor = SourceAvailabilityMonitor(showID: showID, store: store, context: context, setting: setting, transferPolicy: transferPolicy)
        monitor.start()
        if preference is UserDefaultsSourceDownloadPreference {
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSetting() }
            }
        }
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        monitor.stop()
    }

    /// Applies the current "Download sources automatically" preference to the engine.
    public func syncSetting() {
        guard let preference else { return }
        let setting = SourceAvailabilitySetting(downloadSourcesAutomatically: preference.downloadsAutomatically)
        guard setting != monitor.setting else { return }
        Task { await monitor.setAvailabilitySetting(setting) }
    }

    private func key(_ sourceID: SourceID) -> DeviceAccessKey { DeviceAccessKey(showID: showID, sourceID: sourceID) }

    public func scanForImport(_ urls: [URL], episodeSourceIDs: [SourceID]) async throws(SourceEngineError) -> ImportScan {
        let existing = (try? await store.records(in: showID)) ?? []
        let importer = SourceImporter(context: context)
        let showID = showID
        let plan: ImportPlan
        do {
            plan = try await Task.detached { try await importer.plan(selection: urls, showID: showID, existingRecords: existing) }.value
        } catch {
            throw .failed(reason: error.localizedDescription)
        }
        lastPlan = plan
        let inEpisode = Set(episodeSourceIDs)
        var suggestions: [UUID: CandidateSuggestions] = [:]
        for group in plan.suggestions.recorderGroups {
            let reason = group.basis.contains(.folderStructure)
                ? "Suggested because the files share folder \(group.name)"
                : "Suggested because the file names follow the same pattern"
            for id in group.sourceIDs { suggestions[id.rawValue, default: CandidateSuggestions()].group = Suggestion(value: group.name, reason: reason) }
        }
        for speaker in plan.suggestions.speakers {
            for id in speaker.sourceIDs {
                suggestions[id.rawValue, default: CandidateSuggestions()].speaker = Suggestion(value: speaker.name, reason: "Suggested because the file name contains “\(speaker.name)”")
            }
        }
        let candidates = plan.items.map { item in
            ImportCandidate(
                id: item.sourceRecord.id.rawValue,
                details: WWSourcesStatusMapping.details(item.accessRecord.recordedIdentity?.fingerprint, path: item.accessRecord.lastKnownPath),
                kind: .recording(typeFromNameOnly: true),
                alreadyInEpisode: item.possibleDuplicateOf.map(inEpisode.contains) ?? false,
                residency: .unknown
            )
        }
        let skipped = plan.skipped.byCategory
        let notRecordings = [ImportItemCategory.projectOrSession, .transcriptOrDocument, .otherFile, .symbolicLink].reduce(0) { $0 + (skipped[$1] ?? 0) }
        let counts = ImportScan.SkipCounts(
            notRecordings: notRecordings,
            hidden: skipped[.hidden] ?? 0,
            unreadable: plan.skipped.unreadableEntries + plan.failures.count,
            duplicates: plan.skipped.duplicateSelections
        )
        let chosen = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        return ImportScan(
            candidates: candidates,
            chosenDisplayName: chosen,
            folderCount: skipped[.directory] ?? 0,
            fileCount: candidates.count + notRecordings + counts.hidden,
            uncountedSkips: counts,
            suggestions: suggestions
        )
    }

    public func commitImport(_ accepted: [UUID: SourceID]) async throws(SourceEngineError) {
        guard let plan = lastPlan else { return }
        let ids = Set(accepted.values)
        let records = plan.items.map(\.accessRecord).filter { ids.contains($0.sourceID) }
        do {
            try await monitor.adopt(records)
        } catch {
            throw .failed(reason: error.localizedDescription)
        }
    }

    public func forget(_ sourceIDs: [SourceID]) async {
        for id in sourceIDs { try? await store.removeRecord(for: key(id)) }
    }

    public func recordedDetails(for sourceID: SourceID) async -> FileDetails? {
        guard let record = try? await store.record(for: key(sourceID)) else { return nil }
        return WWSourcesStatusMapping.details(record.recordedIdentity?.fingerprint, path: record.lastKnownPath)
    }

    public func lastKnownFolder(for sourceID: SourceID) async -> URL? {
        guard let path = try? await store.record(for: key(sourceID))?.lastKnownPath else { return nil }
        return URL(filePath: path).deletingLastPathComponent()
    }

    public func compare(candidate url: URL, for sourceID: SourceID) async -> RelinkComparison {
        let key = key(sourceID)
        let record = try? await store.record(for: key)
        let others = (try? await store.records(in: showID)) ?? []
        let evaluator = RelinkEvaluator(context: context)
        let proposal = await Task.detached { evaluator.evaluate(candidate: url, for: key, record: record, otherRecords: others) }.value
        proposals[sourceID] = (url, proposal)
        return WWSourcesStatusMapping.comparison(recorded: record, proposal: proposal, chosenName: url.lastPathComponent, otherSourceName: sourceNames)
    }

    public func commitRelink(_ sourceID: SourceID, to url: URL, identity: IdentityStatus) async throws(SourceEngineError) -> RelinkReceipt {
        guard let stored = proposals[sourceID], stored.url == url else { throw .failed(reason: "choose the file again") }
        let key = key(sourceID)
        let previous = try? await store.record(for: key)
        let updated: DeviceAccessRecord
        do {
            updated = try RelinkEvaluator(context: context).apply(stored.proposal, to: previous, userConfirmed: true)
        } catch {
            throw .failed(reason: "the chosen file can't be used")
        }
        do {
            try await store.save(updated)
        } catch {
            throw .failed(reason: error.localizedDescription)
        }
        let receipt = RelinkReceipt(sourceID: sourceID)
        previousRecords[receipt.id] = previous
        await monitor.refresh([sourceID])
        return receipt
    }

    public func revertRelink(_ receipt: RelinkReceipt) async throws(SourceEngineError) {
        guard let previous = previousRecords.removeValue(forKey: receipt.id) else { return }
        do {
            if let previous {
                try await store.save(previous)
            } else {
                try await store.removeRecord(for: key(receipt.sourceID))
            }
        } catch {
            throw .failed(reason: error.localizedDescription)
        }
        await monitor.refresh([receipt.sourceID])
    }

    public nonisolated func observe(_ sourceIDs: Set<SourceID>) -> AsyncStream<[SourceID: SourceStatusSnapshot]> {
        let (stream, continuation) = AsyncStream<[SourceID: SourceStatusSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.syncSetting()
            await self.monitor.refresh(Array(sourceIDs))
            while !Task.isCancelled {
                continuation.yield(self.snapshots(sourceIDs))
                await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.monitor.observations
                        _ = self.monitor.setting
                    } onChange: {
                        resume.resume()
                    }
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func snapshots(_ ids: Set<SourceID>) -> [SourceID: SourceStatusSnapshot] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, WWSourcesStatusMapping.snapshot(monitor.observations[$0])) })
    }

    public func refresh(_ sourceIDs: [SourceID]) async {
        await monitor.refresh(sourceIDs)
    }

    public func perform(_ action: TransferAction, on sourceID: SourceID) async {
        switch action {
        case .download: await monitor.makeAvailable(sourceID)
        case .retry: await monitor.retryTransfer(sourceID)
        case .cancel: await monitor.cancelTransfer(sourceID)
        case .pause, .resume: break
        }
    }
}
