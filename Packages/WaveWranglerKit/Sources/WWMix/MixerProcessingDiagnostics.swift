import Foundation
import Synchronization

/// Numeric aggregates only. Actor submission waits are separate from work executing on the actor.
public final class MixerProcessingDiagnostics: Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        case controlsWait, processWait, render, unitRender, stateCapture
    }

    public struct Timing: Sendable {
        public var count = 0
        public var last: Duration = .zero
        public var longest: Duration = .zero
        public var started: ContinuousClock.Instant?
    }

    private let timings = Mutex(Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, Timing()) }))
    public init() {}
    public var snapshot: [Stage: Timing] { timings.withLock { $0 } }

    @discardableResult
    func begin(_ stage: Stage, at now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        timings.withLock { $0[stage]?.started = now }
        return now
    }

    func end(_ stage: Stage, since start: ContinuousClock.Instant, at now: ContinuousClock.Instant = .now) {
        timings.withLock {
            var timing = $0[stage] ?? Timing()
            timing.count += 1
            timing.last = max(.zero, start.duration(to: now))
            timing.longest = max(timing.longest, timing.last)
            if timing.started == start { timing.started = nil }
            $0[stage] = timing
        }
    }

    func measure<T>(_ stage: Stage, operation: () throws -> T) rethrows -> T {
        let start = begin(stage)
        defer { end(stage, since: start) }
        return try operation()
    }
}
