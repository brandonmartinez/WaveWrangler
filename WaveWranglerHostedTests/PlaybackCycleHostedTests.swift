import Foundation
import Synchronization
import Testing
import WWAlignPipeline
import WWCore
import WWMix
@testable import WaveWrangler

@MainActor
@Suite("Persistent playback cycles (synthetic only)", .serialized)
struct PlaybackCycleHostedTests {
    @Test func cyclesCatchAtTheEndWithoutSeekingAtEnableTime() {
        var cursor = PlaybackCycleCursor(frame: 0, end: 100)
        #expect(cursor.next(maximumFrames: 15, cycle: 10..<20) == 0..<15)
        #expect(cursor.next(maximumFrames: 15, cycle: 10..<20) == 15..<20)
        #expect(cursor.next(maximumFrames: 15, cycle: 10..<20) == 10..<20)
        #expect(cursor.next(maximumFrames: 15, cycle: nil) == 20..<35)
        #expect(cursor.next(maximumFrames: 15, cycle: 5..<10) == 35..<50)
        #expect(cursor.next(maximumFrames: 80, cycle: 40..<100) == 50..<100)
        #expect(cursor.next(maximumFrames: 80, cycle: 40..<100) == 40..<100)
        #expect(cursor.next(maximumFrames: 80, cycle: nil) == nil)

        var changed = PlaybackCycleCursor(frame: 12, end: 100)
        #expect(changed.next(maximumFrames: 3, cycle: nil) == 12..<15)
        #expect(changed.next(maximumFrames: 9, cycle: 10..<20) == 15..<20)
        #expect(changed.next(maximumFrames: 9, cycle: 5..<25) == 20..<25)
        #expect(changed.next(maximumFrames: 9, cycle: 5..<25) == 5..<14)
        #expect(changed.next(maximumFrames: 0, cycle: 5..<25) == nil)

        var boundary = PlaybackCycleCursor(frame: 100, end: 100)
        #expect(boundary.next(maximumFrames: 100, cycle: 40..<100) == 40..<100)
    }

    @Test func programClockWrapsOnTheExactScheduledFrameAndPrunesHeardPasses() {
        let rate = Double(MixerRecipe.sampleRate)
        var timeline = PlaybackProgramTimeline()
        timeline.append(.init(playbackFrame: 0, programFrame: 0), heardFrame: nil)
        timeline.append(.init(playbackFrame: 96_000, programFrame: 48_000), heardFrame: 48_000)
        #expect(timeline.programSeconds(at: 95_999 / rate) == 95_999 / rate)
        #expect(timeline.programSeconds(at: 2) == 1)
        timeline.append(.init(playbackFrame: 144_000, programFrame: 48_000), heardFrame: 120_000)
        #expect(timeline.segments.count == 2)
        #expect(timeline.programSeconds(at: 3.25) == 1.25)
        timeline.append(.init(playbackFrame: 156_000, programFrame: 60_000), heardFrame: nil)
        #expect(timeline.segments.count == 2)
    }

    @Test func rawCycleTilesAreReusedAcrossPassesAndReleasedWhenTheCycleMoves() async throws {
        let decodes = Mutex(0)
        let reference = ChannelReference(sourceID: SourceID(), channel: .unknown)
        let track = AudioTrackID()
        let cache = ProductionCyclePCMCache(bounds: 0..<240_000) { frames in
            decodes.withLock { $0 += 1 }
            let samples = frames.map { Float($0 % 1000) }
            return .init(frames: frames, channels: [reference: samples],
                         audioTracks: [track: [samples, samples.map { -$0 }]])
        }
        let cycle: Range<Int64> = 47_990..<96_010
        let first = try await cache.window(cycle, retaining: cycle)
        for _ in 0..<3 {
            let repeated = try await cache.window(cycle, retaining: cycle)
            #expect(repeated.channels == first.channels && repeated.audioTracks == first.audioTracks)
        }
        #expect(first.channels[reference] == cycle.map { Float($0 % 1000) })
        #expect(decodes.withLock { $0 } == 3)
        _ = try await cache.window(144_010..<144_020, retaining: 144_010..<144_020)
        let retained = await cache.retainedTileCount
        #expect(retained == 1 && decodes.withLock { $0 } == 4)
        _ = try await cache.window(192_010..<192_020, retaining: nil)
        let disabled = await cache.retainedTileCount
        #expect(disabled == 1)
        await #expect(throws: MixerFailure.incompletePCM) {
            try await cache.window(239_990..<240_010, retaining: nil)
        }
    }

    @Test func rawSourceCyclesRetainChannelMetadataAndReuseUngainedTiles() async throws {
        let decodes = Mutex(0)
        let source = SourceID()
        let cache = SourceCyclePCMCache(bounds: 0..<240_000, width: 48_000) { sources, frames in
            decodes.withLock { $0 += 1 }
            return Dictionary(uniqueKeysWithValues: sources.map {
                ($0, AlignmentAudioClip(sampleRate: 48_000, samples: frames.map { Float($0 % 1000) },
                    sourceChannel: 1, sourceChannelCount: 2))
            })
        }
        let cycle: Range<Int64> = 47_990..<96_010
        for _ in 0..<3 {
            let window = try await cache.window(cycle, sources: [source], retaining: cycle)
            #expect(window.frames == cycle)
            #expect(window.clips[source]?.samples == cycle.map { Float($0 % 1000) })
            #expect(window.clips[source]?.sourceChannel == 1 && window.clips[source]?.sourceChannelCount == 2)
        }
        #expect(decodes.withLock { $0 } == 3)
        await #expect(throws: WaveformWindowError.invalidWindow) {
            try await cache.window(239_990..<240_010, sources: [source], retaining: nil)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func runningTransportsCatchNewCyclesWithoutRebuildingAndContinueWhenDisabled(
        enabledAtStart: Bool, production: Bool
    ) async throws {
        let helper = MixerHostedTests()
        let f = try await helper.ready(durationSeconds: 8)
        defer { f.close() }
        f.model.waveformPlayheadSeconds = 0
        f.model.listening.setCycleRange(0.6...1.0)
        f.model.listening.cycleEnabled = enabledAtStart
        if production { f.model.playProductionMix() } else { f.model.playEnabledTracks() }
        try await helper.wait { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.isAuditioning, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
        let processor = f.model.mixer.processor
        if production { try #require(processor != nil) }
        let initialClock = f.model.playbackClockForTesting
        let clock = try #require(initialClock)
        #expect(clock.playhead() < 0.6, "An enabled cycle must not seek directly to its beginning.")
        if !enabledAtStart { f.model.listening.cycleEnabled = true }
        var previous = clock.playhead()
        var wraps = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while wraps < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let currentClock = f.model.playbackClockForTesting
            let current = try #require(currentClock, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
            if current.playhead() < previous - 0.15 { wraps += 1 }
            previous = current.playhead()
            let playing = f.model.isAuditioning
            let preparing = f.model.isPreparingAudition
            #expect(playing && !preparing)
            #expect(current.startedAt == clock.startedAt)
            if production { #expect(f.model.mixer.processor === processor) }
        }
        #expect(wraps == 3, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
        f.model.listening.setCycleRange(1.0...1.4)
        try await helper.wait { f.model.waveformPlayheadSeconds > 1.15 || !f.model.isAuditioning }
        #expect(f.model.isAuditioning && f.model.playbackClockForTesting?.startedAt == clock.startedAt)
        f.model.listening.cycleEnabled = false
        try await helper.wait { f.model.waveformPlayheadSeconds > 1.7 || !f.model.isAuditioning }
        let continued = f.model.isAuditioning
        #expect(continued && f.model.waveformPlayheadSeconds > 1.7)
        #expect(f.model.playbackClockForTesting?.startedAt == clock.startedAt)
        f.model.stopAudition()
    }

    @Test(arguments: [false, true])
    func cyclesEndingAtTheEpisodeEndFinishNormallyAfterDisabling(production: Bool) async throws {
        let helper = MixerHostedTests()
        let f = try await helper.ready(durationSeconds: 2)
        defer { f.close() }
        f.model.listening.setCycleRange(1.2...2)
        f.model.listening.cycleEnabled = true
        if production { f.model.playProductionMix() } else { f.model.playEnabledTracks() }
        try await helper.wait { f.model.isAuditioning || f.model.lastError != nil }
        let initialClock = f.model.playbackClockForTesting
        let clock = try #require(initialClock)
        var previous = clock.playhead()
        var wrapped = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !wrapped, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let position = f.model.playbackClockForTesting?.playhead() ?? previous
            wrapped = position < previous - 0.3
            previous = position
        }
        try #require(wrapped, Comment(rawValue: f.model.lastError ?? f.model.auditionLabel))
        f.model.listening.cycleEnabled = false
        try await helper.wait { !f.model.canStopAudition }
        #expect(f.model.lastError == nil && abs(f.model.waveformPlayheadSeconds - 2) < 0.001)
    }
}
