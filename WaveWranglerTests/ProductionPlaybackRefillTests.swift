import Foundation
import Testing
import WWMix

@Suite("Production playback refill signaling")
struct ProductionPlaybackRefillTests {
    @Test(arguments: [0.0, 0.2, 0.25])
    func availableCapacityDoesNotSuspend(buffered: Double) async throws {
        let refill = ProductionPlaybackRefill()
        let released = try await withCheckedThrowingContinuation { continuation in
            let waiter = ProductionPlaybackRefill.Waiter()
            waiter.install(continuation)
            refill.register(waiter, bufferedSeconds: buffered)
            #expect(refill.pendingCount == 0)
        }
        #expect(released == nil)
    }

    @Test func highWaterWaitUsesHysteresisAndReportsTheReleaseTime() async throws {
        let refill = ProductionPlaybackRefill()
        let now = ContinuousClock.now
        let released = try await withCheckedThrowingContinuation { continuation in
            let waiter = ProductionPlaybackRefill.Waiter()
            waiter.install(continuation)
            refill.register(waiter, bufferedSeconds: 0.26)
            #expect(refill.pendingCount == 1)
            for remaining in [0.25, 0.24, 0.201] {
                refill.consumed(bufferedSeconds: remaining, at: now)
                #expect(refill.pendingCount == 1 && waiter.isPending)
            }
            refill.consumed(bufferedSeconds: 0.2, at: now)
            #expect(refill.pendingCount == 0 && !waiter.isPending)
            refill.consumed(bufferedSeconds: 0, at: now)
        }
        #expect(released == now)
    }

    @Test func aHundredFiftyMillisecondPreparationStallFitsTheNewReserve() async throws {
        let refill = ProductionPlaybackRefill()
        let initial = MixerLiveTiming.maximumScheduledAheadFrames
        let consumed = MixerRecipe.sampleRate * 150 / 1000
        let remaining = initial - consumed
        #expect(remaining == 4_800)
        #expect(remaining > MixerLiveTiming.processingBlockFrames)
        let released = try await withCheckedThrowingContinuation { continuation in
            let waiter = ProductionPlaybackRefill.Waiter()
            waiter.install(continuation)
            refill.register(waiter, bufferedSeconds: Double(initial + 1) / Double(MixerRecipe.sampleRate))
            refill.consumed(bufferedSeconds: Double(remaining) / Double(MixerRecipe.sampleRate))
            #expect(refill.pendingCount == 0)
        }
        #expect(released != nil)
    }

    @Test func cancellationBeforeInstallOrRegistrationCannotLoseAResume() async throws {
        let refill = ProductionPlaybackRefill()
        let waiter = ProductionPlaybackRefill.Waiter()
        waiter.finish(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                refill.register(waiter, bufferedSeconds: 1)
                #expect(refill.pendingCount == 0)
            }
        }
        waiter.finish(.success(.now))
    }

    @Test func cancellationAfterRegistrationRemovesTheWaiterAndDoesNotPoisonTheNextOne() async throws {
        let refill = ProductionPlaybackRefill()
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = ProductionPlaybackRefill.Waiter()
                waiter.install(continuation)
                refill.register(waiter, bufferedSeconds: 1)
                refill.cancel(waiter)
                #expect(refill.pendingCount == 0)
                refill.consumed(bufferedSeconds: 0)
            }
        }
        let released = try await withCheckedThrowingContinuation { continuation in
            let waiter = ProductionPlaybackRefill.Waiter()
            waiter.install(continuation)
            refill.register(waiter, bufferedSeconds: 0.1)
        }
        #expect(released == nil)
    }

    @Test func stopReleasesAllWaitersWithTheOriginalFailure() async throws {
        enum Failure: Error { case deadline }
        let refill = ProductionPlaybackRefill()
        await #expect(throws: Failure.deadline) {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = ProductionPlaybackRefill.Waiter()
                waiter.install(continuation)
                refill.register(waiter, bufferedSeconds: 1)
                refill.stop(throwing: Failure.deadline)
                #expect(refill.pendingCount == 0)
                refill.cancel(waiter)
            }
        }
    }
}
