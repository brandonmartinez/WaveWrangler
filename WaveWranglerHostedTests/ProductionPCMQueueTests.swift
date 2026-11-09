import Foundation
import Synchronization
import Testing
import WWMix
@testable import WaveWrangler

/// No media or device access. Suspension events and gates establish ordering, not sleep thresholds.
@Suite("Production raw PCM queue", .timeLimit(.minutes(1)))
struct ProductionPCMQueueTests {
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private enum SourceFailure: Error, Equatable { case unavailable }

    private func makeQueue(
        frames: Range<Int64>,
        diagnostics: ProductionPlaybackDiagnostics = ProductionPlaybackDiagnostics(),
        prepare: @escaping @Sendable (Range<Int64>) async throws -> MixerPCMWindow = {
            MixerPCMWindow(frames: $0, channels: [:])
        },
        failed: @escaping @Sendable (any Error) -> Void = { error in
            Issue.record("Unexpected source failure: \(error)")
        }
    ) async -> (ProductionPCMQueue, AsyncStream<ProductionPCMQueue.Event>) {
        let queue = ProductionPCMQueue(frames: frames, diagnostics: diagnostics, prepare: prepare, failed: failed)
        let events = AsyncStream<ProductionPCMQueue.Event>.makeStream()
        await queue.setObserverForTesting { events.continuation.yield($0) }
        return (queue, events.stream)
    }

    @Test func boundedPrefetchResumesOnTakeAndPreservesOrderedFrameRanges() async throws {
        let size = Int64(MixerLiveTiming.sourceWindowFrames)
        let capacity = MixerLiveTiming.sourcePrefetchWindows
        let end = size * Int64(capacity + 1) + 17
        let prepared = Mutex<[Range<Int64>]>([])
        let diagnostics = ProductionPlaybackDiagnostics()
        let (queue, stream) = await makeQueue(frames: -3..<end, diagnostics: diagnostics, prepare: { frames in
            prepared.withLock { $0.append(frames) }
            return MixerPCMWindow(frames: frames, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        #expect(await events.next() == .waiting(.capacity))
        #expect(prepared.withLock { $0.count } == capacity)
        #expect(diagnostics.snapshot.queuedRawWindows == capacity)
        try await queue.waitUntilReady()
        let first = try await queue.take()
        #expect(first?.frames == -3..<(size - 3))
        #expect(await events.next() == .waiting(.capacity))
        #expect(prepared.withLock { $0.count } == capacity + 1)
        var next = size - 3
        while let window = try await queue.take() {
            #expect(window.frames.lowerBound == next)
            #expect(window.frames.count <= Int(size))
            next = window.frames.upperBound
        }
        #expect(next == end)
        #expect(diagnostics.snapshot.queuedRawWindows == 0)
        await queue.stop()
        #expect(await queue.pendingWaiterCountForTesting == 0)
    }

    @Test func emptyConsumerAndStartupWakeWhenFinalShortInputArrives() async throws {
        let release = Gate()
        let (queue, stream) = await makeQueue(frames: 0..<17, prepare: {
            await release.wait()
            return MixerPCMWindow(frames: $0, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        let consumer = Task { try await queue.take() }
        #expect(await events.next() == .waiting(.input))
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        await release.open()
        let window = try await consumer.value
        try await startup.value
        #expect(window?.frames == 0..<17)
        #expect(try await queue.take() == nil)
        await queue.stop()
        #expect(await queue.pendingWaiterCountForTesting == 0)
    }

    @Test func emptyProgramCompletesStartupAndConsumer() async throws {
        let (queue, _) = await makeQueue(frames: 9..<9)
        await queue.start()
        try await queue.waitUntilReady()
        #expect(try await queue.take() == nil)
        await queue.stop()
    }

    @Test func startupWaiterWakesAtCapacityBeforeProgramEnds() async throws {
        let release = Gate()
        let size = Int64(MixerLiveTiming.sourceWindowFrames)
        let diagnostics = ProductionPlaybackDiagnostics()
        let (queue, stream) = await makeQueue(frames: 0..<(size * 8), diagnostics: diagnostics, prepare: {
            await release.wait()
            return MixerPCMWindow(frames: $0, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        await release.open()
        try await startup.value
        #expect(await events.next() == .waiting(.capacity))
        #expect(diagnostics.snapshot.preparedRawWindows == MixerLiveTiming.sourcePrefetchWindows)
        await queue.stop()
        #expect(await queue.pendingWaiterCountForTesting == 0)
    }

    @Test func sourceFailureReleasesConsumerAndStartup() async {
        let release = Gate()
        let failures = Mutex(0)
        let (queue, stream) = await makeQueue(frames: 0..<17, prepare: { _ in
            await release.wait()
            throw SourceFailure.unavailable
        }, failed: { error in
            #expect(error as? SourceFailure == .unavailable)
            failures.withLock { $0 += 1 }
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        let consumer = Task { try await queue.take() }
        #expect(await events.next() == .waiting(.input))
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        await release.open()
        await #expect(throws: SourceFailure.unavailable) { try await consumer.value }
        await #expect(throws: SourceFailure.unavailable) { try await startup.value }
        await #expect(throws: SourceFailure.unavailable) { try await queue.take() }
        #expect(failures.withLock { $0 } == 1)
        await queue.stop()
        #expect(await queue.pendingWaiterCountForTesting == 0)
    }

    @Test func cancelingBlockedWaitersDoesNotCancelSharedProducer() async throws {
        let release = Gate()
        let (queue, stream) = await makeQueue(frames: 0..<17, prepare: {
            await release.wait()
            return MixerPCMWindow(frames: $0, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        let consumer = Task { try await queue.take() }
        #expect(await events.next() == .waiting(.input))
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        consumer.cancel()
        startup.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(await queue.pendingWaiterCountForTesting == 0)
        await release.open()
        try await queue.waitUntilReady()
        #expect(try await queue.take()?.frames == 0..<17)
        await queue.stop()
    }

    @Test func sourceFailureTakesPrecedenceOverAlreadyBufferedInput() async {
        let release = Gate()
        let size = Int64(MixerLiveTiming.sourceWindowFrames)
        let diagnostics = ProductionPlaybackDiagnostics()
        let (queue, stream) = await makeQueue(frames: 0..<(size * 2), diagnostics: diagnostics, prepare: { frames in
            if frames.lowerBound == 0 { return MixerPCMWindow(frames: frames, channels: [:]) }
            await release.wait()
            throw SourceFailure.unavailable
        }, failed: { error in
            #expect(error as? SourceFailure == .unavailable)
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        await release.open()
        await #expect(throws: SourceFailure.unavailable) { try await startup.value }
        #expect(diagnostics.snapshot.queuedRawWindows == 1)
        await #expect(throws: SourceFailure.unavailable) { try await queue.take() }
        await queue.stop()
    }

    @Test func discontinuousPreparedFramesFailWithoutPublishingInput() async {
        let diagnostics = ProductionPlaybackDiagnostics()
        let (queue, _) = await makeQueue(frames: 0..<17, diagnostics: diagnostics, prepare: { _ in
            MixerPCMWindow(frames: 1..<18, channels: [:])
        }, failed: { error in
            #expect(error as? MixerFailure == .discontinuousPCM)
        })
        await queue.start()
        await #expect(throws: MixerFailure.discontinuousPCM) { try await queue.waitUntilReady() }
        await #expect(throws: MixerFailure.discontinuousPCM) { try await queue.take() }
        #expect(diagnostics.snapshot.preparedRawWindows == 0)
        await queue.stop()
    }

    @Test func cancellationRacingInputArrivalCannotConsumeFramesOrLeakWaiters() async throws {
        let release = Gate()
        let (queue, stream) = await makeQueue(frames: 0..<17, prepare: {
            await release.wait()
            return MixerPCMWindow(frames: $0, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        let consumer = Task { try await queue.take() }
        #expect(await events.next() == .waiting(.input))
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        consumer.cancel()
        startup.cancel()
        await release.open()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        await #expect(throws: CancellationError.self) { try await startup.value }
        try await queue.waitUntilReady()
        #expect(try await queue.take()?.frames == 0..<17)
        #expect(try await queue.take() == nil)
        await queue.stop()
        #expect(await queue.pendingWaiterCountForTesting == 0)
    }

    @Test func alreadyCanceledWaitersRefuseEmptyAndFullQueue() async throws {
        for full in [false, true] {
            let size = Int64(MixerLiveTiming.sourceWindowFrames)
            let (queue, stream) = await makeQueue(frames: 0..<(size * 8))
            var events = stream.makeAsyncIterator()
            if full {
                await queue.start()
                #expect(await events.next() == .waiting(.capacity))
            }
            let release = Gate()
            let consumer = Task {
                await release.wait()
                return try await queue.take()
            }
            let startup = Task {
                await release.wait()
                try await queue.waitUntilReady()
            }
            consumer.cancel()
            startup.cancel()
            await release.open()
            await #expect(throws: CancellationError.self) { try await consumer.value }
            await #expect(throws: CancellationError.self) { try await startup.value }
            await queue.stop()
            #expect(await queue.pendingWaiterCountForTesting == 0)
        }
    }

    @Test func stopReleasesBackpressuredProducerAndCannotRestart() async {
        let prepared = Mutex(0)
        let diagnostics = ProductionPlaybackDiagnostics()
        let size = Int64(MixerLiveTiming.sourceWindowFrames)
        let (queue, stream) = await makeQueue(frames: 0..<(size * 8), diagnostics: diagnostics, prepare: {
            prepared.withLock { $0 += 1 }
            return MixerPCMWindow(frames: $0, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        #expect(await events.next() == .waiting(.capacity))
        await queue.stop()
        await queue.start()
        #expect(await queue.hasProducerForTesting == false)
        #expect(await queue.pendingWaiterCountForTesting == 0)
        #expect(diagnostics.snapshot.queuedRawWindows == 0)
        #expect(prepared.withLock { $0 } == MixerLiveTiming.sourcePrefetchWindows)
        await #expect(throws: CancellationError.self) { try await queue.take() }
        await #expect(throws: CancellationError.self) { try await queue.waitUntilReady() }
    }

    @Test func concurrentStopsJoinInFlightPreparationAndWakeEmptyWaiters() async {
        let entered = Gate(), release = Gate()
        let completedStops = Mutex(0)
        let diagnostics = ProductionPlaybackDiagnostics()
        let (queue, stream) = await makeQueue(frames: 0..<17, diagnostics: diagnostics, prepare: {
            await entered.open()
            await release.wait() // Deliberately noncooperative: stop must join, not abandon this source read.
            return MixerPCMWindow(frames: $0, channels: [:])
        })
        var events = stream.makeAsyncIterator()
        await queue.start()
        await entered.wait()
        let consumer = Task { try await queue.take() }
        #expect(await events.next() == .waiting(.input))
        let startup = Task { try await queue.waitUntilReady() }
        #expect(await events.next() == .waiting(.ready))
        let firstStop = Task {
            await queue.stop()
            completedStops.withLock { $0 += 1 }
        }
        #expect(await events.next() == .stopping)
        let secondStop = Task {
            await queue.stop()
            completedStops.withLock { $0 += 1 }
        }
        #expect(await events.next() == .stopping)
        #expect(completedStops.withLock { $0 } == 0)
        #expect(await queue.hasProducerForTesting)
        await #expect(throws: CancellationError.self) { try await consumer.value }
        await #expect(throws: CancellationError.self) { try await startup.value }
        await release.open()
        await firstStop.value
        await secondStop.value
        #expect(completedStops.withLock { $0 } == 2)
        #expect(await queue.hasProducerForTesting == false)
        #expect(await queue.pendingWaiterCountForTesting == 0)
        #expect(diagnostics.snapshot.preparedRawWindows == 0)
    }
}
