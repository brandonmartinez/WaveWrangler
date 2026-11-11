import Foundation
import Testing
import WWMix

@Suite("Production playback diagnostics")
struct ProductionPlaybackDiagnosticsTests {
    @Test func lowWaterDiagnosticsCountCrossingsRatherThanEveryClockObservation() throws {
        let diagnostics = ProductionPlaybackDiagnostics()
        #expect(diagnostics.snapshot.minimumBufferedFrames == nil)
        for frames: Int64 in [12_000, 10_000, 9_600, 9_000, 10_000, 9_599, 8_000] {
            diagnostics.recordBufferedFrames(frames)
        }
        #expect(diagnostics.snapshot.minimumBufferedFrames == 8_000)
        #expect(diagnostics.snapshot.lowWaterCrossings == 2)
        let report = try #require(diagnostics.takeUnderrunReport(
            scheduledFrames: 100_000, consumedFrames: 100_100, appendGap: .milliseconds(210)))
        #expect(report.contains("minBufferedFrames=8000 lowWaterCrossings=2"))
    }

    @Test func underrunIncludesProcessorExecutionAndWaitStagesWithoutInventingAnAttribution() throws {
        let processor = MixerProcessingDiagnostics()
        let diagnostics = ProductionPlaybackDiagnostics(processor: processor)
        let report = try #require(diagnostics.takeUnderrunReport(
            scheduledFrames: 0, consumedFrames: 0, appendGap: .zero))
        for stage in MixerProcessingDiagnostics.Stage.allCases {
            #expect(report.contains("\(stage.rawValue)(n=0,lastMs=0.000,maxMs=0.000,activeMs=0.000)"))
        }
        #expect(report.contains("minBufferedFrames=unobserved"))
    }

    @Test func timingsKeepSeparateCompletedAndInFlightStagesWithoutAnEventHistory() throws {
        let diagnostics = ProductionPlaybackDiagnostics()
        let start = ContinuousClock.now
        _ = diagnostics.begin(.source, at: start)
        diagnostics.end(.source, since: start, at: start.advanced(by: .milliseconds(180)))
        let next = start.advanced(by: .milliseconds(200))
        _ = diagnostics.begin(.source, at: next)
        _ = diagnostics.begin(.dsp, at: next)
        diagnostics.end(.dsp, since: next, at: next.advanced(by: .milliseconds(4)))
        let shorter = next.advanced(by: .milliseconds(10))
        _ = diagnostics.begin(.dsp, at: shorter)
        diagnostics.end(.dsp, since: shorter, at: shorter.advanced(by: .milliseconds(2)))
        diagnostics.preparedRawWindow(queued: 1)
        diagnostics.preparedRawWindow(queued: 2)
        diagnostics.rawQueueChanged(count: 1)
        let snapshot = diagnostics.snapshot
        #expect(snapshot.timings.count == ProductionPlaybackDiagnostics.Stage.allCases.count)
        #expect(snapshot.timings[.source]?.started == next)
        #expect(snapshot.timings[.source]?.longest == .milliseconds(180))
        #expect(snapshot.timings[.dsp]?.count == 2)
        #expect(snapshot.timings[.dsp]?.last == .milliseconds(2))
        #expect(snapshot.timings[.dsp]?.longest == .milliseconds(4))
        #expect(snapshot.timings[.dsp]?.started == nil)
        #expect(snapshot.queuedRawWindows == 1 && snapshot.preparedRawWindows == 2)
    }

    @Test func underrunReportsOncePerSessionWithFrameCountsAndActiveStageAge() throws {
        let diagnostics = ProductionPlaybackDiagnostics()
        let start = ContinuousClock.now
        _ = diagnostics.begin(.dsp, at: start)
        let report = try #require(diagnostics.takeUnderrunReport(
            scheduledFrames: 96_000, consumedFrames: 96_512, appendGap: .milliseconds(102),
            at: start.advanced(by: .milliseconds(99))))
        #expect(report.contains("WWAUDIO_UNDERRUN v=2 scheduledFrames=96000 consumedFrames=96512 appendGapMs=102.000"))
        #expect(report.contains("rawQueued=0 rawPrepared=0"))
        #expect(report.contains("dsp(n=0,lastMs=0.000,maxMs=0.000,activeMs=99.000)"))
        #expect(diagnostics.takeUnderrunReport(
            scheduledFrames: 96_000, consumedFrames: 97_024, appendGap: .milliseconds(110)) == nil)
        #expect(ProductionPlaybackDiagnostics().takeUnderrunReport(
            scheduledFrames: 0, consumedFrames: 0, appendGap: .zero) != nil)
    }

    @Test func producerWakeTimingExcludesTheRequestedSleepAndClampsEarlyWakes() {
        let diagnostics = ProductionPlaybackDiagnostics()
        let start = ContinuousClock.now
        diagnostics.recordWakeDelay(since: start, requested: .milliseconds(2),
                                    at: start.advanced(by: .milliseconds(22)))
        diagnostics.recordWakeDelay(since: start, requested: .milliseconds(2),
                                    at: start.advanced(by: .milliseconds(1)))
        #expect(diagnostics.snapshot.timings[.wakeDelay]?.count == 2)
        #expect(diagnostics.snapshot.timings[.wakeDelay]?.longest == .milliseconds(20))
        #expect(diagnostics.snapshot.timings[.wakeDelay]?.last == .zero)
    }

    @Test func thrownAndCanceledOperationsAlwaysFinishTheirMeasurement() async throws {
        let diagnostics = ProductionPlaybackDiagnostics()
        #expect(throws: CancellationError.self) {
            try diagnostics.measure(.enqueue) { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) {
            try await diagnostics.measureAsync(.validation) { throw CancellationError() }
        }
        #expect(diagnostics.snapshot.timings[.enqueue]?.count == 1)
        #expect(diagnostics.snapshot.timings[.enqueue]?.started == nil)
        #expect(diagnostics.snapshot.timings[.validation]?.count == 1)
        #expect(diagnostics.snapshot.timings[.validation]?.started == nil)
    }
}
