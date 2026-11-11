import AppKit
import AVFAudio
import Foundation
import MachO
import Synchronization
import Testing
import WWAlignPipeline
import WWCore
import WWMix
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

    @Test func aStarvedProductionQueueReportsBeforeTheDeadlineHandlerClearsTheGraph() async throws {
        let output = AlignmentAudioPlayback()
        defer { output.stop() }
        let diagnostics = ProductionPlaybackDiagnostics()
        for count in 1...MixerLiveTiming.sourcePrefetchWindows { diagnostics.preparedRawWindow(queued: count) }
        _ = diagnostics.begin(.dsp)
        var deadlines = 0
        for first in stride(from: 0, to: MixerLiveTiming.startupBufferedFrames, by: MixerLiveTiming.processingBlockFrames) {
            try output.enqueueProduction(.init(firstFrame: Int64(first),
                channels: Array(repeating: Array(repeating: 0.1, count: MixerLiveTiming.processingBlockFrames), count: 2)),
                final: false, diagnostics: diagnostics) { deadlines += 1 }
        }
        try await wait("Intentionally starved generated PCM must stop with a diagnostic") { deadlines > 0 }
        #expect(deadlines == 1)
        #expect(diagnostics.takeUnderrunReport(scheduledFrames: 0, consumedFrames: 0, appendGap: .zero) == nil,
            "The output queue must record the real underrun before invoking its UI handler.")
    }

    @Test func stopInvalidatesQueuedProductionAndCannotRestartFromAStaleProducer() async throws {
        let output = AlignmentAudioPlayback()
        defer { output.stop() }
        let generation = output.generation
        var deadlines = 0
        let block = MixerPCMOutput(firstFrame: 0,
            channels: Array(repeating: Array(repeating: 0.25, count: MixerLiveTiming.processingBlockFrames), count: 2))
        try output.enqueueProduction(block, final: false, generation: generation) { deadlines += 1 }
        output.stop()
        #expect(output.generation != generation)
        let clockCleared = output.clock == nil
        #expect(clockCleared)
        #expect(throws: CancellationError.self) {
            try output.enqueueProduction(block, final: true, generation: generation) { deadlines += 1 }
        }
        try await Task.sleep(for: .milliseconds(150))
        let stillStopped = output.clock == nil
        #expect(stillStopped)
        #expect(deadlines == 0)
    }

    @Test func combinedAppendRegistersCapacityBeforeWaitingAndStopCannotLoseItsResume() async throws {
        let output = AlignmentAudioPlayback()
        defer { output.stop() }
        let generation = output.generation
        let first = ProductionPlaybackRefill.Waiter()
        func append(_ frame: Int, waiter: ProductionPlaybackRefill.Waiter) throws {
            try output.enqueueProduction(.init(firstFrame: Int64(frame),
                channels: Array(repeating: Array(repeating: 0.1, count: MixerLiveTiming.processingBlockFrames), count: 2)),
                final: false, generation: generation, capacityWaiter: waiter) {}
        }
        try append(0, waiter: first)
        #expect(try await output.waitForProductionCapacity(first) == nil)
        for frame in stride(from: MixerLiveTiming.processingBlockFrames,
                            through: MixerLiveTiming.maximumScheduledAheadFrames,
                            by: MixerLiveTiming.processingBlockFrames) {
            try append(frame, waiter: .init())
        }
        let blocked = ProductionPlaybackRefill.Waiter()
        let next = ((MixerLiveTiming.maximumScheduledAheadFrames / MixerLiveTiming.processingBlockFrames) + 1)
            * MixerLiveTiming.processingBlockFrames
        try append(next, waiter: blocked)
        #expect(blocked.isPending)
        output.stop()
        await #expect(throws: CancellationError.self) {
            try await output.waitForProductionCapacity(blocked)
        }
        #expect(throws: CancellationError.self) { try append(next, waiter: .init()) }
    }

    @Test func readingPublishedClocksDoesNotQueryTheDeviceAndStopClearsTheSnapshot() throws {
        let output = AlignmentAudioPlayback()
        defer { output.stop() }
        let diagnostics = ProductionPlaybackDiagnostics()
        try output.enqueueProduction(.init(firstFrame: 0, channels: [[0.1], [-0.1]]),
                                     final: false, diagnostics: diagnostics) {}
        let before = diagnostics.snapshot.timings[.deviceClock]?.count ?? 0
        for _ in 0..<100 {
            #expect(output.snapshot.clock == nil)
            #expect(output.linearClock == nil)
            #expect(output.failure == nil)
        }
        #expect((diagnostics.snapshot.timings[.deviceClock]?.count ?? 0) == before)
        output.stop()
        #expect(output.snapshot.linearClock == nil && output.snapshot.failure == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_PLAYER_STOP_DIAGNOSTIC"] == "1",
        "Opt-in bounded AVFAudio completion and shutdown diagnostic; generated silence only."),
        .timeLimit(.minutes(3)))
    func generatedPlayerCompletionStopDiagnostic() async throws {
        let environment = ProcessInfo.processInfo.environment
        let callbacks = environment["WW_PLAYER_STOP_CALLBACKS"] != "0"
        let pauseFirst = environment["WW_PLAYER_STOP_PAUSE_FIRST"] != "0"
        let count = try #require(Int(environment["WW_PLAYER_STOP_BUFFER_COUNT"] ?? "512"))
        let frames = try #require(UInt32(environment["WW_PLAYER_STOP_BUFFER_FRAMES"] ?? "512"))
        try #require(count > 0 && count <= 80_000 && frames > 0 && frames <= 512
            && Double(count) * Double(frames) / 48_000 <= 60)
        let playbackSeconds = Double(count) * Double(frames) / 48_000
        let completed = Atomic<Int>(0)
        let queue = DispatchQueue(label: "com.wavewrangler.test-player-stop", qos: .userInitiated)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Int(frames) { channels[channel][frame] = 0 }
        }
        let checkerLoaded = (0..<_dyld_image_count()).contains { index in
            _dyld_get_image_name(index).map { String(cString: $0).hasSuffix("/libRPAC.dylib") } ?? false
        }
        let start = ContinuousClock.now
        print("PLAYER_STOP_DIAGNOSTIC begin callbacks=\(callbacks) pauseFirst=\(pauseFirst) buffers=\(count) frames=\(frames) threadChecker=\(checkerLoaded)")
        try queue.sync {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            for _ in 0..<count {
                if callbacks {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                        completed.wrappingAdd(1, ordering: .releasing)
                    }
                } else {
                    player.scheduleBuffer(buffer)
                }
            }
            try engine.start()
            player.play()
        }
        defer { queue.sync { player.stop(); engine.stop() } }
        print("PLAYER_STOP_DIAGNOSTIC scheduled elapsed=\(start.duration(to: .now))")
        let deadline = ContinuousClock.now.advanced(by: .seconds(playbackSeconds + 10))
        if callbacks {
            while completed.load(ordering: .acquiring) < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        } else {
            try await Task.sleep(for: .seconds(playbackSeconds + 0.15))
        }
        let finishedCount = completed.load(ordering: .acquiring)
        let state = queue.sync {
            let time = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }
            return "engineRunning=\(engine.isRunning) playerPlaying=\(player.isPlaying) playerFrames=\(time?.sampleTime.description ?? "nil")"
        }
        print("PLAYER_STOP_DIAGNOSTIC stopping completed=\(finishedCount) \(state) elapsed=\(start.duration(to: .now))")
        let stopping = ContinuousClock.now
        queue.sync {
            if pauseFirst { engine.pause() }
            player.stop()
            print("PLAYER_STOP_DIAGNOSTIC playerStopped elapsed=\(stopping.duration(to: .now))")
            if !pauseFirst { engine.pause() }
            engine.detach(player)
            engine.stop()
        }
        print("PLAYER_STOP_DIAGNOSTIC end stopElapsed=\(stopping.duration(to: .now)) total=\(start.duration(to: .now)) completed=\(completed.load(ordering: .acquiring))")
        if callbacks { #expect(finishedCount == count) }
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

    @Test func manualEpisodeSilenceRetainsItsClockAndProductionSeeksWithoutAnArrangement() async throws {
        let f = try await fixture()
        defer { f.close() }
        let editor = f.model.audioEditor
        editor.refresh()
        try await wait(editor.error ?? "Waiting for current production placement") { editor.production != nil }
        let composition = try #require(editor.composition)
        #expect(!editor.hasArrangement)
        let range = EpisodeProductionRange(
            start: try composition.timeline.unpinnedAnchor(atProgramFrame: -48_000),
            end: try composition.timeline.unpinnedAnchor(atProgramFrame: 960_000))
        let changed = editor.setBoundaryTimes(range: range, speakerIn: 0.5, speakerOut: 4)
        try #require(changed, "\(editor.error ?? "")")
        editor.refresh()
        let saved = f.document.store.model
        f.document.undoManager?.undo()
        editor.refresh()
        #expect(editor.episode?.productionRange == nil)
        f.document.undoManager?.redo()
        editor.refresh()
        #expect(f.document.store.model == saved)
        try await MixerHostedTests().save(f.document)
        f.model.selectProductionMix()
        f.model.seekDisplayClock("19", clock: .episode)
        #expect(f.model.waveformPlayheadSeconds == 18)
        #expect(try f.model.displayClockSeconds(at: 18, clock: .episode) == 19)
        f.model.playProductionMix(interval: 18...18.1, repeating: false)
        try await wait(f.model.lastError ?? f.model.auditionLabel) {
            !f.model.canStopAudition || f.model.lastError != nil
        }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.model.waveformPlayheadSeconds == 18.1)
        #expect(try f.model.displayClockSeconds(at: 18.1, clock: .episode) == 19.1)
    }

    @Test func sourceRevalidationDoesNotRebuildTheFrozenProductionRecipe() async throws {
        let f = try await fixture()
        defer { f.close() }
        let model = f.document.store.model
        let episode = f.model.episodeID
        let recipe = try await f.runtime.mixerRecipe(model: model, episode: episode, programFrames: 0..<192_000)
        let constructions = await f.runtime.productionRecipeConstructionCount
        let start = ContinuousClock.now
        for window in 0..<4 {
            let first = Int64(window * 48_000)
            let pcm = try await f.runtime.productionPCM(recipe: recipe, model: model,
                frames: first..<(first + 48_000))
            #expect(pcm.channels.count == recipe.routes.count)
            #expect(pcm.channels.values.allSatisfy { $0.count == 48_000 })
            try await f.runtime.validateProduction(recipe: recipe, model: model)
        }
        #expect(await f.runtime.productionRecipeConstructionCount == constructions,
                "Per-window and periodic checks must verify live sources without rebuilding program geometry")
        print("PRODUCTION_REVALIDATION windows=4 elapsed=\(start.duration(to: .now)) recipeReconstructions=0")
        var changed = model
        changed.episodes[0].mix = EpisodeMixState()
        changed.episodes[0].mix?.master.gainDB = -6
        await #expect(throws: MixerFailure.staleDependencies) {
            try await f.runtime.validateProduction(recipe: recipe, model: changed)
        }
        let handle = try FileHandle(forWritingTo: f.files[1])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await f.runtime.validateProduction(recipe: recipe, model: model)
        }
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
            f.model.mixer.consoleMeters.levels[.master]?.allSatisfy { $0.rmsDB == -.infinity } == true
                || f.model.lastError != nil
        }
        try #require(f.model.lastError == nil)
        f.model.mixer.masterMuted = false
        try await wait("Unmute must restore the running DSP") {
            f.model.mixer.consoleMeters.levels[.master]?.contains { $0.rmsDB.isFinite } == true
                || f.model.lastError != nil
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
