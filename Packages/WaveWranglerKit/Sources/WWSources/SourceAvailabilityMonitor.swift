import Foundation
import Observation
import WWCore

/// Main-actor, observable facade for the Sources UI: per-source observations, the availability
/// setting and explicit Make Available / Cancel / Retry. All file-system work runs off the main actor.
@MainActor
@Observable
public final class SourceAvailabilityMonitor {
    public private(set) var observations: [SourceID: AvailabilityObservation] = [:]
    public private(set) var setting: SourceAvailabilitySetting

    @ObservationIgnored public let store: any DeviceAccessStore
    @ObservationIgnored public let context: SourceAccessContext
    @ObservationIgnored public let transfers: SourceTransferController
    @ObservationIgnored private var tracked: [SourceID] = []
    @ObservationIgnored private var resolvedURLs: [SourceID: URL] = [:]
    /// Sources whose transfer the user cancelled; not automatically re-requested until Retry.
    @ObservationIgnored private var userCancelled: Set<SourceID> = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    public init(
        store: any DeviceAccessStore,
        context: SourceAccessContext = SourceAccessContext(),
        setting: SourceAvailabilitySetting = .default,
        transferPolicy: TransferPolicy = TransferPolicy()
    ) {
        self.store = store
        self.context = context
        self.setting = setting
        self.transfers = SourceTransferController(context: context, policy: transferPolicy)
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

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
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
            await transfers.makeAvailable(sourceID, at: url, setting: setting, userRequested: true)
            return
        }
        await transfers.makeAvailable(sourceID, at: url, setting: setting, userRequested: true)
    }

    public func cancelTransfer(_ sourceID: SourceID) async {
        userCancelled.insert(sourceID)
        await transfers.cancel(sourceID)
    }

    public func retryTransfer(_ sourceID: SourceID) async {
        await makeAvailable(sourceID)
    }

    public func setAvailabilitySetting(_ newSetting: SourceAvailabilitySetting) async {
        guard newSetting != setting else { return }
        setting = newSetting
        await transfers.availabilitySettingChanged(to: newSetting)
        await refreshAll()
    }

    /// Persists records produced by import or relink and observes them.
    public func adopt(_ records: [DeviceAccessRecord]) async throws {
        try await store.save(records)
        await refresh(records.map(\.sourceID))
    }

    private func refreshOne(_ sourceID: SourceID) async {
        let record = try? await store.record(for: sourceID)
        let transferState = await transfers.state(of: sourceID)
        let evaluator = SourceAvailabilityEvaluator(context: context)
        let setting = setting
        let evaluation = await Task.detached {
            evaluator.evaluate(sourceID: sourceID, record: record, setting: setting, transfer: transferState == .unknown ? nil : transferState)
        }.value
        if let refreshed = evaluation.refreshedRecord {
            try? await store.save(refreshed)
        }
        resolvedURLs[sourceID] = evaluation.resolvedURL
        observations[sourceID] = evaluation.observation

        if setting == .on, !userCancelled.contains(sourceID), evaluation.supportsDownloadRequest,
           evaluation.observation.residency == .cloudPlaceholder,
           let url = evaluation.resolvedURL,
           await !transfers.isActive(sourceID) {
            await transfers.makeAvailable(sourceID, at: url, setting: setting)
        }
    }

    private func apply(_ event: TransferEvent) {
        guard var observation = observations[event.sourceID] else { return }
        observation.transfer = event.state
        observation.transferEvidence = .transferController
        if event.state == .idle { observation.residency = .local }
        observations[event.sourceID] = observation
    }
}
