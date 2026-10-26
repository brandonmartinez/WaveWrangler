import AVFAudio
import Darwin
import Foundation
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

struct AlignmentPlaybackClock {
    let startSeconds: Double
    let duration: Double
    let startedAt: Date

    func playhead(at now: Date = Date()) -> Double {
        startSeconds + min(max(0, now.timeIntervalSince(startedAt)), duration)
    }
}

enum AlignmentTransportFailure: LocalizedError {
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

@MainActor
final class AlignmentAudioPlayback {
    private let engine = AVAudioEngine()
    private var players: [SourceID: AVAudioPlayerNode] = [:]
    private var source: AVAudioSourceNode?
    private var productionPlayer: AVAudioPlayerNode?
    private var transportSampleRate: Double?
    private var transportHostTime: UInt64?
    private var bufferDeadlineTask: Task<Void, Never>?
    private var sourceJoinTasks: [SourceID: Task<Void, Never>] = [:]
    private var transportSources = AlignmentTransportSources()
    private(set) var clock: AlignmentPlaybackClock?

    var preparedSources: Set<SourceID> { transportSources.prepared }
    var pendingSources: Set<SourceID> {
        guard let clock else { return [] }
        let playhead = clock.playhead()
        return transportSources.pending(at: playhead)
    }

    func stop() {
        bufferDeadlineTask?.cancel()
        bufferDeadlineTask = nil
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
        clock = nil
        transportHostTime = nil
        transportSources = AlignmentTransportSources()
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
                           onBufferDeadline: @escaping @MainActor () -> Void) throws {
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
            player.scheduleBuffer(buffer)
            do { try engine.start() }
            catch { stop(); throw error }
            let lead = 0.1
            player.play(at: AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)))
            clock = AlignmentPlaybackClock(startSeconds: start, duration: clip.duration,
                startedAt: Date().addingTimeInterval(lead))
        } else {
            guard let clock, let productionPlayer else { throw MixerFailure.discontinuousPCM }
            try Self.validateAppend(to: clock, startSeconds: start)
            productionPlayer.scheduleBuffer(buffer)
            self.clock = AlignmentPlaybackClock(startSeconds: clock.startSeconds,
                duration: clock.duration + clip.duration, startedAt: clock.startedAt)
        }
        bufferDeadlineTask?.cancel()
        bufferDeadlineTask = nil
        if !final, let clock {
            let remaining = max(0, clock.startedAt.addingTimeInterval(clock.duration - 0.02).timeIntervalSinceNow)
            bufferDeadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                stop()
                onBufferDeadline()
            }
        }
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
        to clock: AlignmentPlaybackClock, startSeconds: Double, now: Date = Date()
    ) throws {
        guard startSeconds.isFinite,
              abs(startSeconds - clock.startSeconds - clock.duration) < 0.5 / 48_000 else {
            throw AlignmentTransportFailure.discontinuousWindow
        }
        guard now < clock.startedAt.addingTimeInterval(clock.duration - 0.02) else {
            throw AlignmentTransportFailure.bufferDeadline
        }
    }

    func enqueue(
        _ clips: [SourceID: AlignmentAudioClip], startSeconds: Double, first: Bool,
        availableSources: Set<SourceID>, final: Bool,
        onSourcesJoined: @escaping @MainActor () -> Void,
        onBufferDeadline: @escaping @MainActor () -> Void
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
            try Self.validateAppend(to: clock, startSeconds: startSeconds)
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
        for (source, buffer) in buffers {
            guard let player = players[source] else { throw WaveformWindowError.invalidSamples }
            if !transportSources.prepared.contains(source) {
                player.scheduleBuffer(buffer)
                player.play(at: start)
                if !first {
                    let remaining = max(0, clock.startedAt.addingTimeInterval(startSeconds - clock.startSeconds).timeIntervalSinceNow)
                    sourceJoinTasks[source] = Task {
                        do { try await Task.sleep(for: .seconds(remaining)) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        onSourcesJoined()
                    }
                }
            } else {
                player.scheduleBuffer(buffer)
            }
        }
        transportSources.schedule(Set(clips.keys), startingAt: startSeconds)
        bufferDeadlineTask?.cancel()
        bufferDeadlineTask = nil
        if !final {
            let remaining = max(0, clock.startedAt.addingTimeInterval(clock.duration - 0.02).timeIntervalSinceNow)
            bufferDeadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) }
                catch { return }
                guard let self, !Task.isCancelled, self.clock != nil else { return }
                onBufferDeadline()
                stop()
            }
        }
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
