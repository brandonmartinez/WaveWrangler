import AppKit
import Foundation
import SwiftUI
import Testing
import WWCore
import WWPersistence
import WWSpeech
import WWTimeMap
@testable import WaveWrangler

@MainActor
@Suite("Episode cleanup window state", .serialized)
struct EpisodeCleanupModelTests {
    private func fixture() -> EpisodeCleanupModel {
        let episode = Episode(title: "A",
            alignment: EpisodeAlignment(maps: [TimeMapVersion(revision: 1,
                inputs: TimeMapInputs(sources: []), map: .null)], acceptedRevision: 1))
        let state = ShowWindowState(store: ShowDocumentStore(model: ShowDocumentModel(
            show: Show(title: "Synthetic"), episodes: [episode, Episode(title: "B")])))
        return EpisodeCleanupModel(state: state, episodeID: episode.id)
    }

    @Test func viewportChangesKeepMeasuredOverviewAndUseOneScale() {
        let model = fixture()
        defer { model.cancel() }
        let speaker = SpeakerID()
        model.overviewStrokes[speaker] = []
        let snapshot = model.waveformSnapshot
        model.windowStart = 1
        #expect(model.overviewStrokes[speaker] != nil)
        #expect(model.visibleDuration == 10)
        model.windowDuration = 5
        #expect(model.visibleDuration == 5)
        #expect(model.waveformSnapshot == snapshot)
    }

    @Test func markersAreSharedOnlyWithinTheirEpisodeAndDoNotTouchAlignment() throws {
        let model = fixture()
        let original = model.state.store.model
        model.saveRange(inValue: 1, outValue: 4)
        #expect(model.error == nil)
        #expect(model.episode?.cleanup?.workingRange?.tracksIn == 1)
        #expect(model.episode?.alignment == original.episodes[0].alignment)
        #expect(model.state.store.model.episodes[1] == original.episodes[1])
        model.saveRange(inValue: 4, outValue: 1)
        #expect(model.error != nil)
        #expect(model.episode?.cleanup?.workingRange?.tracksIn == 1)
        model.saveRange(inValue: nil, outValue: nil)
        #expect(model.episode?.cleanup?.workingRange == nil)
    }

    @Test func invalidNavigationIsAnExplicitErrorAndNeverReadsAudio() {
        let model = fixture()
        defer { model.cancel() }
        model.windowStart = .nan
        model.loadWaveforms()
        #expect(model.error != nil)
        #expect(model.windowStrokes.isEmpty)
        #expect(!model.isLoadingWaveforms && !model.isPlaying)
        #expect(!model.canTranscribe)
    }

    @Test func changedDocumentInvalidatesSelectionReadinessAndWaveforms() {
        let model = fixture()
        model.overviewStrokes[SpeakerID()] = []
        model.selectedWord = TranscriptWord(text: "um")
        model.modelDidChange()
        #expect(model.overviewStrokes.isEmpty)
        #expect(model.plan == nil)
        #expect(model.selectedWord == nil)
        #expect(model.identities.isEmpty)
        #expect(!model.canTranscribe)
    }

    @Test func resettingAnAlreadyEmptyRangeStillRestoresTheDraftFields() {
        let model = fixture()
        model.saveRange(inValue: nil, outValue: nil)
        let generation = model.state.store.modelGeneration
        model.inText = "unapplied draft"
        model.outText = "4"
        model.saveRange(inValue: nil, outValue: nil)
        #expect(model.state.store.modelGeneration == generation)
        #expect(model.inText.isEmpty && model.outText.isEmpty)
    }

    @Test func malformedAcceptedTimingIsAnExplicitErrorNotSuccessfulReadiness() async {
        let model = fixture()
        await model.refresh()
        #expect(model.error?.contains("Accepted alignment could not be read") == true)
        #expect(model.plan == nil)
        #expect(!model.canTranscribe)
    }

    private func timelineFixture(offset: ExactRational = ExactRational(-2)) throws -> EpisodeCleanupModel {
        let speaker = Speaker(name: "Host")
        let epoch = RecordingEpoch(label: "Take")
        let group = RecorderGroup(name: "Recorder", epochs: [epoch])
        let referenceEpoch = RecordingEpoch(label: "Reference")
        let referenceGroup = RecorderGroup(name: "Reference", epochs: [referenceEpoch])
        let referenceSource = SourceRecord(displayNameHint: "Reference.wav",
            placement: .init(recorderGroupID: referenceGroup.id, epochID: referenceEpoch.id),
            role: .backup, roleConfirmation: .userConfirmed)
        let source = SourceRecord(displayNameHint: "Synthetic.wav", observations: .init(channelCount: .known(1)),
            placement: .init(recorderGroupID: group.id, epochID: epoch.id),
            role: .primary, roleConfirmation: .userConfirmed)
        let occurrence = try SourceOccurrence(source: source.id, nominalRate: NominalRate(16_000), frameCount: 480_000)
        let referenceOccurrence = try SourceOccurrence(
            source: referenceSource.id, nominalRate: NominalRate(16_000), frameCount: 480_000)
        let reference = TimelineReference(
            group: referenceGroup.id, epoch: referenceEpoch.id, occurrence: referenceOccurrence.id)
        let referenceSegment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(30), rateRatio: .one, alignedOffset: .zero)
        let referenceMap = try GroupTimeMap(group: referenceGroup.id, reference: reference,
            epochs: [.init(epoch: referenceEpoch.id,
                           mapping: .mapped(segments: [referenceSegment], provenance: .timelineReference))],
            placements: [.init(occurrence: referenceOccurrence, spans: [
                .init(startFrame: 0, endFrame: 480_000, epoch: referenceEpoch.id, groupClockOffset: .zero)])])
        let segment = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(30),
            rateRatio: .one, alignedOffset: offset)
        let groupMap = try GroupTimeMap(group: group.id, reference: reference,
            epochs: [.init(epoch: epoch.id,
                           mapping: .mapped(segments: [segment], provenance: .manual(.init(basis: .numericEntry))))],
            placements: [.init(occurrence: occurrence, spans: [
                .init(startFrame: 0, endFrame: 480_000, epoch: epoch.id, groupClockOffset: .zero)])])
        let map = try AlignedTimelineMap(reference: reference, groups: [referenceMap, groupMap])
        let episode = Episode(title: "Synthetic", recorderGroups: [referenceGroup, group], sources: [referenceSource, source],
            speakerAssignments: [.init(speakerID: speaker.id,
                primary: .init(sourceID: source.id, statedChannel: 0), primaryConfirmation: .userConfirmed)],
            alignment: .init(maps: [.init(revision: 1, inputs: .init(sources: [
                .init(sourceID: referenceSource.id), .init(sourceID: source.id),
            ]),
                                         map: try EmbeddedTimeMapCodec.encode(map))], acceptedRevision: 1),
            cleanup: .init(workingRange: .init(alignmentRevision: 1, tracksIn: 1, tracksOut: 4)))
        let model = ShowDocumentModel(show: Show(title: "Synthetic"), speakers: [speaker], episodes: [episode])
        let state = ShowWindowState(store: ShowDocumentStore(model: model))
        let result = EpisodeCleanupModel(state: state, episodeID: episode.id)
        result.plan = PrimaryCleanupPlan.make(model: model, episode: episode.id, map: map)
        return result
    }

    @Test func fitAndNavigationRetainNegativeTimeAndRecoverableBanter() throws {
        let model = try timelineFixture()
        defer { model.cancel() }
        model.playhead = 2
        let original = model.state.store.model
        model.fitTimeline()
        #expect(model.windowStart == -2 && model.windowDuration == 30)
        #expect(model.playhead == 2)
        model.seek(to: 20)
        #expect(model.playhead == 20, "Tracks Out does not hide recoverable banter")
        #expect(model.state.store.model == original, "Navigation never moves tracks or changes saved timing")
        model.setWindow(start: -2, duration: 0.5)
        #expect(model.visibleDuration == 0.5)
        model.setWindow(start: .nan, duration: 1)
        #expect(model.error != nil && model.windowStart == -2)
    }

    @Test(arguments: [false, true])
    func zoomCentersCurrentPlayheadAndClampsWithoutChangingTransportOrDocument(playing: Bool) throws {
        let model = try timelineFixture(offset: ExactRational(numerator: -19, denominator: 8))
        defer { model.cancel() }
        let original = model.state.store.model
        let snapshot = model.waveformSnapshot
        let selected = TranscriptWord(text: "synthetic", alignedStart: 7.125, alignedEnd: 7.5)
        model.selectedWord = selected
        model.isPlaying = playing
        model.transportMessage = playing ? "Playing synthetic timeline" : "Paused synthetic timeline"
        let status = model.transportMessage
        #expect(model.bounds == -2.375...27.625)
        for initialStart in [-2.375, 0.25, 17.625] {
            for time in [-2.375, -2.125, -0.375, 7.125, 27.375, 27.625] {
                for duration in [0.5, 1.25, 5, 20, 30] {
                    model.setWindow(start: initialStart, duration: 10)
                    model.playhead = time
                    model.zoomTimeline(duration: duration)
                    let expectedStart = min(27.625 - duration, max(-2.375, time - duration / 2))
                    #expect(abs(model.windowStart - expectedStart) < 0.000_001)
                    #expect(model.windowDuration == duration && model.visibleDuration == duration)
                    #expect(model.windowStart <= time && time <= model.windowStart + duration)
                    #expect(model.windowStart >= -2.375 && model.windowStart + duration <= 27.625)
                    #expect(model.playhead == time && model.isPlaying == playing)
                    #expect(!model.isPreparingPlayback && model.transportMessage == status)
                    #expect(model.error == nil)
                }
            }
        }
        #expect(model.state.store.model == original)
        #expect(model.selectedWord == selected && model.waveformSnapshot == snapshot)
    }

    @Test func successiveZoomUpdatesFollowTheLatestPlayheadEvenDuringPlaybackPreparation() throws {
        let model = try timelineFixture()
        defer { model.cancel() }
        model.isPreparingPlayback = true
        model.playhead = 10.25
        model.zoomTimeline(duration: 5)
        #expect(model.windowStart == 7.75)
        model.playhead = 11.125
        model.zoomTimeline(duration: 2)
        #expect(model.windowStart == 10.125)
        model.playhead = 10.875
        model.zoomTimeline(duration: 10)
        #expect(model.windowStart == 5.875)
        #expect(model.isPreparingPlayback && !model.isPlaying && model.playhead == 10.875)
    }

    @Test(arguments: [Int64(-86_400), 86_370])
    func zoomAtSupportedTimeLimitsClampsBeforeValidatingTheWindow(offset: Int64) throws {
        let model = try timelineFixture(offset: ExactRational(offset))
        defer { model.cancel() }
        for time in [model.bounds.lowerBound, model.bounds.upperBound] {
            model.playhead = time
            for duration in [0.5, 1.25, 30] {
                model.zoomTimeline(duration: duration)
                #expect(model.error == nil)
                #expect(model.windowDuration == duration && model.playhead == time)
                let expectedStart = time == model.bounds.lowerBound ? time : time - duration
                #expect(model.windowStart == expectedStart)
            }
        }
    }

    @Test func zoomDoesNotTurnPanningIntoSeekingAndFitStillShowsTheFullTimeline() throws {
        let model = try timelineFixture()
        defer { model.cancel() }
        model.playhead = 20.125
        model.setWindow(start: -1.5, duration: 5)
        #expect(model.windowStart == -1.5 && model.playhead == 20.125)
        model.zoomTimeline(duration: 2)
        #expect(model.windowStart == 19.125 && model.playhead == 20.125)
        model.setWindow(start: -2, duration: 2)
        #expect(model.windowStart == -2 && model.playhead == 20.125)
        model.zoomTimeline(duration: 5)
        #expect(model.windowStart == 17.625)
        model.fitTimeline()
        #expect(model.windowStart == -2 && model.windowDuration == 30 && model.playhead == 20.125)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, 0.25, 30.5])
    func invalidZoomReportsAnErrorAndLeavesViewportAndPlayheadUnchanged(duration: Double) throws {
        let model = try timelineFixture()
        defer { model.cancel() }
        model.setWindow(start: 5, duration: 10)
        model.playhead = 8.125
        model.zoomTimeline(duration: duration)
        #expect(model.error != nil)
        #expect(model.windowStart == 5 && model.windowDuration == 10 && model.playhead == 8.125)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -86_401, 86_401])
    func zoomRejectsAnInvalidPlayheadWithoutChangingTheViewport(time: Double) throws {
        let model = try timelineFixture()
        defer {
            model.playhead = 0
            model.cancel()
        }
        model.setWindow(start: 5, duration: 10)
        model.playhead = time
        model.zoomTimeline(duration: 1)
        #expect(model.error != nil)
        #expect(model.windowStart == 5 && model.windowDuration == 10)
        #expect(time.isNaN ? model.playhead.isNaN : model.playhead == time)
    }

    @Test func clickToolsAndPlayheadButtonsSaveCommonUndoableMarkersNotTrackMoves() throws {
        let model = try timelineFixture()
        defer { model.cancel() }
        let alignment = model.episode?.alignment
        model.timelineTool = .markIn
        model.timelineClick(at: 2)
        model.timelineTool = .markOut
        model.timelineClick(at: 3.25)
        #expect(model.episode?.cleanup?.workingRange?.tracksIn == 2)
        #expect(model.episode?.cleanup?.workingRange?.tracksOut == 3.25)
        #expect(model.episode?.alignment == alignment)
        model.timelineTool = .seek
        model.timelineClick(at: 25)
        #expect(model.playhead == 25 && model.episode?.cleanup?.workingRange?.tracksOut == 3.25)
        model.seek(to: .nan)
        #expect(model.playhead == 25 && model.error != nil && !model.isPlaying)
    }

    @Test func mutingDoesNotWeakenAllPrimaryReadinessOrChangeTheDocument() throws {
        let model = try timelineFixture()
        let speaker = try #require(model.plan?.lanes.first?.speaker)
        let original = model.state.store.model
        #expect(model.plan?.isReady == true)
        model.setSpeaker(speaker, enabled: false)
        #expect(model.mutedSpeakers == [speaker])
        #expect(model.plan?.isReady == true)
        #expect(model.state.store.model == original)
        model.setSpeaker(speaker, enabled: true)
        #expect(model.mutedSpeakers.isEmpty)
        #expect(!model.canTranscribe, "A view-only mute never grants missing live-source/model admission")
    }

    @Test func existingRawTranscriptGetsReviewHintsWithoutRetranscriptionOrDocumentChanges() throws {
        let model = try timelineFixture()
        defer { model.cancel() }
        let lane = try #require(model.plan?.lanes.first)
        let identity = String(repeating: "a", count: 64)
        model.identities[lane.primary.sourceID] = identity
        let words: [TranscriptWord] = (0..<8).map { index in
            let time = 1.0 + Double(index) * 0.25
            let frame = Int64((time + 2) * Double(lane.sourceRate))
            return TranscriptWord(text: "no,", sourceStartFrame: frame,
                sourceEndFrame: frame + Int64(lane.sourceRate / 5),
                alignedStart: time, alignedEnd: time + 0.2)
        }
        var transcript = SpeakerTranscript(speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
            sourceIdentity: identity, alignmentRevision: 1, model: "Existing synthetic transcript",
            workingRange: model.episode?.cleanup?.workingRange, words: words)
        func save(_ transcript: SpeakerTranscript) throws {
            try #require(model.state.store.apply("Seed synthetic recognition", { document throws(DomainError) in
                try document.settingCleanup(EpisodeCleanup(workingRange: transcript.workingRange,
                    transcripts: [transcript]), in: model.episodeID)
            }))
        }
        try save(transcript)
        let snapshot = model.state.store.model
        #expect(model.uncertainWordIDs(for: lane) == Set(words.map(\.id)))
        #expect(model.uncertainWordIDs(for: lane) == Set(words.map(\.id)), "Cached review returns the same IDs")
        #expect(model.visibleWords(for: lane) == words)
        model.state.inspectorPresented = false
        model.select(words[0], speaker: lane.speaker)
        #expect(model.selectedWord == words[0] && model.state.inspectorPresented)
        #expect(model.playhead == words[0].alignedStart)
        #expect(model.state.store.model == snapshot, "Review never deletes, retimes, accepts cuts or republishes text")
        transcript.words = Array(words.prefix(5))
        try save(transcript)
        #expect(model.transcript(for: lane)?.id == transcript.id)
        #expect(model.uncertainWordIDs(for: lane).isEmpty, "Same-ID transcript edits invalidate cached review")
    }

    private func fillerFixture(adaptiveGap: Bool? = nil) throws -> EpisodeCleanupModel {
        let model = try timelineFixture()
        var snapshot = model.state.store.model
        if let adaptiveGap {
            let lane = try #require(model.plan?.lanes.first)
            let region = try #require(lane.regions.first)
            let group = try #require(model.episode?.sources.first { $0.id == lane.primary.sourceID }?.placement.recorderGroupID)
            let reference = snapshot.episodes[0].sources[0].id
            snapshot.episodes[0].alignment?.maps[0].sourceCorrections = [
                SourceTimingCorrection(source: lane.primary.sourceID, group: group, epoch: region.epoch,
                    reference: reference,
                    sourceRate: 16_000, sourceFrames: 480_000, channelCount: 1,
                    analysisDigest: String(repeating: "a", count: 64),
                    processing: "ww-native-time-pitch-multichannel/1", segments: [
                        SourceTimingSegment(sourceStart: 0, sourceEnd: 6, alignedStart: -2, rateRatio: 1),
                        SourceTimingSegment(sourceStart: adaptiveGap ? 8 : 6, sourceEnd: 30,
                                            alignedStart: adaptiveGap ? 6 : 4, rateRatio: 1.0002),
                    ]),
            ]
            snapshot.episodes[0].cleanup?.workingRange?.tracksOut = 12
        }
        let map = try snapshot.timeMap(revision: 1, in: model.episodeID)
        model.plan = PrimaryCleanupPlan.make(model: snapshot, episode: model.episodeID, map: map)
        let lane = try #require(model.plan?.lanes.first)
        let identity = String(repeating: "a", count: 64)
        model.identities[lane.primary.sourceID] = identity
        let a = adaptiveGap == nil ? 2.0 : 3.75
        let b = adaptiveGap == false ? 4.15 : a + 0.2
        let frames = try #require(lane.sourceRange(start: a, end: b))
        let words = [
            TranscriptWord(text: "Um,", sourceStartFrame: frames.lowerBound, sourceEndFrame: frames.upperBound,
                           alignedStart: a, alignedEnd: b),
            TranscriptWord(text: "uh"),
        ]
        let workingRange = snapshot.episodes[0].cleanup?.workingRange
        snapshot.episodes[0].cleanup?.transcripts = [
            SpeakerTranscript(speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
                sourceIdentity: identity, alignmentRevision: 1, model: "synthetic-review-recipe",
                workingRange: workingRange, words: words),
        ]
        model.state.store.replaceLoadedModel(snapshot)
        return model
    }

    @Test func findingCandidatesIsIdempotentAndReviewNeverChangesRawTextOrTiming() throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        let raw = model.episode?.cleanup?.transcripts
        let alignment = model.episode?.alignment
        model.proposeFillers()
        let review = try #require(model.fillerReviews.first)
        #expect(model.fillerReviews.count == 1, "Untimed uh has no invented rails")
        #expect(model.fillerIssue(review) == nil)
        let snapshot = model.state.store.model
        model.proposeFillers()
        #expect(model.state.store.model == snapshot)
        model.selectFiller(review.id)
        model.nudgeFiller(review.id, edge: .start, seconds: -0.001)
        #expect(model.selectedFiller?.bounds.alignedEnd == review.bounds.alignedEnd)
        #expect(model.selectedFiller?.bounds.alignedStart == review.bounds.alignedStart - 0.001)
        model.nudgeFiller(review.id, edge: .end, seconds: 0.001)
        #expect(model.selectedFiller?.bounds.alignedEnd == review.bounds.alignedEnd + 0.001)
        #expect(model.selectedFiller?.status == "Adjusted")
        #expect(model.selectedFiller?.detectedBounds == review.detectedBounds)
        #expect(model.episode?.cleanup?.transcripts == raw)
        #expect(model.episode?.alignment == alignment)
        model.decideFiller(review.id, decision: .rejected)
        model.proposeFillers()
        #expect(model.selectedFiller?.decision == .rejected)
        model.revertFiller(review.id)
        #expect(model.selectedFiller == review)
        model.decideFiller(review.id, decision: .reviewed)
        #expect(model.selectedFiller?.status == "Reviewed unchanged")
    }

    @Test(arguments: [false, true])
    func fillerHandlesMoveBeforeMouseUpWithoutPublishingTiming(endEdge: Bool) async throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        model.proposeFillers()
        model.windowStart = 1
        model.windowDuration = 3
        let review = try #require(model.fillerReviews.first)
        let snapshot = model.state.store.model
        let generation = model.state.store.modelGeneration
        let host = HostedTimelineWindow(width: 900, height: 96,
            content: FillerTimingOverlay(model: model, reviews: model.fillerReviews))
        defer { host.close() }
        try await host.settle()
        func handle(_ isEnd: Bool) throws -> CGRect {
            let frames = host.controlFrames.filter { abs($0.width - 18) < 1 && abs($0.height - 18) < 1 }
                .sorted { $0.minY < $1.minY }
            try #require(frames.count == 2, "Expected two real boundary controls: \(host.controlFrames)")
            return frames[isEnd ? 1 : 0]
        }
        let original = try handle(endEdge)
        let stationary = try handle(!endEdge)
        let point = CGPoint(x: original.midX, y: original.midY)
        let direction = endEdge ? 1.0 : -1.0
        try await host.mouse([(.leftMouseDown, point)])
        for distance in [12.0, 30.0, 60.0, 24.0] {
            let dx = direction * distance
            try await host.mouse([(.leftMouseDragged, CGPoint(x: point.x + dx, y: point.y))])
            #expect(abs(try handle(endEdge).midX - original.midX - dx) < 1,
                    "The boundary must follow each pointer move, including reversing, while held down")
            #expect(try handle(!endEdge) == stationary, "The other boundary must not move")
            #expect(model.state.store.model == snapshot, "A preview is not a saved timing edit")
            #expect(model.state.store.modelGeneration == generation)
        }
        try host.capture("Live filler boundary preview before mouse up")
        try await host.mouse([(.leftMouseUp, CGPoint(x: point.x + direction * 24, y: point.y))])
        let updated = try #require(model.selectedFiller)
        #expect(abs(updated.bounds.alignedStart - review.bounds.alignedStart - (endEdge ? 0 : -0.08)) < 0.000_001)
        #expect(abs(updated.bounds.alignedEnd - review.bounds.alignedEnd - (endEdge ? 0.08 : 0)) < 0.000_001)
        #expect(model.state.store.modelGeneration == generation + 1, "Release publishes exactly one edit")
        #expect(model.episode?.cleanup?.transcripts == snapshot.episodes[0].cleanup?.transcripts)
        #expect(model.episode?.alignment == snapshot.episodes[0].alignment)
    }

    @Test func cancellingReviewClearsReactiveRefreshSkip() async throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        model.proposeFillers()
        let reviews = model.fillerReviews
        try #require(model.fillerPublicationGeneration == model.state.store.modelGeneration)
        try #require(!model.identities.isEmpty)
        model.cancel()
        #expect(model.fillerPublicationGeneration == nil)
        await model.refresh(skippingReviewOnlyChange: true)
        #expect(model.identities.isEmpty, "Re-entering the view requires fresh source verification")
        #expect(model.fillerReviews == reviews)
    }

    @Test(arguments: [(Double.nan, 2.3), (2.0, Double.infinity), (2.4, 2.3), (2.3, 2.3), (0.9, 2.3), (2.0, 4.1)])
    func crossingUnsupportedAndNonfiniteFillerBoundsRefuse(start: Double, end: Double) throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        model.proposeFillers()
        let review = try #require(model.fillerReviews.first)
        let snapshot = model.state.store.model
        model.setFillerBounds(review.id, start: start, end: end)
        #expect(model.error != nil)
        #expect(model.state.store.model == snapshot)
    }

    @Test func preciseFieldsDoNotRoundUntouchedEdgesAndManualMissesHaveNoDetectedTimes() throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        let lane = try #require(model.plan?.lanes.first)
        model.addManualFiller(speaker: lane.speaker, start: 2.123456789, end: 2.234567891)
        let manual = try #require(model.selectedFiller)
        #expect(manual.origin == .manual && manual.detectedBounds == nil)
        #expect(manual.transcriptID == model.episode?.cleanup?.transcripts.first?.id)
        model.applyFillerText()
        #expect(model.selectedFiller?.bounds == manual.bounds)
        model.fillerStartText = "2.124"
        model.applyFillerText()
        #expect(model.selectedFiller?.bounds.alignedStart == 2.124)
        #expect(model.selectedFiller?.bounds.alignedEnd == 2.234567891)
        model.fillerEndText = "not a time"
        let snapshot = model.state.store.model
        model.applyFillerText()
        #expect(model.error != nil && model.state.store.model == snapshot)
        #expect(model.selectedFiller?.detectedBounds == nil)
    }

    @Test func keyboardNudgesSelectTheirOwnReviewWithoutChangingAnotherReview() throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        model.proposeFillers()
        let detected = try #require(model.fillerReviews.first)
        model.addManualFiller(speaker: detected.speaker, start: 3, end: 3.2)
        let manual = try #require(model.selectedFiller)
        try #require(manual.origin == .manual)
        model.nudgeFiller(detected.id, edge: .end, seconds: 0.001)
        #expect(model.selectedFillerID == detected.id)
        #expect(model.selectedFiller?.bounds.alignedEnd == detected.bounds.alignedEnd + 0.001)
        #expect(model.selectedFiller?.detectedBounds == detected.detectedBounds)
        #expect(model.fillerReviews.first { $0.id == manual.id } == manual)
    }

    @Test(arguments: [false, true])
    func affineAdaptiveMappingAndGapsRemainAuthoritative(adaptiveGap: Bool) throws {
        let model = try fillerFixture(adaptiveGap: adaptiveGap)
        defer { model.cancel() }
        model.proposeFillers()
        let review = try #require(model.fillerReviews.first)
        let lane = try #require(model.plan?.lanes.first)
        #expect(model.fillerIssue(review) == nil)
        model.setFillerBounds(review.id, start: 3.7, end: adaptiveGap ? 3.99 : 4.25)
        let adjusted = try #require(model.fillerReviews.first)
        let expected = try #require(lane.sourceRange(start: adjusted.bounds.alignedStart, end: adjusted.bounds.alignedEnd))
        #expect(adjusted.bounds.sourceStartFrame == expected.lowerBound)
        #expect(adjusted.bounds.sourceEndFrame == expected.upperBound)
        #expect(adjusted.detectedBounds == review.detectedBounds)
        let audition = try #require(model.fillerAuditionRange(adjusted, context: 0.5))
        if adaptiveGap {
            #expect(audition.upperBound == 4, "Context stops at the accepted run's edge, not inside a gap")
            let snapshot = model.state.store.model
            model.setFillerBounds(review.id, start: 3.7, end: 6.2)
            #expect(model.error != nil && model.state.store.model == snapshot)
            model.setFillerBounds(review.id, start: 6.2, end: 6.4)
            #expect(model.error != nil && model.state.store.model == snapshot, "Cannot teleport across unsupported timing")
        } else {
            #expect(audition.upperBound == 4.75, "Context follows connected adaptive segments")
        }
        #expect(model.fillerAuditionRange(adjusted, context: 0) == adjusted.bounds.alignedStart...adjusted.bounds.alignedEnd)
        #expect(model.fillerAuditionRange(adjusted, context: .nan) == nil)
    }

    @Test func changedTranscriptIdentityWordRecipeRangeAndSourceNeverRebindHumanJudgments() throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        model.proposeFillers()
        let review = try #require(model.fillerReviews.first)
        model.setFillerBounds(review.id, start: 1.99, end: 2.21)
        let saved = model.state.store.model
        let adjusted = try #require(model.fillerReviews.first)
        let lane = try #require(model.plan?.lanes.first)
        let mutations: [(inout SpeakerTranscript) -> Void] = [
            { $0.id = UUID() }, { $0.model = "new recipe" }, { $0.words[0].text = "UH" },
            { $0.words[0].alignedStart = 1.999 }, { $0.sourceIdentity = String(repeating: "b", count: 64) },
            { $0.workingRange?.tracksOut = 5 },
        ]
        for mutate in mutations {
            var replacement = saved
            mutate(&replacement.episodes[0].cleanup!.transcripts[0])
            model.state.store.replaceLoadedModel(replacement)
            #expect(model.fillerIssue(adjusted) != nil)
            #expect(model.visibleFillers(for: lane).isEmpty)
            model.setFillerBounds(review.id, start: 1.98, end: 2.22)
            #expect(model.state.store.model == replacement && model.error != nil)
            #expect(model.fillerReviews.first == adjusted)
        }
        model.state.store.replaceLoadedModel(saved)
        model.identities[lane.primary.sourceID] = String(repeating: "c", count: 64)
        #expect(model.fillerIssue(adjusted) != nil)
        model.identities[lane.primary.sourceID] = review.sourceIdentity
        #expect(model.fillerIssue(adjusted) == nil, "Restoring the exact original reactivates it without rebasing")
        model.plan = nil
        #expect(model.fillerIssue(adjusted) != nil)
        #expect(model.episode?.cleanup?.isValid == true)
    }

    @Test func reviewEditsUseTheNormalDocumentUndoRedoAndPersistenceValue() throws {
        let base = try fillerFixture()
        defer { base.cancel() }
        let document = ShowDocument()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        document.store.replaceLoadedModel(base.state.store.model)
        let model = EpisodeCleanupModel(state: ShowWindowState(store: document.store), episodeID: base.episodeID)
        defer { model.cancel() }
        model.plan = base.plan
        model.identities = base.identities
        let undo = try #require(document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        let original = document.store.model
        undo.beginUndoGrouping()
        model.proposeFillers()
        undo.endUndoGrouping()
        let proposed = document.store.model
        let review = try #require(model.fillerReviews.first)
        undo.beginUndoGrouping()
        model.setFillerBounds(review.id, start: 1.99, end: 2.21)
        undo.endUndoGrouping()
        let adjusted = document.store.model
        #expect(document.isDocumentEdited && adjusted != proposed)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(coder.encode(adjusted, revision: 1)).payload == adjusted)
        undo.undo()
        #expect(document.store.model == proposed)
        undo.undo()
        #expect(document.store.model == original, "Undo of finding candidates is not immediately re-proposed")
        undo.redo()
        undo.redo()
        #expect(document.store.model == adjusted)
    }

    @Test func changedAcceptedRevisionPrimaryAndWorkingRangeDisableWithoutRebasing() throws {
        let model = try fillerFixture()
        defer { model.cancel() }
        model.proposeFillers()
        let review = try #require(model.fillerReviews.first)
        let saved = model.state.store.model
        let mutations: [(inout Episode) -> Void] = [
            { $0.cleanup?.workingRange?.tracksOut = 2.1 },
            { $0.speakerAssignments[0].primary = ChannelReference(sourceID: review.primary.sourceID, statedChannel: 1) },
            {
                let old = $0.alignment!.maps[0]
                $0.alignment?.maps.append(.init(revision: 2, derivedFrom: 1, inputs: old.inputs, map: old.map))
                $0.alignment?.acceptedRevision = 2
            },
        ]
        let lane = try #require(model.plan?.lanes.first)
        for mutate in mutations {
            var changed = saved
            mutate(&changed.episodes[0])
            model.state.store.replaceLoadedModel(changed)
            #expect(model.fillerIssue(review) != nil)
            #expect(model.visibleFillers(for: lane).isEmpty)
            #expect(model.fillerAuditionRange(review, context: 0.5) == nil)
            model.selectFiller(review.id)
            model.markMissedFiller()
            #expect(model.error != nil && model.state.store.model == changed,
                    "An inactive historical selection cannot silently seed a new manual interval")
            model.state.store.replaceLoadedModel(saved)
            #expect(model.fillerIssue(review) == nil)
            #expect(model.fillerReviews.first == review)
        }
    }
}
