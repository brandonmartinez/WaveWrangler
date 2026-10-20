import Foundation
import Testing
import WWAlignPipeline
import WWCore

@MainActor
@Suite("Shared-clock listening buffering")
struct AlignmentTransportBufferingTests {
    @Test func consecutiveMultiTrackWindowsRetainTheClockThroughThreeCycles() throws {
        let a = SourceID(), b = SourceID()
        for cycle in 0..<3 {
            var schedule = try AlignedAuditionSchedule(startSeconds: -0.125, endSeconds: 2.25)
            let began = Date(timeIntervalSinceReferenceDate: Double(100 + cycle * 10))
            var clock: AlignmentPlaybackClock?
            var routing = AlignmentTransportSources()
            while let frames = schedule.next() {
                let start = Double(frames.lowerBound) / 48_000
                let duration = Double(frames.count) / 48_000
                let clip = AlignmentAudioClip(sampleRate: 48_000, samples: Array(repeating: 0.25, count: frames.count))
                #expect(try AlignmentAudioPlayback.validateTransport([a: clip, b: clip]).duration == duration)
                if let prior = clock {
                    try AlignmentAudioPlayback.validateAppend(to: prior, startSeconds: start, now: began)
                    clock = AlignmentPlaybackClock(
                        startSeconds: prior.startSeconds, duration: prior.duration + duration, startedAt: prior.startedAt
                    )
                } else {
                    clock = AlignmentPlaybackClock(startSeconds: start, duration: duration, startedAt: began)
                }
                routing.schedule([a, b], startingAt: start)
                #expect(routing.starts[a] == -0.125)
                #expect(routing.starts[b] == -0.125)
                #expect(clock?.startedAt == began)
            }
            #expect(clock?.playhead(at: began.addingTimeInterval(10)) == 2.25)
        }
    }

    @Test func unreadyUnmuteStaysPendingThenJoinsWithoutResettingExistingSources() {
        let a = SourceID(), b = SourceID()
        var routing = AlignmentTransportSources()
        routing.schedule([a], startingAt: 10)
        #expect(AlignmentTransportSelection.gains(prepared: routing.prepared, enabled: [a, b]) == [a: 1])
        #expect(!routing.prepared.contains(b))
        routing.schedule([a, b], startingAt: 12)
        #expect(routing.starts[a] == 10)
        #expect(routing.starts[b] == 12)
        #expect(routing.pending(at: 11.9) == [b])
        #expect(AlignmentTransportSelection.gains(
            prepared: routing.prepared.subtracting(routing.pending(at: 11.9)), enabled: [a, b]
        ) == [a: 1])
        #expect(routing.pending(at: 12).isEmpty)
        #expect(AlignmentTransportSelection.gains(prepared: routing.prepared, enabled: [b]) == [a: 0, b: 1])
        #expect(routing.starts[a] == 10)
        #expect(AlignmentTransportSelection.gains(prepared: routing.prepared, enabled: [a, b]) == [a: 0.5, b: 0.5])
    }

    @Test func lateOrDiscontinuousFillIsAnExplicitFailureNotScheduledSilence() throws {
        let began = Date(timeIntervalSinceReferenceDate: 100)
        let clock = AlignmentPlaybackClock(startSeconds: 10, duration: 1, startedAt: began)
        try AlignmentAudioPlayback.validateAppend(to: clock, startSeconds: 11, now: began.addingTimeInterval(0.9))
        for time in [0.98, 1, 2] {
            #expect(throws: AlignmentTransportFailure.self) {
                try AlignmentAudioPlayback.validateAppend(to: clock, startSeconds: 11, now: began.addingTimeInterval(time))
            }
        }
        for start in [10.99, 11.01, Double.nan] {
            #expect(throws: AlignmentTransportFailure.self) {
                try AlignmentAudioPlayback.validateAppend(to: clock, startSeconds: start, now: began)
            }
        }
    }
}
