import Foundation
import OSLog
import Synchronization

/// Bounded numeric evidence only; never retains audio, source identifiers, paths, or vendor state.
final class ProductionPlaybackDiagnostics: Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case source, sourceWait, validation, controls, dsp, enqueue, wakeDelay
    }

    struct Timing: Sendable {
        var count = 0
        var last: Duration = .zero
        var longest: Duration = .zero
        var started: ContinuousClock.Instant?
    }

    struct Snapshot: Sendable {
        let timings: [Stage: Timing]
        let queuedRawWindows: Int
        let preparedRawWindows: Int
    }

    private struct State {
        var timings = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, Timing()) })
        var queuedRawWindows = 0
        var preparedRawWindows = 0
        var reportedUnderrun = false
    }

    private static let logger = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "AudioPlayback")
    private let state = Mutex(State())

    func begin(_ stage: Stage, at now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        state.withLock { $0.timings[stage]?.started = now }
        return now
    }

    func end(_ stage: Stage, since start: ContinuousClock.Instant, at now: ContinuousClock.Instant = .now) {
        state.withLock {
            var timing = $0.timings[stage] ?? Timing()
            timing.count += 1
            timing.last = max(.zero, start.duration(to: now))
            timing.longest = max(timing.longest, timing.last)
            if timing.started == start { timing.started = nil }
            $0.timings[stage] = timing
        }
    }

    func measure<T>(_ stage: Stage, operation: () throws -> T) rethrows -> T {
        let start = begin(stage)
        defer { end(stage, since: start) }
        return try operation()
    }

    func measureAsync<T: Sendable>(
        _ stage: Stage, operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let start = begin(stage)
        defer { end(stage, since: start) }
        return try await operation()
    }

    func recordWakeDelay(since start: ContinuousClock.Instant, requested: Duration,
                         at now: ContinuousClock.Instant = .now) {
        let delayedStart = start.advanced(by: requested)
        end(.wakeDelay, since: delayedStart, at: now)
    }

    func preparedRawWindow(queued: Int) {
        state.withLock {
            $0.preparedRawWindows += 1
            $0.queuedRawWindows = queued
        }
    }

    func rawQueueChanged(count: Int) { state.withLock { $0.queuedRawWindows = count } }

    var snapshot: Snapshot {
        state.withLock {
            Snapshot(timings: $0.timings, queuedRawWindows: $0.queuedRawWindows,
                     preparedRawWindows: $0.preparedRawWindows)
        }
    }

    func reportUnderrun(scheduledFrames: Int64, consumedFrames: Int64, appendGap: Duration,
                        at now: ContinuousClock.Instant = .now) {
        guard let report = takeUnderrunReport(scheduledFrames: scheduledFrames, consumedFrames: consumedFrames,
                                              appendGap: appendGap, at: now) else { return }
        Self.logger.error("\(report, privacy: .public)")
    }

    func takeUnderrunReport(scheduledFrames: Int64, consumedFrames: Int64, appendGap: Duration,
                            at now: ContinuousClock.Instant = .now) -> String? {
        let captured: Snapshot? = state.withLock {
            guard !$0.reportedUnderrun else { return nil }
            $0.reportedUnderrun = true
            return Snapshot(timings: $0.timings, queuedRawWindows: $0.queuedRawWindows,
                            preparedRawWindows: $0.preparedRawWindows)
        }
        guard let captured else { return nil }
        let stages = Stage.allCases.map { stage in
            let timing = captured.timings[stage] ?? Timing()
            let active = timing.started.map { max(.zero, $0.duration(to: now)) } ?? .zero
            return "\(stage.rawValue)(n=\(timing.count),lastMs=\(Self.milliseconds(timing.last)),maxMs=\(Self.milliseconds(timing.longest)),activeMs=\(Self.milliseconds(active)))"
        }.joined(separator: " ")
        return "WWAUDIO_UNDERRUN v=1 scheduledFrames=\(scheduledFrames) consumedFrames=\(consumedFrames) appendGapMs=\(Self.milliseconds(appendGap)) rawQueued=\(captured.queuedRawWindows) rawPrepared=\(captured.preparedRawWindows) \(stages)"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                      Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }
}
