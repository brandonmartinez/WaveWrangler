import Foundation
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
            alignment: .init(maps: [.init(revision: 1, inputs: .init(sources: []),
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
}
