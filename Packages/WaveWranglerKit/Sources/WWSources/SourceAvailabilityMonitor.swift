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
    #if DEBUG
    /// Test only: suspends the detached evaluator task after launch, before synchronous source I/O.
    @ObservationIgnored package var evaluatorTaskDidStart: (@Sendable () async -> Void)?
    #endif

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
        isStopped = false
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

    /// Stops consuming events and tears down every transfer observer that exists now (not recorded as a
    /// user cancel). Returns once teardown finished. After `stop()` the monitor requests nothing —
    /// including explicit `makeAvailable` and refreshes that were already in flight — until `start()` is
    /// called again. Call when the owning window closes; deinit does the same without awaiting.
    public func stop() async {
        isStopped = true
        lifecycleGeneration += 1
        eventTask?.cancel()
        eventTask = nil
        let ticket = transfers.beginShutdown()
        await transfers.shutdown(through: ticket)
    }

    /// Set by `stop()`. A stopped monitor never requests a transfer again, even from work that was
    /// already in flight (checked after every await).
    public private(set) var isStopped = false
    /// Incremented by every `stop()`: work that began before a stop never requests a transfer, even if
    /// the monitor was started again meanwhile.
    @ObservationIgnored private var lifecycleGeneration = 0

    isolated deinit {
        eventTask?.cancel()
        let transfers = transfers
        let ticket = transfers.beginShutdown()
        Task { await transfers.shutdown(through: ticket) }
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
        guard !isStopped else { return }
        let generation = lifecycleGeneration
        let decided = transfers.shutdownTicket()
        userCancelled.remove(sourceID)
        guard let url = resolvedURLs[sourceID] else {
            await refreshOne(sourceID)
            guard !isStopped, lifecycleGeneration == generation, let url = resolvedURLs[sourceID] else { return }
            await transfers.makeAvailable(key(sourceID), at: url, userRequested: true, decidedAt: decided)
            return
        }
        await transfers.makeAvailable(key(sourceID), at: url, userRequested: true, decidedAt: decided)
    }

    public func cancelTransfer(_ sourceID: SourceID) async {
        userCancelled.insert(sourceID)
        await transfers.cancel(key(sourceID))
    }

    public func retryTransfer(_ sourceID: SourceID) async {
        await makeAvailable(sourceID)
    }

    /// The network came back (T30). With availability ON, every tracked transfer that failed with an
    /// observed connectivity error is requested again automatically (`ReconnectRetry`); with OFF, and for
    /// stalls, other failures and user cancels, nothing is requested. Returns the sources requested.
    @discardableResult
    public func connectivityRestored() async -> [SourceID] {
        guard !isStopped, setting == .on else { return [] }
        let generation = lifecycleGeneration
        let evaluatedGeneration = settingGeneration
        let decided = transfers.shutdownTicket()
        let due = tracked.filter {
            ReconnectRetry.shouldRetry(observations[$0]?.transfer, setting: setting, userCancelled: userCancelled.contains($0))
        }
        var requested: [SourceID] = []
        for sourceID in due {
            // Re-check after every await: a stop or a setting change (OFF) ends the pass.
            guard setting == .on, settingGeneration == evaluatedGeneration, !isStopped, lifecycleGeneration == generation,
                  let url = resolvedURLs[sourceID] else { continue }
            await transfers.makeAvailable(key(sourceID), at: url, decidedAt: decided)
            requested.append(sourceID)
        }
        return requested
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
        let generation = lifecycleGeneration
        let decided = transfers.shutdownTicket()
        let key = key(sourceID)
        let record = try? await store.record(for: key)
        let transferState = await transfers.reportableState(of: key)
        let evaluator = SourceAvailabilityEvaluator(context: context)
        let evaluatedSetting = setting
        let evaluatedGeneration = settingGeneration
        #if DEBUG
        let evaluatorTaskDidStart = evaluatorTaskDidStart
        #endif
        let evaluation = await Task.detached {
            #if DEBUG
            if let evaluatorTaskDidStart { await evaluatorTaskDidStart() }
            #endif
            return evaluator.evaluate(key: key, record: record, setting: evaluatedSetting, transfer: transferState)
        }.value
        if let refreshed = evaluation.refreshedRecord {
            try? await store.save(refreshed)
        }
        // Re-read after every await: a setting change while this ran supersedes the result.
        guard settingGeneration == evaluatedGeneration, !isStopped, lifecycleGeneration == generation else { return }
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
        guard await !transfers.isActive(key), setting == .on, !isStopped, lifecycleGeneration == generation else { return }
        // The controller re-checks its own setting atomically and refuses if it is OFF, or if a stop
        // began after this refresh decided (closes the gap between the check above and the hop).
        await transfers.makeAvailable(key, at: url, decidedAt: decided)
    }

    private func apply(_ event: TransferEvent) {
        guard event.key.showID == showID, var observation = observations[event.key.sourceID] else { return }
        observation.transfer = event.state
        observation.transferEvidence = .transferController
        if event.state == .idle { observation.residency = .local }
        observations[event.key.sourceID] = observation
    }
}
