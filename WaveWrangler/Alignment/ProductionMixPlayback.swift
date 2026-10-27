import Foundation
import Synchronization
import WWCore
import WWMix

/// One bounded raw-PCM producer. Prepared samples do not contain gains, effects, or faders.
private actor ProductionPCMQueue {
    private let end: Int64
    private let prepare: @Sendable (Range<Int64>) async throws -> MixerPCMWindow
    private let failed: @Sendable (any Error) -> Void
    private var nextFrame: Int64
    private var windows: [MixerPCMWindow] = []
    private var producer: Task<Void, Never>?
    private var finished = false
    private var failure: (any Error)?

    init(frames: Range<Int64>, prepare: @escaping @Sendable (Range<Int64>) async throws -> MixerPCMWindow,
         failed: @escaping @Sendable (any Error) -> Void) {
        nextFrame = frames.lowerBound
        end = frames.upperBound
        self.prepare = prepare
        self.failed = failed
    }

    func start() {
        guard producer == nil else { return }
        producer = Task { await fill() }
    }

    private func fill() async {
        defer { finished = true }
        do {
            while nextFrame < end {
                try Task.checkCancellation()
                if windows.count >= MixerLiveTiming.sourcePrefetchWindows {
                    try await Task.sleep(for: .milliseconds(5))
                    continue
                }
                let frames = nextFrame..<min(end, nextFrame + Int64(MixerLiveTiming.sourceWindowFrames))
                let window = try await prepare(frames)
                try Task.checkCancellation()
                guard window.frames == frames else { throw MixerFailure.discontinuousPCM }
                windows.append(window)
                nextFrame = frames.upperBound
            }
        } catch {
            failure = error
            failed(error)
        }
    }

    func take() async throws -> MixerPCMWindow? {
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            if !windows.isEmpty { return windows.removeFirst() }
            if finished { return nil }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitUntilReady() async throws {
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            if finished || windows.count >= MixerLiveTiming.sourcePrefetchWindows { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func stop() {
        producer?.cancel()
        producer = nil
        windows.removeAll()
        finished = true
    }
}

/// Only value snapshots cross from UI controls to the serial DSP producer. No main-actor hop is
/// required to render, refill, or pace a block; UI meters read the latest snapshot independently.
final class ProductionMixPlayback: Sendable {
    private struct State {
        var controls: MixerLiveControls
        var output: MixerPCMOutput?
        var failure: (any Error)?
    }

    let processor: MixerProcessor
    private let runtime: AlignmentRuntime
    private let model: ShowDocumentModel
    private let outputGeneration: UInt64
    private let state: Mutex<State>
    private let canceled = Atomic<Bool>(false)

    init(processor: MixerProcessor, runtime: AlignmentRuntime, model: ShowDocumentModel,
         controls: MixerLiveControls, outputGeneration: UInt64) {
        self.processor = processor
        self.runtime = runtime
        self.model = model
        self.outputGeneration = outputGeneration
        state = Mutex(State(controls: controls))
    }

    var latestOutput: MixerPCMOutput? { state.withLock { $0.output } }
    func setControls(_ controls: MixerLiveControls) { state.withLock { $0.controls = controls } }
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
    func play(output: AlignmentAudioPlayback,
              onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        let recipe = processor.recipe
        let queue = ProductionPCMQueue(frames: recipe.programFrames, prepare: { [self] frames in
            try check()
            guard output.generation == outputGeneration else { throw CancellationError() }
            return try await runtime.productionPCM(recipe: recipe, model: model, frames: frames)
        }, failed: { [self] in invalidate($0) })
        await queue.start()
        var validation: Task<Void, Never>?
        do {
            try await queue.waitUntilReady()
            try await runtime.validateProduction(recipe: recipe, model: model)
            try check()
            // Bookmark/File Provider and full-map verification can exceed the processed horizon.
            // Keep checking even after the whole program is prefetched, without blocking live DSP.
            validation = Task { [self] in
                do {
                    while true {
                        try await Task.sleep(for: .milliseconds(250))
                        try check()
                        try await runtime.validateProduction(recipe: recipe, model: model)
                    }
                } catch is CancellationError {
                } catch {
                    invalidate(error)
                }
            }
            while let input = try await queue.take() {
                try check()
                var next = input.frames.lowerBound
                while next < input.frames.upperBound {
                    try check()
                    if let failure = output.failure { throw failure }
                    let end = min(input.frames.upperBound, next + Int64(MixerLiveTiming.processingBlockFrames))
                    let lower = Int(next - input.frames.lowerBound)
                    let channels = input.channels.mapValues { Array($0[lower..<(lower + Int(end - next))]) }
                    try await processor.setLiveControls(state.withLock { $0.controls })
                    let rendered = try await processor.process(.init(frames: next..<end, channels: channels))
                    state.withLock { $0.output = rendered }
                    let final = end == recipe.programFrames.upperBound && processor.latencyFrames == 0 && processor.tailFrames == 0
                    if rendered.frameCount > 0 {
                        try output.enqueueProduction(rendered, final: final, generation: outputGeneration,
                            onBufferDeadline: onBufferDeadline)
                    }
                    next = end
                    try await pace(output)
                }
            }
            while true {
                try check()
                try await processor.setLiveControls(state.withLock { $0.controls })
                guard let rendered = try await processor.finishNext(maximumFrames: MixerLiveTiming.processingBlockFrames) else { break }
                state.withLock { $0.output = rendered }
                let final = rendered.firstFrame + Int64(rendered.frameCount)
                    == recipe.programFrames.upperBound + Int64(processor.tailFrames)
                if rendered.frameCount > 0 {
                    try output.enqueueProduction(rendered, final: final, generation: outputGeneration,
                        onBufferDeadline: onBufferDeadline)
                }
                try await pace(output)
            }
            while !output.isFinished {
                try check()
                if let failure = output.failure { throw failure }
                try await Task.sleep(for: .milliseconds(5))
            }
            validation?.cancel()
            await queue.stop()
        } catch {
            validation?.cancel()
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            await queue.stop()
            throw error
        }
    }

    private func pace(_ output: AlignmentAudioPlayback) async throws {
        let horizon = Double(MixerLiveTiming.maximumScheduledAheadFrames) / Double(MixerRecipe.sampleRate)
        while output.bufferedSeconds > horizon {
            try check()
            if let failure = output.failure { throw failure }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
