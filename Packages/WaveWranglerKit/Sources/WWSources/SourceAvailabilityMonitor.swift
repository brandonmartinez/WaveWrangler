import Foundation
import Observation
import WWCore

/// Main-actor, observable facade for one show's Sources UI: per-source observations, the availability
/// setting and explicit Make Available / Cancel / Retry. All file-system work runs off the main actor.
/// Records are read and written only under this show's `DeviceAccessKey`s.
@MainActor
@Observable
public final class SourceAvailabilityMonitor {
    public let showID: ShowID
    public private(set) var observations: [SourceID: AvailabilityObservation] = [:]
    public private(set) var setting: SourceAvailabilitySetting

    @ObservationIgnored public let store: any DeviceAccessStore
    @ObservationIgnored public let context: SourceAccessContext
    @ObservationIgnored public let transfers: SourceTransferController
    @ObservationIgnored private var tracked: [SourceID] = []
    @ObservationIgnored private var resolvedURLs: [SourceID: URL] = [:]
    /// Sources whose transfer the user cancelled; not automatically re-requested until Retry.
    @ObservationIgnored private var userCancelled: Set<SourceID> = []
    /// Bumped on every setting change; refreshes evaluated under an older setting are discarded (the
    /// change triggers its own refresh).
    @ObservationIgnored private var settingGeneration = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    public init(
        showID: ShowID,
        store: any DeviceAccessStore,
        context: SourceAccessContext = SourceAccessContext(),
        setting: SourceAvailabilitySetting = .default,
        transferPolicy: TransferPolicy = TransferPolicy()
    ) {
        self.showID = showID
        self.store = store
        self.context = context
        self.setting = setting
        self.transfers = SourceTransferController(context: context, policy: transferPolicy, setting: setting)
    }

    /// Starts consuming transfer events. Call once (e.g. when the window appears).
    public func start() {
        guard eventTask == nil else { return }
        let transfers = transfers
        eventTask = Task { [weak self] in
            let stream = await transfers.events()
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    /// Stops consuming events and tears down every transfer observer (not recorded as a user cancel).
    /// Call when the owning window closes; deinit does the same.
    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        let transfers = transfers
        Task { await transfers.shutdown() }
    }

    isolated deinit {
        eventTask?.cancel()
        let transfers = transfers
        Task { await transfers.shutdown() }
    }

    /// Observes the given sources (metadata only) and, when availability is ON, requests downloads for
    /// iCloud placeholders.
    public func refresh(_ sourceIDs: [SourceID]) async {
        for sourceID in sourceIDs where !tracked.contains(sourceID) { tracked.append(sourceID) }
        for sourceID in sourceIDs {
            await refreshOne(sourceID)
        }
    }

    public func refreshAll() async {
        await refresh(tracked)
    }

    /// Explicit per-item request; allowed even when availability is OFF (labelled a content transfer).
    public func makeAvailable(_ sourceID: SourceID) async {
        userCancelled.remove(sourceID)
        guard let url = resolvedURLs[sourceID] else {
            await refreshOne(sourceID)
            guard let url = resolvedURLs[sourceID] else { return }
            await transfers.makeAvailable(key(sourceID), at: url, userRequested: true)
            return
        }
        await transfers.makeAvailable(key(sourceID), at: url, userRequested: true)
    }

    public func cancelTransfer(_ sourceID: SourceID) async {
        userCancelled.insert(sourceID)
        await transfers.cancel(key(sourceID))
    }

    public func retryTransfer(_ sourceID: SourceID) async {
        await makeAvailable(sourceID)
    }

    public func setAvailabilitySetting(_ newSetting: SourceAvailabilitySetting) async {
        guard newSetting != setting else { return }
        setting = newSetting
        settingGeneration += 1
        await transfers.availabilitySettingChanged(to: newSetting)
        await refreshAll()
    }

    /// Persists records produced by import or relink for this show and observes them.
    public func adopt(_ records: [DeviceAccessRecord]) async throws {
        let mine = records.filter { $0.showID == showID }
        try await store.save(mine)
        await refresh(mine.map(\.sourceID))
    }

    private func key(_ sourceID: SourceID) -> DeviceAccessKey {
        DeviceAccessKey(showID: showID, sourceID: sourceID)
    }

    private func refreshOne(_ sourceID: SourceID) async {
        let key = key(sourceID)
        let record = try? await store.record(for: key)
        let transferState = await transfers.reportableState(of: key)
        let evaluator = SourceAvailabilityEvaluator(context: context)
        let evaluatedSetting = setting
        let evaluatedGeneration = settingGeneration
        let evaluation = await Task.detached {
            evaluator.evaluate(key: key, record: record, setting: evaluatedSetting, transfer: transferState)
        }.value
        if let refreshed = evaluation.refreshedRecord {
            try? await store.save(refreshed)
        }
        // Re-read after every await: a setting change while this ran supersedes the result.
        guard settingGeneration == evaluatedGeneration else { return }
        resolvedURLs[sourceID] = evaluation.resolvedURL
        observations[sourceID] = evaluation.observation

        let needsUserRetry: Bool = switch evaluation.observation.transfer {
        case .failed, .offlineOrUnknown, .cancelled: true
        default: false
        }
        guard setting == .on, !userCancelled.contains(sourceID), !needsUserRetry,
              evaluation.supportsDownloadRequest,
              evaluation.observation.residency == .cloudPlaceholder,
              let url = evaluation.resolvedURL
        else { return }
        guard await !transfers.isActive(key), setting == .on else { return }
        // The controller re-checks its own setting atomically and refuses if it is OFF.
        await transfers.makeAvailable(key, at: url)
    }

    private func apply(_ event: TransferEvent) {
        guard event.key.showID == showID, var observation = observations[event.key.sourceID] else { return }
        observation.transfer = event.state
        observation.transferEvidence = .transferController
        if event.state == .idle { observation.residency = .local }
        observations[event.key.sourceID] = observation
    }
}
