import Darwin
import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWAlignPipeline

enum PipelineHeavyGate {
    static let enabled = ProcessInfo.processInfo.environment["WW_PIPELINE_HEAVY_TESTS"] == "1"
    static let reason: Comment = "serialized pipeline memory pass (WW_PIPELINE_HEAVY_TESTS=1, scripts/test.sh)"
}

/// Samples this process's resident size and physical footprint from a dedicated thread (never a cooperative
/// pool thread) so the peak of a short-lived allocation is seen, alongside the kernel's lifetime `ru_maxrss`.
final class MemorySampler: @unchecked Sendable {
    struct Peaks: Sendable { var resident: Int; var footprint: Int }

    private let lock = NSLock()
    private var running = true
    private var peaks = Peaks(resident: 0, footprint: 0)

    static func now() -> Peaks {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return Peaks(resident: -1, footprint: -1) }
        return Peaks(resident: Int(info.resident_size), footprint: Int(info.phys_footprint))
    }

    /// Process-lifetime resident peak (macOS reports `ru_maxrss` in bytes).
    static func maxResident() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }

    init() {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sample = Self.now()
                lock.withLock {
                    peaks.resident = max(peaks.resident, sample.resident)
                    peaks.footprint = max(peaks.footprint, sample.footprint)
                }
                usleep(2000)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func stop() -> Peaks {
        lock.withLock {
            running = false
            return peaks
        }
    }
}

/// WW-021 resource bound (user-directed compute budget, 2026-10-06): analysing an episode of 75-minute,
/// 14-channel recorder groups stays well under 1 GiB of resident memory. Issue #188's harness peaked at
/// 20.6 GB because every analysis buffered full-rate sources and ran unbounded; here each source streams
/// through `AnalysisDecimator` (8 kHz mono) and units are admitted by the shared `ResourceGate`.
@Suite("Pipeline memory bound (heavy, serialized)", .serialized, .enabled(if: PipelineHeavyGate.enabled, PipelineHeavyGate.reason))
struct PipelineMemoryTests {
    static let minutes = 75.0
    static let mebibyte = 1 << 20

    /// A reference group and two target groups, each two 7-channel 48 kHz sources (14 channels per group).
    static func groups() -> [GroupSpec] {
        let seconds = minutes * 60
        func group(_ name: String, rate: Double, offset: Double) -> GroupSpec {
            GroupSpec(name: name, sources: ["a", "b"].map { side in
                SourceSpec(name: "\(name)-\(side)", channels: 7, seconds: seconds, signal: .scene(seed: TwoRecorder.seed, rate: rate, offset: offset))
            })
        }
        return [group("ref", rate: 1, offset: 0), group("t1", rate: 1.0001, offset: 1.25), group("t2", rate: 0.99995, offset: -2.5)]
    }

    @Test("Analysing three 14-channel 75-minute groups at the default configuration peaks well under 1 GiB")
    func analysisPeakResident() async throws {
        let configuration = AlignmentPipelineConfiguration()
        #expect(configuration.concurrency == 2)
        let fixture = try await PipelineFixture(Self.groups(), configuration: configuration, label: "pipeline-memory")
        let baseline = MemorySampler.now()
        let baselineMax = MemorySampler.maxResident()
        let sampler = MemorySampler()
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await fixture.analyse(preferredReference: "ref-a")
        let elapsed = clock.now - started
        let peaks = sampler.stop()
        let maxResident = MemorySampler.maxResident()
        let gate = await fixture.pipeline.gate.snapshot

        #expect(report.sourceFailures.isEmpty && report.epochFailures.isEmpty)
        for epoch in fixture.epochs.dropFirst() {
            let analysis = try #require(report.analyses[epoch])
            #expect(analysis.outcome == .published(analysis.key))
            let record = try #require(report.records[epoch])
            #expect(record.target.channelCount == 7 && record.target.sourceFrames == Int64(Self.minutes * 60 * 48_000))
            print("[pipeline-memory] epoch \(record.target.group): proposal ppm \(record.proposal.map { String(format: "%.2f", $0.ppm) } ?? "none"), abstention \(record.abstention?.reason ?? "none")")
        }
        #expect(fixture.content.peakOpenReaders <= configuration.concurrency)
        #expect(fixture.content.total.readsOnMainThread == 0)
        #expect(gate.peakActive <= configuration.concurrency && gate.peakBytes <= configuration.analysisMemoryBudgetBytes)

        let decodedFrames = fixture.specs.keys.map { fixture.content.record(fixture.url($0)).furthestFrame }.reduce(0, +)
        print("""
        [pipeline-memory] 3 groups × 14 ch × \(Int(Self.minutes)) min, concurrency \(configuration.concurrency), budget \(configuration.analysisMemoryBudgetBytes / Self.mebibyte) MiB
        [pipeline-memory] elapsed \(elapsed); decoded \(decodedFrames) source frames across \(fixture.content.total.opens) opens
        [pipeline-memory] gate: peak \(gate.peakActive) unit(s), peak estimated working set \(gate.peakBytes / Self.mebibyte) MiB, admitted \(gate.admitted)
        [pipeline-memory] baseline resident \(baseline.resident / Self.mebibyte) MiB, footprint \(baseline.footprint / Self.mebibyte) MiB; ru_maxrss before \(baselineMax / Self.mebibyte) MiB
        [pipeline-memory] sampled peak resident \(peaks.resident / Self.mebibyte) MiB, footprint \(peaks.footprint / Self.mebibyte) MiB; ru_maxrss after \(maxResident / Self.mebibyte) MiB
        """)
        // The bound is on the whole process (test runner included), not a delta.
        #expect(maxResident < 1 << 30, "process peak resident \(maxResident / Self.mebibyte) MiB")
        #expect(peaks.resident < 768 * Self.mebibyte, "sampled peak resident \(peaks.resident / Self.mebibyte) MiB")
        #expect(peaks.footprint < 768 * Self.mebibyte, "sampled peak footprint \(peaks.footprint / Self.mebibyte) MiB")
    }
}
