import Foundation
import Testing
import WWCore
@testable import WaveWrangler

/// Run only in the coordinator's leased macOS VM. These exercise the real engine/model,
/// not an acoustic-latency measurement.
@MainActor
@Suite("Aligned listening startup, cycles and live unmute (synthetic only)", .serialized)
struct AlignmentListeningStartupHostedTests {
    private func wait(_ reason: @autoclosure () -> String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready(), Comment(rawValue: reason()))
    }

    private func preparedFixture() async throws -> AlignmentWaveformRetentionHostedTests.Fixture {
        let fixture = try await AlignmentWaveformRetentionHostedTests().fixture(durationSeconds: 8)
        fixture.model.placeGroupsAtSourceTime()
        do {
            try await wait(fixture.model.lastError ?? fixture.model.waveformMessage) {
                !fixture.model.isWorking && !fixture.model.isLoadingWaveforms
                    && fixture.document.verifiedModel == fixture.document.store.model
                    && fixture.model.waveformMap != nil
            }
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    @Test func threeShortCyclesReplayThroughTheRealTransportWithoutLosingStop() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.close() }
        let originals = try fixture.files.map { try Data(contentsOf: $0) }
        var completed = 0
        fixture.model.playEnabledTracks(interval: 0...1.25, repeatInterval: true, repeatWhile: {
            completed += 1
            return completed < 3
        })
        #expect(fixture.model.isPreparingAudition)
        try #require(fixture.model.canStopAudition, Comment(rawValue: fixture.model.auditionLabel))
        try await wait(fixture.model.lastError ?? fixture.model.auditionLabel) {
            completed == 3 && !fixture.model.canStopAudition
        }
        #expect(fixture.model.lastError == nil)
        #expect(fixture.model.waveformPlayheadSeconds == 1.25)
        #expect(try fixture.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func initiallyMutedTrackJoinsWithoutRestartingTheAlreadyAudibleTrack() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.close() }
        let originals = try fixture.files.map { try Data(contentsOf: $0) }
        fixture.model.setTrack(fixture.target, enabled: false)
        fixture.model.playEnabledTracks(interval: 0...6, repeatInterval: false)
        try await wait(fixture.model.lastError ?? fixture.model.auditionLabel) {
            fixture.model.isAuditioning && fixture.model.waveformPlayheadSeconds > 0.2
        }
        var prior = fixture.model.waveformPlayheadSeconds
        var progress = ["Unmuting at \(prior): \(fixture.model.auditionLabel)"]
        defer { Attachment.record(progress.joined(separator: "\n"), named: "Live unmute shared-clock progress.txt") }
        fixture.model.setTrack(fixture.target, enabled: true)
        #expect(fixture.model.isAuditioning)
        #expect(fixture.model.auditionLabel.contains("preparing"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !fixture.model.auditionLabel.contains("Playing 2 timed"),
              ContinuousClock.now < deadline {
            #expect(fixture.model.isAuditioning, Comment(rawValue: fixture.model.auditionLabel))
            #expect(fixture.model.waveformPlayheadSeconds >= prior)
            if fixture.model.waveformPlayheadSeconds != prior {
                progress.append("\(fixture.model.waveformPlayheadSeconds): \(fixture.model.auditionLabel)")
            }
            prior = fixture.model.waveformPlayheadSeconds
            try await Task.sleep(for: .milliseconds(10))
        }
        progress.append("Join check at \(fixture.model.waveformPlayheadSeconds): \(fixture.model.auditionLabel)")
        try #require(fixture.model.auditionLabel.contains("Playing 2 timed"), Comment(rawValue: fixture.model.auditionLabel))
        fixture.model.setSoloed(true, scope: .source(fixture.target))
        #expect(fixture.model.auditionLabel.contains("Playing 1 timed"))
        #expect(fixture.model.isAuditioning && fixture.model.waveformPlayheadSeconds >= prior)
        fixture.model.setSoloed(false, scope: .source(fixture.target))
        #expect(fixture.model.auditionLabel.contains("Playing 2 timed"))
        #expect(fixture.model.lastError == nil)
        fixture.model.stopAudition()
        #expect(try fixture.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func excludingAnUnavailableMutedSourcePreservesTheOtherPlayersClock() throws {
        let playback = AlignmentAudioPlayback()
        defer { playback.stop() }
        let source = SourceID(), muted = SourceID()
        let clip = AlignmentAudioClip(sampleRate: 48_000, samples: Array(repeating: 0, count: 14_400))
        try playback.enqueue(
            [source: clip, muted: clip], startSeconds: 0, first: true,
            availableSources: [source, muted], final: true, onSourcesJoined: {}, onBufferDeadline: {}
        )
        let started = try #require(playback.clock?.startedAt)
        playback.setGains([source: 1, muted: 0])
        playback.excludeSource(muted)
        #expect(playback.preparedSources == [source])
        #expect(playback.clock?.startedAt == started)
        try playback.enqueue(
            [source: clip], startSeconds: 0.3, first: false,
            availableSources: [source, muted], final: true, onSourcesJoined: {}, onBufferDeadline: {}
        )
        #expect(playback.clock?.startedAt == started)
        #expect(playback.clock?.duration == 0.6)
    }

    @Test func exhaustedProducerDeadlineReportsOnceAndClearsScheduledPlayback() async throws {
        let playback = AlignmentAudioPlayback()
        defer { playback.stop() }
        let source = SourceID()
        var failures = 0
        let clip = AlignmentAudioClip(sampleRate: 48_000, samples: Array(repeating: 0, count: 14_400))
        try playback.enqueue(
            [source: clip], startSeconds: 0, first: true, availableSources: [source], final: false,
            onSourcesJoined: {}
        ) {
            failures += 1
            #expect(playback.clock != nil, "The caller must be able to preserve the final shared playhead.")
            playback.stop()
        }
        try await wait("The missed producer deadline did not report") { failures == 1 }
        #expect(playback.clock == nil && playback.preparedSources.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(failures == 1)
    }
}
