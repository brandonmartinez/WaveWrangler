import Foundation
import Synchronization
import WWAlignPipeline
import WWCore
import WWMix

/// Shared-cache diagnostic listening. Decoder work, refill, gains, and source warmup never await UI.
final class RegularAudioPlayback: Sendable {
    private struct Warm: Sendable {
        let source: SourceID
        let frames: Range<Int64>
    }

    private struct State {
        var enabled: Set<SourceID>
        var unavailable: [SourceID: String] = [:]
        var warm: Warm?
        var warming: SourceID?
        var failure: (any Error)?
    }

    private let runtime: AlignmentRuntime
    private let model: ShowDocumentModel
    private let episode: EpisodeID
    private let output: AlignmentAudioPlayback
    private let outputGeneration: UInt64
    private let media: EpisodeMediaInputs
    private let applyingCuts: Bool
    private let revealingCut: UUID?
    private let timebase: AlignmentRuntime.AuditionTimebase
    private let initialSources: [SourceID]
    private let availableSources: [SourceID]
    private let state: Mutex<State>
    private let canceled = Atomic<Bool>(false)

    init(runtime: AlignmentRuntime, model: ShowDocumentModel, episode: Episode,
         output: AlignmentAudioPlayback, sources: [SourceID], availableSources: [SourceID],
         applyingCuts: Bool, revealingCut: UUID?,
         timebase: AlignmentRuntime.AuditionTimebase = .acceptedTimeline) {
        self.runtime = runtime
        self.model = model
        self.episode = episode.id
        self.output = output
        outputGeneration = output.generation
        media = EpisodeMediaInputs(episode)
        self.initialSources = sources
        self.availableSources = availableSources
        self.applyingCuts = applyingCuts
        self.revealingCut = revealingCut
        self.timebase = timebase
        state = Mutex(State(enabled: Set(sources)))
    }

    var unavailable: [SourceID: String] { state.withLock { $0.unavailable } }
    func setEnabled(_ sources: [SourceID]) { state.withLock { $0.enabled = Set(sources) } }
    func cancel() { canceled.store(true, ordering: .releasing) }

    func documentDidChange(_ updated: ShowDocumentModel) {
        guard !canceled.load(ordering: .acquiring) else { return }
        guard let current = updated.episode(episode),
              EpisodeMediaInputs(current) == media,
              current.activeManualCuts == model.episode(episode)?.activeManualCuts,
              current.mix?.inputGains == model.episode(episode)?.mix?.inputGains else {
            state.withLock { $0.failure = MixerFailure.staleDependencies }
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            return
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure = state.withLock({ $0.failure }) { throw failure }
        if canceled.load(ordering: .acquiring) { throw CancellationError() }
        guard output.generation == outputGeneration else { throw CancellationError() }
        if let failure = output.failure { throw failure }
    }

    private func applyGains() throws {
        let enabled = state.withLock { $0.enabled.subtracting($0.unavailable.keys) }
        let ready = output.preparedSources.subtracting(output.pendingSources)
        try output.setGains(AlignmentTransportSelection.gains(prepared: ready, enabled: Array(enabled)),
            generation: outputGeneration)
    }

    @concurrent
    func play(schedule initial: AlignedAuditionSchedule,
              onSourcesJoined: @escaping @MainActor @Sendable () -> Void,
              onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        do {
            try await run(schedule: initial, onSourcesJoined: onSourcesJoined, onBufferDeadline: onBufferDeadline)
        } catch {
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            throw error
        }
    }

    @concurrent
    private func run(schedule initial: AlignedAuditionSchedule,
                     onSourcesJoined: @escaping @MainActor @Sendable () -> Void,
                     onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        var schedule = initial
        var prepared = initialSources
        var warmed: Set<SourceID> = []
        var warmingTask: Task<Void, Never>?
        defer { warmingTask?.cancel() }
        var first = true
        while let frames = schedule.next() {
            try check()
            var joining: SourceID?
            if let warm = state.withLock({ $0.warm }) {
                warmed.insert(warm.source)
                let enabled = state.withLock { $0.enabled.contains(warm.source) }
                if enabled, warm.frames.lowerBound <= frames.lowerBound, warm.frames.upperBound >= frames.upperBound {
                    joining = warm.source
                    state.withLock { $0.warm = nil }
                    warmingTask = nil
                } else if !enabled || warm.frames.upperBound < frames.upperBound {
                    state.withLock { $0.warm = nil }
                    warmingTask = nil
                }
            }
            if state.withLock({ $0.warming == nil && $0.warm == nil }) { warmingTask = nil }
            var requested = prepared + (joining.map { [$0] } ?? [])
            let clips: [SourceID: AlignmentAudioClip]
            while true {
                do {
                    clips = try await runtime.sourceAuditions(model: model, episode: episode,
                        sources: requested, outputFrames: frames, applyingCuts: applyingCuts, revealingCut: revealingCut,
                        timebase: timebase)
                    prepared = requested
                    break
                } catch let error as AlignmentRuntime.AuditionSourceFailure {
                    let enabled = state.withLock { $0.enabled.contains(error.source) }
                    guard requested.contains(error.source), error.source == joining || !enabled else { throw error }
                    state.withLock { $0.unavailable[error.source] = error.reason }
                    try output.excludeSource(error.source, generation: outputGeneration)
                    requested.removeAll { $0 == error.source }
                    guard !requested.isEmpty else { throw error }
                }
            }
            try check()
            try output.enqueue(clips, startSeconds: Double(frames.lowerBound) / 48_000, first: first,
                availableSources: Set(availableSources), final: frames.upperBound == schedule.endFrame,
                generation: outputGeneration,
                onSourcesJoined: onSourcesJoined, onBufferDeadline: onBufferDeadline)
            first = false
            try applyGains()
            if warmingTask == nil, state.withLock({ $0.warm == nil }), schedule.nextFrame < schedule.endFrame,
               output.bufferedSeconds >= schedule.maximumBufferedSeconds / 2 {
                let enabled = state.withLock { $0.enabled }
                let unavailable = self.unavailable
                let candidates = availableSources.filter {
                    !prepared.contains($0) && unavailable[$0] == nil && (!warmed.contains($0) || enabled.contains($0))
                }
                let start = schedule.nextFrame + AlignedAuditionSchedule.followingFrames
                if let source = candidates.first(where: { enabled.contains($0) }) ?? candidates.first,
                   start < schedule.endFrame {
                    let range = start..<min(schedule.endFrame, start + AlignedAuditionSchedule.initialFrames)
                    state.withLock { $0.warming = source }
                    warmingTask = Task { [self] in
                        do {
                            _ = try await runtime.sourceAuditions(model: model, episode: episode,
                                sources: [source], outputFrames: range, applyingCuts: applyingCuts, revealingCut: revealingCut,
                                timebase: timebase)
                            try Task.checkCancellation()
                            state.withLock { $0.warm = Warm(source: source, frames: range); $0.warming = nil }
                        } catch {
                            state.withLock {
                                $0.warming = nil
                                if !(error is CancellationError) { $0.unavailable[source] = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            while output.bufferedSeconds >= schedule.maximumBufferedSeconds {
                try check()
                try applyGains()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        while !output.isFinished {
            try check()
            try applyGains()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
