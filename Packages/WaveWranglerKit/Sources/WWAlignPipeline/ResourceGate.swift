import Darwin
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
        budgetBytes: AlignmentPipelineConfiguration.maximumMemoryBudgetBytes,
        processLimitBytes: 1 << 30
    )

    /// The 180 s / six-channel long-form run grew ~208 MiB beyond its 484 MiB reservation.
    /// Round that observed gap up to 256 MiB; other shapes still need independent qualification.
    static let processHeadroomBytes = 256 << 20

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
        case processMemoryUnavailable
        case processEnvelope(resident: Int, footprint: Int, reserved: Int, limit: Int)
    }

    let permits: Int
    let budgetBytes: Int
    let processLimitBytes: Int?
    private let measureProcess: @Sendable () -> (resident: Int, footprint: Int)?
    private var active = 0
    private var activeBytes = 0
    private var peakActive = 0
    private var peakBytes = 0
    private var admitted = 0
    private var nextWaiter: UInt64 = 0
    private var waiters: [(id: UInt64, bytes: Int, continuation: CheckedContinuation<Void, any Error>)] = []

    init(
        permits: Int, budgetBytes: Int, processLimitBytes: Int? = nil,
        measureProcess: @escaping @Sendable () -> (resident: Int, footprint: Int)? = { ResourceGate.processMemory() }
    ) {
        precondition(permits > 0 && budgetBytes > 0)
        self.permits = permits
        self.budgetBytes = budgetBytes
        self.processLimitBytes = processLimitBytes
        self.measureProcess = measureProcess
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
            try checkProcessEnvelope(adding: bytes)
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
            do {
                try checkProcessEnvelope(adding: head.bytes)
            } catch {
                head.continuation.resume(throwing: error)
                continue
            }
            grant(head.bytes)
            head.continuation.resume()
        }
    }

    private func checkProcessEnvelope(adding bytes: Int) throws {
        guard let processLimitBytes else { return }
        guard let usage = measureProcess() else { throw Refusal.processMemoryUnavailable }
        if let refusal = Self.processEnvelopeRefusal(
            resident: usage.resident, footprint: usage.footprint,
            reserved: activeBytes, adding: bytes, limit: processLimitBytes
        ) {
            throw refusal
        }
    }

    /// The live footprint includes only allocations already committed. Charge outstanding reservations
    /// again to avoid admitting a second unit against a first unit that has not yet allocated its buffers.
    static func processEnvelopeRefusal(
        resident: Int, footprint: Int, reserved: Int, adding: Int, limit: Int
    ) -> Refusal? {
        let available = limit - processHeadroomBytes
        let (combined, overflow) = reserved.addingReportingOverflow(adding)
        let used = max(resident, footprint)
        guard !overflow, used >= 0, combined >= 0, used <= available,
              combined <= available - used
        else {
            return .processEnvelope(resident: resident, footprint: footprint, reserved: combined, limit: limit)
        }
        return nil
    }

    private static func processMemory() -> (resident: Int, footprint: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Int(info.resident_size), Int(info.phys_footprint))
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let waiter = waiters.first(where: { $0.id == id }) else { return }
        waiters = waiters.filter { $0.id != id }
        waiter.continuation.resume(throwing: CancellationError())
        drain()
    }
}
