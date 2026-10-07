import Foundation
import Synchronization
import WWAlignEstimate
import WWCore
import WWDecode
import WWDerived
import WWRender

/// Why a pipeline job produced nothing. Kept typed (the coordinator only records a description).
public enum AlignmentWorkFailure: Error, Sendable, Equatable {
    /// The WWDecode gateway refused or failed (see the inspection spec §1.2 for the user-facing rows).
    case decode(DecodeFailure)
    /// The file's metadata no longer matches the revision the app registered; re-register it first.
    case sourceChangedSinceRegistration
    /// The decoder's interpretation/envelope versions differ from the coordinator's format revision.
    case formatRevisionMismatch(interpretation: Int, envelope: Int)
    /// The source rate is below the estimator's minimum analysis rate.
    case sourceRateBelowAnalysisMinimum(rate: Int, minimum: Int)
    /// What the decoder reported while analysing differs from the source's recorded facts.
    case sourceFactsMismatch
    /// A source's facts are not ready (probe first).
    case sourceFactsUnavailable(SourceID)
    /// A required recorder cannot close the planned cycle; do not run a smaller-cohort estimator.
    case cyclePeerUnavailable(SourceID)
    case estimator(AlignEstimateError)
    /// One unit's estimated working set exceeds the whole analysis memory budget.
    case memoryBudget(requested: Int, budget: Int)
    case encoding(String)
    case render(RenderFailure)
    /// The accepted map changed (or was cleared) while the job ran.
    case acceptedMapChanged
    /// The coordinator already considers the job's inputs stale (a source, format, map or recipe changed).
    case staleInputs(Set<StaleReason>)
    case cancelled
}

/// Holds the typed failure of one job (the coordinator keeps only a string).
final class FailureBox: Sendable {
    private let value = Mutex<AlignmentWorkFailure?>(nil)

    func record(_ failure: AlignmentWorkFailure) {
        value.withLock { if $0 == nil { $0 = failure } }
    }

    var failure: AlignmentWorkFailure? { value.withLock { $0 } }
}

/// The outcome of one coordinator job plus its typed failure, if the work threw.
public struct PipelineJobResult: Sendable, Equatable {
    public let slot: DerivedSlot
    public let key: DerivedAssetKey
    public let outcome: DerivedJobOutcome
    public let failure: AlignmentWorkFailure?

    /// Published now, or a verified cached result was adopted.
    public var isAvailable: Bool {
        switch outcome {
        case .published, .reused: true
        default: false
        }
    }
}

enum PipelineSlots {
    static func sourceFacts(_ source: SourceID) -> DerivedSlot {
        DerivedSlot("\(AlignmentAssetKinds.sourceFacts.kind)/\(source)")
    }

    static func analysis(_ epoch: RecordingEpochID) -> DerivedSlot {
        DerivedSlot("\(AlignmentAssetKinds.analysis.kind)/\(epoch)")
    }

    static func alignedSegment(group: RecorderGroupID, source: SourceID, channel: Int, segment: Int64) -> DerivedSlot {
        DerivedSlot("\(AlignmentAssetKinds.alignedAudio.kind)/\(group)/\(source)/ch\(channel)/seg\(segment)")
    }

    static func acceptedMapIdentity(_ episode: EpisodeID) -> DerivedSlot {
        DerivedSlot("\(AlignmentAssetKinds.acceptedMapIdentity.kind)/\(episode)")
    }
}

/// Work the pipeline runs outside coordinator jobs (a group render holds gateway cursors between commits).
/// Each unit is registered before it starts, atomically with the closed check, so `close()` sees every unit
/// that can still open a cursor; the owner cancels and awaits them all on shutdown.
actor TrackedWork {
    struct Entry: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private var closed = false
    private var nextID: UInt64 = 0
    private var entries: [UInt64: Entry] = [:]

    var isClosed: Bool { closed }
    var count: Int { entries.count }

    private func start<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> (UInt64, Task<T, Never>)? {
        guard !closed else { return nil }
        nextID += 1
        let task = Task.detached(priority: .utility) { await operation() }
        entries[nextID] = Entry(cancel: { task.cancel() }, wait: { _ = await task.value })
        return (nextID, task)
    }

    private func finished(_ id: UInt64) {
        entries[id] = nil
    }

    /// Runs `operation` as tracked work and returns its result; `nil` (nothing ran) once closed. Cancelling
    /// the caller cancels the work.
    nonisolated func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
        guard let (id, task) = await start(operation) else { return nil }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await finished(id)
        return value
    }

    /// Refuses new work and returns every unit still registered.
    func close() -> [Entry] {
        closed = true
        return Array(entries.values)
    }
}

extension DerivedJobCoordinator {
    /// Cancels `slot` only while it is running `key`, so cancelling one caller never stops newer work that
    /// superseded it under a different key.
    func cancel(_ slot: DerivedSlot, ifRunning key: DerivedAssetKey) {
        if case let .running(running) = state(of: slot), running == key { cancel(slot) }
    }

    /// Submits `work` and waits for its outcome. Cancelling the calling task cancels the job (the coordinator
    /// runs work in its own detached task, which the caller's cancellation would not otherwise reach).
    func run(
        _ slot: DerivedSlot,
        key: DerivedAssetKey,
        work: @escaping @Sendable () async throws(AlignmentWorkFailure) -> Data
    ) async -> PipelineJobResult {
        let box = FailureBox()
        let job = submit(slot, key: key) {
            do throws(AlignmentWorkFailure) {
                return try await work()
            } catch {
                box.record(error)
                throw error
            }
        }
        let outcome = await withTaskCancellationHandler {
            await job.outcome
        } onCancel: {
            Task { await self.cancel(slot, ifRunning: key) }
        }
        return PipelineJobResult(slot: slot, key: key, outcome: outcome, failure: box.failure)
    }
}

/// Runs `operations` with at most `limit` in flight, returning results in input order. Child tasks inherit
/// cancellation; nothing runs on the main actor.
func boundedMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    limit: Int,
    _ operation: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    precondition(limit >= 1)
    return await withTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: inputs.count)
        var next = 0
        while next < inputs.count, next < limit {
            let index = next
            group.addTask { (index, await operation(inputs[index])) }
            next += 1
        }
        while let (index, output) = await group.next() {
            results[index] = output
            if next < inputs.count {
                let index = next
                group.addTask { (index, await operation(inputs[index])) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}

extension DecodeFailure {
    var asWorkFailure: AlignmentWorkFailure {
        self == .cancelled ? .cancelled : .decode(self)
    }
}

/// Maps any error from a decode call (the cursor API throws untyped) to a typed work failure.
func workFailure(_ error: any Error) -> AlignmentWorkFailure {
    switch error {
    case let failure as AlignmentWorkFailure: failure
    case let failure as DecodeFailure: failure.asWorkFailure
    case is CancellationError: .cancelled
    case let failure as ResourceGate.Refusal:
        switch failure {
        case let .exceedsBudget(requested, budget): .memoryBudget(requested: requested, budget: budget)
        }
    default: .encoding(String(describing: error))
    }
}
