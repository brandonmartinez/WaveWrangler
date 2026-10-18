import Foundation

public enum TranscriptionConcurrency: Int, Sendable, CaseIterable {
    case one = 1, two, three, four
}

/// One app-wide pool, shared by episode jobs. Admission never blocks an executor thread.
public actor TranscriptionWorkerPool {
    public struct Snapshot: Sendable {
        public let limit: Int
        public let active: Int
        public let waiting: Int
        public let peakActive: Int
        public let reservedBytes: Int
        public let activeCPUThreads: Int
        public let activeMetalWorkers: Int
        public let peakReservedBytes: Int
    }

    private var limit: Int
    private var configurationRevision: UInt64 = 0
    private var active = 0
    private var peakActive = 0
    public nonisolated let budget: TranscriptionResourceBudget
    private var reservedBytes = 0
    private var activeCPUThreads = 0
    private var activeMetalWorkers = 0
    private var peakReservedBytes = 0
    private var nextWaiter: UInt64 = 0
    private var waiters: [(id: UInt64, resources: TranscriptionResources, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(concurrency: TranscriptionConcurrency = .one, budget: TranscriptionResourceBudget = .system) {
        limit = concurrency.rawValue
        self.budget = budget
    }

    public var snapshot: Snapshot {
        Snapshot(limit: limit, active: active, waiting: waiters.count, peakActive: peakActive,
                 reservedBytes: reservedBytes, activeCPUThreads: activeCPUThreads,
                 activeMetalWorkers: activeMetalWorkers, peakReservedBytes: peakReservedBytes)
    }

    public func configure(_ concurrency: TranscriptionConcurrency, revision: UInt64) {
        guard revision >= configurationRevision else { return }
        configurationRevision = revision
        limit = concurrency.rawValue
        drain()
    }

    @concurrent
    public func withAdmission<T: Sendable>(
        resources: TranscriptionResources = .init(), _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(resources)
        do {
            try Task.checkCancellation()
            let result = try await body()
            await release(resources)
            return result
        } catch {
            await release(resources)
            throw error
        }
    }

    private func acquire(_ resources: TranscriptionResources) async throws {
        try Task.checkCancellation()
        guard resources.memoryBytes >= 0, resources.cpuThreads >= 0, resources.metalWorkers >= 0,
              resources.memoryBytes <= budget.memoryBytes, resources.cpuThreads <= budget.cpuThreads,
              resources.metalWorkers <= budget.metalWorkers else {
            throw TranscriptionConfigurationError.resourceBudgetExceeded
        }
        if waiters.isEmpty, canAdmit(resources) {
            grant(resources)
            return
        }
        nextWaiter += 1
        let id = nextWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, resources, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if Task.isCancelled {
            release(resources)
            throw CancellationError()
        }
    }

    private func canAdmit(_ resources: TranscriptionResources) -> Bool {
        active < limit && resources.memoryBytes <= budget.memoryBytes - reservedBytes
            && resources.cpuThreads <= budget.cpuThreads - activeCPUThreads
            && resources.metalWorkers <= budget.metalWorkers - activeMetalWorkers
    }

    private func grant(_ resources: TranscriptionResources) {
        active += 1
        peakActive = max(peakActive, active)
        reservedBytes += resources.memoryBytes
        activeCPUThreads += resources.cpuThreads
        activeMetalWorkers += resources.metalWorkers
        peakReservedBytes = max(peakReservedBytes, reservedBytes)
    }

    private func release(_ resources: TranscriptionResources) {
        precondition(active > 0, "Cannot release an unclaimed transcription worker")
        active -= 1
        reservedBytes -= resources.memoryBytes
        activeCPUThreads -= resources.cpuThreads
        activeMetalWorkers -= resources.metalWorkers
        drain()
    }

    private func drain() {
        while let first = waiters.first, canAdmit(first.resources) {
            let waiter = waiters.removeFirst()
            grant(waiter.resources)
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }
}
