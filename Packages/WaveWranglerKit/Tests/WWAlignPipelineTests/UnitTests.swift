import Foundation
import Testing
import WWDecode
@testable import WWAlignPipeline

// MARK: - ResourceGate

@Suite("ResourceGate: permit cap, byte budget, FIFO admission, cancellable waiters", .timeLimit(.minutes(1)))
struct ResourceGateTests {
    static func until(_ gate: ResourceGate, _ condition: @Sendable (ResourceGate.Snapshot) -> Bool) async throws {
        while !condition(await gate.snapshot) { try await Task.sleep(for: .milliseconds(1)) }
    }

    @Test("At most `permits` units are admitted; a release admits the next waiter")
    func permitCap() async throws {
        let gate = ResourceGate(permits: 2, budgetBytes: 1000)
        try await gate.acquire(bytes: 1)
        try await gate.acquire(bytes: 1)
        let third = Task { try await gate.acquire(bytes: 1) }
        try await Self.until(gate) { $0.waiting == 1 }
        #expect(await gate.snapshot.active == 2)
        await gate.release(bytes: 1)
        try await third.value
        let snapshot = await gate.snapshot
        #expect(snapshot.active == 2 && snapshot.peakActive == 2 && snapshot.waiting == 0 && snapshot.admitted == 3)
        await gate.release(bytes: 1)
        await gate.release(bytes: 1)
        #expect(await gate.snapshot.active == 0)
    }

    @Test("Admitted bytes never exceed the budget, and waiters are served strictly in arrival order")
    func budgetAndFIFO() async throws {
        let gate = ResourceGate(permits: 3, budgetBytes: 100)
        try await gate.acquire(bytes: 10)
        let large = Task { try await gate.acquire(bytes: 95) }
        try await Self.until(gate) { $0.waiting == 1 }
        // Fits beside the 10 already admitted, but must not overtake the large waiter.
        let small = Task { try await gate.acquire(bytes: 6) }
        try await Self.until(gate) { $0.waiting == 2 }
        #expect(await gate.snapshot.active == 1)
        await gate.release(bytes: 10)
        try await large.value
        // 95 + 6 > 100: the small unit keeps waiting.
        var snapshot = await gate.snapshot
        #expect(snapshot.active == 1 && snapshot.activeBytes == 95 && snapshot.waiting == 1)
        await gate.release(bytes: 95)
        try await small.value
        snapshot = await gate.snapshot
        #expect(snapshot.active == 1 && snapshot.activeBytes == 6 && snapshot.peakBytes == 95)
        await gate.release(bytes: 6)
    }

    @Test("A unit larger than the whole budget is refused at once and admits nothing")
    func overBudgetRefused() async throws {
        let gate = ResourceGate(permits: 2, budgetBytes: 100)
        await #expect(throws: ResourceGate.Refusal.exceedsBudget(requested: 101, budget: 100)) { try await gate.acquire(bytes: 101) }
        #expect(await gate.snapshot == ResourceGate.Snapshot(active: 0, activeBytes: 0, peakActive: 0, peakBytes: 0, admitted: 0, waiting: 0))
    }

    @Test("A cancelled waiter leaves the queue without being admitted; the next waiter is still served")
    func cancelledWaiter() async throws {
        let gate = ResourceGate(permits: 1, budgetBytes: 100)
        try await gate.acquire(bytes: 1)
        let cancelled = Task { try await gate.acquire(bytes: 1) }
        try await Self.until(gate) { $0.waiting == 1 }
        let next = Task { try await gate.acquire(bytes: 1) }
        try await Self.until(gate) { $0.waiting == 2 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await Self.until(gate) { $0.waiting == 1 }
        #expect(await gate.snapshot.active == 1)
        await gate.release(bytes: 1)
        try await next.value
        let snapshot = await gate.snapshot
        #expect(snapshot.active == 1 && snapshot.admitted == 2 && snapshot.waiting == 0)
        await gate.release(bytes: 1)
    }

    @Test("withAdmission releases on success and on throw")
    func withAdmissionReleases() async throws {
        struct Boom: Error {}
        let gate = ResourceGate(permits: 1, budgetBytes: 100)
        #expect(try await gate.withAdmission(bytes: 40) { 7 } == 7)
        await #expect(throws: Boom.self) { try await gate.withAdmission(bytes: 40) { () throws -> Int in throw Boom() } }
        let snapshot = await gate.snapshot
        #expect(snapshot.active == 0 && snapshot.activeBytes == 0 && snapshot.admitted == 2)
    }
}

// MARK: - boundedMap

@Suite("boundedMap keeps at most `limit` operations in flight and preserves order")
struct BoundedMapTests {
    @Test("Peak in-flight never exceeds the limit", arguments: [1, 3])
    func peakInFlight(limit: Int) async {
        let state = Box((now: 0, peak: 0))
        let results = await boundedMap(Array(0 ..< 20), limit: limit) { value in
            state.update { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            try? await Task.sleep(for: .milliseconds(2))
            state.update { $0.now -= 1 }
            return value * 2
        }
        #expect(results == (0 ..< 20).map { $0 * 2 })
        #expect(state.value.peak <= limit && state.value.peak >= 1)
    }
}

// MARK: - Configuration

@Suite("Configuration: concurrency is a small cap, never the processor count")
struct ConfigurationTests {
    @Test("Defaults and clamps")
    func clamps() {
        let defaults = AlignmentPipelineConfiguration()
        #expect(defaults.concurrency == 2)
        #expect(AlignmentPipelineConfiguration.maximumConcurrency == 4)
        #expect(defaults.analysisMemoryBudgetBytes == 512 << 20)
        #expect(AlignmentPipelineConfiguration(concurrency: 0).concurrency == 1)
        #expect(AlignmentPipelineConfiguration(concurrency: -3).concurrency == 1)
        #expect(AlignmentPipelineConfiguration(concurrency: ProcessInfo.processInfo.activeProcessorCount).concurrency <= 4)
        #expect(AlignmentPipelineConfiguration(concurrency: 64).concurrency == 4)
        #expect(AlignmentPipelineConfiguration(analysisMemoryBudgetBytes: 0).analysisMemoryBudgetBytes == 16 << 20)
        #expect(AlignmentPipelineConfiguration(targetExcerptSeconds: 1).targetExcerptSeconds == 10)
        #expect(AlignmentPipelineConfiguration(targetExcerptSeconds: 99_999).targetExcerptSeconds == 3600)
        #expect(AlignmentPipelineConfiguration(searchDeviationSeconds: 0).searchDeviationSeconds == 1)
        #expect(AlignmentPipelineConfiguration(searchDeviationSeconds: 601).searchDeviationSeconds == 600)
        #expect(AlignmentPipelineConfiguration(minimumAnalysisRate: 10).minimumAnalysisRate == 8000)
        #expect(AlignmentPipelineConfiguration(minimumAnalysisRate: 96_000).minimumAnalysisRate == 48_000)
        #expect(AlignmentPipelineConfiguration(renderSegmentSeconds: 0).renderSegmentSeconds == 1)
        #expect(AlignmentPipelineConfiguration(renderSegmentSeconds: 1000).renderSegmentSeconds == 300)
    }

    @Test("Every result-changing parameter is part of the recipe names")
    func recipesNameTheirParameters() {
        let base = AlignmentPipelineConfiguration()
        let variants = [
            AlignmentPipelineConfiguration(targetExcerptSeconds: 300),
            AlignmentPipelineConfiguration(searchDeviationSeconds: 60),
            AlignmentPipelineConfiguration(searchCenterSeconds: 5),
            AlignmentPipelineConfiguration(minimumAnalysisRate: 16_000),
        ]
        for variant in variants { #expect(variant.analysisRecipeName != base.analysisRecipeName) }
        #expect(AlignmentPipelineConfiguration(concurrency: 4).analysisRecipeName == base.analysisRecipeName, "concurrency changes no result")
        #expect(AlignmentPipelineConfiguration(renderSegmentSeconds: 5).renderRecipeName != base.renderRecipeName)
    }
}

// MARK: - AnalysisDecimator

@Suite("AnalysisDecimator: exact-rate, unit-gain, chunking-invariant streaming decimation")
struct AnalysisDecimatorTests {
    /// Feeds `frames` source frames of `value(frame, channel)` in chunks of `chunk` frames.
    static func run(rate: Int, range: Range<Int64>, frames: Int64, channels: Int = 2, chunk: Int, _ value: (Int64, Int) -> Float) throws -> [Float] {
        var decimator = try AnalysisDecimator(sourceRate: rate, minimumRate: 8000, range: range)
        var start: Int64 = 0
        while start < frames, start < decimator.neededInput.upperBound {
            let count = Int(min(Int64(chunk), frames - start))
            var samples = [Float](repeating: 0, count: count * channels)
            for c in 0 ..< channels {
                for i in 0 ..< count { samples[c * count + i] = value(start + Int64(i), c) }
            }
            decimator.consume(DecodedChunk(firstSourceFrame: start, frameCount: count, channelCount: channels, samples: samples))
            start += Int64(count)
        }
        return decimator.finish()
    }

    @Test("The factor is the largest exact divisor keeping the rate at or above the minimum")
    func factors() throws {
        #expect(try AnalysisDecimator.factor(sourceRate: 48_000, minimumRate: 8000) == 6)
        #expect(try AnalysisDecimator.factor(sourceRate: 44_100, minimumRate: 8000) == 5)
        #expect(try AnalysisDecimator.factor(sourceRate: 96_000, minimumRate: 8000) == 12)
        #expect(try AnalysisDecimator.factor(sourceRate: 8000, minimumRate: 8000) == 1)
        #expect(throws: AnalysisDecimator.Refusal.rateBelowMinimum(rate: 4000, minimum: 8000)) { try AnalysisDecimator.factor(sourceRate: 4000, minimumRate: 8000) }
        #expect(throws: AnalysisDecimator.Refusal.emptyRange) { try AnalysisDecimator(sourceRate: 48_000, minimumRate: 8000, range: 10 ..< 10) }
        let decimator = try AnalysisDecimator(sourceRate: 48_000, minimumRate: 8000, range: 48_000 ..< 96_000)
        #expect(decimator.outputRate == 8000 && decimator.outputCount == 8000)
        #expect(decimator.neededInput == (48_000 - 48) ..< (48_000 + 7999 * 6 + 49))
    }

    @Test("Factor 1 is an exact passthrough of the channel mean")
    func passthrough() throws {
        let value: (Int64, Int) -> Float = { frame, c in Float(frame % 97) * 0.01 + Float(c) * 0.25 }
        let output = try Self.run(rate: 8000, range: 100 ..< 900, frames: 1000, chunk: 77, value)
        #expect(output.count == 800)
        for (j, sample) in output.enumerated() {
            let frame = Int64(100 + j)
            #expect(sample == (value(frame, 0) + value(frame, 1)) / 2)
        }
    }

    @Test("Unit DC gain, an in-band tone is preserved, an out-of-band tone is rejected")
    func frequencyResponse() throws {
        let rate = 48_000
        let range: Range<Int64> = 4800 ..< 52_800
        func tone(_ hz: Double) -> (Int64, Int) -> Float { { frame, _ in Float(0.5 * sin(2 * Double.pi * hz * Double(frame) / Double(rate))) } }
        let dc = try Self.run(rate: rate, range: range, frames: 60_000, chunk: 4096) { _, _ in 0.5 }
        #expect(dc.allSatisfy { abs($0 - 0.5) < 1e-4 })
        let inBand = try Self.run(rate: rate, range: range, frames: 60_000, chunk: 4096, tone(1000))
        let expected = (0 ..< inBand.count).map { j in 0.5 * sin(2 * Double.pi * 1000 * Double(range.lowerBound + Int64(j * 6)) / Double(rate)) }
        let error = zip(inBand, expected).map { abs(Double($0) - $1) }.max() ?? 1
        #expect(error < 5e-3, "1 kHz error \(error)")
        let alias = try Self.run(rate: rate, range: range, frames: 60_000, chunk: 4096, tone(7000))
        let rms = (alias.map { Double($0 * $0) }.reduce(0, +) / Double(alias.count)).squareRoot()
        #expect(rms < 5e-3, "7 kHz leaks \(rms)")
    }

    @Test("The output does not depend on how the stream is chunked, and stops needing input at the range end")
    func chunkingInvariance() throws {
        let value: (Int64, Int) -> Float = { frame, c in Signal.scene(7, Double(frame) / 48_000) * channelGain(c) }
        let range: Range<Int64> = 30 ..< 20_000
        let reference = try Self.run(rate: 48_000, range: range, frames: 25_000, chunk: 25_000, value)
        for chunk in [1, 97, 4096] {
            let output = try Self.run(rate: 48_000, range: range, frames: 25_000, chunk: chunk, value)
            #expect(output.count == reference.count)
            let difference = zip(output, reference).map { abs($0 - $1) }.max() ?? 0
            #expect(difference <= 1e-6, "chunk \(chunk): \(difference)")
        }
        // A range ending at the source end: frames past it count as zero, and finish() completes.
        let tail = try Self.run(rate: 48_000, range: 24_000 ..< 25_000, frames: 25_000, chunk: 512, value)
        #expect(tail.count == AnalysisDecimator.outputCount(frames: 1000, factor: 6))
    }
}
