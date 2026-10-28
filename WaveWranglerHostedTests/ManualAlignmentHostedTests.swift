import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WWAlignPipeline
import WWCore
import WWDerived
import WWSources
import WWTimeMap
@testable import WaveWrangler

@MainActor
@Suite("Interactive manual alignment and honest source-time audition", .serialized)
struct ManualAlignmentHostedTests {
    private func wait(_ reason: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), Comment(rawValue: reason()))
    }

    private func ready(_ f: AlignmentWaveformRetentionHostedTests.Fixture) async throws {
        try await wait(f.model.lastError ?? f.model.waveformMessage) {
            !f.model.isWorking && f.model.trackProcessingOperation == nil
                && !f.model.waveformNeedsRefreshAfterSave && f.document.verifiedModel == f.document.store.model
        }
    }

    private func point(_ seconds: Double, on track: AlignmentWaveformTrack,
                       in model: EpisodeAlignmentModel) throws {
        model.selectWaveform(track)
        let stroke = try #require(model.waveformInteractionStrokes(for: track.id).min {
            abs($0.sourceSeconds - seconds) < abs($1.sourceSeconds - seconds)
        })
        model.selectWaveformAnchorPoint(track, position: stroke, sourceSeconds: seconds)
        try #require(model.waveformPickedPoint?.source == track.id)
    }

    @Test func soloAnUntimedRecordingPlaysOriginalTimeWithoutSavingAnAlignment() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(durationSeconds: 4)
        defer { f.close() }
        let before = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        f.model.setSoloed(true, scope: .source(f.target))
        f.model.waveformPlayheadSeconds = 0.25
        #expect(f.model.isSourceTimePreview && !f.model.sourceHasAcceptedTiming(f.target))
        f.model.playEnabledTracks(interval: 0.25...1.25, repeatInterval: false)
        try await wait(f.model.lastError ?? f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.model.listeningMode == .sourceTimePreview)
        #expect(f.model.sourceTimePreviewSource == f.target)
        #expect(f.model.auditionLabel.contains("source"))
        try await wait(f.model.auditionLabel) { !f.model.canStopAudition }
        #expect(abs(f.model.waveformPlayheadSeconds - 1.25) < 1 / 48_000)
        #expect(f.model.auditionLabel.contains("No timing was applied"))
        #expect(f.document.store.model == before && before.episodes[0].alignment?.acceptedRevision == nil)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func sourceTimeRenderingStillRequiresTheCurrentOriginalAuthorization() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(durationSeconds: 4)
        defer { f.close() }
        let snapshot = f.document.store.model
        let clips = try await f.runtime.sourceAuditions(model: snapshot, episode: f.model.episodeID,
            sources: [f.target], outputFrames: 12_000..<36_000, applyingCuts: false, timebase: .sourceTime)
        let clip = try #require(clips[f.target])
        #expect(clip.sampleRate == 48_000 && clip.channelCount == 1 && clip.samples.count == 24_000)
        #expect(clip.samples.contains { abs($0) > 0.001 } && clip.samples.allSatisfy(\.isFinite))
        let store = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        try await store.removeRecord(for: .init(showID: snapshot.show.id, sourceID: f.target))
        await #expect(throws: (any Error).self) {
            try await f.runtime.sourceAuditions(model: snapshot, episode: f.model.episodeID,
                sources: [f.target], outputFrames: 12_000..<36_000, applyingCuts: false, timebase: .sourceTime)
        }
        #expect(f.document.store.model == snapshot)
    }

    @Test func sourceTimeAuditionStartsAtTheRecordingInsteadOfPlayingNegativePreroll() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(durationSeconds: 4)
        defer { f.close() }
        let original = f.document.store.model
        f.model.setSoloed(true, scope: .source(f.target))
        f.model.waveformPlayheadSeconds = -300
        f.model.playEnabledTracks()
        try await wait(f.model.lastError ?? f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.model.playbackClockForTesting?.startSeconds == 0)
        f.model.stopAudition()
        #expect(f.document.store.model == original)
    }

    @Test func onePairAppliesOffsetSecondPairFitsDriftAndLaterMovesRemainUndoable() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(extraSources: 1)
        defer { f.close() }
        let before = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        let reference = try #require(f.model.waveformTracks.first { $0.group == f.model.referenceGroup })
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        try point(1, on: reference, in: f.model)
        f.model.markWaveformReference(reference)
        let marker = try #require(f.model.waveformReferenceMarkers.first)
        try point(2, on: target, in: f.model)
        #expect(f.model.canCorrect && f.model.canMoveGroup)
        f.model.linkWaveformAnchor(marker, to: target)
        #expect(f.model.waveformDraftAnchors == [.init(sourceSeconds: 2, alignedSeconds: 1)])
        f.model.applyWaveformAnchors()
        try await ready(f)
        #expect(f.model.selectedAnchors.count == 1)
        #expect(abs((f.model.selectedRow?.offsetMilliseconds ?? .infinity) + 1_000) < 0.001)
        #expect(f.model.canMoveGroup && !f.model.positionIsLocked(target.group))
        let first = f.document.store.model
        let referenceMap = try #require(f.model.waveformMap?.groups.first { $0.group == reference.group })
        try point(11, on: reference, in: f.model)
        f.model.markWaveformReference(reference)
        let second = try #require(f.model.referenceMarkers(for: target).last)
        try point(12.001, on: target, in: f.model)
        f.model.linkWaveformAnchor(second, to: target)
        #expect(f.model.waveformDraftAnchors.count == 2, "The first saved pair remains part of the fitted anchors")
        f.model.applyWaveformAnchors()
        try await ready(f)
        #expect(abs((f.model.selectedRow?.ratePPM ?? .infinity) + 99.990001) < 0.01)
        #expect(f.model.selectedAnchors.count == 2 && f.model.canMoveGroup)
        let anchored = f.document.store.model
        let oldOffset = try #require(f.model.selectedRow?.offsetMilliseconds)
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        f.model.groupDraftMilliseconds = 250
        f.model.commitGroupMove()
        try await ready(f)
        undo.endUndoGrouping()
        let moved = f.document.store.model
        #expect(abs((f.model.selectedRow?.offsetMilliseconds ?? .infinity) - oldOffset - 250) < 0.001)
        #expect(f.model.waveformMap?.groups.first { $0.group == reference.group } == referenceMap)
        #expect(f.model.waveformMap?.groups.first { $0.group == target.group }?.placements.count == 2)
        undo.undo()
        try await ready(f)
        #expect(f.document.store.model == anchored)
        undo.redo()
        try await ready(f)
        #expect(f.document.store.model == moved && f.model.canMoveGroup)
        #expect(moved.episodes[0].sources == before.episodes[0].sources)
        #expect(first.episodes[0].alignment?.acceptedRevision != nil)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func onePairOutsideTheRecordingCannotPublishAPosition() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(durationSeconds: 4)
        defer { f.close() }
        let original = f.document.store.model
        let track = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(track)
        f.model.waveformTargetPoint = 100
        f.model.waveformReferencePoint = 1
        f.model.addWaveformAnchor()
        f.model.applyWaveformAnchors()
        #expect(f.model.lastError?.contains("inside the original recording") == true)
        #expect(f.document.store.model == original && !f.model.isWorking)
    }

    @Test func anUnplacedGroupBesideDynamicTimingCanMoveWhileTheCorrectedGroupNeedsReset() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(extraGroups: 1)
        defer { f.close() }
        let original = f.document.store.model
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        let unplaced = try #require(f.model.waveformTracks.first { $0.name == "unplaced-0.wav" })
        _ = try await f.runtime.prepareManual(model: original, episode: f.model.episodeID)
        let base = try await f.runtime.accept(model: original, episode: f.model.episodeID,
            decisions: [target.epoch: .numeric(ppm: 0, offsetMilliseconds: 0)])
        try #require(f.model.publishAlignment(base, expecting: original, actionName: "Synthetic partial acceptance"))
        try await ready(f)
        let prior = f.document.store.model
        let episode = try #require(prior.episode(f.model.episodeID))
        let version = try #require(episode.alignment?.acceptedMap)
        let map = try prior.timeMap(revision: version.revision, in: episode.id)
        let referenceSource = try #require(episode.sources.first?.id)
        let correction = SourceTimingCorrection(source: target.id, group: target.group, epoch: target.epoch,
            reference: referenceSource, sourceRate: target.envelope.sampleRate,
            sourceFrames: target.envelope.totalFrames, channelCount: 1,
            analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
            segments: [.init(sourceStart: 0, sourceEnd: 40, alignedStart: 0.1, rateRatio: 1)])
        let coordinator = await f.runtime.coordinator
        let inputs = await coordinator.inputs
        let digest = try #require(MapDependencies.digest(map: map, tokens: inputs.sources,
            format: inputs.format, corrections: [correction]))
        let recorded = try prior.recordingMap(map, in: episode.id, inputs: version.inputs.sources,
            recipe: MapDependencies.recipe(digest: digest), derivedFrom: version.revision, sourceCorrections: [correction])
        let corrected = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: episode.id)
        let published = f.document.store.applyReplacement("Synthetic dynamic timing", expecting: prior,
            model: corrected, afterChange: { _ in })
        try #require(published)
        try await MixerHostedTests().save(f.document)
        f.model.load()
        f.model.loadWaveforms()
        try await ready(f)
        f.model.selectWaveform(target)
        #expect(!f.model.canMoveGroup && !f.model.canCorrect)
        #expect(f.model.manualTimingBlockReason(for: target.group) != nil)
        f.model.applyNumeric(ratePPM: 0, offsetMilliseconds: 100)
        #expect(f.document.store.model == corrected)
        f.model.saveAdaptiveCorrection(restoringAudio: target.id)
        try await ready(f)
        #expect(f.model.adaptiveCorrection(for: target.id) == correction,
                "Restoring unmatched audio remains available without unlocking the underlying recorder clock")
        f.model.selectWaveform(unplaced)
        #expect(f.model.selectedWaveform != nil && f.model.canMoveGroup && f.model.canCorrect)
        f.model.groupDraftMilliseconds = 200
        f.model.commitGroupMove()
        try await ready(f)
        #expect(f.document.store.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == [correction])
        #expect(f.model.sourceHasAcceptedTiming(unplaced.id) && f.model.canMoveGroup)
        f.model.selectWaveform(target)
        f.model.saveAdaptiveCorrection(removing: target.id)
        try await ready(f)
        #expect(f.model.adaptiveCorrection(for: target.id) == nil)
        #expect(f.model.canMoveGroup && f.model.canCorrect)
        f.model.setPositionLocked(true, group: target.group)
        #expect(!f.model.canMoveGroup && !f.model.canCorrect, "Explicit user position locks remain authoritative")
    }
}
