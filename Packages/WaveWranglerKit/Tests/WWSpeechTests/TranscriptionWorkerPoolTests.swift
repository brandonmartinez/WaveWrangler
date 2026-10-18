import Foundation
import Testing
import WWSpeech

@Suite("Shared bounded transcription workers", .serialized)
struct TranscriptionWorkerPoolTests {
    @Test(arguments: TranscriptionConcurrency.allCases)
    func twoIndependentJobsShareOneLimitAndActuallyOverlap(_ policy: TranscriptionConcurrency) async throws {
        #expect(TranscriptionConcurrency.allCases.map(\.rawValue) == [1, 2, 3, 4])
        let pool = TranscriptionWorkerPool(concurrency: policy)
        let probe = WorkerProbe()
        async let first = batch(pool, probe: probe, offset: 0)
        async let second = batch(pool, probe: probe, offset: 4)
        let results = try await first + second
        #expect(results.sorted() == Array(0..<8))
        #expect(await probe.peak == policy.rawValue)
        let snapshot = await pool.snapshot
        #expect(snapshot.peakActive == policy.rawValue && snapshot.active == 0 && snapshot.waiting == 0)
    }

    @Test func cancelledWaiterDoesNotRunOrBlockAnotherJob() async throws {
        let pool = TranscriptionWorkerPool()
        let holder = Task { try await pool.withAdmission { try await Task.sleep(for: .seconds(60)) } }
        defer { holder.cancel() }
        try await wait { await pool.snapshot.active == 1 }
        let cancelled = Task { try await pool.withAdmission { Issue.record("Cancelled queued work ran") } }
        defer { cancelled.cancel() }
        try await wait { await pool.snapshot.waiting == 1 }
        let tail = Task { try await pool.withAdmission { 42 } }
        defer { tail.cancel() }
        try await wait { await pool.snapshot.waiting == 2 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await pool.snapshot.waiting == 1)
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        #expect(try await tail.value == 42)
        #expect(await pool.snapshot.active == 0)
    }

    @Test func loweringLimitDrainsExistingWorkersWithoutAdmittingMoreAndRejectsStaleConfiguration() async throws {
        let pool = TranscriptionWorkerPool(concurrency: .three)
        let holders = (0..<3).map { _ in
            Task { try await pool.withAdmission { try await Task.sleep(for: .seconds(60)) } }
        }
        defer { holders.forEach { $0.cancel() } }
        try await wait { await pool.snapshot.active == 3 }
        await pool.configure(.one, revision: 2)
        await pool.configure(.four, revision: 1)
        #expect(await pool.snapshot.limit == 1)
        let tail = Task { try await pool.withAdmission { 42 } }
        defer { tail.cancel() }
        try await wait { await pool.snapshot.waiting == 1 }
        for (index, holder) in holders.enumerated() {
            holder.cancel()
            await #expect(throws: CancellationError.self) { try await holder.value }
            if index < 2 { #expect(await pool.snapshot.waiting == 1) }
        }
        #expect(try await tail.value == 42)
        #expect(await pool.snapshot.active == 0)
    }

    @Test func errorsReleaseWorkersAndIncreasingLimitWakesQueuedWork() async throws {
        let pool = TranscriptionWorkerPool()
        await #expect(throws: ExpectedFailure.test) {
            try await pool.withAdmission { throw ExpectedFailure.test }
        }
        #expect(await pool.snapshot.active == 0)
        let holder = Task { try await pool.withAdmission { try await Task.sleep(for: .seconds(60)) } }
        defer { holder.cancel() }
        try await wait { await pool.snapshot.active == 1 }
        let queued = Task { try await pool.withAdmission { 42 } }
        defer { queued.cancel() }
        try await wait { await pool.snapshot.waiting == 1 }
        await pool.configure(.two, revision: 1)
        #expect(try await queued.value == 42)
        #expect(await pool.snapshot.peakActive == 2)
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        let snapshot = await pool.snapshot
        #expect(snapshot.active == 0 && snapshot.waiting == 0)
    }

    private func batch(_ pool: TranscriptionWorkerPool, probe: WorkerProbe, offset: Int) async throws -> [Int] {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in offset..<(offset + 4) {
                group.addTask {
                    try await pool.withAdmission {
                        await probe.enter()
                        do {
                            try await Task.sleep(for: .milliseconds(20))
                            await probe.leave()
                            return index
                        } catch {
                            await probe.leave()
                            throw error
                        }
                    }
                }
            }
            var results: [Int] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await predicate(), "Timed out waiting for worker admission")
    }
}

private enum ExpectedFailure: Error { case test }
private actor WorkerProbe {
    private var active = 0
    var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}
