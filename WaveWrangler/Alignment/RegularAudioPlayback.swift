import Foundation
import Synchronization
import WWAlignPipeline
import WWCore
import WWMix

/// Cached diagnostic listening with independent raw preparation and bounded device scheduling.
final class RegularAudioPlayback: Sendable {
    private static let schedulingBlockFrames: Int64 = 2048

    private struct State {
        var enabled: Set<SourceID>
        var inputGains: [RecordingInputGain]
        var unavailable: [SourceID: String] = [:]
        var preparedFirstWindow = false
        var prepared: Set<SourceID> = []
        var cycle: Range<Int64>?
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
    private let presentation: AudioTimelineProjection?
    private let initialSources: [SourceID]
    private let availableSources: [SourceID]
    private let meterReferences: [SpeakerID: Set<ChannelReference>]
    private let state: Mutex<State>
    private let canceled = Atomic<Bool>(false)

    init(runtime: AlignmentRuntime, model: ShowDocumentModel, episode: Episode,
         output: AlignmentAudioPlayback, sources: [SourceID], availableSources: [SourceID],
         applyingCuts: Bool, revealingCut: UUID?,
         timebase: AlignmentRuntime.AuditionTimebase = .acceptedTimeline,
         presentation: AudioTimelineProjection? = nil) {
        self.runtime = runtime
        self.model = model
        self.episode = episode.id
        self.output = output
        outputGeneration = output.generation
        media = EpisodeMediaInputs(episode)
        self.initialSources = sources
        self.availableSources = availableSources
        meterReferences = Dictionary(uniqueKeysWithValues: episode.speakerAssignments.map { assignment in
            (assignment.speakerID, Set(assignment.primary.map { [$0] } ?? []).union(assignment.backups))
        })
        self.applyingCuts = applyingCuts
        self.revealingCut = revealingCut
        self.timebase = timebase
        self.presentation = presentation
        state = Mutex(State(enabled: Set(sources), inputGains: episode.mix?.inputGains ?? []))
    }

    var unavailable: [SourceID: String] { state.withLock { $0.unavailable } }
    func setEnabled(_ sources: [SourceID]) { state.withLock { $0.enabled = Set(sources) } }
    func setCycle(_ frames: Range<Int64>?) { state.withLock { $0.cycle = frames } }
    func invalidate(_ error: any Error) {
        state.withLock { $0.failure = error }
        output.stop(ifCurrent: outputGeneration, preservingClock: true)
    }
    func cancel() { canceled.store(true, ordering: .releasing) }

    func documentDidChange(_ updated: ShowDocumentModel) {
        guard !canceled.load(ordering: .acquiring) else { return }
        guard let current = updated.episode(episode),
              EpisodeMediaInputs(current) == media,
              current.activeManualCuts == model.episode(episode)?.activeManualCuts else {
            state.withLock { $0.failure = MixerFailure.staleDependencies }
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            return
        }
        if presentation != nil,
           current.audioArrangement?.insertionRegions != model.episode(episode)?.audioArrangement?.insertionRegions {
            state.withLock { $0.failure = MixerFailure.staleDependencies }
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            return
        }
        state.withLock { $0.inputGains = current.mix?.inputGains ?? [] }
        do { try applyGains() }
        catch {
            state.withLock { $0.failure = error }
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
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
        try output.setRecordingInputGains(state.withLock { $0.inputGains }, generation: outputGeneration)
        try output.setGains(AlignmentTransportSelection.gains(prepared: ready, enabled: Array(enabled)),
            generation: outputGeneration)
    }

    @concurrent
    func play(schedule initial: AlignedAuditionSchedule,
              bounds: Range<Int64>? = nil, repeatWhile: (@MainActor @Sendable () -> Bool)? = nil,
              onSourcesJoined: @escaping @MainActor @Sendable () -> Void,
              onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        do {
            try await run(schedule: initial, bounds: bounds ?? initial.firstFrame..<initial.endFrame,
                repeatWhile: repeatWhile, onSourcesJoined: onSourcesJoined, onBufferDeadline: onBufferDeadline)
        } catch {
            output.stop(ifCurrent: outputGeneration, preservingClock: true)
            throw error
        }
    }

    @concurrent
    private func run(schedule initial: AlignedAuditionSchedule,
                     bounds: Range<Int64>, repeatWhile: (@MainActor @Sendable () -> Bool)?,
                     onSourcesJoined: @escaping @MainActor @Sendable () -> Void,
                     onBufferDeadline: @escaping @MainActor @Sendable () -> Void) async throws {
        var startup = initial
        guard let firstWindow = startup.next(), bounds.contains(initial.firstFrame),
              bounds.upperBound == initial.endFrame else { throw WaveformWindowError.invalidWindow }
        let width = Int64(firstWindow.count)
        let cache = SourceCyclePCMCache(bounds: bounds, width: width) { [self] sources, frames in
            try check()
            return try await runtime.sourceAuditions(model: model, episode: episode,
                sources: sources, outputFrames: frames, applyingCuts: applyingCuts, revealingCut: revealingCut,
                applyingInputGain: false, timebase: timebase, presentation: presentation)
        }
        func queueEnd(at frame: Int64) -> Int64 {
            state.withLock { $0.cycle.flatMap { frame < $0.upperBound ? $0.upperBound : nil } ?? bounds.upperBound }
        }
        func makeQueue(from frame: Int64, to end: Int64) -> PlaybackPCMQueue<SourcePCMWindow> {
            PlaybackPCMQueue(frames: frame..<end, diagnostics: ProductionPlaybackDiagnostics(),
                initialWindowFrames: width, windowFrames: AlignedAuditionSchedule.followingFrames,
                capacity: Int(ceil(initial.maximumBufferedSeconds / 0.5)), readyWindows: 1,
                prepare: { [self] frames in
                    var requested = state.withLock { state in
                        let sources = state.preparedFirstWindow || state.cycle != nil ? availableSources : initialSources
                        return sources.filter { state.unavailable[$0] == nil }
                    }
                    while true {
                        do {
                            let window = try await cache.window(frames, sources: requested,
                                retaining: state.withLock { $0.cycle })
                            state.withLock {
                                $0.preparedFirstWindow = true
                                $0.prepared.formUnion(requested)
                            }
                            return window
                        } catch let error as AlignmentRuntime.AuditionSourceFailure {
                            let required = state.withLock { $0.enabled.contains(error.source) && $0.prepared.contains(error.source) }
                            guard requested.contains(error.source),
                                  !required && (!initialSources.contains(error.source)
                                    || !state.withLock({ $0.enabled.contains(error.source) })) else { throw error }
                            state.withLock { $0.unavailable[error.source] = error.reason }
                            requested.removeAll { $0 == error.source }
                            guard !requested.isEmpty else { throw error }
                        }
                    }
                }, failed: { [self] error in state.withLock { $0.failure = error } })
        }
        var queuedEnd = queueEnd(at: initial.firstFrame)
        var queue = makeQueue(from: initial.firstFrame, to: queuedEnd)
        await queue.start()
        var validation: Task<Void, Never>?
        do {
            try await queue.waitUntilReady()
            validation = Task { [self] in
                do {
                    while true {
                        try await Task.sleep(for: .milliseconds(250))
                        try check()
                        let requested = state.withLock { Array($0.prepared.subtracting($0.unavailable.keys)) }
                        do {
                            try await runtime.validateSourceAudition(model: model, episode: episode,
                                sources: requested, timebase: timebase)
                        } catch let error as AlignmentRuntime.AuditionSourceFailure {
                            guard !state.withLock({ $0.enabled.contains(error.source) }) else { throw error }
                            state.withLock { $0.unavailable[error.source] = error.reason }
                            try output.excludeSource(error.source, generation: outputGeneration)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    state.withLock { $0.failure = error }
                    output.stop(ifCurrent: outputGeneration, preservingClock: true)
                }
            }
            var cursor = PlaybackCycleCursor(frame: initial.firstFrame, end: initial.endFrame)
            var expected = cursor.frame
            var deviceFrame = cursor.frame
            var input: SourcePCMWindow?
            var first = true
            while true {
                try check()
                let cycle = state.withLock { $0.cycle }
                let prior = cursor.frame
                cursor.prepare(cycle: cycle)
                if cursor.frame < prior, let repeatWhile, !(await repeatWhile()) { break }
                guard cursor.frame < cursor.end else { break }
                if cursor.frame != expected || cursor.frame == queuedEnd {
                    await queue.stop()
                    queuedEnd = queueEnd(at: cursor.frame)
                    queue = makeQueue(from: cursor.frame, to: queuedEnd)
                    input = nil
                    await queue.start()
                }
                if input == nil || cursor.frame == input?.frames.upperBound { input = try await queue.take() }
                guard let input, input.frames.contains(cursor.frame),
                      let frames = cursor.next(maximumFrames: min(Self.schedulingBlockFrames,
                          input.frames.upperBound - cursor.frame), cycle: cycle) else {
                    throw AlignmentTransportFailure.discontinuousWindow
                }
                let unavailable = self.unavailable
                for source in output.preparedSources where unavailable[source] != nil {
                    try output.excludeSource(source, generation: outputGeneration)
                }
                let slice = Int(frames.lowerBound - input.frames.lowerBound)..<Int(frames.upperBound - input.frames.lowerBound)
                let clips = input.clips.filter { unavailable[$0.key] == nil }.mapValues { original in
                    var clip = original
                    clip.samples = Array(original.samples[slice])
                    return clip
                }
                let meterSpeakers = meterReferences.mapValues { references in
                    Set(references.compactMap { reference -> SourceID? in
                        guard let clip = clips[reference.sourceID], let channel = clip.sourceChannel,
                              reference.resolvedChannel(channelCount: clip.sourceChannelCount) == channel else { return nil }
                        return reference.sourceID
                    })
                }
                try check()
                try output.enqueue(clips, startSeconds: Double(deviceFrame) / 48_000, first: first,
                    availableSources: Set(availableSources), final: false, generation: outputGeneration,
                    meterSpeakers: meterSpeakers, programFrame: frames.lowerBound,
                    onSourcesJoined: onSourcesJoined, onBufferDeadline: onBufferDeadline)
                first = false
                try applyGains()
                deviceFrame += Int64(frames.count)
                expected = frames.upperBound
                while output.bufferedSeconds >= Double(MixerLiveTiming.maximumScheduledAheadFrames) / 48_000 {
                    try check()
                    try applyGains()
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try output.finishProduction(generation: outputGeneration)
            while !output.isFinished {
                try check()
                try applyGains()
                try await Task.sleep(for: .milliseconds(5))
            }
            validation?.cancel()
            await validation?.value
            await queue.stop()
        } catch {
            validation?.cancel()
            await validation?.value
            await queue.stop()
            throw error
        }
    }
}
