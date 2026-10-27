import AVFAudio
import Foundation
import Testing
import WWCore
import WWMix

@MainActor
@Suite("Alignment audio playback foundations")
struct AlignmentAudioPlaybackTests {
    @Test func productionPrefillIncludesLatencyShortenedBlocksAndKeepsTheControlHorizonBounded() throws {
        var buffer = AlignmentProductionBuffer()
        try buffer.append(productionOutput(first: -4, frames: 384), final: false)
        #expect(!buffer.isReady && buffer.firstFrame == -4)
        while !buffer.isReady {
            let first = try #require(buffer.endFrame)
            try buffer.append(productionOutput(first: first, frames: MixerLiveTiming.processingBlockFrames), final: false)
        }
        #expect(buffer.endFrame == -4 + buffer.frameCount)
        #expect(buffer.frameCount >= MixerLiveTiming.startupBufferedFrames)
        #expect(buffer.frameCount + Int64(MixerLiveTiming.startLeadFrames) <= MixerLiveTiming.maximumPreparedControlFrames)
        #expect(MixerLiveTiming.maximumPreparedControlFrames <= MixerRecipe.sampleRate / 10)
    }

    @Test func shortFinalProductionAndDiscontinuousOrOverflowingPacketsAreExplicit() throws {
        var short = AlignmentProductionBuffer()
        try short.append(productionOutput(first: -1, frames: 3), final: true)
        #expect(short.isReady && short.frameCount == 3 && short.endFrame == 2)
        #expect(throws: MixerFailure.self) { try short.append(productionOutput(first: 2, frames: 1), final: true) }
        var buffer = AlignmentProductionBuffer()
        try buffer.append(productionOutput(first: 0, frames: 512), final: false)
        #expect(throws: AlignmentTransportFailure.self) {
            try buffer.append(productionOutput(first: 513, frames: 512), final: false)
        }
        #expect(buffer.frameCount == 512 && buffer.endFrame == 512 && !buffer.isReady)
        var overflow = AlignmentProductionBuffer()
        #expect(throws: MixerFailure.self) {
            try overflow.append(productionOutput(first: .max, frames: 1), final: true)
        }
        #expect(overflow.firstFrame == nil && overflow.frameCount == 0)
    }

    private func productionOutput(first: Int64, frames: Int) -> MixerPCMOutput {
        .init(firstFrame: first, channels: Array(repeating: Array(repeating: 0.1, count: frames), count: 2))
    }

    @Test func productionStereoAdapterIsHeadlessExactAndNeverNormalizes() throws {
        let output = MixerPCMOutput(firstFrame: -5, channels: [[1.5, 0.25, -1.5], [-0.5, 0, 0.5]])
        let clip = try AlignmentAudioPlayback.validateProduction(output)
        #expect(clip.channelCount == 2 && clip.sampleRate == 48_000)
        #expect(clip.samples == [1.5, 0.25, -1.5, -0.5, 0, 0.5])
        #expect(clip.duration == 3.0 / 48_000)
        let invalid: [[[Float]]] = [[], [[]], [[], []], [[0]], [[0], [0, 0]], [[0], [.nan]], [[0], [.infinity]]]
        for channels in invalid {
            #expect(throws: MixerFailure.self) {
                try AlignmentAudioPlayback.validateProduction(.init(firstFrame: 0, channels: channels))
            }
        }
    }

    @Test func playbackClockIncludesLeadAndClampsToScheduledAudio() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let clock = AlignmentPlaybackClock(startSeconds: 25, duration: 3, startedAt: start)
        #expect(clock.playhead(at: start.addingTimeInterval(-0.1)) == 25)
        #expect(clock.playhead(at: start.addingTimeInterval(1)) == 26)
        #expect(clock.playhead(at: start.addingTimeInterval(10)) == 28)
    }

    @Test func transportRejectsInconsistentWindowsBeforeOpeningAnAudioDevice() throws {
        let a = SourceID(), b = SourceID()
        let clip = AlignmentAudioClip(sampleRate: 48_000, samples: [0.1, -0.1])
        #expect(try AlignmentAudioPlayback.validateTransport([a: clip]).duration == 2.0 / 48_000)
        #expect(throws: CocoaError.self) { try AlignmentAudioPlayback.validateTransport([:]) }
        for invalid in [
            AlignmentAudioClip(sampleRate: 48_000, samples: []),
            AlignmentAudioClip(sampleRate: 44_100, samples: clip.samples),
            AlignmentAudioClip(sampleRate: 48_000, samples: [0.1]),
            AlignmentAudioClip(sampleRate: 48_000, samples: clip.samples, channelCount: 2),
        ] {
            #expect(throws: CocoaError.self) {
                try AlignmentAudioPlayback.validateTransport([a: clip, b: invalid])
            }
        }
        for rate in [0, -1, Double.nan, Double.infinity] {
            let invalid = AlignmentAudioClip(sampleRate: rate, samples: clip.samples)
            #expect(throws: CocoaError.self) { try invalid.makeFormat() }
            #expect(throws: CocoaError.self) { try AlignmentAudioPlayback.validateTransport([a: invalid]) }
        }
        for channels in [0, -1, Int(AVAudioChannelCount.max) + 1] {
            #expect(throws: CocoaError.self) {
                try AlignmentAudioClip(sampleRate: 48_000, samples: clip.samples, channelCount: channels).makeFormat()
            }
        }
    }

    @Test func planarStereoRenderPreservesChannelsAndZeroFillsOnlyAfterTheClip() throws {
        let clip = AlignmentAudioClip(sampleRate: 48_000, samples: [1, 2, 3, -1, -2, -3], channelCount: 2)
        let format = try clip.makeFormat()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let channels = try #require(buffer.floatChannelData)
        let cursor = AlignmentAudioSampleCursor(samples: clip.samples, channelCount: clip.channelCount)
        #expect(cursor.render(frameCount: 4, output: buffer.mutableAudioBufferList) == noErr)
        #expect(Array(UnsafeBufferPointer(start: channels[0], count: 4)) == [1, 2, 3, 0])
        #expect(Array(UnsafeBufferPointer(start: channels[1], count: 4)) == [-1, -2, -3, 0])
        #expect(cursor.render(frameCount: 4, output: buffer.mutableAudioBufferList) == noErr)
        #expect(Array(UnsafeBufferPointer(start: channels[0], count: 4)) == [0, 0, 0, 0])
        #expect(Array(UnsafeBufferPointer(start: channels[1], count: 4)) == [0, 0, 0, 0])
    }
}
