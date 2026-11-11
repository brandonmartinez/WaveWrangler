import Foundation
import Synchronization
import WWCore
import WWMix

/// Only explicitly stopped transports enter this barrier; independent active consumers are untouched.
final class ProductionPlaybackRetirements: Sendable {
    private let pending = Mutex<[UUID: Task<Void, Never>]>([:])
    #if DEBUG
    private let beforeSnapshotForTesting: (@Sendable () async -> Void)?
    private let beforeJoiningForTesting: (@Sendable () throws -> Void)?

    init(beforeSnapshotForTesting: (@Sendable () async -> Void)? = nil,
         beforeJoiningForTesting: (@Sendable () throws -> Void)? = nil) {
        self.beforeSnapshotForTesting = beforeSnapshotForTesting
        self.beforeJoiningForTesting = beforeJoiningForTesting
    }
    #endif

    func retire(_ task: Task<Void, Never>) {
        task.cancel()
        let id = UUID()
        pending.withLock { $0[id] = task }
        Task { [self] in
            await task.value
            pending.withLock { $0[id] = nil }
        }
    }

    func wait() async throws {
        try Task.checkCancellation()
        #if DEBUG
        await beforeSnapshotForTesting?()
        #endif
        let tasks = pending.withLock { Array($0.values) }
        // A task can be retired between the first check and snapshotting itself.
        try Task.checkCancellation()
        for task in tasks {
            try Task.checkCancellation()
            #if DEBUG
            try beforeJoiningForTesting?()
            #endif
            await task.value
            try Task.checkCancellation()
        }
    }
}

protocol PlaybackPCMWindow: Sendable {
    var frames: Range<Int64> { get }
}

extension MixerPCMWindow: PlaybackPCMWindow {}
typealias ProductionPCMQueue = PlaybackPCMQueue<MixerPCMWindow>

/// One bounded raw-PCM producer. Prepared samples do not contain gains, effects, or faders.
actor PlaybackPCMQueue<Window: PlaybackPCMWindow> {
    enum WaitKind: Sendable, Equatable { case capacity, input, ready }

    private struct Waiter {
        let kind: WaitKind
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let end: Int64
    private let prepare: @Sendable (Range<Int64>) async throws -> Window
    private let failed: @Sendable (any Error) -> Void
    private let diagnostics: ProductionPlaybackDiagnostics
    private var nextFrame: Int64
    private var windows: [Window] = []
    private let initialWindowFrames: Int64
    private let windowFrames: Int64
    private let capacity: Int
    private let readyWindows: Int
    private let firstFrame: Int64
    private var producer: Task<Void, Never>?
    private var finished = false
    private var stopped = false
    private var failure: (any Error)?
    private var waiters: [UUID: Waiter] = [:]

    #if DEBUG
    enum Event: Sendable, Equatable { case waiting(WaitKind), stopping }
    private var onEventForTesting: (@Sendable (Event) -> Void)?
    var pendingWaiterCountForTesting: Int { waiters.count }
    var hasProducerForTesting: Bool { producer != nil }
    func setObserverForTesting(_ observer: @escaping @Sendable (Event) -> Void) {
        onEventForTesting = observer
    }
    #endif

    init(frames: Range<Int64>, diagnostics: ProductionPlaybackDiagnostics,
         initialWindowFrames: Int64 = Int64(MixerLiveTiming.sourceWindowFrames),
         windowFrames: Int64 = Int64(MixerLiveTiming.sourceWindowFrames),
         capacity: Int = MixerLiveTiming.sourcePrefetchWindows, readyWindows: Int? = nil,
         prepare: @escaping @Sendable (Range<Int64>) async throws -> Window,
         failed: @escaping @Sendable (any Error) -> Void) {
        firstFrame = frames.lowerBound
        nextFrame = frames.lowerBound
        end = frames.upperBound
        self.prepare = prepare
        self.failed = failed
        self.diagnostics = diagnostics
        self.initialWindowFrames = initialWindowFrames
        self.windowFrames = windowFrames
        self.capacity = capacity
        self.readyWindows = readyWindows ?? capacity
    }

    func start() {
        guard producer == nil, !finished, !stopped else { return }
        producer = Task { await fill() }
    }

    private func fill() async {
        defer {
            finished = true
            signal()
        }
        do {
            while nextFrame < end {
                try Task.checkCancellation()
                if windows.count >= capacity {
                    try await wait(for: .capacity)
                    continue
                }
                let width = nextFrame == firstFrame ? initialWindowFrames : windowFrames
                let frames = nextFrame..<min(end, nextFrame + width)
                let window = try await diagnostics.measureAsync(.source) { [prepare] in try await prepare(frames) }
                try Task.checkCancellation()
                guard window.frames == frames else { throw MixerFailure.discontinuousPCM }
                windows.append(window)
                diagnostics.preparedRawWindow(queued: windows.count)
                nextFrame = frames.upperBound
                signal(.input)
                if windows.count >= readyWindows { signal(.ready) }
            }
        } catch {
            // Explicit stop cancels the producer; it is not a source failure.
            if !stopped {
                failure = error
                failed(error)
            }
        }
    }

    func take() async throws -> Window? {
        while true {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            if let failure { throw failure }
            if !windows.isEmpty {
                let window = windows.removeFirst()
                diagnostics.rawQueueChanged(count: windows.count)
                signal(.capacity)
                return window
            }
            if finished { return nil }
            try await wait(for: .input)
        }
    }

    func waitUntilReady() async throws {
        while true {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            if let failure { throw failure }
            if finished || windows.count >= readyWindows { return }
            try await wait(for: .ready)
        }
    }

    private func needsWait(_ kind: WaitKind) -> Bool {
        guard !stopped, !finished, failure == nil else { return false }
        switch kind {
        case .capacity: return windows.count >= capacity
        case .input: return windows.isEmpty
        case .ready: return windows.count < readyWindows
        }
    }

    private func wait(for kind: WaitKind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Predicate and registration share this actor turn, including cancellation-before-registration.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !needsWait(kind) {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(kind: kind, continuation: continuation)
                    #if DEBUG
                    onEventForTesting?(.waiting(kind))
                    #endif
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func signal(_ kind: WaitKind? = nil) {
        let ids = waiters.compactMap { id, waiter in kind == nil || waiter.kind == kind ? id : nil }
        for id in ids {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func stop() async {
        stopped = true
        let pending = producer
        pending?.cancel()
        windows.removeAll()
        diagnostics.rawQueueChanged(count: 0)
        signal()
        #if DEBUG
        onEventForTesting?(.stopping)
        #endif
        // Keep the handle published while joining: concurrent stops must join the same preparation.
        await pending?.value
        producer = nil
        finished = true
    }
}

/// Only value snapshots cross from UI controls to the serial DSP producer. No main-actor hop is
/// required to render, refill, or pace a block; UI meters consume summaries on the playback clock.
final class ProductionMixPlayback: Sendable {
    private struct State {
        var controls: MixerLiveControls
        var metering = MixerConsoleMetering()
        var failure: (any Error)?
        var cycle: Range<Int64>?
    }

    let processor: MixerProcessor
    private let runtime: AlignmentRuntime
    private let model: ShowDocumentModel
    private let outputGeneration: UInt64
    private let state: Mutex<State>
    private let canceled = Atomic<Bool>(false)
    private let diagnostics: ProductionPlaybackDiagnostics

    #if DEBUG
    var diagnosticsForTesting: ProductionPlaybackDiagnostics { diagnostics }
    #endif

    init(processor: MixerProcessor, runtime: AlignmentRuntime, model: ShowDocumentModel,
         controls: MixerLiveControls, outputGeneration: UInt64) {
        self.processor = processor
        self.runtime = runtime
        self.model = model
        self.outputGeneration = outputGeneration
        diagnostics = ProductionPlaybackDiagnostics(processor: processor.diagnostics)
        state = Mutex(State(controls: controls))
    }

    func meterSnapshot(through frame: Int64) -> MixerConsoleSnapshot {
        state.withLock { $0.metering.read(through: frame) }
    }
    func resetMeterPeaks(for bus: MixerBusAddress) {
        state.withLock { $0.metering.resetPeaks(for: bus) }
    }
    func setControls(_ controls: MixerLiveControls) { state.withLock { $0.controls = controls } }
    func setCycleRange(_ frames: Range<Int64>?) { state.withLock { $0.cycle = frames } }
    func cancel() { canceled.store(true, ordering: .releasing) }
    func invalidate(_ error: any Error) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure = state.withLock({ $0.failure }) { throw failure }
        if canceled.load(ordering: .acquiring) { throw CancellationError() }
    }

    @concurrent
    func play(output: AlignmentAudioPlayback, startFrame: Int64? = nil,
              onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        try check()
        try await runtime.withProductionConsumer(recipe: processor.recipe, model: model) { [self] consumer in
            try check()
            try await playPrepared(consumer: consumer, output: output, startFrame: startFrame,
                                   onBufferDeadline: onBufferDeadline)
        }
    }

    private func playPrepared(consumer: SupplementalClipConsumer, output: AlignmentAudioPlayback, startFrame: Int64?,
                              onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        let recipe = processor.recipe
        let first = (startFrame ?? recipe.programFrames.lowerBound) - Int64(recipe.policy.prerollFrames)
        let inputFrames = (recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames))..<recipe.programFrames.upperBound
        let cache = ProductionCyclePCMCache(bounds: inputFrames) { [self] frames in
            try check()
            guard output.generation == outputGeneration else { throw CancellationError() }
            return try await runtime.productionPCM(recipe: recipe, model: model, frames: frames, consumer: consumer)
        }
        func queueEnd(at frame: Int64) -> Int64 {
            state.withLock { state in
                state.cycle.map { frame < $0.upperBound ? $0.upperBound : inputFrames.upperBound } ?? inputFrames.upperBound
            }
        }
        func makeQueue(from frame: Int64, to end: Int64) -> ProductionPCMQueue {
            ProductionPCMQueue(frames: frame..<end, diagnostics: diagnostics, prepare: { [self] frames in
                try await cache.window(frames, retaining: state.withLock { $0.cycle })
            }, failed: { [self] in invalidate($0) })
        }
        var queuedEnd = queueEnd(at: first)
        var queue = makeQueue(from: first, to: queuedEnd)
        await queue.start()
        var validation: Task<Void, Never>?
        do {
            try await queue.waitUntilReady()
            try await validate(recipe: recipe)
            try check()
            // Bookmark/File Provider and full-map verification can exceed the processed horizon.
            // Keep checking even after the whole program is prefetched, without blocking live DSP.
            validation = Task { [self] in
                do {
                    while true {
                        try await Task.sleep(for: .milliseconds(250))
                        try check()
                        try await validate(recipe: recipe)
                    }
                } catch is CancellationError {
                } catch {
                    invalidate(error)
                }
            }
            try await processor.beginPlaybackPass(at: first)
            var cursor = PlaybackCycleCursor(frame: first, end: inputFrames.upperBound)
            var expectedInput = first
            var virtualInput = first
            var input: MixerPCMWindow?
            var segments: [PlaybackProgramTimeline.Segment] = [.init(playbackFrame: first, programFrame: first)]
            while true {
                try check()
                let cycle = state.withLock { $0.cycle }
                cursor.prepare(cycle: cycle)
                guard cursor.frame < cursor.end else { break }
                if cursor.frame != expectedInput || cursor.frame == queuedEnd {
                    await queue.stop()
                    queuedEnd = queueEnd(at: cursor.frame)
                    queue = makeQueue(from: cursor.frame, to: queuedEnd)
                    input = nil
                    await queue.start()
                    if cursor.frame != expectedInput {
                        try await processor.beginPlaybackPass(at: cursor.frame)
                        segments.append(.init(playbackFrame: virtualInput, programFrame: cursor.frame))
                    }
                }
                if input == nil || cursor.frame == input?.frames.upperBound {
                    let activeQueue = queue
                    input = try await diagnostics.measureAsync(.sourceWait) { try await activeQueue.take() }
                }
                guard let input, input.frames.contains(cursor.frame),
                      let frames = cursor.next(maximumFrames: min(Int64(MixerLiveTiming.processingBlockFrames),
                          input.frames.upperBound - cursor.frame), cycle: cycle) else {
                    throw MixerFailure.discontinuousPCM
                }
                if let failure = output.failure { throw failure }
                let lower = Int(frames.lowerBound - input.frames.lowerBound)
                let channels = input.channels.mapValues { Array($0[lower..<(lower + frames.count)]) }
                let tracks = input.audioTracks.mapValues {
                    $0.map { Array($0[lower..<(lower + frames.count)]) }
                }
                try await synchronizeControls()
                let block = MixerPCMWindow(frames: frames, channels: channels, audioTracks: tracks)
                let rendered = try await diagnostics.measureAsync(.dsp) { [processor] in
                    try await processor.process(block, submittedAt: .now)
                }
                state.withLock { $0.metering.append(rendered) }
                let final = frames.upperBound == recipe.programFrames.upperBound
                    && cycle?.upperBound != frames.upperBound && processor.latencyFrames == 0 && processor.tailFrames == 0
                if rendered.frameCount > 0 {
                    try enqueue(rendered, final: final, output: output, programSegments: segments,
                                onBufferDeadline: onBufferDeadline)
                    segments.removeAll(keepingCapacity: true)
                }
                virtualInput += Int64(frames.count)
                expectedInput = frames.upperBound
                try await pace(output)
            }
            while true {
                try check()
                try await synchronizeControls()
                guard let rendered = try await diagnostics.measureAsync(.dsp, operation: { [processor] in
                    try await processor.finishNext(maximumFrames: MixerLiveTiming.processingBlockFrames, submittedAt: .now)
                }) else { break }
                state.withLock { $0.metering.append(rendered) }
                let final = rendered.firstFrame + Int64(rendered.frameCount)
                    == virtualInput + Int64(processor.tailFrames)
                if rendered.frameCount > 0 {
                    try enqueue(rendered, final: final, output: output, onBufferDeadline: onBufferDeadline)
                }
                try await pace(output)
            }
            try output.finishProduction(generation: outputGeneration)
            while !output.isFinished {
                try check()
                if let failure = output.failure { throw failure }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await validate(recipe: recipe)
            try check()
            validation?.cancel()
            await validation?.value
            await queue.stop()
        } catch {
            validation?.cancel()
            await validation?.value
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            await queue.stop()
            throw error
        }
    }

    private func validate(recipe: MixerRecipe) async throws {
        try await diagnostics.measureAsync(.validation) { [self] in
            try await runtime.validateProduction(recipe: recipe, model: model)
        }
    }

    private func synchronizeControls() async throws {
        let controls = state.withLock { $0.controls }
        try await diagnostics.measureAsync(.controls) { [processor] in
            try await processor.setLiveControls(controls, submittedAt: .now)
        }
    }

    private func enqueue(_ rendered: MixerPCMOutput, final: Bool, output: AlignmentAudioPlayback,
                         programSegments: [PlaybackProgramTimeline.Segment] = [],
                         onBufferDeadline: @escaping @MainActor @Sendable () -> Void) throws {
        try diagnostics.measure(.enqueue) {
            try output.enqueueProduction(rendered, final: final, generation: outputGeneration,
                diagnostics: diagnostics, programSegments: programSegments, onBufferDeadline: onBufferDeadline)
        }
    }

    private func pace(_ output: AlignmentAudioPlayback) async throws {
        try check()
        if let released = try await diagnostics.measureAsync(.refillWait, operation: { [outputGeneration] in
            try await output.waitForProductionCapacity(generation: outputGeneration)
        }) {
            diagnostics.recordWakeDelay(since: released, requested: .zero)
        }
        try check()
    }
}
