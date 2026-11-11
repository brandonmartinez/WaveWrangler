import Foundation
import Synchronization
import WWMix

/// Owned by the output queue. The existing audio-clock watchdog supplies consumption observations.
final class ProductionPlaybackRefill {
    final class Waiter: Sendable {
        let id = UUID()
        private struct State {
            var continuation: CheckedContinuation<ContinuousClock.Instant?, any Error>?
            var result: Result<ContinuousClock.Instant?, any Error>?
        }
        private let state = Mutex(State())

        var isPending: Bool { state.withLock { $0.result == nil } }

        func install(_ continuation: CheckedContinuation<ContinuousClock.Instant?, any Error>) {
            let result: Result<ContinuousClock.Instant?, any Error>? = state.withLock {
                if let result = $0.result { return result }
                $0.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }

        func finish(_ result: Result<ContinuousClock.Instant?, any Error>) {
            let continuation: CheckedContinuation<ContinuousClock.Instant?, any Error>? = state.withLock {
                guard $0.result == nil else { return nil }
                $0.result = result
                let continuation = $0.continuation
                $0.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private var waiters: [UUID: Waiter] = [:]
    var pendingCount: Int { waiters.count }

    func register(_ waiter: Waiter, bufferedSeconds: Double) {
        guard waiter.isPending else { return }
        if bufferedSeconds > Double(MixerLiveTiming.maximumScheduledAheadFrames) / Double(MixerRecipe.sampleRate) {
            waiters[waiter.id] = waiter
        } else {
            waiter.finish(.success(nil))
        }
    }

    func consumed(bufferedSeconds: Double, at now: ContinuousClock.Instant = .now) {
        guard bufferedSeconds <= Double(MixerLiveTiming.refillLowWaterFrames) / Double(MixerRecipe.sampleRate) else { return }
        let ready = waiters.values
        waiters.removeAll()
        for waiter in ready { waiter.finish(.success(now)) }
    }

    func cancel(_ waiter: Waiter) {
        waiters.removeValue(forKey: waiter.id)
        waiter.finish(.failure(CancellationError()))
    }

    func stop(throwing error: any Error = CancellationError()) {
        let stopped = waiters.values
        waiters.removeAll()
        for waiter in stopped { waiter.finish(.failure(error)) }
    }
}
