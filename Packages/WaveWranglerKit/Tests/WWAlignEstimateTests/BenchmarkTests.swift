import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWAlignEstimate

enum EstimatorTimingGate {
    static let enabled = ProcessInfo.processInfo.environment["WW_TIMING_TESTS"] == "1"
}

/// The CPU-heavy suites (scenarios and calibration) run in scripts/test.sh's serialized estimator pass, alone in
/// their process. In the parallel `swift test` pass their synchronous signal processing would occupy the
/// cooperative pool for minutes on a small CI runner and starve other suites' liveness waits.
enum EstimatorHeavyGate {
    static let enabled = ProcessInfo.processInfo.environment["WW_ESTIMATOR_TESTS"] == "1"
    static let reason: Comment = "serialized estimator pass (WW_ESTIMATOR_TESTS=1, scripts/test.sh)"
}

/// Throughput report for the serialized timing pass (scripts/test.sh). Prints only: the estimator has no
/// latency gate yet, and wall-clock assertions are not deterministic.
@Suite("Estimator benchmark")
struct EstimatorBenchmarkTests {
    @Test(.enabled(if: EstimatorTimingGate.enabled, "timing pass (WW_TIMING_TESTS=1)"))
    func estimatorThroughputBenchmark() throws {
        var rng = SplitMix64(seed: 0xBE4C_0016)
        let scene = Scene.random(&rng, range: -5...605)
        let referenceRecipe = TrackRecipe(sampleRate: 48000, duration: 600, groupClockStart: 0, truth: ClockTruth(ppm: 0, offset: 0),
                                          hearings: [Hearing(scene: scene, gain: 1, delay: .none)], noiseRMS: 0.004, noiseSeed: rng.next())
        let reference = EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                                       buffer: try SampleBuffer(samples: referenceRecipe.render(), sampleRate: 48000))
        var tracks: [EstimatorTrack] = []
        var truths: [ClockTruth] = []
        for (ppm, offset) in [(35.0, 0.8), (-120.0, -1.3)] {
            let truth = ClockTruth(ppm: ppm, offset: offset)
            let recipe = TrackRecipe(sampleRate: 48000, duration: 590, groupClockStart: 0, truth: truth,
                                     hearings: [Hearing(scene: scene, gain: 1, delay: .none)], noiseRMS: 0.005, noiseSeed: rng.next())
            tracks.append(EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                                         buffer: try SampleBuffer(samples: recipe.render(), sampleRate: 48000),
                                         declaredOverlap: 3 * 48000..<587 * 48000))
            truths.append(truth)
        }
        let request = EstimationRequest(reference: reference, tracks: tracks, search: try SearchRange(maximumDeviationSeconds: 2))
        let clock = ContinuousClock()
        var report: EstimationReport?
        let elapsed = try clock.measure { report = try AcousticEstimator.estimate(request) }
        let estimates = try #require(report).epochs
        let audioSeconds = 600.0 + 2 * 590
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        print(String(format: "WW-016 estimator benchmark: %.0f s of 48 kHz audio (reference + 2 tracks, 10 min) in %.3f s (%.0fx real time)", audioSeconds, seconds, audioSeconds / seconds))
        for (estimate, truth) in zip(estimates, truths) {
            #expect(proposal(estimate) != nil)
            #expect((CalibrationRunner.clockResiduals(estimate, truth: truth).max() ?? .infinity) < 1)
        }
    }
}
