import Foundation
import WWCore

/// A logical place a derived result lives in (e.g. "waveform of source S, channel 2"). A slot holds at most one
/// current key; submitting a different key for the same slot supersedes the previous job.
public struct DerivedSlot: Sendable, Hashable, Codable, CustomStringConvertible {
    public var name: String

    public init(_ name: String) { self.name = name }

    public var description: String { name }
}

/// Why a derived result (or in-flight job) is no longer current. Every M2-C5 key component has a reason.
public enum StaleReason: Sendable, Hashable {
    case sourceChanged(SourceID)
    case formatChanged
    case mapChanged(EpisodeID)
    case recipeChanged(String)
    case assetRevisionChanged(String)
    case upstreamChanged
    /// The slot was re-keyed (epoch, occurrence, channel or any other component) or explicitly invalidated.
    case superseded
}

public enum DerivedSlotState: Sendable, Equatable {
    case idle
    case running(DerivedAssetKey)
    /// Published and current.
    case ready(DerivedAssetKey)
    /// The last result or job no longer matches the current inputs; it is never served.
    case stale(DerivedAssetKey, reasons: Set<StaleReason>)
    case failed(DerivedAssetKey, reason: String)
    case cancelled(DerivedAssetKey)

    public var key: DerivedAssetKey? {
        switch self {
        case .idle: nil
        case let .running(key), let .ready(key), let .stale(key, _), let .failed(key, _), let .cancelled(key): key
        }
    }
}

public enum DerivedJobOutcome: Sendable, Equatable {
    case published(DerivedAssetKey)
    /// A verified asset with the same key was already in the cache; the work was not run.
    case reused(DerivedAssetKey)
    /// The key was stale when the job finished (or when it was submitted); nothing was published.
    case discardedStale(Set<StaleReason>)
    case cancelled
    case failed(String)
}

/// The current revision of every input a key can name. A key is current only if each component it names
/// matches; components that are not registered are not current.
public struct DerivedInputs: Sendable, Equatable {
    public var sources: [SourceID: String] = [:]
    public var format: FormatRevision
    public var acceptedMaps: [EpisodeID: Int] = [:]
    public var recipes: [String: Int] = [:]
    public var assets: [String: Int] = [:]

    public init(format: FormatRevision = .current) {
        self.format = format
    }
}

public struct DerivedSlotChange: Sendable, Equatable {
    public var slot: DerivedSlot
    public var state: DerivedSlotState
}

/// A submitted job. `outcome` waits for it to finish (cancelled jobs finish promptly once their work observes
/// cancellation).
public struct DerivedJob: Sendable {
    public let slot: DerivedSlot
    public let key: DerivedAssetKey
    let task: Task<DerivedJobOutcome, Never>

    public var outcome: DerivedJobOutcome {
        get async { await task.value }
    }
}

#if DEBUG
/// Test-only seams (DEBUG builds only).
package struct DerivedCoordinatorTestHooks: Sendable {
    /// Called off the coordinator after a result is staged and verified, before its currency check.
    package var beforeCommit: (@Sendable (DerivedSlot, DerivedAssetKey) async -> Void)?
    /// Negative control only: publish without the currency check, to prove the ordering tests can fail.
    package var skipCurrencyCheck = false

    package init(beforeCommit: (@Sendable (DerivedSlot, DerivedAssetKey) async -> Void)? = nil, skipCurrencyCheck: Bool = false) {
        self.beforeCommit = beforeCommit
        self.skipCurrencyCheck = skipCurrencyCheck
    }
}
#endif

/// Runs derived-asset jobs off the main thread and publishes their results only while their M2-C5 key is
/// current (WW-020).
///
/// Ordering per job: (off the coordinator) verified-cache lookup → work → stage + flush + read-back verify →
/// (on the coordinator, one synchronous turn with no suspension point) "is this still the slot's job, not
/// cancelled, and is every key component current?" → atomic move into the cache → state `ready`. Because the
/// check and the publish share one actor turn, an invalidation can only land entirely before (the result is
/// discarded) or entirely after (the published result is then marked stale) — the read→transform→publish
/// sequence cannot interleave with actor reentrancy. Late results never publish stale assets.
///
/// Any input change (`updateSource`, `setFormat`, `acceptMap`, `setRecipe`, `setAssetRevision`, re-keying a
/// slot) marks every dependent slot stale, cancels its in-flight job, and cascades through `upstream`.
///
/// Lifetime: the owner calls `await shutdown()` before it releases source access (closing the show, stopping
/// security-scoped access) and before releasing the coordinator; it returns once no job is still running.
/// Releasing the coordinator without it still cancels every job (`deinit`), but cannot wait for them.
public actor DerivedJobCoordinator {
    public nonisolated let store: DerivedAssetStore
    public nonisolated let changes: AsyncStream<DerivedSlotChange>
    private let continuation: AsyncStream<DerivedSlotChange>.Continuation

    public private(set) var inputs: DerivedInputs
    private var slots: [DerivedSlot: SlotRecord] = [:]
    private var cachedCandidates: [DerivedSlot: [DerivedAssetKey]] = [:]
    private var explicitlyInvalidated: [DerivedSlot: Set<DerivedAssetKey>] = [:]
    private var nextJobID: UInt64 = 0
    /// Every job that has not finished, including superseded or cancelled ones whose work is still returning.
    private var inFlight: [UInt64: Task<DerivedJobOutcome, Never>] = [:]
    private var hasShutDown = false

    #if DEBUG
    private let hooks: DerivedCoordinatorTestHooks
    #endif

    private struct SlotRecord {
        var state: DerivedSlotState = .idle
        /// The job allowed to publish into this slot, if any.
        var currentJob: UInt64?
        var task: Task<DerivedJobOutcome, Never>?
    }

    public init(store: DerivedAssetStore, inputs: DerivedInputs = DerivedInputs()) {
        self.store = store
        self.inputs = inputs
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
        #if DEBUG
        hooks = DerivedCoordinatorTestHooks()
        #endif
    }

    #if DEBUG
    package init(store: DerivedAssetStore, inputs: DerivedInputs = DerivedInputs(), testHooks: DerivedCoordinatorTestHooks) {
        self.store = store
        self.inputs = inputs
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
        hooks = testHooks
    }
    #endif

    deinit {
        for task in inFlight.values { task.cancel() }
        continuation.finish()
    }

    /// Stops all derived work: every in-flight job is cancelled and can no longer publish, running slots become
    /// `.cancelled`, and later submits are refused (their work never runs). Returns once every job has finished;
    /// work should observe cancellation promptly (work that ignores it delays the return). Idempotent. Call it
    /// before releasing source access — see the type's lifetime note.
    public func shutdown() async {
        hasShutDown = true
        let jobs = inFlight.values
        for task in jobs { task.cancel() }
        for slot in slots.keys.sorted(by: { $0.name < $1.name }) {
            guard var record = slots[slot] else { continue }
            record.task = nil
            record.currentJob = nil
            if case let .running(key) = record.state {
                record.state = .cancelled(key)
                continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
            }
            slots[slot] = record
        }
        continuation.finish()
        for task in jobs { _ = await task.value }
    }

    public var isShutdown: Bool { hasShutDown }

    // MARK: - Inputs

    public func updateSource(_ revision: SourceRevision) {
        inputs.sources[revision.source] = revision.token
        refresh()
    }

    public func removeSource(_ source: SourceID) {
        inputs.sources[source] = nil
        refresh()
    }

    public func setFormat(_ format: FormatRevision) {
        inputs.format = format
        refresh()
    }

    /// The accepted map changed (REF-019): everything derived from any other revision of this episode's map
    /// becomes stale and its in-flight jobs are cancelled.
    public func acceptMap(_ map: MapRevisionReference) {
        inputs.acceptedMaps[map.episode] = map.revision
        refresh()
    }

    public func clearAcceptedMap(episode: EpisodeID) {
        inputs.acceptedMaps[episode] = nil
        refresh()
    }

    public func setRecipe(_ recipe: RecipeReference) {
        inputs.recipes[recipe.name] = recipe.revision
        refresh()
    }

    public func setAssetRevision(_ asset: AssetSpec) {
        inputs.assets[asset.kind] = asset.revision
        refresh()
    }

    /// Marks one slot stale (e.g. its definition changed) and cancels its job.
    public func invalidate(_ slot: DerivedSlot) {
        guard var record = slots[slot], let key = record.state.key else { return }
        explicitlyInvalidated[slot, default: []].insert(key)
        cachedCandidates[slot] = nil
        if case .stale = record.state { return }
        record.task?.cancel()
        record.task = nil
        record.currentJob = nil
        record.state = .stale(key, reasons: [.superseded])
        slots[slot] = record
        continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
        refresh()
    }

    // MARK: - Queries

    public func state(of slot: DerivedSlot) -> DerivedSlotState {
        slots[slot]?.state ?? .idle
    }

    /// A stable query snapshot for presentation and diagnostics. Callers cannot mutate coordinator state.
    public func states() -> [DerivedSlot: DerivedSlotState] {
        slots.mapValues(\.state)
    }

    /// Why `key` is not current; empty when it is.
    public func staleReasons(for key: DerivedAssetKey) -> Set<StaleReason> {
        staleReasons(for: key, ready: key.upstream.isEmpty ? [] : readyDigests())
    }

    private func staleReasons(for key: DerivedAssetKey, ready: Set<String>) -> Set<StaleReason> {
        var reasons = Set<StaleReason>()
        for source in key.sources where inputs.sources[source.source] != source.token {
            reasons.insert(.sourceChanged(source.source))
        }
        if let format = key.format, format != inputs.format { reasons.insert(.formatChanged) }
        if let map = key.map, inputs.acceptedMaps[map.episode] != map.revision { reasons.insert(.mapChanged(map.episode)) }
        if let recipe = key.recipe, inputs.recipes[recipe.name] != recipe.revision { reasons.insert(.recipeChanged(recipe.name)) }
        if inputs.assets[key.asset.kind] != key.asset.revision { reasons.insert(.assetRevisionChanged(key.asset.kind)) }
        if !key.upstream.isEmpty {
            if key.upstream.contains(where: { !ready.contains($0) }) { reasons.insert(.upstreamChanged) }
        }
        return reasons
    }

    /// The published payload of a `ready` (hence current) slot. Stale, running or failed slots serve nothing.
    public func readyPayload(for slot: DerivedSlot) -> Data? {
        guard case let .ready(key) = state(of: slot) else { return nil }
        return store.payload(for: key)
    }

    // MARK: - Jobs

    /// Starts `work` for `slot` under `key`, superseding any job already running for the slot. `work` runs off
    /// the main thread and off this actor; it should check `Task.isCancelled`.
    @discardableResult
    public func submit(
        _ slot: DerivedSlot,
        key: DerivedAssetKey,
        work: @escaping @Sendable () async throws -> Data
    ) -> DerivedJob {
        guard !hasShutDown else { return DerivedJob(slot: slot, key: key, task: Task { .cancelled }) }
        var record = slots[slot] ?? SlotRecord()
        record.task?.cancel()
        nextJobID += 1
        let jobID = nextJobID
        let initial = staleReasons(for: key)
        guard initial.isEmpty else {
            record.task = nil
            record.currentJob = nil
            record.state = .stale(key, reasons: initial)
            slots[slot] = record
            continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
            refresh()
            return DerivedJob(slot: slot, key: key, task: Task { .discardedStale(initial) })
        }
        rememberCachedCandidate(record.state.key, for: slot)

        let store = store
        let mustRecompute = explicitlyInvalidated[slot]?.contains(key) == true
        #if DEBUG
        let beforeCommit = hooks.beforeCommit
        #endif
        let task = Task.detached(priority: .utility) { [weak self] () async -> DerivedJobOutcome in
            if Task.isCancelled { return await self?.finishWithoutPublishing(jobID, slot: slot, key: key, failure: nil) ?? .cancelled }
            if !mustRecompute && store.payload(for: key) != nil {
                return await self?.adoptCached(jobID, slot: slot, key: key) ?? .cancelled
            }
            let payload: Data
            do {
                payload = try await work()
            } catch {
                return await self?.finishWithoutPublishing(jobID, slot: slot, key: key, failure: String(describing: error)) ?? .cancelled
            }
            if Task.isCancelled { return await self?.finishWithoutPublishing(jobID, slot: slot, key: key, failure: nil) ?? .cancelled }
            let staged: StagedDerivedAsset
            do {
                staged = try store.stage(payload, for: key)
            } catch {
                return await self?.finishWithoutPublishing(jobID, slot: slot, key: key, failure: String(describing: error)) ?? .cancelled
            }
            #if DEBUG
            await beforeCommit?(slot, key)
            #endif
            guard let self else {
                store.discard(staged)
                return .cancelled
            }
            return await self.commit(jobID, slot: slot, staged: staged)
        }
        inFlight[jobID] = task
        record.task = task
        record.currentJob = jobID
        record.state = .running(key)
        slots[slot] = record
        continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
        refresh()
        return DerivedJob(slot: slot, key: key, task: task)
    }

    public func cancel(_ slot: DerivedSlot) {
        guard var record = slots[slot], case let .running(key) = record.state else { return }
        record.task?.cancel()
        record.task = nil
        record.currentJob = nil
        record.state = .cancelled(key)
        slots[slot] = record
        continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
    }

    /// Re-adopts cached results that match the current inputs after an intentional history move such as
    /// undo/redo. Ordinary `refresh()` only invalidates forward; this explicit path runs after the restored
    /// accepted-map identity has published, so upstream-dependent assets can become current again without
    /// rerunning work. Explicitly invalidated slots are never revived.
    public func restoreCachedCurrentSlots() {
        var changed = true
        while changed {
            changed = false
            let ready = readyDigests()
            for slot in slots.keys.sorted(by: { $0.name < $1.name }) {
                guard let record = slots[slot],
                      case let .stale(current, _) = record.state
                else { continue }
                let candidates = [current] + (cachedCandidates[slot] ?? [])
                guard let restored = candidates.first(where: {
                    explicitlyInvalidated[slot]?.contains($0) != true
                        && staleReasons(for: $0, ready: ready).isEmpty && store.payload(for: $0) != nil
                }) else { continue }
                rememberCachedCandidate(current, for: slot)
                var updated = record
                updated.state = .ready(restored)
                updated.currentJob = nil
                updated.task = nil
                slots[slot] = updated
                continuation.yield(DerivedSlotChange(slot: slot, state: updated.state))
                changed = true
            }
        }
    }

    // MARK: - Completion (each is one synchronous actor turn)

    /// Currency check and publication with no suspension point in between.
    private func commit(_ jobID: UInt64, slot: DerivedSlot, staged: StagedDerivedAsset) -> DerivedJobOutcome {
        inFlight[jobID] = nil
        var skipCheck = false
        #if DEBUG
        skipCheck = hooks.skipCurrencyCheck
        #endif
        if !skipCheck {
            if let refusal = refusal(jobID, slot: slot, key: staged.key) {
                store.discard(staged)
                return refusal
            }
        }
        var record = slots[slot] ?? SlotRecord()
        do {
            try store.commit(staged)
        } catch {
            record.state = .failed(staged.key, reason: String(describing: error))
            record.currentJob = nil
            record.task = nil
            slots[slot] = record
            continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
            refresh()
            return .failed(String(describing: error))
        }
        record.state = .ready(staged.key)
        explicitlyInvalidated[slot]?.subtract([staged.key])
        record.currentJob = nil
        record.task = nil
        slots[slot] = record
        continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
        return .published(staged.key)
    }

    private func adoptCached(_ jobID: UInt64, slot: DerivedSlot, key: DerivedAssetKey) -> DerivedJobOutcome {
        inFlight[jobID] = nil
        if let refusal = refusal(jobID, slot: slot, key: key) { return refusal }
        slots[slot]?.state = .ready(key)
        slots[slot]?.currentJob = nil
        slots[slot]?.task = nil
        continuation.yield(DerivedSlotChange(slot: slot, state: .ready(key)))
        return .reused(key)
    }

    private func finishWithoutPublishing(_ jobID: UInt64, slot: DerivedSlot, key: DerivedAssetKey, failure: String?) -> DerivedJobOutcome {
        inFlight[jobID] = nil
        if let refusal = refusal(jobID, slot: slot, key: key) { return refusal }
        let state: DerivedSlotState = failure.map { .failed(key, reason: $0) } ?? .cancelled(key)
        slots[slot]?.state = state
        slots[slot]?.currentJob = nil
        slots[slot]?.task = nil
        continuation.yield(DerivedSlotChange(slot: slot, state: state))
        refresh()
        return failure.map { .failed($0) } ?? .cancelled
    }

    /// Non-nil when the job may no longer publish: superseded, cancelled, or its key is stale.
    private func refusal(_ jobID: UInt64, slot: DerivedSlot, key: DerivedAssetKey) -> DerivedJobOutcome? {
        guard let record = slots[slot], record.currentJob == jobID else {
            switch slots[slot]?.state {
            case let .stale(staleKey, reasons)? where staleKey == key: return .discardedStale(reasons)
            case let .cancelled(cancelledKey)? where cancelledKey == key: return .cancelled
            default: return .discardedStale([.superseded])
            }
        }
        let reasons = staleReasons(for: key)
        guard reasons.isEmpty else {
            markStale(slot, key: key, reasons: reasons)
            return .discardedStale(reasons)
        }
        return nil
    }

    // MARK: - Staleness

    private func readyDigests() -> Set<String> {
        Set(slots.values.compactMap { record in
            if case let .ready(key) = record.state { key.digest } else { nil }
        })
    }

    private func markStale(_ slot: DerivedSlot, key: DerivedAssetKey, reasons: Set<StaleReason>) {
        guard var record = slots[slot] else { return }
        record.task?.cancel()
        record.task = nil
        record.currentJob = nil
        record.state = .stale(key, reasons: reasons)
        slots[slot] = record
        continuation.yield(DerivedSlotChange(slot: slot, state: record.state))
    }

    private func rememberCachedCandidate(_ key: DerivedAssetKey?, for slot: DerivedSlot) {
        guard let key, store.payload(for: key) != nil else { return }
        var candidates = cachedCandidates[slot] ?? []
        candidates.removeAll(where: { $0 == key })
        candidates.insert(key, at: 0)
        if candidates.count > 8 { candidates.removeLast(candidates.count - 8) }
        cachedCandidates[slot] = candidates
    }

    /// Re-evaluates every ready or running slot against the current inputs until nothing changes, so a stale
    /// upstream result cascades to everything keyed on it.
    private func refresh() {
        var changed = true
        while changed {
            changed = false
            let ready = readyDigests()
            for (slot, record) in slots.sorted(by: { $0.key.name < $1.key.name }) {
                let key: DerivedAssetKey
                switch record.state {
                case let .ready(k), let .running(k): key = k
                default: continue
                }
                let reasons = staleReasons(for: key, ready: ready)
                if !reasons.isEmpty {
                    markStale(slot, key: key, reasons: reasons)
                    changed = true
                }
            }
        }
    }
}
