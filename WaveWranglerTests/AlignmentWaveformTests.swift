import Foundation
import Testing
@testable import WWAlignPipeline
@testable import WWAutoAlign
import WWCore
import WWTimeMap

@Suite("Waveform selection")
struct AlignmentWaveformTests {
    @Test func adaptiveGhostAndClockMarkersAreFileLocalAndNeverBridgeUnsupportedAudio() throws {
        let f = try previewFixture()
        func participant(_ track: AlignmentWaveformTrack) -> AnalysisParticipant {
            AnalysisParticipant(group: track.group, epoch: track.epoch, source: track.id,
                occurrence: SourceOccurrenceID(), revisionToken: "synthetic", sourceRate: 1000,
                sourceFrames: 20_000, channelCount: 1, excerptStartFrame: 0, excerptEndFrame: 20_000, analysisRate: 1000)
        }
        let observations = (4..<11).map { index in
            DelayEvidence(station: index, attempt: 0, targetCenter: Double(index), status: "eligible",
                offsetSeconds: -3, nccScore: 0.8, nccSecond: 0.1, phatOffsetSeconds: -3,
                phatPeakRatio: 0.1, method: AutomaticAlignment.fineMethod)
        } + (12..<19).map { index in
            DelayEvidence(station: index % 16, attempt: 0, targetCenter: Double(index), status: "eligible",
                offsetSeconds: -2.98, nccScore: 0.8, nccSecond: 0.1, phatOffsetSeconds: -2.98,
                phatPeakRatio: 0.1, method: AutomaticAlignment.fineMethod)
        }
        let timing = try AdaptiveAlignment.regions(observations: observations, start: 0, end: 20)
        let record = AdaptiveAnalysisRecord(
            reference: participant(f.track), target: participant(f.track), timing: timing,
            referenceToAlignedRate: 1.0002, referenceToAlignedOffset: 0.5, referenceCoverageEnd: 20
        )
        let before = try AlignmentWaveformProjection.strokes(track: f.track, map: f.map)
        let ghosts = AlignmentWaveformProjection.adaptiveStrokes(track: f.track, record: record)
        #expect(ghosts.count == 12)
        #expect(ghosts.allSatisfy { $0.sourceSeconds < 10 || $0.sourceSeconds >= 12 })
        for ghost in ghosts {
            let delay = ghost.sourceSeconds < 10 ? -3.0 : -2.98
            #expect(abs(ghost.displaySeconds - ((ghost.sourceSeconds + delay) * 1.0002 + 0.5)) < 1e-9)
            #expect(ghost.low == -0.4 && ghost.high == 0.6)
        }
        let markers = AlignmentWaveformProjection.adaptiveMarkers(track: f.track, record: record)
        #expect(markers.map(\.sourceSeconds) == [4, 12])
        #expect(markers.allSatisfy { !$0.isQuiet })
        #expect(record.playbackIntervals(includeEstimated: true).allSatisfy { $0.kind != .estimated },
                "the estimate's native rate bound is checked after accepted-reference projection")
        let estimateRecord = AdaptiveAnalysisRecord(reference: record.reference, target: record.target, timing: timing,
            referenceToAlignedOffset: 0.5, referenceCoverageEnd: 20)
        let estimatedGhosts = AlignmentWaveformProjection.adaptiveStrokes(
            track: f.track, record: estimateRecord, includeEstimated: true)
        #expect(estimatedGhosts.count > ghosts.count)
        #expect(estimatedGhosts.contains { $0.sourceSeconds > 10 && $0.sourceSeconds < 12 })
        #expect(estimatedGhosts.contains { $0.sourceSeconds < 4 })
        #expect(estimatedGhosts.contains { $0.sourceSeconds >= 18 })
        #expect(estimatedGhosts.reduce(0) { $0 + $1.groupRange.upperBound - $1.groupRange.lowerBound } == 20)
        let estimatedMarkers = AlignmentWaveformProjection.adaptiveMarkers(
            track: f.track, record: estimateRecord, includeEstimated: true)
        #expect(estimatedMarkers.filter { $0.kind == .estimated }.count == 3)
        #expect(estimatedMarkers.filter { $0.kind == nil }
            == AlignmentWaveformProjection.adaptiveMarkers(track: f.track, record: estimateRecord))
        #expect(AlignmentWaveformProjection.adaptiveStrokes(track: f.track, record: record) == ghosts,
                "estimated preview is explicit and must not mutate the conservative proposal")
        func energy(reference: Bool) throws -> QuietAudioProfile {
            let samples: [Float] = (0..<160000).map {
                let time = Double($0) / 8000
                let quiet = reference ? (7.05..<9).contains(time) : (10.05..<12).contains(time)
                return quiet ? 0.00003 : 0.1
            }
            var builder = try QuietAudioProfileBuilder(sampleRate: 8000, channelCount: 1,
                selectedChannel: 0, allChannels: !reference)
            try builder.append(samples, firstFrame: 0, frameCount: samples.count)
            return try builder.finish()
        }
        let quietTiming = try AdaptiveQuietTiming.adding(
            to: timing, target: energy(reference: false), reference: energy(reference: true))
        try #require(quietTiming.quietSeconds > 0.5)
        let quietRecord = AdaptiveAnalysisRecord(
            reference: record.reference, target: record.target, timing: quietTiming,
            referenceToAlignedRate: record.referenceToAlignedRate,
            referenceToAlignedOffset: record.referenceToAlignedOffset, referenceCoverageEnd: 20)
        let quietMarkers = AlignmentWaveformProjection.adaptiveMarkers(track: f.track, record: quietRecord)
        #expect(quietMarkers.filter(\.isQuiet).count == 1)
        #expect(quietMarkers.filter { !$0.isQuiet } == markers)
        let fineTrack = AlignmentWaveformTrack(group: f.track.group, epoch: f.track.epoch,
            name: f.track.name, groupName: f.track.groupName,
            envelope: WaveformEnvelope(source: f.track.id, sampleRate: 1000, channelCount: 1, totalFrames: 20000,
                bins: stride(from: 0, to: 20000, by: 100).map {
                    WaveformBin(firstFrame: Int64($0), endFrame: Int64($0 + 100), minimum: -0.4, maximum: 0.6)
                }))
        let quietGhosts = AlignmentWaveformProjection.adaptiveStrokes(track: fineTrack, record: quietRecord)
        #expect(quietGhosts.contains { $0.sourceSeconds > 10 && $0.sourceSeconds < 12 })
        #expect(quietGhosts.allSatisfy {
            quietTiming.containsPlayableInterval(from: $0.groupRange.lowerBound, to: $0.groupRange.upperBound.nextDown)
        })
        #expect(try AlignmentWaveformProjection.strokes(track: f.track, map: f.map) == before)
        let sibling = AlignmentWaveformTrack(group: f.track.group, epoch: f.track.epoch,
            name: "another file", groupName: f.track.groupName,
            envelope: WaveformEnvelope(source: SourceID(), sampleRate: 1000, channelCount: 1,
                                      totalFrames: 20_000, bins: f.track.envelope.bins))
        #expect(AlignmentWaveformProjection.adaptiveStrokes(track: sibling, record: record).isEmpty)
        #expect(AlignmentWaveformProjection.adaptiveMarkers(track: sibling, record: record).isEmpty)
    }

    @Test func trackViewOrderRetainsTheSpeakerDefaultAndAllSerializedModes() {
        #expect(AlignmentWaveformLayout.defaultValue == .speaker)
        #expect(AlignmentWaveformLayout.allCases == [.recorderGroup, .speaker, .overlay, .speakersOnly])
        #expect(AlignmentWaveformLayout.allCases.map(\.rawValue) == ["By recorder", "By speaker", "Overlay", "Speakers only"])
    }

    @Test func acceptedAdaptiveProjectionRetainsBinsAndUndoRestoresCoordinatesWithoutBridgingGaps() throws {
        let f = try previewFixture()
        let track = AlignmentWaveformTrack(group: f.track.group, epoch: f.track.epoch, name: f.track.name,
            groupName: f.track.groupName,
            envelope: WaveformEnvelope(source: f.track.id, sampleRate: 8000, channelCount: 1, totalFrames: 160000,
                bins: f.track.envelope.bins.map {
                    WaveformBin(firstFrame: $0.firstFrame * 8, endFrame: $0.endFrame * 8, minimum: $0.minimum, maximum: $0.maximum)
                }))
        let correction = SourceTimingCorrection(source: track.id, group: track.group, epoch: track.epoch,
            reference: SourceID(), sourceRate: 8000, sourceFrames: 160000, channelCount: 1,
            analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
            segments: [
                SourceTimingSegment(sourceStart: 4, sourceEnd: 10, alignedStart: 1, rateRatio: 1.0002),
                SourceTimingSegment(sourceStart: 12, sourceEnd: 18, alignedStart: 9.02, rateRatio: 1),
            ])
        let before = try AlignmentWaveformProjection.strokes(track: track, map: nil)
        let after = try AlignmentWaveformProjection.strokes(track: track, map: nil, correction: correction)
        #expect(after.filter(\.mapped).count == 12)
        #expect(after.count == before.count, "unverified source bins stay visible rather than disappearing")
        #expect(after.filter { !$0.mapped }.allSatisfy { $0.displaySeconds == $0.sourceSeconds })
        for stroke in after where stroke.mapped {
            #expect(abs(stroke.displaySeconds - (try #require(correction.alignedTime(at: stroke.sourceSeconds)))) < 1e-9)
        }
        #expect(try AlignmentWaveformProjection.strokes(track: track, map: nil) == before)
        let spanning = AlignmentWaveformTrack(group: track.group, epoch: track.epoch, name: track.name,
            groupName: track.groupName,
            envelope: WaveformEnvelope(source: track.id, sampleRate: 8000, channelCount: 1, totalFrames: 160000,
                bins: [WaveformBin(firstFrame: 72000, endFrame: 104000, minimum: -0.2, maximum: 0.2)]))
        let pieces = try AlignmentWaveformProjection.strokes(track: spanning, map: nil, correction: correction)
        #expect(pieces.count == 3 && pieces.filter(\.mapped).count == 2)
        #expect(pieces.filter(\.mapped).map(\.groupRange) == [9...10, 12...13])
        let preserved = try correction.preservingAudio()
        let full = try AlignmentWaveformProjection.strokes(track: spanning, map: nil, correction: preserved)
        #expect(full.count == 3 && full.allSatisfy(\.mapped))
        #expect(full.reduce(0) { $0 + $1.groupRange.upperBound - $1.groupRange.lowerBound } == 4)
    }

    private func previewFixture() throws -> (
        track: AlignmentWaveformTrack, map: AlignedTimelineMap, reference: TimelineReference, segment: AffineClockSegment
    ) {
        let referenceGroup = RecorderGroupID(), targetGroup = RecorderGroupID()
        let referenceEpoch = RecordingEpochID(), targetEpoch = RecordingEpochID()
        let reference = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 20_000)
        let target = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 20_000)
        let timeline = TimelineReference(group: referenceGroup, epoch: referenceEpoch, occurrence: reference.id)
        let identity = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(20),
                                             rateRatio: .one, alignedOffset: .zero)
        let targetIdentity = try AffineClockSegment(groupClockStart: ExactRational(1), groupClockEnd: ExactRational(21),
                                                   rateRatio: .one, alignedOffset: .zero)
        let map = try AlignedTimelineMap(reference: timeline, groups: [
            GroupTimeMap(group: referenceGroup, reference: timeline, epochs: [
                EpochClockMap(epoch: referenceEpoch, mapping: .mapped(segments: [identity], provenance: .timelineReference))
            ], placements: [OccurrencePlacement(occurrence: reference, spans: [
                EpochSpan(startFrame: 0, endFrame: 20_000, epoch: referenceEpoch, groupClockOffset: .zero)
            ])]),
            GroupTimeMap(group: targetGroup, reference: timeline, epochs: [
                EpochClockMap(epoch: targetEpoch, mapping: .mapped(segments: [targetIdentity],
                    provenance: .manual(ManualCorrection(basis: .numericEntry))))
            ], placements: [OccurrencePlacement(occurrence: target, spans: [
                EpochSpan(startFrame: 0, endFrame: 20_000, epoch: targetEpoch, groupClockOffset: ExactRational(1))
            ])])
        ])
        let track = AlignmentWaveformTrack(
            group: targetGroup, epoch: targetEpoch, name: "target.wav", groupName: "Synthetic",
            envelope: WaveformEnvelope(source: target.source, sampleRate: 1_000, channelCount: 1, totalFrames: 20_000,
                bins: (0..<20).map { WaveformBin(firstFrame: Int64($0 * 1_000), endFrame: Int64(($0 + 1) * 1_000),
                                               minimum: -0.4, maximum: 0.6) })
        )
        return (track, map, timeline, try AffineClockSegment(
            groupClockStart: ExactRational(2), groupClockEnd: ExactRational(12),
            rateRatio: ExactRational(10_001, 10_000), alignedOffset: ExactRational(-3)))
    }

    @Test func proposalGhostUsesGroupCoordinatesAndNeverExtrapolatesOrChangesTheMap() throws {
        let f = try previewFixture()
        let before = f.map
        let ghosts = AlignmentWaveformProjection.proposedStrokes(
            track: f.track, map: f.map, targetGroup: f.track.group, targetEpoch: f.track.epoch, segment: f.segment
        )
        #expect(ghosts.count == 10)
        for ghost in ghosts {
            #expect(ghost.groupRange.lowerBound >= 2 && ghost.groupRange.upperBound <= 12)
            #expect(abs(ghost.displaySeconds - (1.0001 * ghost.groupSeconds - 3)) < 1e-10)
            #expect(abs(ghost.sourceSeconds + 1 - ghost.groupSeconds) < 1e-10)
            #expect(ghost.low == -0.4 && ghost.high == 0.6)
        }
        #expect(f.map == before)
        #expect(AlignmentWaveformProjection.proposedStrokes(
            track: f.track, map: f.map, targetGroup: f.reference.group,
            targetEpoch: f.track.epoch, segment: f.segment
        ).isEmpty)
        #expect(AlignmentWaveformProjection.proposedStrokes(
            track: f.track, map: f.map, targetGroup: f.track.group,
            targetEpoch: RecordingEpochID(), segment: f.segment
        ).isEmpty)
    }

    @Test func timingOnlyChangesReprojectExistingBinsWithoutRemovingUnmeasuredAudio() throws {
        let f = try previewFixture()
        let group = try #require(f.map.groups.first { $0.group == f.track.group })
        let updated = try AlignedTimelineMap(reference: f.reference, groups: f.map.groups.map {
            $0.group == f.track.group ? try GroupTimeMap(
                group: group.group, reference: group.reference, epochs: [
                    EpochClockMap(epoch: f.track.epoch, mapping: .mapped(segments: [f.segment],
                        provenance: .manual(ManualCorrection(basis: .acceptedAcousticProposal))))
                ], placements: group.placements.map {
                    OccurrencePlacement(occurrence: $0.occurrence, spans: [
                        EpochSpan(startFrame: 1_000, endFrame: 11_000, epoch: f.track.epoch,
                                  groupClockOffset: ExactRational(1))
                    ])
                }
            ) : $0
        })
        let before = try AlignmentWaveformProjection.strokes(track: f.track, map: f.map)
        let after = try AlignmentWaveformProjection.strokes(track: f.track, map: updated)
        #expect(before.count == 20 && after.count == 20)
        #expect(after.filter(\.mapped).count == 10)
        #expect(after.filter { !$0.mapped }.count == 10)
        #expect(after.map(\.low) == before.map(\.low))
        #expect(after.map(\.high) == before.map(\.high))
        let measured = try #require(after.first { $0.mapped })
        #expect(abs(measured.displaySeconds - (1.0001 * measured.groupSeconds - 3)) < 1e-10)
        #expect(try AlignmentWaveformProjection.strokes(track: f.track, map: f.map).map(\.displaySeconds)
            == before.map(\.displaySeconds), "Undo reuses the same source-coordinate envelope")
    }

    @Test func cachedSamplesCannotCrossEpisodeOrSourceChanges() {
        let epoch = RecordingEpoch(label: "Synthetic")
        let group = RecorderGroup(name: "Recorder", epochs: [epoch])
        let source = SourceRecord(displayNameHint: "synthetic.wav",
                                  placement: SourcePlacement(recorderGroupID: group.id, epochID: epoch.id))
        let episode = Episode(title: "Synthetic", recorderGroups: [group], sources: [source])
        var renamed = episode
        renamed.title = "Renamed"
        #expect(AlignmentWaveformProjection.canReuseSamples(from: episode, to: renamed))
        var changed = episode
        changed.sources[0].displayNameHint = "replacement.wav"
        changed.recorderGroups[0].name = "Renamed origin"
        changed.recorderGroups[0].icon = .computer
        #expect(AlignmentWaveformProjection.canReuseSamples(from: episode, to: changed),
                "A display-name hint is not source identity; renaming must not decode audio again.")
        changed.sources[0].id = SourceID()
        #expect(!AlignmentWaveformProjection.canReuseSamples(from: episode, to: changed))
        changed = episode
        changed.recorderGroups = []
        #expect(!AlignmentWaveformProjection.canReuseSamples(from: episode, to: changed))
        #expect(!AlignmentWaveformProjection.canReuseSamples(from: episode, to: Episode(title: "Other")))
        #expect(!AlignmentWaveformProjection.canReuseSamples(from: nil, to: episode))
    }

    @Test func waveformAnchorUsesClickedTimeWithinMeasuredBin() {
        let epoch = RecordingEpochID()
        let mapped = AlignmentWaveformStroke(
            sourceSeconds: 10.5, groupSeconds: 10.5, displaySeconds: 12.5,
            low: -0.4, high: 0.5, mapped: true, epoch: epoch,
            displayRange: 12...13, groupRange: 10...11
        )
        #expect(AlignmentWaveformProjection.anchorSourceSeconds(at: 12.75, stroke: mapped) == 10.75)
        #expect(AlignmentWaveformProjection.anchorSourceSeconds(at: 14, stroke: mapped) == nil)
        let untimed = AlignmentWaveformStroke(
            sourceSeconds: 10.5, groupSeconds: 10.5, displaySeconds: 10.5,
            low: -0.4, high: 0.5, mapped: false, epoch: epoch,
            displayRange: 10...11, groupRange: 10...11
        )
        #expect(AlignmentWaveformProjection.anchorSourceSeconds(at: 10.75, stroke: untimed) == 10.75)
    }

    @Test func transportShowHearChangesGainsWithoutChangingPreparedTracks() {
        let recorder = RecorderGroupID()
        let otherRecorder = RecorderGroupID()
        let first = SourceID()
        let second = SourceID()
        let third = SourceID()
        let tracks = [(first, recorder), (second, recorder), (third, otherRecorder)].map { source, group in
            AlignmentWaveformTrack(
                group: group, epoch: RecordingEpochID(), name: "generated.wav",
                groupName: "Synthetic", envelope: WaveformEnvelope(
                    source: source, sampleRate: 1_000, channelCount: 1, totalFrames: 1_000, bins: []
                )
            )
        }
        let prepared: Set<SourceID> = [first, second, third]
        let all = AlignmentTransportSelection.enabledSources(
            tracks: tracks, disabledGroups: [], disabledTracks: []
        )
        #expect(AlignmentTransportSelection.gains(prepared: prepared, enabled: all)
            == [first: Float(1) / 3, second: Float(1) / 3, third: Float(1) / 3])
        let trackMuted = AlignmentTransportSelection.enabledSources(
            tracks: tracks, disabledGroups: [], disabledTracks: [second]
        )
        #expect(AlignmentTransportSelection.gains(prepared: prepared, enabled: trackMuted)
            == [first: 0.5, second: 0, third: 0.5])
        let groupMuted = AlignmentTransportSelection.enabledSources(
            tracks: tracks, disabledGroups: [recorder], disabledTracks: []
        )
        #expect(AlignmentTransportSelection.gains(prepared: prepared, enabled: groupMuted)
            == [first: 0, second: 0, third: 1])
        #expect(AlignmentTransportSelection.gains(prepared: prepared, enabled: [])
            == [first: 0, second: 0, third: 0])
        #expect(AlignmentTransportSelection.gains(prepared: prepared, enabled: all)
            == [first: Float(1) / 3, second: Float(1) / 3, third: Float(1) / 3])
        #expect(AlignmentTransportSelection.gains(prepared: [first, third], enabled: all)
            == [first: 0.5, third: 0.5])
    }

    @Test func speakerLayoutsGroupSourcesWithoutChangingRecorderMembership() {
        let firstSpeaker = SpeakerID()
        let secondSpeaker = SpeakerID()
        let sharedRecorder = RecorderGroupID()
        let otherRecorder = RecorderGroupID()
        let first = SourceID()
        let second = SourceID()
        let backup = SourceID()
        let unknown = SourceID()
        let tracks = [(first, sharedRecorder), (second, sharedRecorder),
                      (backup, otherRecorder), (unknown, otherRecorder)].map { source, recorder in
            AlignmentWaveformTrack(
                group: recorder, epoch: RecordingEpochID(), name: "generated.wav",
                groupName: "Synthetic", envelope: WaveformEnvelope(
                    source: source, sampleRate: 1_000, channelCount: 1,
                    totalFrames: 1_000, bins: []
                )
            )
        }
        let speakerGroups = AlignmentWaveformProjection.speakerGroups(tracks: tracks) { source in
            switch source {
            case first, backup: firstSpeaker
            case second: secondSpeaker
            default: nil
            }
        }
        #expect(speakerGroups.map(\.id) == [firstSpeaker, secondSpeaker, nil])
        #expect(speakerGroups.map { $0.tracks.map(\.id) } == [[first, backup], [second], [unknown]])
        #expect(speakerGroups[0].tracks[0].group == speakerGroups[1].tracks[0].group)
        #expect(speakerGroups[0].tracks[1].group == speakerGroups[2].tracks[0].group)
    }

    @Test func speakerLayoutsRetainUnknownSourcesAndFollowReassignments() throws {
        let recorder = RecorderGroupID()
        let sources = [SourceID(), SourceID(), SourceID()]
        let tracks = sources.map { source in
            AlignmentWaveformTrack(
                group: recorder, epoch: RecordingEpochID(), name: "generated.wav",
                groupName: "Synthetic", envelope: WaveformEnvelope(
                    source: source, sampleRate: 1_000, channelCount: 1, totalFrames: 1_000, bins: []
                )
            )
        }
        #expect(AlignmentWaveformProjection.speakerGroups(tracks: [], speakerForSource: { _ in nil }).isEmpty)
        let unknown = AlignmentWaveformProjection.speakerGroups(tracks: tracks) { _ in nil }
        try #require(unknown.count == 1)
        #expect(unknown[0].id == nil)
        #expect(unknown[0].tracks.map(\.id) == sources)
        let speaker = SpeakerID()
        let reassigned = AlignmentWaveformProjection.speakerGroups(tracks: tracks) {
            $0 == sources[1] ? speaker : nil
        }
        #expect(reassigned.map(\.id) == [nil, speaker])
        #expect(reassigned.map { $0.tracks.map(\.id) } == [[sources[0], sources[2]], [sources[1]]])
        #expect(reassigned.flatMap(\.tracks).allSatisfy { $0.group == recorder })
    }

    @Test func adaptivePlaybackAdmitsTheCorrectedFileWithoutMappingItsRecorderOrSiblings() throws {
        let referenceGroup = RecorderGroupID(), targetGroup = RecorderGroupID()
        let referenceEpoch = RecordingEpochID(), targetEpoch = RecordingEpochID()
        let referenceSource = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(8000), frameCount: 160_000)
        let target = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(8000), frameCount: 160_000)
        let sibling = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(8000), frameCount: 160_000)
        let reference = TimelineReference(group: referenceGroup, epoch: referenceEpoch, occurrence: referenceSource.id)
        let segment = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(20),
            rateRatio: .one, alignedOffset: .zero)
        let map = try AlignedTimelineMap(reference: reference, groups: [
            GroupTimeMap(group: referenceGroup, reference: reference,
                epochs: [EpochClockMap(epoch: referenceEpoch,
                    mapping: .mapped(segments: [segment], provenance: .timelineReference))],
                placements: [OccurrencePlacement(occurrence: referenceSource, spans: [
                    EpochSpan(startFrame: 0, endFrame: 160_000, epoch: referenceEpoch, groupClockOffset: .zero),
                ])]),
            GroupTimeMap(group: targetGroup, reference: reference,
                epochs: [EpochClockMap(epoch: targetEpoch, mapping: .unsupported(.notAttempted))],
                placements: [target, sibling].map {
                    OccurrencePlacement(occurrence: $0, spans: [
                        EpochSpan(startFrame: 0, endFrame: 160_000, epoch: targetEpoch, groupClockOffset: .zero),
                    ])
                }),
        ])
        let correction = SourceTimingCorrection(source: target.source, group: targetGroup, epoch: targetEpoch,
            reference: referenceSource.source, sourceRate: 8000, sourceFrames: 160_000, channelCount: 1,
            analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
            segments: [SourceTimingSegment(sourceStart: 0, sourceEnd: 20, alignedStart: 5,
                rateRatio: 1, kind: .estimated)])
        let playable = AlignmentWaveformProjection.playableSources(in: map, corrections: [correction])
        #expect(playable == [referenceSource.source, target.source])
        #expect(!playable.contains(sibling.source))
        #expect([target.source].filter { playable.contains($0) } == [target.source],
                "Solo must not discard an accepted file correction just because its recorder epoch is unmapped")
        #expect(AlignmentWaveformProjection.timedSources(in: map) == [referenceSource.source])
        #expect(!AlignmentWaveformProjection.hasAcceptedTiming(
            source: target.source, epoch: targetEpoch, group: targetGroup, map: map),
            "File playback eligibility must not approve recorder-clock timing")
        for mismatch in 0..<4 {
            var invalid = correction
            switch mismatch {
            case 0: invalid.sourceFrames += 8000
            case 1: invalid.epoch = RecordingEpochID()
            case 2: invalid.group = RecorderGroupID()
            default: invalid.processing = "unrecognized"
            }
            #expect(AlignmentWaveformProjection.playableSources(in: map, corrections: [invalid])
                == [referenceSource.source])
        }
    }

    @Test func playbackSelectsOnlySourcesWithAcceptedMappedEpochs() throws {
        let group = RecorderGroupID()
        let mappedEpoch = RecordingEpochID()
        let untimedEpoch = RecordingEpochID()
        let mapped = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 1_000
        )
        let untimed = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 1_000
        )
        let reference = TimelineReference(
            group: group, epoch: mappedEpoch, occurrence: mapped.id
        )
        let segment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(1),
            rateRatio: ExactRational(1), alignedOffset: .zero
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [
            GroupTimeMap(group: group, reference: reference, epochs: [
                EpochClockMap(epoch: mappedEpoch, mapping: .mapped(
                    segments: [segment], provenance: .timelineReference
                )),
                EpochClockMap(epoch: untimedEpoch, mapping: .unsupported(.notAttempted)),
            ], placements: [
                OccurrencePlacement(occurrence: mapped, spans: [
                    EpochSpan(startFrame: 0, endFrame: 1_000, epoch: mappedEpoch, groupClockOffset: .zero),
                ]),
                OccurrencePlacement(occurrence: untimed, spans: [
                    EpochSpan(startFrame: 0, endFrame: 1_000, epoch: untimedEpoch, groupClockOffset: .zero),
                ]),
            ]),
        ])
        #expect(AlignmentWaveformProjection.timedSources(in: map) == [mapped.source])
        #expect(!AlignmentWaveformProjection.timedSources(in: map).contains(untimed.source))
        #expect(AlignmentWaveformProjection.hasAcceptedTiming(
            source: mapped.source, epoch: mappedEpoch, group: group, map: map
        ))
        #expect(!AlignmentWaveformProjection.hasAcceptedTiming(
            source: untimed.source, epoch: untimedEpoch, group: group, map: map
        ))
        let unplaced = SourceID()
        #expect(!AlignmentWaveformProjection.timedSources(in: map).contains(unplaced))
        let preview = AlignmentWaveformTrack(
            group: group, epoch: untimedEpoch, name: "generated-unplaced.wav",
            groupName: "Synthetic", envelope: WaveformEnvelope(
                source: unplaced, sampleRate: 1_000, channelCount: 1, totalFrames: 1_000,
                bins: [WaveformBin(firstFrame: 0, endFrame: 1_000, minimum: -0.5, maximum: 0.5)]
            )
        )
        let position = try #require(try AlignmentWaveformProjection.position(frame: 500, track: preview, map: map))
        #expect(position.sourceSeconds == 0.5)
        #expect(position.displaySeconds == 0.5)
        #expect(!position.mapped)
    }

    @Test func acceptedAcousticEvidenceAppearsAsSourceSpecificAnchorMarkers() throws {
        let referenceGroup = RecorderGroupID()
        let targetGroup = RecorderGroupID()
        let referenceEpoch = RecordingEpochID()
        let targetEpoch = RecordingEpochID()
        let reference = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 20_000
        )
        let first = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 10_000
        )
        let measured = try SourceOccurrence(
            source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 10_000
        )
        let timeline = TimelineReference(
            group: referenceGroup, epoch: referenceEpoch, occurrence: reference.id
        )
        let anchors = [
            AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 5),
            AlignmentAnchor(sourceSeconds: 8, alignedSeconds: 11),
        ]
        let note = AlignmentAnchorNote.encode(anchors, source: measured.source)
        let referenceSegment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: ExactRational(20),
            rateRatio: .one, alignedOffset: .zero
        )
        let targetSegment = try AffineClockSegment(
            groupClockStart: ExactRational(2), groupClockEnd: ExactRational(12),
            rateRatio: .one, alignedOffset: ExactRational(1)
        )
        let map = try AlignedTimelineMap(reference: timeline, groups: [
            GroupTimeMap(group: referenceGroup, reference: timeline, epochs: [
                EpochClockMap(epoch: referenceEpoch, mapping: .mapped(
                    segments: [referenceSegment], provenance: .timelineReference
                )),
            ], placements: [
                OccurrencePlacement(occurrence: reference, spans: [
                    EpochSpan(startFrame: 0, endFrame: 20_000, epoch: referenceEpoch, groupClockOffset: .zero),
                ]),
            ]),
            GroupTimeMap(group: targetGroup, reference: timeline, epochs: [
                EpochClockMap(epoch: targetEpoch, mapping: .mapped(
                    segments: [targetSegment],
                    provenance: .manual(ManualCorrection(basis: .acceptedAcousticProposal, note: note))
                )),
            ], placements: [first, measured].map { occurrence in
                OccurrencePlacement(occurrence: occurrence, spans: [
                    EpochSpan(
                        startFrame: occurrence.source == measured.source ? 0 : 2_000,
                        endFrame: 10_000, epoch: targetEpoch,
                        groupClockOffset: occurrence.source == measured.source ? ExactRational(2) : .zero
                    ),
                ])
            }),
        ])
        let displayed = try #require(AlignmentPresentation.makeAnchors(map: map)[targetEpoch])
        #expect(displayed.map(\.sourceSeconds) == [2, 8])
        #expect(displayed.map(\.groupSeconds) == [4, 10])
        #expect(displayed.map(\.alignedSeconds) == [5, 11])
        #expect(AlignmentAnchorNote.source(in: note) == measured.source)
    }

    @Test func scalableRulerKeepsTimeAndCursorInTheSameCoordinates() throws {
        let start = 90.0
        let width = 800.0
        let duration = 20.0
        let zoom = try #require(AlignmentWaveformProjection.rulerZoom(
            duration: duration, playhead: 95, magnification: 2,
            bounds: 0...120, maximumDuration: 30
        ))
        #expect(zoom.duration == 10)
        #expect(zoom.start == 90)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: 400, width: width, start: zoom.start, duration: zoom.duration, bounds: 0...120
        ) == 95)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: 400, width: width, start: start, duration: duration, bounds: 0...95
        ) == 95)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: -100, width: width, start: start, duration: duration, bounds: 0...120
        ) == 90)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 10, translation: 50, width: 500, duration: 5, bounds: 0...100
        ) == 9.5)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 0, translation: 500, width: 500, duration: 5, bounds: 0...100
        ) == 0)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 4, translation: 0, width: 500, duration: 2, bounds: 0...5
        ) == 4)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: 4.5, translation: -200, width: 500, duration: 2, bounds: 0...5
        ) == 4.5)
        #expect(AlignmentWaveformProjection.rulerZoom(
            duration: 20, playhead: 5, magnification: 0.01,
            bounds: 0...120, maximumDuration: 30
        )?.duration == 30)
        #expect(AlignmentWaveformProjection.rulerZoom(
            duration: 20, playhead: 5, magnification: 1_000,
            bounds: 0...120, maximumDuration: 30
        )?.duration == 0.5)
        #expect(AlignmentWaveformProjection.rulerZoom(
            duration: 2, playhead: 4, magnification: 2,
            bounds: 0...4, maximumDuration: 30
        )?.start == 3)
        #expect(AlignmentWaveformProjection.rulerZoom(
            duration: 20, playhead: 5, magnification: 0,
            bounds: 0...120, maximumDuration: 30
        ) == nil)
        #expect(AlignmentWaveformProjection.rulerTime(
            at: .nan, width: width, start: start, duration: duration, bounds: 0...120
        ) == nil)
    }

    @Test func rulerTickDensityAdaptsToVisibleScale() {
        let wide = AlignmentWaveformProjection.rulerTicks(start: 60, duration: 30, width: 600)
        let close = AlignmentWaveformProjection.rulerTicks(start: 60, duration: 0.5, width: 600)
        let wideMajors = wide.filter(\.major).map(\.time)
        let closeMajors = close.filter(\.major).map(\.time)
        #expect(wideMajors == [60, 70, 80, 90])
        #expect(closeMajors.count >= 3)
        #expect(closeMajors[1] - closeMajors[0] < 1)
        #expect(wide.count < 100 && close.count < 100)
        #expect(AlignmentWaveformProjection.rulerTicks(start: 0, duration: 0, width: 600).isEmpty)
    }

    @Test func distinctSpeakerColorsRemainStableWhenSpeakerOrderChanges() throws {
        let first = try #require(SpeakerID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(SpeakerID(uuidString: "00000000-0000-0000-0000-000000000009"))
        let ordered = [first, second]
        let firstColor = AlignmentWaveformProjection.speakerColorIndex(
            for: first, speakers: ordered, paletteCount: 8
        )
        let secondColor = AlignmentWaveformProjection.speakerColorIndex(
            for: second, speakers: Array(ordered.reversed()), paletteCount: 8
        )
        #expect(firstColor == 0)
        #expect(secondColor == 1)
        #expect(firstColor != secondColor)
    }

    @Test func displayColumnsMergePeaksWithoutMixingUnplacedAudio() throws {
        let epoch = RecordingEpochID()
        func stroke(_ time: Double, _ low: Float, _ high: Float, mapped: Bool) -> AlignmentWaveformStroke {
            AlignmentWaveformStroke(
                sourceSeconds: time, groupSeconds: time, displaySeconds: time,
                low: low, high: high, mapped: mapped, epoch: epoch,
                displayRange: time...time, groupRange: time...time
            )
        }
        let strokes = [
            stroke(0.100, -0.2, 0.3, mapped: true),
            stroke(0.101, -0.8, 0.1, mapped: true),
            stroke(0.102, -0.4, 0.6, mapped: false),
        ]
        let columns = AlignmentWaveformProjection.displayColumns(
            strokes: strokes, start: 0, duration: 1, width: 100, pixelsPerPoint: 2
        )
        #expect(columns.count == 2)
        #expect(columns[0].x == 10.25)
        #expect(columns[0].low == -0.8 && columns[0].high == 0.3 && columns[0].mapped)
        #expect(columns[1].low == -0.4 && columns[1].high == 0.6 && !columns[1].mapped)
        #expect(AlignmentWaveformProjection.displayColumns(
            strokes: strokes, start: .nan, duration: 1, width: 100, pixelsPerPoint: 2
        ).isEmpty)
    }

    @Test func completeMeasuredEnvelopeCanRoundTripThroughDerivedPayload() throws {
        let source = SourceID()
        let envelope = WaveformEnvelope(
            source: source, sampleRate: 48_000, channelCount: 2, totalFrames: 480_000,
            bins: [WaveformBin(firstFrame: 0, endFrame: 240_000, minimum: -0.7, maximum: 0.9),
                   WaveformBin(firstFrame: 240_000, endFrame: 480_000, minimum: -0.5, maximum: 0.6)]
        )
        #expect(try JSONDecoder().decode(
            WaveformEnvelope.self, from: JSONEncoder().encode(envelope)
        ) == envelope)
    }

    @Test func logarithmicZoomKeepsTheTimelineCenterAndBounds() throws {
        #expect(AlignmentWaveformProjection.zoomDuration(for: 0) == 30)
        #expect(AlignmentWaveformProjection.zoomDuration(for: 1) == 0.5)
        let level = try #require(AlignmentWaveformProjection.zoomLevel(for: 2))
        #expect(abs((AlignmentWaveformProjection.zoomDuration(for: level) ?? 0) - 2) < 0.000_001)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 10, duration: 2) == 9)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 10, duration: 0.5) == 9.75)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 0.5, duration: 30) == -14.5)
        #expect(AlignmentWaveformProjection.zoomDuration(for: 0, maximum: 4_200) == 4_200)
        #expect(AlignmentWaveformProjection.zoomLevel(for: 4_200, maximum: 4_200) == 0)
        #expect(AlignmentWaveformProjection.rulerPanStart(
            from: -10, translation: 200, width: 400, duration: 20,
            bounds: -86_400...86_400
        ) == -20)
        let fullRuler = AlignmentWaveformProjection.rulerTicks(
            start: -9_132, duration: 14_400, width: 900
        )
        #expect(fullRuler.contains { $0.time < 0 })
        #expect(fullRuler.contains { $0.time > 0 })
        #expect(AlignmentPresentation.formatTime(-9_132) == "−02:32:12.000")
        #expect(AlignmentWaveformProjection.zoomDuration(for: .nan) == nil)
        #expect(AlignmentWaveformProjection.zoomLevel(for: 0) == nil)
        #expect(AlignmentWaveformProjection.zoomLevel(for: 31) == nil)
    }

    @Test func pendingMoveRetainsOnlyThePriorTileAtItsDroppedPosition() {
        let moved = RecorderGroupID()
        let reference = RecorderGroupID()
        let pending = PendingWaveformMove(
            group: moved, milliseconds: 25.75,
            priorGeneration: 12, expectedGeneration: 13
        )
        #expect(pending.retainsTile(generation: 12, liveGeneration: 13))
        #expect(!pending.retainsTile(generation: 12, liveGeneration: 12))
        #expect(!pending.retainsTile(generation: 12, liveGeneration: 14))
        #expect(!pending.retainsTile(generation: 11, liveGeneration: 13))
        #expect(pending.displayShift(for: moved) == 25.75)
        #expect(pending.displayShift(for: reference) == 0)
    }

    @Test func smallPointerDragStaysSmallWhenTheCanvasRelayouts() {
        let group = RecorderGroupID()
        let drag = AlignmentWaveformDrag(
            startX: 420, width: 400, durationSeconds: 2,
            initialMilliseconds: 10, group: group, snapshot: UUID()
        )
        #expect(drag.previewMilliseconds(at: 422) == 20)
        #expect(drag.previewMilliseconds(at: 424) == 30)
        #expect(drag.previewMilliseconds(at: 420) == 10)
        #expect(drag.previewMilliseconds(at: 20) == -1_990)
        #expect(drag.previewMilliseconds(at: -1_000) == -7_090)
        let next = AlignmentWaveformDrag(
            startX: 600, width: 400, durationSeconds: 2,
            initialMilliseconds: 0, group: group, snapshot: UUID()
        )
        #expect(next.previewMilliseconds(at: 594) == -30)
        #expect(drag.previewMilliseconds(at: .nan) == nil)
        #expect(AlignmentWaveformDrag(
            startX: 0, width: 0, durationSeconds: 2,
            initialMilliseconds: 0, group: group, snapshot: UUID()
        ).previewMilliseconds(at: 2) == nil)
        let fineDrag = AlignmentWaveformDrag(
            startX: 800, width: 2_000, durationSeconds: 30,
            initialMilliseconds: 0, group: group, snapshot: UUID()
        )
        #expect(fineDrag.previewMilliseconds(at: 802) == 30)
        #expect(AlignmentWaveformProjection.moveMicroseconds(
            fromMilliseconds: fineDrag.previewMilliseconds(at: 802) ?? .nan
        ) == 30_000)
        #expect(AlignmentWaveformProjection.moveMicroseconds(fromMilliseconds: 25.75) == 25_750)
        #expect(AlignmentWaveformProjection.moveMicroseconds(fromMilliseconds: .nan) == nil)
    }

    @Test func sharedNavigationUsesFullSourceLengthNotOnlyTheLoadedWindow() {
        #expect(AlignmentWaveformProjection.sourceTimelineEnd(
            durations: [(frames: 48_000 * 360, rate: 48_000)]
        ) == 360)
        #expect(AlignmentWaveformProjection.sourceTimelineEnd(durations: []) == 0)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 240, duration: 2) == 239)
        let tile = AlignmentWaveformProjection.tileWindow(start: 239, visible: 2)
        #expect(tile?.start == 237)
        #expect(tile?.duration == 6)
        #expect(AlignmentWaveformProjection.tileWindow(start: 20, visible: 30)?.start == 20)
        #expect(AlignmentWaveformProjection.tileWindow(start: 0, visible: 5)?.start == -5)
        #expect(AlignmentWaveformProjection.tileTranslation(
            tileStart: 237, windowStart: 239, visible: 2, width: 400
        ) == -400)
        #expect(AlignmentWaveformProjection.tileTranslation(
            tileStart: 237, windowStart: 239.5, visible: 2, width: 400
        ) == -500)
        #expect(AlignmentWaveformProjection.tileTranslation(
            tileStart: 237, windowStart: 239, visible: 0, width: 400
        ) == nil)
    }

    @Test func adjacentTilesCoverContinuousPanningWithoutRebuildingStrokes() {
        let first = UUID()
        let second = UUID()
        let tiles = [(id: first, start: 0.0, duration: 30.0),
                     (id: second, start: 30.0, duration: 30.0)]
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 1, duration: 30, tiles: tiles
        ) == [
            .init(id: first, range: 1...30),
            .init(id: second, range: 30...31),
        ])
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 29.5, duration: 30, tiles: tiles
        ) == [
            .init(id: first, range: 29.5...30),
            .init(id: second, range: 30...59.5),
        ])
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 60, duration: 30, tiles: tiles
        ).isEmpty)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 1, duration: 30, tiles: Array(tiles.prefix(1))
        ) == 30)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 1, duration: 30, tiles: tiles
        ) == nil)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 0, duration: 30, margin: 15, tiles: Array(tiles.prefix(1))
        ) == -15)
        #expect(AlignmentWaveformProjection.firstUncoveredTime(
            start: 0, duration: 30, margin: 15, tiles: tiles
        ) == -15)
        let overlap = [(id: first, start: 0.0, duration: 30.0),
                       (id: second, start: 15.0, duration: 30.0)]
        #expect(AlignmentWaveformProjection.visibleTileSlices(
            start: 10, duration: 30, tiles: overlap
        ) == [
            .init(id: first, range: 10...15),
            .init(id: second, range: 15...40),
        ])
    }

    @Test func tileClipStaysAttachedToMeasuredAudioAcrossPanZoomAndGroupMoves() throws {
        let clip = try #require(AlignmentWaveformProjection.tileClip(
            range: 15...30, tileStart: 0, tileDuration: 30, tileWidth: 600
        ))
        #expect(clip.origin == 300)
        #expect(clip.width == 300)
        let firstWindow = try #require(AlignmentWaveformProjection.tileTranslation(
            tileStart: 0, windowStart: 15, visible: 15, width: 300
        ))
        let pannedWindow = try #require(AlignmentWaveformProjection.tileTranslation(
            tileStart: 0, windowStart: 20, visible: 15, width: 300
        ))
        #expect(firstWindow + clip.origin == 0)
        #expect(pannedWindow + clip.origin == -100)
        let moved = PendingWaveformMove(
            group: RecorderGroupID(), milliseconds: 125,
            priorGeneration: 1, expectedGeneration: 2
        )
        #expect(firstWindow + clip.origin + moved.displayShift(for: moved.group) / 1_000 / 15 * 300 == 2.5)
        #expect(AlignmentWaveformProjection.tileClip(
            range: 15...31, tileStart: 0, tileDuration: 30, tileWidth: 600
        ) == nil)
    }

    @Test func visualNormalizationUsesEachWindowPeakWithoutChangingSamples() {
        let epoch = RecordingEpochID()
        let strokes = [
            AlignmentWaveformStroke(
                sourceSeconds: 0.5, groupSeconds: 0.5, displaySeconds: 0.5,
                low: -0.1, high: 0.2, mapped: true, epoch: epoch,
                displayRange: 0...1, groupRange: 0...1
            ),
            AlignmentWaveformStroke(
                sourceSeconds: 1.5, groupSeconds: 1.5, displaySeconds: 1.5,
                low: -0.5, high: 0.3, mapped: false, epoch: epoch,
                displayRange: 1...2, groupRange: 1...2
            ),
        ]
        #expect(AlignmentWaveformProjection.displayGain(for: strokes, normalized: false) == 1)
        #expect(AlignmentWaveformProjection.displayGain(for: strokes, normalized: true) == 2)
        #expect(strokes[0].high == 0.2)
        #expect(AlignmentWaveformProjection.displayGain(for: [], normalized: true) == 1)
        let silent = strokes.map {
            AlignmentWaveformStroke(
                sourceSeconds: $0.sourceSeconds, groupSeconds: $0.groupSeconds,
                displaySeconds: $0.displaySeconds, low: 0, high: 0,
                mapped: $0.mapped, epoch: $0.epoch,
                displayRange: $0.displayRange, groupRange: $0.groupRange
            )
        }
        #expect(AlignmentWaveformProjection.displayGain(for: silent, normalized: true) == 1)
    }

    @Test func overviewSeparatesSourceDurationFromAcceptedAlignedExtent() throws {
        func stroke(offset: Int64, ratio: Int64 = 1) throws -> AlignmentWaveformStroke {
            let group = RecorderGroupID()
            let epoch = RecordingEpochID()
            let occurrence = try SourceOccurrence(
                source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 360_000
            )
            let reference = TimelineReference(
                group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID()
            )
            let segment = try AffineClockSegment(
                groupClockStart: .zero, groupClockEnd: ExactRational(360),
                rateRatio: ExactRational(ratio), alignedOffset: ExactRational(offset)
            )
            let map = try GroupTimeMap(
                group: group, reference: reference,
                epochs: [EpochClockMap(
                    epoch: epoch,
                    mapping: .mapped(segments: [segment], provenance: .manual(.init(basis: .numericEntry)))
                )],
                placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: 360_000, epoch: epoch, groupClockOffset: .zero)
                ])]
            )
            guard case let .aligned(first) = try map.alignedTime(ofFrame: 0, in: occurrence.id),
                  case let .aligned(last) = try map.alignedTime(ofFrame: 359_999, in: occurrence.id)
            else { throw TimeMapError.invalidFrameCount(360_000) }
            let range = first.instant.approximateDouble...last.instant.approximateDouble
            return AlignmentWaveformStroke(
                sourceSeconds: 180, groupSeconds: 180,
                displaySeconds: (range.lowerBound + range.upperBound) / 2,
                low: -0.5, high: 0.5, mapped: true, epoch: epoch,
                displayRange: range, groupRange: 0...359.999
            )
        }
        func start(_ time: Double, _ stroke: AlignmentWaveformStroke) -> Double? {
            AlignmentWaveformProjection.overviewWindowStart(at: time, duration: 5, strokes: [stroke])
        }
        let negativeOffset = try stroke(offset: -180)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: negativeOffset.displayRange).isEmpty)
        #expect(start(-100, negativeOffset) == -102.5)
        #expect(start(0, negativeOffset) == -2.5)
        #expect(start(100, negativeOffset) == 97.5)
        #expect(start(200, negativeOffset) == nil)

        let positiveOffset = try stroke(offset: 86_410)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: positiveOffset.displayRange) == [positiveOffset.displayRange])
        #expect(start(86_500, positiveOffset) == nil)
        #expect(start(86_400, positiveOffset) == nil)

        let fasterClock = try stroke(offset: 86_200, ratio: 2)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: fasterClock.displayRange) == [86_400...fasterClock.displayRange.upperBound])
        #expect(start(86_400, fasterClock) == 86_397.5)
        #expect(start(86_400.001, fasterClock) == nil)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: 0...86_400).isEmpty)
        let farNegative = try stroke(offset: -86_410)
        #expect(AlignmentWaveformProjection.unavailableOverviewRanges(in: farNegative.displayRange)
            == [farNegative.displayRange.lowerBound ... -86_400])
    }

    @Test func overviewNavigationBoundsExactWindowWithoutMakingAnAnchor() {
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 7_200, duration: 5) == 7_197.5)
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 0, duration: 30) == -15)
        for time in [-86_401, .nan, .infinity, 86_401] {
            #expect(AlignmentWaveformProjection.windowStart(centeredAt: time, duration: 5) == nil)
        }
        #expect(AlignmentWaveformProjection.windowStart(centeredAt: 1, duration: 31) == nil)
        #expect(AlignmentWaveformProjection.overviewExtent([]) == nil)
    }

    @Test func coveredBinSelectionNeverSnapsAcrossRestartGaps() {
        let first = RecordingEpochID()
        let restart = RecordingEpochID()
        let bins = [
            AlignmentWaveformStroke(
                sourceSeconds: 1.5, groupSeconds: 1.5, displaySeconds: 1.5,
                low: 0, high: 0.5, mapped: false, epoch: first,
                displayRange: 1...2, groupRange: 1...2
            ),
            AlignmentWaveformStroke(
                sourceSeconds: 3.5, groupSeconds: 0.5, displaySeconds: 3.5,
                low: 0, high: 0.5, mapped: false, epoch: restart,
                displayRange: 3...4, groupRange: 0...1
            ),
        ]
        func select(_ time: Double, draft: RecordingEpochID? = nil) -> AlignmentWaveformStroke? {
            AlignmentWaveformProjection.selectedStroke(
                at: time, strokes: bins, draftEpoch: draft, ratePPM: 0, offsetMilliseconds: 0
            )
        }
        #expect(select(1.5)?.epoch == first)
        #expect(select(3.5)?.epoch == restart)
        #expect(select(2.5) == nil)
        #expect(select(4.5) == nil)
        #expect(select(.nan) == nil)
        #expect(select(0.5, draft: restart)?.sourceSeconds == 3.5)
        #expect(select(3.5, draft: restart) == nil)
    }

    @Test func sameRecorderDoesNotMakeAnotherSourceAnEpochMatch() throws {
        let source = SourceID()
        let otherSource = SourceID()
        let group = RecorderGroupID()
        let first = RecordingEpochID()
        let second = RecordingEpochID()
        let restart = RecordingEpochID()
        let occurrence = try SourceOccurrence(
            source: source, nominalRate: NominalRate(48_000), frameCount: 96_000
        )
        let reference = TimelineReference(group: group, epoch: first, occurrence: occurrence.id)
        let referenceSegment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: .one, rateRatio: .one, alignedOffset: .zero
        )
        let otherOccurrence = try SourceOccurrence(
            source: otherSource, nominalRate: NominalRate(48_000), frameCount: 48_000
        )
        let clock = try GroupTimeMap(
            group: group, reference: reference,
            epochs: [
                EpochClockMap(epoch: first, mapping: .mapped(
                    segments: [referenceSegment], provenance: .timelineReference
                )),
                EpochClockMap(epoch: second, mapping: .unsupported(.notAttempted)),
                EpochClockMap(epoch: restart, mapping: .unsupported(.notAttempted)),
            ],
            placements: [
                OccurrencePlacement(occurrence: occurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: 48_000, epoch: first, groupClockOffset: .zero),
                    EpochSpan(startFrame: 48_000, endFrame: 96_000, epoch: restart, groupClockOffset: .zero),
                ]),
                OccurrencePlacement(occurrence: otherOccurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: 48_000, epoch: second, groupClockOffset: .zero),
                ]),
            ]
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [clock])
        #expect(AlignmentWaveformProjection.timelineEnd(map: map) == 1)
        #expect(AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: first, map: map
        ))
        #expect(AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: restart, map: map
        ))
        #expect(!AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: second, map: map
        ))
        #expect(!AlignmentWaveformProjection.containsSelectedEpoch(
            source: source, group: group, initialEpoch: first, selectedEpoch: restart, map: nil
        ))
    }
}
