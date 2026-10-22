import AppKit
import Foundation
import Testing
import WWCore
import WWPersistence
@testable import WWSpeech
@testable import WaveWrangler

@MainActor
@Suite("Sample-exact cleanup transcription windows", .serialized)
struct CleanupTranscriptionTimingTests {
    @Test func fillerReviewsPublishAtomicallySaveReopenAndKeepOldJudgmentsAsHistory() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true)
        let originalAudio = try f.files.map { try Data(contentsOf: $0) }
        let snapshot = f.document.store.model
        let transcripts = try await f.runtime.transcribeCleanup(
            model: snapshot, episode: f.model.episodeID, modelRevision: "synthetic-filler-review",
            transcribeWindow: { _ in PCMTranscript(segments: [
                PCMSegment(text: "Um,", startSeconds: 1, endSeconds: 1.25),
                PCMSegment(text: "uh", startSeconds: nil, endSeconds: nil),
            ]) }, progress: { _ in })
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        #expect(try cleanup.publishTranscripts(transcripts, expecting: snapshot))
        undo.endUndoGrouping()
        let published = f.document.store.model
        #expect(cleanup.fillerReviews.count == 2)
        #expect(cleanup.fillerReviews.allSatisfy { $0.origin == .detected && $0.humanBounds == nil })
        undo.undo()
        #expect(f.document.store.model == snapshot, "All speakers' transcripts and suggestions undo together")
        undo.redo()
        #expect(f.document.store.model == published)
        await cleanup.refresh()
        let review = try #require(cleanup.fillerReviews.first)
        undo.beginUndoGrouping()
        cleanup.setFillerBounds(review.id, start: 0.98, end: 1.27)
        undo.endUndoGrouping()
        #expect(cleanup.error == nil)
        let adjusted = f.document.store.model
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(Data(contentsOf: #require(f.document.fileURL))).payload == adjusted)
        #expect(f.document.verifiedModel == adjusted)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originalAudio)
        do {
            let raw = try NSDocumentController.shared.makeDocument(
                withContentsOf: #require(f.document.fileURL), ofType: DocumentTypes.show)
            let reopened = try #require(raw as? ShowDocument)
            defer { reopened.close() }
            #expect(reopened !== f.document)
            #expect(reopened.store.model == adjusted && reopened.verifiedModel == adjusted)
            #expect(!reopened.isDocumentEdited && reopened.status.formatUpdate == nil)
        }
        var replacement = transcripts
        for index in replacement.indices { replacement[index].id = UUID() }
        undo.beginUndoGrouping()
        #expect(try cleanup.publishTranscripts(replacement, expecting: adjusted))
        undo.endUndoGrouping()
        let historical = try #require(cleanup.fillerReviews.first)
        #expect(historical == adjusted.episodes[0].cleanup?.fillerReviews?.first)
        #expect(cleanup.fillerIssue(historical) == nil)
        #expect(cleanup.fillerReviews.count == 2, "The adjusted judgment stays active at its exact timing; only undecided suggestions regenerate")
        let beforeLateResult = f.document.store.model
        #expect(try !cleanup.publishTranscripts(transcripts, expecting: snapshot))
        #expect(f.document.store.model == beforeLateResult, "An obsolete job cannot overwrite new reviews")
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        #expect(try coder.decode(Data(contentsOf: #require(f.document.fileURL))).payload == beforeLateResult)
        let raw = try NSDocumentController.shared.makeDocument(
            withContentsOf: #require(f.document.fileURL), ofType: DocumentTypes.show)
        let reopened = try #require(raw as? ShowDocument)
        defer { reopened.close() }
        let reopenedCleanup = EpisodeCleanupModel(state: ShowWindowState(store: reopened.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { reopenedCleanup.cancel() }
        await reopenedCleanup.refresh()
        try #require(reopenedCleanup.plan?.isReady == true, "\(reopenedCleanup.error ?? "")")
        #expect(reopenedCleanup.fillerReviews.count == 2)
        #expect(reopenedCleanup.fillerReviews.first == historical)
        #expect(reopenedCleanup.fillerIssue(historical) == nil)
        #expect(reopenedCleanup.fillerReviews.filter { reopenedCleanup.fillerIssue($0) == nil }.count == 2)
    }

    @Test func explicitRefreshAfterReviewReverifiesSourcesAndKeepsJudgments() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let lane = try #require(cleanup.plan?.lanes.first)
        cleanup.addManualFiller(speaker: lane.speaker, start: 1, end: 1.2)
        let review = try #require(cleanup.selectedFiller)
        try #require(cleanup.fillerIssue(review) == nil)
        try #require(cleanup.fillerPublicationGeneration == cleanup.state.store.modelGeneration)
        let verified = cleanup.identities
        await cleanup.refresh(skippingReviewOnlyChange: true)
        #expect(cleanup.identities == verified, "An own-publication task does not dismiss the active review controls")
        let source = try #require(f.files.first)
        let original = try Data(contentsOf: source)
        let replacement = try Data(contentsOf: #require(f.files.last))
        try #require(replacement != original)
        cleanup.cancelWaveforms()
        try replacement.write(to: source)
        await cleanup.refresh()
        #expect(cleanup.fillerPublicationGeneration == nil)
        #expect(cleanup.identities[lane.primary.sourceID] != review.sourceIdentity)
        #expect(cleanup.fillerIssue(review) != nil, "Explicit Refresh must not reuse the review-only verification skip")
        #expect(cleanup.visibleFillers(for: lane).isEmpty && !cleanup.canNavigate)
        #expect(cleanup.fillerReviews == [review], "A failed source recheck retains the original human judgment")
    }

    @Test func fillerAuditionLoopsStopsWhenUncheckedAndCancelsOnReviewEdits() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true)
        let before = f.document.store.model
        let transcripts = try await f.runtime.transcribeCleanup(
            model: before, episode: f.model.episodeID, modelRevision: "synthetic-audition",
            transcribeWindow: { _ in PCMTranscript(segments: [
                PCMSegment(text: "um", startSeconds: 1, endSeconds: 1.4),
            ]) }, progress: { _ in })
        try #require(try cleanup.publishTranscripts(transcripts, expecting: before))
        await cleanup.refresh()
        let review = try #require(cleanup.fillerReviews.first)
        let interval = try #require(cleanup.fillerAuditionRange(review, context: 0.5))
        #expect(interval.lowerBound == review.bounds.alignedStart - 0.5)
        #expect(interval.upperBound == review.bounds.alignedEnd + 0.5)
        let snapshot = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        cleanup.loopsFillerAudition = true
        cleanup.auditionFiller(review.id, context: 0)
        var reachedLaterAudio = false
        var repeated = false
        try await wait {
            if cleanup.playhead > review.bounds.alignedStart + 0.15 { reachedLaterAudio = true }
            if reachedLaterAudio && cleanup.isPlaying && cleanup.playhead < review.bounds.alignedStart + 0.1 {
                repeated = true
            }
            return repeated || cleanup.error != nil
        }
        try #require(repeated && cleanup.error == nil, "\(cleanup.error ?? cleanup.transportMessage)")
        cleanup.loopsFillerAudition = false
        try await wait { !cleanup.isPlaying && !cleanup.isPreparingPlayback || cleanup.error != nil }
        #expect(cleanup.error == nil)
        #expect(cleanup.transportMessage == "Finished filler timing audition.")
        #expect(f.document.store.model == snapshot, "Playback preferences and looping are not document edits")
        cleanup.loopsFillerAudition = true
        cleanup.auditionFiller(review.id)
        try await wait { cleanup.isPlaying || cleanup.error != nil }
        try #require(cleanup.error == nil && cleanup.isPlaying)
        cleanup.setFillerBounds(review.id,
            start: review.bounds.alignedStart - 0.01, end: review.bounds.alignedEnd + 0.01)
        #expect(!cleanup.isPlaying && !cleanup.isPreparingPlayback && cleanup.error == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!cleanup.isPlaying && !cleanup.isPreparingPlayback, "A canceled loop cannot restart after the edit")
        #expect(cleanup.fillerReviews.first?.detectedBounds == review.detectedBounds)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
        cleanup.setFillerBounds(review.id, start: review.bounds.alignedStart, end: review.bounds.alignedStart + 0.000001)
        try #require(cleanup.error == nil)
        cleanup.auditionFiller(review.id, context: 0)
        #expect(cleanup.error?.contains("With context") == true)
        #expect(!cleanup.isPlaying && !cleanup.isPreparingPlayback,
                "Sub-frame intervals report an error instead of pretending to play nothing")
    }

    @Test(arguments: [148.874, 148.874229167, 1.0 / 48_000, -148.874, -86_400])
    func longFractionalTimelinesKeepExactThirtySecondLimits(_ start: Double) throws {
        let end = 4413.319
        let windows = try AlignmentRuntime.cleanupTranscriptionWindows(start: start, end: end)
        let first = Int64((start * 48_000).rounded()), last = Int64((end * 48_000).rounded())
        #expect(windows.first?.coreFrames.lowerBound == first)
        #expect(windows.last?.coreFrames.upperBound == last)
        #expect(windows.reduce(0) { $0 + $1.coreFrames.count } == last - first)
        for window in windows {
            #expect(window.audioFrames.count <= 30 * 48_000)
            #expect(window.audioFrames.lowerBound == max(first, window.coreFrames.lowerBound - 48_000))
            #expect(window.audioFrames.upperBound == min(last, window.coreFrames.upperBound + 48_000))
            #expect(window.coreFrames.count > 0 && window.coreFrames.count <= 28 * 48_000)
        }
        #expect(zip(windows, windows.dropFirst()).allSatisfy {
            $0.coreFrames.upperBound == $1.coreFrames.lowerBound
        })
        if start == 148.874 {
            #expect(windows.contains {
                Double($0.audioFrames.upperBound) / 48_000 - Double($0.audioFrames.lowerBound) / 48_000 > 30
            }, "Reproduces the floating-point duration that the former guard falsely rejected")
        }
    }

    @Test func oneFrameTailIsRetainedAndInvalidRangesAreExplicitErrors() throws {
        let first: Int64 = 7_145_952
        let last = first + 28 * 48_000 + 1
        let windows = try AlignmentRuntime.cleanupTranscriptionWindows(
            start: Double(first) / 48_000, end: Double(last) / 48_000)
        #expect(windows.count == 2)
        #expect(windows.last?.coreFrames.count == 1)
        #expect(windows.last?.audioFrames.count == 48_001)
        for (start, end) in [(Double.nan, 1.0), (0, .infinity), (1, 1), (2, 1),
                             (-86_401, 0), (0, 86_401), (0, 1.0 / 96_001)] {
            #expect(throws: (any Error).self) {
                try AlignmentRuntime.cleanupTranscriptionWindows(start: start, end: end)
            }
        }
    }

    @Test func actualAlignedPCMCompletesTheFormerlyFailingFractionalWindow() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 70)
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let state = ShowWindowState(store: f.document.store)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 1.0 / 48_000, outValue: 69.5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true, "\(cleanup.error ?? "")")
        let lane = try #require(cleanup.plan?.lanes.first)
        let windows = try AlignmentRuntime.cleanupTranscriptionWindows(start: lane.start, end: lane.end)
        let second = windows[1]
        let legacyCursor = lane.start + 28
        #expect(min(lane.end, legacyCursor + 28 + 1) - max(lane.start, legacyCursor - 1) > 30,
                "The former seconds-based scheduler rejects this same aligned interval")
        #expect(second.audioFrames.count == 30 * 48_000)
        let snapshot = f.document.store.model
        let probe = TranscriptionFrameProbe()
        let transcripts = try await f.runtime.transcribeCleanup(
            model: snapshot, episode: f.model.episodeID, modelRevision: "synthetic-window-probe",
            chunking: .fixed,
            transcribeWindow: { await probe.transcribe($0) },
            progress: { await probe.progress($0) })
        let counts = await probe.counts
        #expect(counts == windows.map(\.audioFrames.count))
        #expect(counts == [29 * 48_000, 30 * 48_000, 14 * 48_000 + 23_999])
        #expect(await probe.allSamplesValid)
        #expect(await probe.lastProgress == 1)
        let updates = await probe.updates
        #expect(updates.filter { $0.stage == .completedWindow }.map(\.windowIndex) == [1, 2, 3])
        #expect(updates.filter { $0.stage == .recognizing }.count == 3)
        #expect(updates.last?.stage == .verifying)
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(updates.allSatisfy { $0.speakerCount == 1 && $0.totalSeconds == lane.end - lane.start })
        let transcript = try #require(transcripts.first)
        #expect(transcripts.count == 1, "Backup recordings are never transcription inputs")
        #expect(transcript.model == "synthetic-window-probe")
        #expect(transcript.primary == lane.primary && transcript.sourceRate == lane.sourceRate)
        #expect(transcript.words.map(\.text) == ["context", "core", "core", "core"])
        #expect(transcript.words.allSatisfy { $0.sourceStartFrame != nil && $0.sourceEndFrame != nil })
        #expect(transcript.words[0].alignedStart == lane.start + 0.25)
        #expect(transcript.words[2].alignedStart == Double(second.audioFrames.lowerBound) / 48_000 + 1.25)
        #expect(f.document.store.model == snapshot, "Rendering does not publish a partial transcript or alter timing")
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
        await #expect(throws: (any Error).self) {
            try await f.runtime.cleanupPreview(model: snapshot, episode: f.model.episodeID,
                start: 1.0 / 48_000, duration: 30 + 1.0 / 48_000)
        }
    }

    @Test func previewPastANonGridSourceEdgeDoesNotInventAnExtraFrame() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(target)
        f.model.applyNumeric(ratePPM: 0, offsetMilliseconds: 0.001)
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let snapshot = f.document.store.model
        let prepared = try await f.runtime.prepareCleanup(model: snapshot, episode: f.model.episodeID, requireReady: false)
        let lane = try #require(prepared.plan.lanes.first { $0.primary.sourceID == f.target })
        let end = try #require(lane.regions.last?.alignedEnd)
        let start = floor(end * 48_000) / 48_000
        try #require(end > start && (end - start) * 48_000 < 0.5)
        let preview = try await f.runtime.cleanupPreview(model: snapshot, episode: f.model.episodeID,
            start: start, duration: 1.0 / 48_000, respectWorkingRange: false)
        #expect(preview.channels.count == 2)
        #expect(preview.channels.values.allSatisfy { $0.count == 1 && $0[0] == 0 })
        #expect(f.document.store.model == snapshot)
    }

    @Test func actualPausePreferredPCMRetainsSilenceCoverageFillersAndSourceAnchors() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1,
            durationSeconds: 70, pauses: [26..<27, 51..<52])
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 1.0 / 48_000, outValue: 69.5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true)
        let lane = try #require(cleanup.plan?.lanes.first)
        let snapshot = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let probe = TranscriptionFrameProbe()
        let transcripts = try await f.runtime.transcribeCleanup(model: snapshot, episode: f.model.episodeID,
            modelRevision: "pause-window-probe", transcribeWindow: { pcm in
                _ = await probe.transcribe(pcm)
                return PCMTranscript(segments: [
                    PCMSegment(text: "um,", startSeconds: 1.25, endSeconds: 1.5),
                    PCMSegment(text: "untimed filler uh", startSeconds: nil, endSeconds: nil),
                ])
            }, progress: { await probe.progress($0) })
        let updates = await probe.updates
        let completed = updates.filter { $0.stage == .completedWindow }
        let recognizing = updates.filter { $0.stage == .recognizing }
        #expect(completed.count == 3 && recognizing.count == 3)
        #expect(abs(completed[0].alignedEnd - 26.5) < 0.02)
        #expect(abs(completed[1].alignedEnd - 51.5) < 0.02)
        #expect(completed.last?.alignedEnd == lane.end)
        #expect(zip(completed, completed.dropFirst()).allSatisfy { $0.alignedEnd == $1.alignedStart })
        #expect(completed.map(\.windowCount) == [0, 0, 3])
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        let firstFrame = Int64((lane.start * 48_000).rounded())
        let lastFrame = Int64((lane.end * 48_000).rounded())
        let expectedCounts = recognizing.map { update -> Int in
            let first = max(firstFrame, Int64((update.alignedStart * 48_000).rounded()) - 48_000)
            let last = min(lastFrame, Int64((update.alignedEnd * 48_000).rounded()) + 48_000)
            return Int(last - first)
        }
        #expect(await probe.counts == expectedCounts)
        let transcript = try #require(transcripts.first)
        #expect(transcript.words.map(\.text) == ["um,", "untimed filler uh", "um,", "untimed filler uh", "um,", "untimed filler uh"])
        for (index, update) in recognizing.enumerated() {
            let audioStart = max(lane.start, update.alignedStart - 1)
            let word = transcript.words[index * 2]
            #expect(abs(try #require(word.alignedStart) - audioStart - 1.25) < 1.0 / 48_000)
            #expect(word.sourceStartFrame == lane.sourceRange(start: audioStart + 1.25, end: audioStart + 1.5)?.lowerBound)
            #expect(word.sourceEndFrame == lane.sourceRange(start: audioStart + 1.25, end: audioStart + 1.5)?.upperBound)
        }
        #expect(f.document.store.model == snapshot)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func progressAccumulatesCompletedCoresAcrossEveryPrimary() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true, "\(cleanup.error ?? "")")
        let probe = TranscriptionFrameProbe()
        let snapshot = f.document.store.model
        let result = try await f.runtime.transcribeCleanup(model: snapshot,
            episode: f.model.episodeID, modelRevision: "synthetic-progress-probe",
            transcribeWindow: { await probe.transcribe($0) }, progress: { await probe.progress($0) })
        let updates = await probe.updates
        let completed = updates.filter { $0.stage == .completedWindow }
        #expect(result.count == 2)
        #expect(completed.map(\.fraction) == [0.5, 1])
        #expect(completed.map(\.speakerIndex) == [1, 2])
        #expect(completed.map(\.completedSeconds) == [5, 10])
        #expect(updates.allSatisfy { $0.totalSeconds == 10 && $0.speakerCount == 2 })
        #expect(f.document.store.model == snapshot, "Progress never publishes intermediate words")
    }

    @Test(arguments: [ParallelTranscriptionOutcome.success, .failure, .cancellation])
    func parallelPrimariesPreserveOrderAndDrainOnFailureOrCancellation(_ outcome: ParallelTranscriptionOutcome) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true, "\(cleanup.error ?? "")")
        let snapshot = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let reference = try await f.runtime.transcribeCleanup(model: snapshot,
            episode: f.model.episodeID, modelRevision: "parallel-probe",
            transcribeWindow: { _ in ParallelTranscriptionProbe.result }, progress: { _ in })
        let pool = TranscriptionWorkerPool(concurrency: .two)
        let probe = ParallelTranscriptionProbe(outcome: outcome)
        let job = Task {
            try await f.runtime.transcribeCleanup(model: snapshot, episode: f.model.episodeID,
                modelRevision: "parallel-probe", concurrency: .two, workerPool: pool,
                transcribeWindow: { try await probe.transcribe($0) }, progress: { await probe.progress($0) })
        }
        defer { job.cancel() }
        if outcome == .cancellation {
            let deadline = Date().addingTimeInterval(10)
            while await probe.entered < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(await probe.entered == 2)
            job.cancel()
        }
        switch outcome {
        case .success:
            let result = try await job.value
            #expect(result.map(\.speaker) == reference.map(\.speaker), "Completion order never becomes transcript order")
            for (actual, serial) in zip(result, reference) {
                #expect(actual.sourceIdentity == serial.sourceIdentity && actual.primary == serial.primary)
                #expect(actual.alignmentRevision == serial.alignmentRevision && actual.workingRange == serial.workingRange)
                #expect(actual.words.count == serial.words.count)
                #expect(zip(actual.words, serial.words).allSatisfy {
                    $0.text == $1.text && $0.sourceStartFrame == $1.sourceStartFrame
                        && $0.sourceEndFrame == $1.sourceEndFrame && $0.alignedStart == $1.alignedStart
                        && $0.alignedEnd == $1.alignedEnd
                })
            }
            #expect(await probe.finished == [2, 1], "The test deliberately finishes the second worker first")
            let updates = await probe.updates
            #expect(updates.contains { $0.activeSpeakers.count == 2 })
            #expect(updates.filter { $0.stage == .completedWindow }.map(\.completedSeconds) == [5, 10])
            #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
            #expect(updates.last?.stage == .verifying && updates.last?.fraction == 1)
        case .failure:
            await #expect(throws: ParallelTranscriptionFailure.expected) { try await job.value }
        case .cancellation:
            await #expect(throws: CancellationError.self) { try await job.value }
        }
        #expect(await probe.peak == 2)
        #expect(await probe.active == 0)
        let workers = await pool.snapshot
        #expect(workers.active == 0 && workers.waiting == 0 && workers.peakActive == 2)
        #expect(f.document.store.model == snapshot, "No parallel worker publishes a partial result")
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func verifiedModelLoadingWaitsForAdmissionAndFailuresReleaseEverything() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: f.document.store),
            episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true)
        let snapshot = f.document.store.model
        let pool = TranscriptionWorkerPool(concurrency: .four,
            budget: .init(memoryBytes: 10, cpuThreads: 4, metalWorkers: 1))
        let cost = TranscriptionResources(memoryBytes: 10, cpuThreads: 4, metalWorkers: 1)
        let holder = Task {
            try await pool.withAdmission(resources: cost) { try await Task.sleep(for: .seconds(30)) }
        }
        defer { holder.cancel() }
        let probe = TranscriptionLoadingProbe()
        let job = Task {
            try await f.runtime.transcribeCleanupWorkers(model: snapshot, episode: f.model.episodeID,
                modelRevision: "captured-metal-recipe", concurrency: .two, workerPool: pool,
                resources: { bytes in
                    #expect(bytes > 32 << 20, "Actual multichannel decoder/render memory is included")
                    return cost
                },
                makeTranscriber: {
                    let budget = await pool.snapshot
                    #expect(budget.reservedBytes == 10 && budget.activeCPUThreads == 4 && budget.activeMetalWorkers == 1)
                    await probe.loaded()
                    throw TranscriptionConfigurationError.metalUnavailable
                }, progress: { await probe.progress($0) })
        }
        defer { job.cancel() }
        let deadline = Date().addingTimeInterval(10)
        while await pool.snapshot.waiting < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await pool.snapshot.waiting == 2)
        #expect(await probe.loads == 0, "No verified model bytes are retained while work queues behind another episode")
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        await #expect(throws: TranscriptionConfigurationError.metalUnavailable) { try await job.value }
        let drained = await pool.snapshot
        #expect(drained.active == 0 && drained.waiting == 0 && drained.reservedBytes == 0)
        #expect(drained.activeCPUThreads == 0 && drained.activeMetalWorkers == 0)
        #expect(await probe.sawLoading)
        #expect(f.document.store.model == snapshot, "Model/backend failure cannot publish partial words")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Timed out waiting for synthetic timing")
    }
}

enum ParallelTranscriptionOutcome: Sendable { case success, failure, cancellation }
private enum ParallelTranscriptionFailure: Error { case expected, timedOut }
private actor ParallelTranscriptionProbe {
    let outcome: ParallelTranscriptionOutcome
    var entered = 0
    var active = 0
    var peak = 0
    var finished: [Int] = []
    var updates: [CleanupTranscriptionProgress] = []
    init(outcome: ParallelTranscriptionOutcome) { self.outcome = outcome }

    static var result: PCMTranscript {
        PCMTranscript(segments: [PCMSegment(text: "core", startSeconds: 1.25, endSeconds: 1.5)])
    }

    func transcribe(_ samples: [Float]) async throws -> PCMTranscript {
        #expect(samples.count == 5 * 48_000)
        entered += 1
        let index = entered
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        let deadline = Date().addingTimeInterval(10)
        while entered < 2 {
            guard Date() < deadline else { throw ParallelTranscriptionFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        if outcome == .failure, index == 1 { throw ParallelTranscriptionFailure.expected }
        if outcome != .success { try await Task.sleep(for: .seconds(60)) }
        if index == 1 { try await Task.sleep(for: .milliseconds(50)) }
        finished.append(index)
        return Self.result
    }

    func progress(_ update: CleanupTranscriptionProgress) { updates.append(update) }
}

private actor TranscriptionLoadingProbe {
    var loads = 0
    var sawLoading = false
    func loaded() { loads += 1 }
    func progress(_ update: CleanupTranscriptionProgress) {
        if update.stage == .loading { sawLoading = true }
    }
}

private actor TranscriptionFrameProbe {
    var counts: [Int] = []
    var allSamplesValid = true
    var lastProgress = 0.0
    var updates: [CleanupTranscriptionProgress] = []

    func transcribe(_ samples: [Float]) -> PCMTranscript {
        counts.append(samples.count)
        allSamplesValid = allSamplesValid && samples.allSatisfy(\.isFinite) && samples.contains { abs($0) > 0.001 }
        return PCMTranscript(segments: [
            PCMSegment(text: "context", startSeconds: 0.25, endSeconds: 0.5),
            PCMSegment(text: "core", startSeconds: 1.25, endSeconds: 1.5),
        ])
    }

    func progress(_ update: CleanupTranscriptionProgress) {
        lastProgress = update.fraction
        updates.append(update)
    }
}
