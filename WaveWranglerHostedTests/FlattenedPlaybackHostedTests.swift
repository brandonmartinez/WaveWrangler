import AppKit
import Foundation
import Synchronization
import Testing
import WWAlignPipeline
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Flattened playback and UI isolation (synthetic only)", .serialized)
struct FlattenedPlaybackHostedTests {
    private func wait(_ reason: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), Comment(rawValue: reason()))
    }

    private func fixture() async throws -> AlignmentWaveformRetentionHostedTests.Fixture {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2, durationSeconds: 16)
        f.model.placeGroupsAtSourceTime()
        try await wait(f.model.lastError ?? f.model.waveformMessage) {
            !f.model.isWorking && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
                && f.document.verifiedModel == f.document.store.model
        }
        let episode = try #require(f.document.store.model.episode(f.model.episodeID))
        let track = try #require(f.model.waveformTracks.first { $0.id == f.target })
        let reference = try #require(episode.speakerAssignments.first?.primary?.sourceID)
        var aligned = 0.0
        let seconds = Double(track.envelope.totalFrames) / Double(track.envelope.sampleRate)
        let segments = (0..<64).map { index in
            let segment = SourceTimingSegment(sourceStart: Double(index) * seconds / 64,
                sourceEnd: Double(index + 1) * seconds / 64, alignedStart: aligned,
                rateRatio: index.isMultiple(of: 2) ? 0.999 : 1.001, kind: .estimated)
            aligned = segment.alignedEnd
            return segment
        }
        let correction = SourceTimingCorrection(source: f.target, group: track.group, epoch: track.epoch,
            reference: reference, sourceRate: track.envelope.sampleRate, sourceFrames: track.envelope.totalFrames,
            channelCount: track.envelope.channelCount, analysisDigest: String(repeating: "a", count: 64),
            processing: PitchPreservingAudio.identifier, segments: segments)
        try #require(correction.isValid)
        var timing = try #require(episode.alignment)
        let index = try #require(timing.maps.firstIndex { $0.revision == timing.acceptedRevision })
        timing.maps[index].sourceCorrections = [correction]
        let changed = timing
        let episodeIndex = try #require(f.document.store.model.episodes.firstIndex { $0.id == episode.id })
        try #require(f.document.store.apply("Install Synthetic Adaptive Timing") { model throws(DomainError) in
            var result = model
            result.episodes[episodeIndex].alignment = changed
            return result
        })
        try await MixerHostedTests().save(f.document)
        f.model.loadWaveforms(keepingSnapshot: true)
        try await wait(f.model.lastError ?? f.model.waveformMessage) {
            !f.model.isWorking && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
                && f.document.verifiedModel == f.document.store.model
        }
        return f
    }

    @Test(arguments: [false, true])
    func adaptivePlaybackContinuesWhileTheMainActorLaysOutDenseTranscripts(production: Bool) async throws {
        let f = try await fixture()
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let original = f.document.store.model
        let words = (0..<40_000).map { index in
            TranscriptWord(text: "synthetic", alignedStart: Double(index) / 10, alignedEnd: Double(index) / 10 + 0.08)
        }
        let index = AudioTimelineWordIndex(words: words)
        let end = production ? 4.0 : 8.0
        if production { f.model.playProductionMix(interval: 0...end) }
        else { f.model.playEnabledTracks(interval: 0...end, repeatInterval: false) }
        try await wait(f.model.lastError ?? f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        let before = try #require(f.model.playbackClockForTesting).playhead()
        let until = ContinuousClock.now.advanced(by: production ? .milliseconds(450) : .milliseconds(4200))
        var covered = 0
        // Actual UI CPU work, not a blocking sleep/semaphore on a cooperative-pool thread.
        while ContinuousClock.now < until {
            covered += AudioTimelineWordLayout.make(index: index, start: 0, duration: 5000, width: 1400).wordCount
        }
        #expect(covered > 0)
        let after = try #require(f.model.playbackClockForTesting).playhead()
        #expect(after - before > (production ? 0.2 : 3.5),
            "Audio must refill beyond its initial scheduled horizon while the UI actor is busy.")
        try await wait(f.model.lastError ?? f.model.auditionLabel) { !f.model.canStopAudition || f.model.lastError != nil }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.model.waveformPlayheadSeconds == end)
        #expect(f.document.store.model == original)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func prefetchedMixAudioStillRefusesAnExternallyChangedOriginal() async throws {
        let f = try await fixture()
        defer { f.close() }
        f.model.playProductionMix(interval: 0...4)
        try await wait(f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.lastError == nil)
        let handle = try FileHandle(forWritingTo: f.files[1])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        try await wait("Changed original must stop even when raw PCM was prefetched") { !f.model.canStopAudition }
        #expect(f.model.lastError != nil)
        #expect(f.model.waveformPlayheadSeconds < 4)
    }

    @Test func slowSourceRevalidationDoesNotBlockTheProcessedAudioDeadline() async throws {
        let f = try await fixture()
        defer { f.close() }
        let checks = Atomic<Int>(0)
        await f.runtime.setProductionValidationHookForTesting {
            checks.wrappingAdd(1, ordering: .relaxed)
            try await Task.sleep(for: .milliseconds(180))
        }
        f.model.playProductionMix(interval: 0...4)
        try await wait(f.model.lastError ?? f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        try await wait(f.model.lastError ?? f.model.auditionLabel) { !f.model.canStopAudition || f.model.lastError != nil }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.model.waveformPlayheadSeconds == 4)
        #expect(checks.load(ordering: .relaxed) >= 3)
    }

    @Test func preparedPCMDoesNotBakeLiveMixControlsOrRebuildForAFaderEdit() async throws {
        let f = try await fixture()
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.playProductionMix(interval: 0...4)
        try await wait(f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.lastError == nil)
        let revision = f.model.mixer.instanceRevision
        let before = await f.runtime.coordinator.states()
        let keys = Set(before.values.compactMap(\.key).filter {
            $0.asset.kind == "ww.adaptive-audio-pcm" || $0.asset.kind == "ww.aligned-listening-pcm"
        })
        let episode = f.model.episodeID
        try #require(f.document.store.apply("Change Live Fader") { model throws(DomainError) in
            var master = model.episode(episode)?.mix?.master ?? MasterMixState()
            master.gainDB = -12
            return try model.settingMasterMix(master, in: episode)
        })
        f.model.mixer.masterMuted = true
        try await wait("Muted controls must reach the running DSP without replacing cached source PCM") {
            f.model.mixer.meters?.masterMeters.allSatisfy { $0.peak == 0 } == true || f.model.lastError != nil
        }
        try #require(f.model.lastError == nil)
        f.model.mixer.masterMuted = false
        try await wait("Unmute must restore the running DSP") {
            f.model.mixer.meters?.masterMeters.contains { $0.peak > 0 } == true || f.model.lastError != nil
        }
        #expect(f.model.lastError == nil)
        #expect(f.model.mixer.instanceRevision == revision)
        let after = await f.runtime.coordinator.states()
        #expect(Set(after.values.compactMap(\.key).filter {
            $0.asset.kind == "ww.adaptive-audio-pcm" || $0.asset.kind == "ww.aligned-listening-pcm"
        }) == keys)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
        f.model.stopAudition()
    }
}
