import Foundation
import Testing
import WWSpeech

@Suite("Captured hardware and shared resources", .serialized)
struct TranscriptionResourceTests {
    @Test func automaticResolutionAndExplicitMetalRefusalAreTruthful() throws {
        let cpu = try TranscriptionConfiguration.resolve(backend: .automatic, threads: .four, metalAvailable: false)
        let gpu = try TranscriptionConfiguration.resolve(backend: .automatic, threads: .two, metalAvailable: true)
        #expect(cpu.backend == .cpu && cpu.requestedBackend == .automatic)
        #expect(gpu.backend == .metal && gpu.threads == .two)
        #expect(throws: TranscriptionConfigurationError.metalUnavailable) {
            try TranscriptionConfiguration.resolve(backend: .metal, threads: .four, metalAvailable: false)
        }
        #expect(try TranscriptionConfiguration.resolve(backend: .cpu, threads: .eight, metalAvailable: false).backend == .cpu)
        for weights in LocalWhisperWeights.allCases {
            #expect(cpu.revision(weights: weights).contains("requested=automatic;backend=cpu;threads=4"))
            #expect(gpu.revision(weights: weights).contains("requested=automatic;backend=metal;threads=2"))
            #expect(cpu.revision(weights: weights) != gpu.revision(weights: weights))
            let base = try TranscriptionResources(weights: weights, configuration: gpu, renderBytes: 0)
            let rendered = try TranscriptionResources(weights: weights, configuration: gpu, renderBytes: 123)
            #expect(rendered.memoryBytes == base.memoryBytes + 123)
            for invalid in [-1, Int.max] {
                #expect(throws: TranscriptionConfigurationError.resourceBudgetExceeded) {
                    try TranscriptionResources(weights: weights, configuration: gpu, renderBytes: invalid)
                }
            }
        }
    }

    @Test func modelSpecificReservationsAndLegacyRecipesRemainStable() throws {
        let expected: [(LocalWhisperWeights, Int)] = [
            (.baseEnglish, 768 << 20), (.smallEnglish, 2 << 30), (.turbo, 3 << 30), (.largeV3, 5 << 30)
        ]
        for (weights, memory) in expected {
            let cost = try TranscriptionResources(weights: weights, configuration: .cpu)
            #expect(cost.memoryBytes == memory + (32 << 20))
            #expect(cost.cpuThreads == 4 && cost.metalWorkers == 0)
            #expect(memory > weights.byteCount * 2, "Include retained bytes as well as native weights and graphs")
        }
        for weights in [LocalWhisperWeights.baseEnglish, .turbo] {
            #expect(TranscriptionConfiguration.cpu.revision(weights: weights)
                == "whisper.cpp/1.6.2+ww-token-bounds-v1+metal-v1/\(weights.rawValue)/\(weights.sha256)/verbatim-v1/requested=cpu;backend=cpu;threads=4")
        }
    }

    @Test func largeModelRefusesAnInsufficientBudgetBeforeLoading() async throws {
        let pool = TranscriptionWorkerPool(budget: .init(memoryBytes: 4 << 30, cpuThreads: 4, metalWorkers: 2))
        let cost = try TranscriptionResources(weights: .largeV3, configuration: .cpu)
        await #expect(throws: TranscriptionConfigurationError.resourceBudgetExceeded) {
            try await pool.withAdmission(resources: cost) { Issue.record("An oversized model reached loading") }
        }
        let snapshot = await pool.snapshot
        #expect(snapshot.active == 0 && snapshot.reservedBytes == 0)
    }

    @Test(arguments: [0, 1, 2])
    func memoryThreadsAndGPUIndependentlyBoundTwoJobsBeforeLoading(_ constraint: Int) async throws {
        let budget = TranscriptionResourceBudget(memoryBytes: constraint == 0 ? 10 : 100,
                                                cpuThreads: constraint == 1 ? 2 : 100,
                                                metalWorkers: constraint == 2 ? 1 : 100)
        let pool = TranscriptionWorkerPool(concurrency: .four, budget: budget)
        let request = TranscriptionResources(memoryBytes: 6, cpuThreads: 2, metalWorkers: 1)
        let holder = Task {
            try await pool.withAdmission(resources: request) {
                let snapshot = await pool.snapshot
                #expect(snapshot.reservedBytes == 6 && snapshot.activeCPUThreads == 2 && snapshot.activeMetalWorkers == 1)
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { holder.cancel() }
        try await wait { await pool.snapshot.active == 1 }
        let tail = Task { try await pool.withAdmission(resources: request) { 42 } }
        defer { tail.cancel() }
        try await wait { await pool.snapshot.waiting == 1 }
        #expect(await pool.snapshot.active == 1, "The selected 4-worker maximum cannot bypass any shared budget")
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        #expect(try await tail.value == 42)
        let final = await pool.snapshot
        #expect(final.active == 0 && final.waiting == 0 && final.reservedBytes == 0)
        #expect(final.activeCPUThreads == 0 && final.activeMetalWorkers == 0 && final.peakReservedBytes == 6)
    }

    @Test func impossibleRequestsRefuseBeforeTheBodyAndCancellationDoesNotLeakReservations() async throws {
        let pool = TranscriptionWorkerPool(budget: .init(memoryBytes: 10, cpuThreads: 4, metalWorkers: 1))
        for request in [TranscriptionResources(memoryBytes: 11), .init(cpuThreads: 5), .init(metalWorkers: 2),
                        .init(memoryBytes: -1), .init(cpuThreads: -1), .init(metalWorkers: -1)] {
            await #expect(throws: TranscriptionConfigurationError.resourceBudgetExceeded) {
                try await pool.withAdmission(resources: request) { Issue.record("Work ran without resource admission") }
            }
        }
        let cost = TranscriptionResources(memoryBytes: 10, cpuThreads: 4, metalWorkers: 1)
        let holder = Task { try await pool.withAdmission(resources: cost) { try await Task.sleep(for: .seconds(30)) } }
        defer { holder.cancel() }
        try await wait { await pool.snapshot.active == 1 }
        let canceled = Task {
            try await pool.withAdmission(resources: cost) { Issue.record("A canceled waiter loaded its model") }
        }
        try await wait { await pool.snapshot.waiting == 1 }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await pool.snapshot.reservedBytes == 10)
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        await #expect(throws: TranscriptionConfigurationError.metalUnavailable) {
            try await pool.withAdmission(resources: cost) { throw TranscriptionConfigurationError.metalUnavailable }
        }
        let final = await pool.snapshot
        #expect(final.reservedBytes == 0 && final.activeCPUThreads == 0 && final.activeMetalWorkers == 0)
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await predicate(), "Resource admission timed out")
    }
}
