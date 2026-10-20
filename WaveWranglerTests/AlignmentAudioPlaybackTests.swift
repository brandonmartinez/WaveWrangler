import AVFAudio
import Foundation
import Testing
import WWCore

@MainActor
@Suite("Alignment audio playback foundations")
struct AlignmentAudioPlaybackTests {
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
