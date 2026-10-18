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
    }

    private var limit: Int
    private var configurationRevision: UInt64 = 0
    private var active = 0
    private var peakActive = 0
    private var nextWaiter: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(concurrency: TranscriptionConcurrency = .one) { limit = concurrency.rawValue }

    public var snapshot: Snapshot {
        Snapshot(limit: limit, active: active, waiting: waiters.count, peakActive: peakActive)
    }

    public func configure(_ concurrency: TranscriptionConcurrency, revision: UInt64) {
        guard revision >= configurationRevision else { return }
        configurationRevision = revision
        limit = concurrency.rawValue
        drain()
    }

    @concurrent
    public func withAdmission<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if waiters.isEmpty, active < limit {
            grant()
            return
        }
        nextWaiter += 1
        let id = nextWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func grant() {
        active += 1
        peakActive = max(peakActive, active)
    }

    private func release() {
        precondition(active > 0, "Cannot release an unclaimed transcription worker")
        active -= 1
        drain()
    }

    private func drain() {
        while !waiters.isEmpty, active < limit {
            let waiter = waiters.removeFirst()
            grant()
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }
}
