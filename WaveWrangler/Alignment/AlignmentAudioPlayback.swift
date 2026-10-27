import AVFAudio
import Darwin
import Foundation
import Synchronization
import WWAlignPipeline
import WWCore
import WWMix

struct AlignmentAudioClip: Sendable {
    var sampleRate: Double
    var samples: [Float]
    var channelCount: Int = 1

    var duration: Double { Double(samples.count) / Double(channelCount) / sampleRate }

    func makeFormat() throws -> AVAudioFormat {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0,
              channelCount > 0, channelCount <= Int(AVAudioChannelCount.max),
              samples.count.isMultiple(of: channelCount),
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)
              )
        else { throw CocoaError(.fileReadCorruptFile) }
        return format
    }
}

struct AlignmentPlaybackClock: Sendable {
    let startSeconds: Double
    let duration: Double
    let startedAt: Date
    var audioPosition: Double? = nil
    var sampledAt: Date? = nil

    func playhead(at now: Date = Date()) -> Double {
        let elapsed = if let audioPosition, let sampledAt {
            audioPosition + max(0, now.timeIntervalSince(sampledAt))
        } else {
            now.timeIntervalSince(startedAt)
        }
        return startSeconds + min(max(0, elapsed), duration)
    }
}

enum AlignmentTransportFailure: LocalizedError, Sendable {
    case bufferDeadline
    case discontinuousWindow

    var errorDescription: String? {
        switch self {
        case .bufferDeadline:
            "Verified audio could not be prepared before the scheduled buffer ran out"
        case .discontinuousWindow:
            "The next audio window does not continue the shared transport clock"
        }
    }
}

struct AlignmentTransportSources {
    private(set) var starts: [SourceID: Double] = [:]
    var prepared: Set<SourceID> { Set(starts.keys) }

    mutating func schedule(_ sources: Set<SourceID>, startingAt seconds: Double) {
        for source in sources where starts[source] == nil { starts[source] = seconds }
    }

    mutating func remove(_ source: SourceID) {
        starts[source] = nil
    }

    func pending(at seconds: Double) -> Set<SourceID> {
        Set(starts.filter { $0.value > seconds }.keys)
    }
}

struct AlignmentProductionBuffer {
    private(set) var firstFrame: Int64?
    private(set) var endFrame: Int64?
    private(set) var frameCount: Int64 = 0
    private(set) var isFinal = false

    var isReady: Bool { isFinal || frameCount >= MixerLiveTiming.startupBufferedFrames }

    mutating func append(_ output: MixerPCMOutput, final: Bool) throws {
        guard output.frameCount > 0, !isFinal else { throw MixerFailure.incompletePCM }
        guard endFrame == nil || endFrame == output.firstFrame else {
            throw AlignmentTransportFailure.discontinuousWindow
        }
        let (end, overflow) = output.firstFrame.addingReportingOverflow(Int64(output.frameCount))
        let (count, countOverflow) = frameCount.addingReportingOverflow(Int64(output.frameCount))
        guard !overflow, !countOverflow else { throw MixerFailure.incompletePCM }
        firstFrame = firstFrame ?? output.firstFrame
        endFrame = end
        frameCount = count
        isFinal = final
    }
}

/// The graph has one serial owner; neither refill nor its audio-clock watchdog needs the UI actor.
final class AlignmentAudioPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wavewrangler.audio-output", qos: .userInitiated)
    private let graph: AlignmentAudioPlaybackGraph
    private var sessionGeneration: UInt64 = 0

    init() { graph = AlignmentAudioPlaybackGraph(queue: queue) }
    deinit { queue.sync { graph.stop() } }

    var clock: AlignmentPlaybackClock? { queue.sync { graph.readClock() } }
    var bufferedSeconds: Double { queue.sync { graph.bufferedSeconds } }
    var failure: AlignmentTransportFailure? { queue.sync { graph.failure } }
    var isFinished: Bool { queue.sync { graph.isFinished } }
    var generation: UInt64 { queue.sync { sessionGeneration } }
    var preparedSources: Set<SourceID> { queue.sync { graph.preparedSources } }
    var pendingSources: Set<SourceID> { queue.sync { graph.pendingSources } }

    func stop() { queue.sync { sessionGeneration &+= 1; graph.stop() } }
    func stop(ifCurrent generation: UInt64, preservingClock: Bool = false) {
        queue.sync {
            guard sessionGeneration == generation else { return }
            sessionGeneration &+= 1
            graph.stop(preservingClock: preservingClock)
        }
    }
    func setGains(_ gains: [SourceID: Float]) { queue.sync { graph.setGains(gains) } }
    func excludeSource(_ source: SourceID) { queue.sync { graph.excludeSource(source) } }
    func setGains(_ gains: [SourceID: Float], generation: UInt64) throws {
        try queue.sync {
            guard sessionGeneration == generation else { throw CancellationError() }
            graph.setGains(gains)
        }
    }
    func excludeSource(_ source: SourceID, generation: UInt64) throws {
        try queue.sync {
            guard sessionGeneration == generation else { throw CancellationError() }
            graph.excludeSource(source)
        }
    }
    func play(_ clip: AlignmentAudioClip, startSeconds: Double) throws {
        try queue.sync { try graph.play(clip, startSeconds: startSeconds) }
    }

    func enqueueProduction(_ output: MixerPCMOutput, final: Bool, generation: UInt64? = nil,
                           onBufferDeadline: @escaping @MainActor @Sendable () -> Void) throws {
        try queue.sync {
            if let generation, sessionGeneration != generation { throw CancellationError() }
            try graph.enqueueProduction(output, final: final, onBufferDeadline: onBufferDeadline)
        }
    }

    func enqueue(_ clips: [SourceID: AlignmentAudioClip], startSeconds: Double, first: Bool,
                 availableSources: Set<SourceID>, final: Bool, generation: UInt64? = nil,
                 onSourcesJoined: @escaping @MainActor @Sendable () -> Void,
                 onBufferDeadline: @escaping @MainActor @Sendable () -> Void) throws {
        try queue.sync {
            if let generation, sessionGeneration != generation { throw CancellationError() }
            try graph.enqueue(clips, startSeconds: startSeconds, first: first,
                availableSources: availableSources, final: final, onSourcesJoined: onSourcesJoined,
                onBufferDeadline: onBufferDeadline)
        }
    }

    static func validateProduction(_ output: MixerPCMOutput) throws -> AlignmentAudioClip {
        try AlignmentAudioPlaybackGraph.validateProduction(output)
    }
    static func validateTransport(_ clips: [SourceID: AlignmentAudioClip]) throws -> AlignmentAudioClip {
        try AlignmentAudioPlaybackGraph.validateTransport(clips)
    }
    static func validateAppend(to clock: AlignmentPlaybackClock, startSeconds: Double, playedSeconds: Double? = nil) throws {
        try AlignmentAudioPlaybackGraph.validateAppend(to: clock, startSeconds: startSeconds, playedSeconds: playedSeconds)
    }
}

/// Every mutable field and AVFAudio object is confined to the output queue, including timer events.
private final class PlaybackCompletion: Sendable {
    let remaining: Atomic<Int>
    init(_ count: Int) { remaining = Atomic(count) }
    func finish() { remaining.wrappingSubtract(1, ordering: .releasing) }
    var isFinished: Bool { remaining.load(ordering: .acquiring) == 0 }
}

private final class AlignmentAudioPlaybackGraph: @unchecked Sendable {
    private let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private var players: [SourceID: AVAudioPlayerNode] = [:]
    private var source: AVAudioSourceNode?
    private var productionPlayer: AVAudioPlayerNode?
    private var productionBuffer = AlignmentProductionBuffer()
    private var transportSampleRate: Double?
    private var transportHostTime: UInt64?
    private var monitor: DispatchSourceTimer?
    private var finalBuffer = true
    private var onDeadline: (@MainActor @Sendable () -> Void)?
    private(set) var failure: AlignmentTransportFailure?
    private var generation: UInt64 = 0
    private var completion = PlaybackCompletion(1)
    private var sourceJoinTasks: [SourceID: Task<Void, Never>] = [:]
    private var transportSources = AlignmentTransportSources()
    private(set) var clock: AlignmentPlaybackClock?
    var isFinished: Bool { finalBuffer && completion.isFinished }

    init(queue: DispatchQueue) { self.queue = queue }

    private var elapsedAudioSeconds: Double? {
        if let productionPlayer, let time = productionPlayer.lastRenderTime,
           let player = productionPlayer.playerTime(forNodeTime: time), player.isSampleTimeValid {
            return Double(player.sampleTime) / player.sampleRate
        }
        guard let clock,
              let entry = transportSources.starts.min(by: { $0.value < $1.value }),
              let node = players[entry.key], let time = node.lastRenderTime,
              let player = node.playerTime(forNodeTime: time), player.isSampleTimeValid else { return nil }
        return entry.value - clock.startSeconds + Double(player.sampleTime) / player.sampleRate
    }

    func readClock() -> AlignmentPlaybackClock? {
        if failure == nil, let prior = clock, let elapsed = elapsedAudioSeconds, elapsed >= 0 {
            clock = AlignmentPlaybackClock(startSeconds: prior.startSeconds, duration: prior.duration,
                startedAt: prior.startedAt, audioPosition: elapsed, sampledAt: Date())
        }
        return clock
    }

    var bufferedSeconds: Double {
        guard let clock else { return 0 }
        if let elapsed = elapsedAudioSeconds { return max(0, clock.duration - elapsed) }
        return max(0, clock.startedAt.addingTimeInterval(clock.duration).timeIntervalSinceNow)
    }

    var preparedSources: Set<SourceID> { transportSources.prepared }
    var pendingSources: Set<SourceID> {
        guard let clock = readClock() else { return [] }
        let playhead = clock.playhead()
        return transportSources.pending(at: playhead)
    }

    func stop(preservingClock: Bool = false) {
        let terminal: AlignmentPlaybackClock? = if preservingClock, let current = readClock() {
            AlignmentPlaybackClock(startSeconds: current.startSeconds,
                duration: max(0, current.playhead() - current.startSeconds), startedAt: current.startedAt)
        } else { nil }
        generation &+= 1
        monitor?.cancel()
        monitor = nil
        onDeadline = nil
        finalBuffer = true
        failure = nil
        completion = PlaybackCompletion(1)
        for task in sourceJoinTasks.values { task.cancel() }
        sourceJoinTasks.removeAll()
        for player in players.values {
            player.volume = 0
            player.stop()
        }
        engine.pause()
        if let productionPlayer {
            productionPlayer.stop()
            engine.detach(productionPlayer)
            self.productionPlayer = nil
        }
        if let source, engine.attachedNodes.contains(source) { engine.detach(source) }
        source = nil
        productionBuffer = AlignmentProductionBuffer()
        clock = terminal
        transportHostTime = nil
        transportSources = AlignmentTransportSources()
    }

    private func watch(final: Bool, deadline: @escaping @MainActor @Sendable () -> Void) {
        finalBuffer = final
        onDeadline = deadline
        guard monitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.checkDeadline() }
        monitor = timer
        timer.resume()
    }

    private func checkDeadline() {
        guard !finalBuffer, failure == nil, let scheduled = clock,
              let elapsed = elapsedAudioSeconds, elapsed >= scheduled.duration else { return }
        let callback = onDeadline
        let stopped = readClock()
        stop()
        clock = stopped
        failure = .bufferDeadline
        let stoppedGeneration = generation
        if let callback {
            Task { @MainActor [weak self] in
                callback()
                self?.clearTerminalClock(generation: stoppedGeneration)
            }
        }
    }

    private func clearTerminalClock(generation expected: UInt64) {
        queue.async { [weak self] in
            guard let self, self.generation == expected else { return }
            self.clock = nil
            self.failure = nil
        }
    }

    private func validateQueueAppend(startSeconds: Double) throws {
        if let failure { throw failure }
        guard let clock else { throw AlignmentTransportFailure.discontinuousWindow }
        try Self.validateAppend(to: clock, startSeconds: startSeconds, playedSeconds: elapsedAudioSeconds)
    }

    private func clearPlayers() {
        for player in players.values where engine.attachedNodes.contains(player) {
            engine.detach(player)
        }
        players.removeAll()
        transportSampleRate = nil
    }

    func play(_ clip: AlignmentAudioClip, startSeconds: Double) throws {
        stop()
        clearPlayers()
        let format = try clip.makeFormat()
        let cursor = AlignmentAudioSampleCursor(samples: clip.samples, channelCount: clip.channelCount)
        let node = cursor.makeSourceNode(format: format)
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        clock = AlignmentPlaybackClock(startSeconds: startSeconds, duration: clip.duration, startedAt: Date())
    }

    func setGains(_ gains: [SourceID: Float]) {
        for (source, player) in players { player.volume = gains[source] ?? 0 }
    }

    static func validateProduction(_ output: MixerPCMOutput) throws -> AlignmentAudioClip {
        guard output.channels.count == 2, output.frameCount > 0,
              output.frameCount <= MixerRecipe.maximumWindowFrames,
              output.channels.allSatisfy({ $0.count == output.frameCount && $0.allSatisfy(\.isFinite) }) else {
            throw MixerFailure.incompletePCM
        }
        return AlignmentAudioClip(sampleRate: Double(MixerRecipe.sampleRate),
            samples: output.channels.flatMap { $0 }, channelCount: 2)
    }

    /// Only pre-rendered stereo reaches the device graph. No vendor code or Swift task is called
    /// from the output callback; the serial mixer worker owns persistent effect state.
    func enqueueProduction(_ output: MixerPCMOutput, final: Bool,
                           onBufferDeadline: @escaping @MainActor @Sendable () -> Void) throws {
        if let failure { throw failure }
        let clip = try Self.validateProduction(output)
        let format = try clip.makeFormat()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(output.frameCount)),
              let data = buffer.floatChannelData else { throw MixerFailure.incompletePCM }
        buffer.frameLength = AVAudioFrameCount(output.frameCount)
        for channel in 0..<2 {
            output.channels[channel].withUnsafeBufferPointer {
                if let base = $0.baseAddress { data[channel].update(from: base, count: output.frameCount) }
            }
        }
        let start = Double(output.firstFrame) / Double(MixerRecipe.sampleRate)
        if productionPlayer == nil {
            stop()
            clearPlayers()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            productionPlayer = player
        }
        guard let productionPlayer else { throw MixerFailure.incompletePCM }
        var scheduled = productionBuffer
        try scheduled.append(output, final: final)
        if clock != nil { try validateQueueAppend(startSeconds: start) }
        if final {
            let finished = PlaybackCompletion(1)
            completion = finished
            productionPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in finished.finish() }
        } else {
            productionPlayer.scheduleBuffer(buffer)
        }
        productionBuffer = scheduled
        if clock == nil, scheduled.isReady, let first = scheduled.firstFrame {
            do { try engine.start() }
            catch { stop(); throw error }
            let lead = Double(MixerLiveTiming.startLeadFrames) / Double(MixerRecipe.sampleRate)
            productionPlayer.play(at: AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)))
            clock = AlignmentPlaybackClock(startSeconds: Double(first) / Double(MixerRecipe.sampleRate),
                duration: Double(scheduled.frameCount) / Double(MixerRecipe.sampleRate),
                startedAt: Date().addingTimeInterval(lead))
        } else if let clock {
            self.clock = AlignmentPlaybackClock(startSeconds: clock.startSeconds,
                duration: Double(scheduled.frameCount) / Double(MixerRecipe.sampleRate), startedAt: clock.startedAt)
        }
        if clock != nil { watch(final: final, deadline: onBufferDeadline) }
    }

    func excludeSource(_ source: SourceID) {
        sourceJoinTasks.removeValue(forKey: source)?.cancel()
        players[source]?.volume = 0
        players[source]?.stop()
        transportSources.remove(source)
    }

    static func validateTransport(_ clips: [SourceID: AlignmentAudioClip]) throws -> AlignmentAudioClip {
        guard let representative = clips.values.first, !representative.samples.isEmpty,
              representative.sampleRate.isFinite, representative.sampleRate > 0,
              representative.samples.count <= Int(AVAudioFrameCount.max),
              clips.values.allSatisfy({
                  $0.channelCount == 1 && $0.sampleRate == representative.sampleRate
                      && $0.samples.count == representative.samples.count
              })
        else { throw CocoaError(.fileReadCorruptFile) }
        return representative
    }

    static func validateAppend(
        to clock: AlignmentPlaybackClock, startSeconds: Double, playedSeconds: Double? = nil
    ) throws {
        guard startSeconds.isFinite,
              abs(startSeconds - clock.startSeconds - clock.duration) < 0.5 / 48_000 else {
            throw AlignmentTransportFailure.discontinuousWindow
        }
        if let playedSeconds {
            guard playedSeconds.isFinite, playedSeconds < clock.duration else {
                throw AlignmentTransportFailure.bufferDeadline
            }
        }
    }

    func enqueue(
        _ clips: [SourceID: AlignmentAudioClip], startSeconds: Double, first: Bool,
        availableSources: Set<SourceID>, final: Bool,
        onSourcesJoined: @escaping @MainActor @Sendable () -> Void,
        onBufferDeadline: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let representative = try Self.validateTransport(clips)
        let format = try representative.makeFormat()
        var buffers: [SourceID: AVAudioPCMBuffer] = [:]
        for (source, clip) in clips {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
                  let samples = buffer.floatChannelData?.pointee else {
                throw CocoaError(.fileReadCorruptFile)
            }
            buffer.frameLength = AVAudioFrameCount(clip.samples.count)
            clip.samples.withUnsafeBufferPointer { values in
                if let base = values.baseAddress { samples.update(from: base, count: values.count) }
            }
            buffers[source] = buffer
        }
        if first {
            stop()
            if Set(players.keys) != availableSources || transportSampleRate != representative.sampleRate {
                clearPlayers()
                for source in availableSources {
                    let player = AVAudioPlayerNode()
                    player.volume = 0
                    players[source] = player
                    engine.attach(player)
                    engine.connect(player, to: engine.mainMixerNode, format: format)
                }
            }
            do {
                try engine.start()
            } catch {
                stop()
                throw error
            }
            transportSampleRate = representative.sampleRate
        } else {
            guard let clock else { throw WaveformWindowError.invalidSamples }
            try validateQueueAppend(startSeconds: startSeconds)
        }
        guard Set(clips.keys).isSubset(of: Set(players.keys)),
              preparedSources.isSubset(of: Set(clips.keys)),
              transportSampleRate == representative.sampleRate, first || clock != nil else {
            throw WaveformWindowError.invalidSamples
        }
        if first {
            let lead = 0.1
            transportHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
            clock = AlignmentPlaybackClock(
                startSeconds: startSeconds, duration: representative.duration,
                startedAt: Date().addingTimeInterval(lead)
            )
        } else if let prior = clock {
            clock = AlignmentPlaybackClock(
                startSeconds: prior.startSeconds, duration: prior.duration + representative.duration,
                startedAt: prior.startedAt
            )
        }
        guard let clock, let transportHostTime else { throw WaveformWindowError.invalidSamples }
        let hostTime = transportHostTime + AVAudioTime.hostTime(forSeconds: max(0, startSeconds - clock.startSeconds))
        let start = AVAudioTime(hostTime: hostTime)
        let finished: PlaybackCompletion? = final ? PlaybackCompletion(buffers.count) : nil
        if let finished { completion = finished }
        for (source, buffer) in buffers {
            guard let player = players[source] else { throw WaveformWindowError.invalidSamples }
            if !transportSources.prepared.contains(source) {
                if let finished {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in finished.finish() }
                } else {
                    player.scheduleBuffer(buffer)
                }
                player.play(at: start)
                if !first {
                    let remaining = max(0, clock.startedAt.addingTimeInterval(startSeconds - clock.startSeconds).timeIntervalSinceNow)
                    sourceJoinTasks[source] = Task { @MainActor in
                        do { try await Task.sleep(for: .seconds(remaining)) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        onSourcesJoined()
                    }
                }
            } else {
                if let finished {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in finished.finish() }
                } else {
                    player.scheduleBuffer(buffer)
                }
            }
        }
        transportSources.schedule(Set(clips.keys), startingAt: startSeconds)
        watch(final: final, deadline: onBufferDeadline)
    }
}

/// Audio render callbacks run off the main actor; AVAudioSourceNode invokes this cursor serially.
final class AlignmentAudioSampleCursor: @unchecked Sendable {
    private let samples: [Float]
    private let channelCount: Int
    private var frameCount: Int { samples.count / channelCount }
    private var index = 0

    init(samples: [Float], channelCount: Int) {
        self.samples = samples
        self.channelCount = channelCount
    }

    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, output in
            render(frameCount: frameCount, output: output)
        }
    }

    func render(frameCount: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let count = Int(frameCount)
        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<count {
                data[frame] = channel < channelCount && index + frame < self.frameCount
                    ? samples[channel * self.frameCount + index + frame] : 0
            }
        }
        index = min(self.frameCount, index + count)
        return noErr
    }
}
