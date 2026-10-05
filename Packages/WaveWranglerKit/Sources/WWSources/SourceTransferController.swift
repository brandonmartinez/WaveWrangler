import Foundation
import WWCore

public struct TransferPolicy: Sendable, Equatable {
    /// How often progress is sampled (metadata only).
    public var pollInterval: Duration
    /// No reported change for this long ⇒ `offlineOrUnknown`, with retry offered.
    public var stallTimeout: Duration

    public init(pollInterval: Duration = .milliseconds(500), stallTimeout: Duration = .seconds(60)) {
        self.pollInterval = pollInterval
        self.stallTimeout = stallTimeout
    }
}

public struct TransferEvent: Sendable, Equatable {
    public var key: DeviceAccessKey
    public var state: TransferState
    public var provenance: ObservationProvenance
}

/// Requests and observes provider downloads for placeholder sources.
///
/// - Requests only for placeholder items with an evidenced request API (iCloud), only when source
///   availability is ON or the user explicitly asked for the item.
/// - Exactly one active request per source; a second call while active just reports the current state.
/// - Cancel stops the app's request/observation; it never evicts, deletes or modifies the original.
/// - Switching availability OFF cancels automatic transfers (user-requested ones continue).
public actor SourceTransferController {
    public let context: SourceAccessContext
    public let policy: TransferPolicy

    private struct Active {
        var generation: Int
        var task: Task<Void, Never>
        var userRequested: Bool
    }

    private var states: [DeviceAccessKey: TransferState] = [:]
    private var active: [DeviceAccessKey: Active] = [:]
    private var generation = 0
    private var continuations: [UUID: AsyncStream<TransferEvent>.Continuation] = [:]
    /// Total download requests issued to the gateway (for audits/tests).
    public private(set) var downloadRequestCount = 0

    public init(context: SourceAccessContext, policy: TransferPolicy = TransferPolicy()) {
        self.context = context
        self.policy = policy
    }

    public func state(of key: DeviceAccessKey) -> TransferState {
        states[key] ?? .unknown
    }

    public func isActive(_ key: DeviceAccessKey) -> Bool {
        active[key] != nil
    }

    public var activeCount: Int { active.count }

    public func events() -> AsyncStream<TransferEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    @discardableResult
    public func makeAvailable(
        _ key: DeviceAccessKey,
        at url: URL,
        setting: SourceAvailabilitySetting,
        userRequested: Bool = false
    ) -> TransferState {
        if active[key] != nil { return state(of: key) }

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
            generation += 1
            let current = generation
            let initial: TransferState = if case .request = decision { .requested } else { .inProgress(fractionCompleted: .unknown) }
            publish(key, initial)
            let task = Task { await self.observe(key, url: url, generation: current) }
            active[key] = Active(generation: current, task: task, userRequested: userRequested)
            return initial
        }
    }

    /// Stops requesting/observing. The original is never evicted or modified.
    public func cancel(_ key: DeviceAccessKey) {
        guard let running = active.removeValue(forKey: key) else { return }
        running.task.cancel()
        publish(key, .cancelled)
    }

    /// Re-requests after cancel/failure/offline. A no-op while a request is active.
    @discardableResult
    public func retry(_ key: DeviceAccessKey, at url: URL, setting: SourceAvailabilitySetting, userRequested: Bool = true) -> TransferState {
        makeAvailable(key, at: url, setting: setting, userRequested: userRequested)
    }

    /// ON→OFF cancels automatic transfers honestly (state `.cancelled`); OFF→ON issues nothing by itself —
    /// callers re-evaluate sources and request only placeholders.
    public func availabilitySettingChanged(to setting: SourceAvailabilitySetting) {
        guard setting == .off else { return }
        for (key, running) in active where !running.userRequested {
            active[key] = nil
            running.task.cancel()
            publish(key, .cancelled)
        }
    }

    /// Waits for the current request (if any) to finish and returns the final state.
    public func waitUntilSettled(_ key: DeviceAccessKey) async -> TransferState {
        if let running = active[key] {
            await running.task.value
        }
        return state(of: key)
    }

    public func cancelAll() {
        for key in Array(active.keys) { cancel(key) }
    }

    // MARK: - Observation

    private func observe(_ key: DeviceAccessKey, url: URL, generation: Int) async {
        let clock = ContinuousClock()
        var lastChange = clock.now
        var lastSignature: String?
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: policy.pollInterval)
            } catch {
                return
            }
            guard isCurrent(key, generation) else { return }
            let metadata = context.withScopedAccess(to: url) { context.io.metadata(at: $0) }
            let fraction = await context.withScopedAccess(to: url) { await context.io.downloadFraction(of: $0) }
            guard isCurrent(key, generation), !Task.isCancelled else { return }

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
                    let signature = "\(String(describing: fraction.value))|\(String(describing: value.ubiquitous.isDownloading.value))|\(String(describing: value.ubiquitous.downloadingStatus.value))"
                    if signature != lastSignature {
                        lastSignature = signature
                        lastChange = clock.now
                    } else if clock.now - lastChange >= policy.stallTimeout {
                        finish(key, generation, .offlineOrUnknown(nil))
                        return
                    }
                }
            }
            if finished {
                finish(key, generation, next)
                return
            }
            if state(of: key) != next { publish(key, next) }
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
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
