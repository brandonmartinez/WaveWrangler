import Foundation
import Synchronization
import WWCore

public struct TransferPolicy: Sendable, Equatable {
    /// When a transfer with no reported change counts as stalled (`offlineOrUnknown`, retry offered).
    public enum StallDetection: Sendable, Equatable {
        /// Wall-clock time without a reported change (production default).
        case elapsed(Duration)
        /// Number of consecutive polls without a reported change (deterministic; independent of load).
        case unchangedPolls(Int)
    }

    /// How often progress is sampled (metadata only).
    public var pollInterval: Duration
    /// The default 60 s is a heuristic, not an observed provider property: the iCloud trial never saw a
    /// progress signal at all, so "no change for 60 s" says nothing certain about connectivity.
    public var stallDetection: StallDetection
    /// After a stall the transfer stays observed (the provider may still be downloading) at a slower,
    /// doubling interval starting here …
    public var stalledPollInterval: Duration
    /// … and capped here.
    public var maxStalledPollInterval: Duration

    public init(
        pollInterval: Duration = .milliseconds(500),
        stallTimeout: Duration = .seconds(60),
        stalledPollInterval: Duration = .seconds(5),
        maxStalledPollInterval: Duration = .seconds(30)
    ) {
        self.pollInterval = pollInterval
        self.stallDetection = .elapsed(stallTimeout)
        self.stalledPollInterval = stalledPollInterval
        self.maxStalledPollInterval = max(stalledPollInterval, maxStalledPollInterval)
    }

    public init(
        pollInterval: Duration,
        stallAfterUnchangedPolls polls: Int,
        stalledPollInterval: Duration = .seconds(5),
        maxStalledPollInterval: Duration = .seconds(30)
    ) {
        self.pollInterval = pollInterval
        self.stallDetection = .unchangedPolls(max(1, polls))
        self.stalledPollInterval = stalledPollInterval
        self.maxStalledPollInterval = max(stalledPollInterval, maxStalledPollInterval)
    }

    /// Backoff while stalled: double, capped at `maxStalledPollInterval`.
    public func nextStalledInterval(after current: Duration) -> Duration {
        min(current * 2, maxStalledPollInterval)
    }
}

public struct TransferEvent: Sendable, Equatable {
    public var key: DeviceAccessKey
    public var state: TransferState
    public var provenance: ObservationProvenance
}

/// Requests and observes provider downloads for placeholder sources.
///
/// - Requests only for placeholder items with an evidenced request API (iCloud), only when the
///   controller's *current* availability setting is ON or the user explicitly asked for the item. The
///   setting lives here, so the check and the request are atomic inside the actor.
/// - Exactly one active request per source; a second call while active just reports the current state.
/// - Cancel stops the app's request/observation; it never evicts, deletes or modifies the original.
/// - A stall publishes `offlineOrUnknown` but keeps observing with backoff, so a provider that keeps
///   downloading still flips the source to available; an explicit retry issues a fresh request.
/// - Switching availability OFF cancels automatic transfers (user-requested ones continue).
/// - Observation never outlives its owner: `shutdown()` stops every observer, and observers hold the
///   controller only weakly between polls, so dropping the controller also stops polling.
public actor SourceTransferController {
    /// Sleep used between polls (injectable so tests can assert the backoff schedule deterministically).
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public nonisolated let context: SourceAccessContext
    public nonisolated let policy: TransferPolicy

    private struct Active {
        var generation: Int
        var task: Task<Void, Never>
        var userRequested: Bool
    }

    private var states: [DeviceAccessKey: TransferState] = [:]
    private var active: [DeviceAccessKey: Active] = [:]
    private var cancelledByUser: Set<DeviceAccessKey> = []
    /// Per active transfer: the observer's latest poll showed the provider idle (see `providerIsIdle`).
    private var providerIdle: [DeviceAccessKey: Bool] = [:]
    /// Observers that were replaced (explicit retry of a stalled transfer) and may still be finishing
    /// their last poll; `waitUntilSettled` drains them so no scope or poll outlives the call.
    private var draining: [DeviceAccessKey: [Task<Void, Never>]] = [:]
    /// The authoritative availability setting for automatic requests.
    public private(set) var setting: SourceAvailabilitySetting
    /// Monotonic epoch shared by transfer generations and event subscriptions. Readable without
    /// awaiting (`shutdownTicket()`), so an owner can say "shut down what exists *now*" and a late
    /// shutdown never touches transfers or subscriptions created afterwards.
    private let epoch = Mutex(0)
    private var continuations: [UUID: (epoch: Int, continuation: AsyncStream<TransferEvent>.Continuation)] = [:]
    /// Total download requests issued to the gateway (for audits/tests).
    public private(set) var downloadRequestCount = 0
    private let sleep: Sleeper

    public init(
        context: SourceAccessContext,
        policy: TransferPolicy = TransferPolicy(),
        setting: SourceAvailabilitySetting = .default,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.context = context
        self.policy = policy
        self.setting = setting
        self.sleep = sleep
    }

    public func state(of key: DeviceAccessKey) -> TransferState {
        states[key] ?? .unknown
    }

    public func isActive(_ key: DeviceAccessKey) -> Bool {
        active[key] != nil
    }

    public func isUserRequested(_ key: DeviceAccessKey) -> Bool {
        active[key]?.userRequested ?? false
    }

    /// The transfer state that should still override fresh metadata evidence: an active transfer, a
    /// deliberate user cancel, or a failure/offline result. Terminal `idle`, `notRequested` or
    /// OFF-toggle cancellations are history, so callers derive transfer from fresh evidence instead.
    public func reportableState(of key: DeviceAccessKey) -> TransferState? {
        if active[key] != nil { return state(of: key) }
        switch state(of: key) {
        case .cancelled where cancelledByUser.contains(key): return .cancelled
        case let .failed(error): return .failed(error)
        case let .offlineOrUnknown(error): return .offlineOrUnknown(error)
        default: return nil
        }
    }

    public var activeCount: Int { active.count }

    public func events() -> AsyncStream<TransferEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuations[id] = (nextEpoch(), continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// Requests local availability. Automatic requests (`userRequested == false`) are refused unless the
    /// controller's current setting is ON; explicit user requests are honored in either setting.
    @discardableResult
    public func makeAvailable(
        _ key: DeviceAccessKey,
        at url: URL,
        userRequested: Bool = false
    ) -> TransferState {
        if let running = active[key] {
            if userRequested, providerIsIdle(key) {
                // Explicit retry while the provider is not working on the item (stalled, or it dropped the
                // request: still a placeholder and not downloading): stop the old observer and request
                // again. Otherwise the user's Retry would be silently swallowed (#85).
                running.task.cancel()
                draining[key, default: []].append(running.task)
                active[key] = nil
            } else {
                // An explicit request upgrades an in-flight automatic transfer so OFF will not cancel it.
                if userRequested { active[key]?.userRequested = true }
                return state(of: key)
            }
        }
        let setting = setting

        enum Decision {
            case set(TransferState)
            case request
            /// The provider is already transferring (e.g. after an earlier request was cancelled):
            /// observe without issuing another request.
            case observeOnly
        }
        let decision: Decision = context.withScopedAccess(to: url) { url in
            switch context.io.metadata(at: url) {
            case .failure(.permissionDenied), .failure(.notFound):
                return .set(.notRequested(.awaitingAccess))
            case let .failure(.other(error)):
                return .set(.failed(error))
            case let .success(metadata):
                let (residency, _) = metadata.residency
                switch residency {
                case .local:
                    return .set(.idle)
                case .unknown:
                    return .set(.unknown)
                case .downloading:
                    guard setting == .on || userRequested else { return .set(.notRequested(.availabilityOff)) }
                    return .observeOnly
                case .cloudPlaceholder:
                    guard metadata.supportsDownloadRequest else { return .set(.notRequested(.unsupportedLocation)) }
                    guard setting == .on || userRequested else { return .set(.notRequested(.availabilityOff)) }
                    do {
                        downloadRequestCount += 1
                        try context.io.requestDownload(of: url)
                        return .request
                    } catch {
                        return .set(TransferErrorClassifier.state(for: SourceErrorDescriptor(error)))
                    }
                }
            }
        }

        switch decision {
        case let .set(state):
            publish(key, state)
            return state
        case .request, .observeOnly:
            cancelledByUser.remove(key)
            let current = nextEpoch()
            let initial: TransferState = if case .request = decision { .requested } else { .inProgress(fractionCompleted: .unknown) }
            publish(key, initial)
            let owner = WeakOwner(self)
            providerIdle[key] = nil
            let task = Task.detached { [context, policy, sleep] in
                await Self.observe(owner: owner, context: context, policy: policy, sleep: sleep, key: key, url: url, generation: current)
            }
            active[key] = Active(generation: current, task: task, userRequested: userRequested)
            return initial
        }
    }

    /// True when an active transfer has stalled, or its observer's latest poll reported the item as a
    /// placeholder the provider is neither downloading nor has a request for (it dropped the request).
    /// Uses only evidence the observer already read; a provider reporting `downloading` is left alone.
    private func providerIsIdle(_ key: DeviceAccessKey) -> Bool {
        if case .offlineOrUnknown = state(of: key) { return true }
        return providerIdle[key] == true
    }

    /// The user stopped the transfer. The original is never evicted or modified. Returns once the
    /// observer has finished, so no poll or security scope outlives the call.
    public func cancel(_ key: DeviceAccessKey) async {
        guard let running = active.removeValue(forKey: key) else { return }
        running.task.cancel()
        cancelledByUser.insert(key)
        publish(key, .cancelled)
        await running.task.value
    }

    /// Re-requests after cancel/failure/offline. A no-op while a request is active (except that an
    /// explicit retry marks it user-requested).
    @discardableResult
    public func retry(_ key: DeviceAccessKey, at url: URL, userRequested: Bool = true) -> TransferState {
        makeAvailable(key, at: url, userRequested: userRequested)
    }

    /// Stores the setting. ON→OFF cancels automatic transfers honestly (state `.cancelled`); OFF→ON
    /// issues nothing by itself — callers re-evaluate sources and request only placeholders.
    public func availabilitySettingChanged(to setting: SourceAvailabilitySetting) async {
        self.setting = setting
        guard setting == .off else { return }
        var stopped: [Task<Void, Never>] = []
        for (key, running) in active where !running.userRequested {
            active[key] = nil
            running.task.cancel()
            stopped.append(running.task)
            publish(key, .cancelled)
        }
        for task in stopped { await task.value }
    }

    /// Waits until no transfer is active for `key` (following any replacement started by a retry while
    /// waiting) and returns the final state. A stalled transfer keeps observing, so this returns only
    /// once it completes, fails or is cancelled.
    public func waitUntilSettled(_ key: DeviceAccessKey) async -> TransferState {
        while true {
            if let running = active[key] {
                await running.task.value
            } else if let replaced = draining.removeValue(forKey: key) {
                for task in replaced { await task.value }
            } else {
                break
            }
        }
        return state(of: key)
    }

    public func cancelAll() async {
        for key in Array(active.keys) { await cancel(key) }
    }

    /// The current epoch. Pass it to `shutdown(through:)` to limit teardown to what exists now.
    public nonisolated func shutdownTicket() -> Int {
        epoch.withLock { $0 }
    }

    /// Owner teardown (window closed, monitor stopped/deallocated): stops observers without recording
    /// a user cancel, finishes event streams and returns once those observers have finished. With a
    /// `ticket`, only transfers and subscriptions created at or before it are affected, so a late
    /// teardown never cancels a request made afterwards. Cancelled transfers publish `.cancelled`
    /// (so remaining subscribers are not left stale). The originals are untouched.
    public func shutdown(through ticket: Int? = nil) async {
        let limit = ticket ?? Int.max
        var stopped: [Task<Void, Never>] = draining.values.flatMap { $0 }
        draining.removeAll()
        for (key, running) in active where running.generation <= limit {
            active[key] = nil
            running.task.cancel()
            stopped.append(running.task)
            publish(key, .cancelled)
        }
        for (id, entry) in continuations where entry.epoch <= limit {
            entry.continuation.finish()
            continuations[id] = nil
        }
        for task in stopped { await task.value }
    }

    private func nextEpoch() -> Int {
        epoch.withLock {
            $0 += 1
            return $0
        }
    }

    // MARK: - Observation

    /// Polls metadata for one transfer generation. Runs detached and holds the controller only weakly
    /// between polls; it exits when the controller is gone, the generation was replaced/cancelled, or
    /// the transfer finished.
    private static func observe(
        owner: WeakOwner,
        context: SourceAccessContext,
        policy: TransferPolicy,
        sleep: Sleeper,
        key: DeviceAccessKey,
        url: URL,
        generation: Int
    ) async {
        let clock = ContinuousClock()
        var lastChange = clock.now
        var unchangedPolls = 0
        var lastSignature: String?
        var stalled = false
        var interval = policy.pollInterval
        while !Task.isCancelled {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard let controller = owner.value, await controller.isCurrent(key, generation) else { return }
            let metadata = context.withScopedAccess(to: url) { context.io.metadata(at: $0) }
            let fraction = await context.withScopedAccess(to: url) { await context.io.downloadFraction(of: $0) }
            guard !Task.isCancelled else { return }

            let next: TransferState
            var finished = false
            switch metadata {
            case .failure(.permissionDenied), .failure(.notFound):
                next = .notRequested(.awaitingAccess)
                finished = true
            case let .failure(.other(error)):
                next = .failed(error)
                finished = true
            case let .success(value):
                if let error = value.ubiquitous.downloadingError {
                    next = TransferErrorClassifier.state(for: error)
                    finished = true
                } else if value.residency.0 == .local {
                    next = .idle
                    finished = true
                } else {
                    next = .inProgress(fractionCompleted: fraction)
                    let idle = value.residency.0 == .cloudPlaceholder && value.ubiquitous.downloadRequested.value != true
                    guard await controller.noteProviderIdle(key, generation, idle) else { return }
                    let signature = "\(String(describing: fraction.value))|\(String(describing: value.ubiquitous.isDownloading.value))|\(String(describing: value.ubiquitous.downloadingStatus.value))"
                    if signature != lastSignature {
                        // Any reported change (including after a stall) resumes normal observation.
                        lastSignature = signature
                        lastChange = clock.now
                        unchangedPolls = 0
                        stalled = false
                        interval = policy.pollInterval
                    } else if stalled {
                        interval = policy.nextStalledInterval(after: interval)
                        continue
                    } else if isStalled(policy.stallDetection, unchangedPolls: &unchangedPolls, since: lastChange, now: clock.now) {
                        // Say so honestly, but keep watching: the provider may still finish.
                        stalled = true
                        interval = policy.stalledPollInterval
                        guard await controller.publishIfCurrent(key, generation, .offlineOrUnknown(nil)) else { return }
                        continue
                    }
                }
            }
            if finished {
                await controller.finish(key, generation, next)
                return
            }
            guard await controller.publishIfCurrent(key, generation, next) else { return }
        }
    }

    /// Records the observer's latest provider-idle evidence; false when the generation is no longer current.
    private func noteProviderIdle(_ key: DeviceAccessKey, _ generation: Int, _ idle: Bool) -> Bool {
        guard isCurrent(key, generation) else { return false }
        providerIdle[key] = idle
        return true
    }

    /// Publishes `state` if `generation` is still the active one (and the state changed). Returns false
    /// when the generation is no longer current, so the observer stops.
    private func publishIfCurrent(_ key: DeviceAccessKey, _ generation: Int, _ state: TransferState) -> Bool {
        guard isCurrent(key, generation) else { return false }
        if self.state(of: key) != state { publish(key, state) }
        return true
    }

    private static func isStalled(_ detection: TransferPolicy.StallDetection, unchangedPolls: inout Int, since lastChange: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Bool {
        unchangedPolls += 1
        switch detection {
        case let .elapsed(timeout): return now - lastChange >= timeout
        case let .unchangedPolls(limit): return unchangedPolls >= limit
        }
    }

    private func isCurrent(_ key: DeviceAccessKey, _ generation: Int) -> Bool {
        active[key]?.generation == generation
    }

    private func finish(_ key: DeviceAccessKey, _ generation: Int, _ state: TransferState) {
        guard isCurrent(key, generation) else { return }
        active[key] = nil
        publish(key, state)
    }

    private func publish(_ key: DeviceAccessKey, _ state: TransferState) {
        states[key] = state
        let event = TransferEvent(key: key, state: state, provenance: context.io.provenance)
        for entry in continuations.values { entry.continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

/// Weak reference to the controller for detached observers.
final class WeakOwner: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: SourceTransferController?

    init(_ value: SourceTransferController) {
        _value = value
    }

    var value: SourceTransferController? { lock.withLock { _value } }
}
