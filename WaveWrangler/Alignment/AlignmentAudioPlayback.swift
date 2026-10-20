import AVFAudio
import Darwin
import Foundation
import WWAlignPipeline
import WWCore

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

@MainActor
final class AlignmentAudioPlayback {
    private let engine = AVAudioEngine()
    private var players: [SourceID: AVAudioPlayerNode] = [:]
    private var source: AVAudioSourceNode?
    private var transportSampleRate: Double?
    private(set) var clock: AlignmentPlaybackClock?

    var preparedSources: Set<SourceID> { Set(players.keys) }

    func stop() {
        engine.stop()
        for player in players.values where engine.attachedNodes.contains(player) {
            engine.detach(player)
        }
        players.removeAll()
        if let source, engine.attachedNodes.contains(source) { engine.detach(source) }
        source = nil
        clock = nil
        transportSampleRate = nil
    }

    func play(_ clip: AlignmentAudioClip, startSeconds: Double) throws {
        stop()
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

    func enqueue(_ clips: [SourceID: AlignmentAudioClip], startSeconds: Double, first: Bool) throws {
        let representative = try Self.validateTransport(clips)
        let format = try representative.makeFormat()
        if first {
            stop()
            for source in clips.keys {
                let player = AVAudioPlayerNode()
                players[source] = player
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            do {
                try engine.start()
            } catch {
                stop()
                throw error
            }
            transportSampleRate = representative.sampleRate
        }
        guard Set(clips.keys).isSubset(of: preparedSources),
              transportSampleRate == representative.sampleRate, first || clock != nil else {
            throw WaveformWindowError.invalidSamples
        }
        for (source, clip) in clips {
            guard let player = players[source],
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)
                  ),
                  let samples = buffer.floatChannelData?.pointee
            else { throw CocoaError(.fileReadCorruptFile) }
            buffer.frameLength = AVAudioFrameCount(clip.samples.count)
            clip.samples.withUnsafeBufferPointer { values in
                if let base = values.baseAddress { samples.update(from: base, count: values.count) }
            }
            player.scheduleBuffer(buffer)
        }
        if first {
            let lead = 0.1
            let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
            clock = AlignmentPlaybackClock(
                startSeconds: startSeconds, duration: representative.duration,
                startedAt: Date().addingTimeInterval(lead)
            )
            for player in players.values { player.play(at: start) }
        } else if let prior = clock {
            clock = AlignmentPlaybackClock(
                startSeconds: prior.startSeconds, duration: prior.duration + representative.duration,
                startedAt: prior.startedAt
            )
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
