import Foundation

/// Admission control for pipeline work: at most `permits` units at once and at most `budgetBytes` of
/// estimated working set across admitted units. Waiters are served strictly in arrival order (no
/// starvation of large units) and never block a thread: waiting is a suspended continuation, and a
/// cancelled waiter is removed and resumed with `CancellationError`.
actor ResourceGate {
    /// All pipeline instances share this admission, including instances with different coordinators.
    /// Their individual gates still enforce each caller's smaller configured budget and concurrency.
    static let process = ResourceGate(
        permits: AlignmentPipelineConfiguration.maximumConcurrency,
        budgetBytes: AlignmentPipelineConfiguration.maximumMemoryBudgetBytes
    )

    struct Snapshot: Sendable, Equatable {
        var active: Int
        var activeBytes: Int
        var peakActive: Int
        var peakBytes: Int
        var admitted: Int
        var waiting: Int
    }

    enum Refusal: Error, Equatable {
        case exceedsBudget(requested: Int, budget: Int)
    }

    let permits: Int
    let budgetBytes: Int
    private var active = 0
    private var activeBytes = 0
    private var peakActive = 0
    private var peakBytes = 0
    private var admitted = 0
    private var nextWaiter: UInt64 = 0
    private var waiters: [(id: UInt64, bytes: Int, continuation: CheckedContinuation<Void, any Error>)] = []

    init(permits: Int, budgetBytes: Int) {
        precondition(permits > 0 && budgetBytes > 0)
        self.permits = permits
        self.budgetBytes = budgetBytes
    }

    var snapshot: Snapshot {
        Snapshot(active: active, activeBytes: activeBytes, peakActive: peakActive, peakBytes: peakBytes, admitted: admitted, waiting: waiters.count)
    }

    /// Runs `body` once admitted (off this actor, on the concurrent executor); releases on every path.
    @concurrent
    nonisolated func withAdmission<T: Sendable>(bytes: Int, _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(bytes: bytes)
        do {
            let value = try await body()
            await release(bytes: bytes)
            return value
        } catch {
            await release(bytes: bytes)
            throw error
        }
    }

    func acquire(bytes requested: Int) async throws {
        let bytes = max(requested, 0)
        guard bytes <= budgetBytes else { throw Refusal.exceedsBudget(requested: bytes, budget: budgetBytes) }
        try Task.checkCancellation()
        if waiters.isEmpty, fits(bytes) {
            grant(bytes)
            return
        }
        nextWaiter += 1
        let id = nextWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, bytes, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Granted; a cancellation that raced the grant gives the admission straight back.
        if Task.isCancelled {
            release(bytes: bytes)
            throw CancellationError()
        }
    }

    func release(bytes requested: Int) {
        let bytes = max(requested, 0)
        precondition(active > 0 && activeBytes >= bytes, "ResourceGate released more than it admitted")
        active -= 1
        activeBytes -= bytes
        drain()
    }

    private func fits(_ bytes: Int) -> Bool {
        active < permits && activeBytes + bytes <= budgetBytes
    }

    private func grant(_ bytes: Int) {
        active += 1
        activeBytes += bytes
        admitted += 1
        peakActive = max(peakActive, active)
        peakBytes = max(peakBytes, activeBytes)
    }

    private func drain() {
        while let head = waiters.first, fits(head.bytes) {
            waiters.removeFirst()
            grant(head.bytes)
            head.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let waiter = waiters.first(where: { $0.id == id }) else { return }
        waiters = waiters.filter { $0.id != id }
        waiter.continuation.resume(throwing: CancellationError())
        drain()
    }
}
