import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWSpeech

@Suite("All-Primary cleanup admission")
struct PrimaryCleanupPlanTests {
    struct Fixture {
        let speaker = Speaker(name: "Host")
        let group = RecorderGroup(name: "Recorder", epochs: [RecordingEpoch(label: "1")])
        let source: SourceRecord
        let placement: OccurrencePlacement
        let map: AlignedTimelineMap
        var model: ShowDocumentModel

        init() throws {
            let epoch = group.epochs[0].id
            source = SourceRecord(displayNameHint: "Original", observations: SourceObservations(channelCount: .known(1)),
                placement: SourcePlacement(recorderGroupID: group.id, epochID: epoch),
                role: .primary, roleConfirmation: .userConfirmed)
            let occurrence = try SourceOccurrence(source: source.id, nominalRate: NominalRate(16000), frameCount: 160000)
            placement = OccurrencePlacement(occurrence: occurrence,
                spans: [EpochSpan(startFrame: 0, endFrame: 160000, epoch: epoch, groupClockOffset: .zero)])
            let reference = TimelineReference(group: group.id, epoch: epoch, occurrence: occurrence.id)
            let segment = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(10),
                rateRatio: .one, alignedOffset: .zero)
            let groupMap = try GroupTimeMap(group: group.id, reference: reference,
                epochs: [EpochClockMap(epoch: epoch, mapping: .mapped(segments: [segment], provenance: .timelineReference))],
                placements: [placement])
            map = try AlignedTimelineMap(reference: reference, groups: [groupMap])
            let version = TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: []), map: .null)
            model = ShowDocumentModel(show: Show(title: "Show"), speakers: [speaker], episodes: [
                Episode(title: "Episode", recorderGroups: [group], sources: [source], speakerAssignments: [
                    SpeakerAssignment(speakerID: speaker.id, primary: ChannelReference(sourceID: source.id, statedChannel: 0),
                        primaryConfirmation: .userConfirmed),
                ], alignment: EpisodeAlignment(maps: [version], acceptedRevision: 1)),
            ])
        }
        var plan: PrimaryCleanupPlan { PrimaryCleanupPlan.make(model: model, episode: model.episodes[0].id, map: map) }
    }

    @Test func referenceCountsAsAlignedAndExclusiveEndMapsWithoutExtrapolation() throws {
        let fixture = try Fixture()
        #expect(fixture.plan.isReady)
        let lane = try #require(fixture.plan.lanes.first)
        #expect(lane.sourceRange(start: 0, end: 10) == 0..<160000)
        #expect(lane.sourceRange(start: 9, end: 10) == 144000..<160000)
        #expect(lane.sourceRange(start: 9, end: 10.001) == nil)
        #expect(lane.sourceRange(start: -1, end: 1) == nil)
    }

    @Test func automaticBoundariesRetainWholeOffsetPrimariesRatherThanCroppingToTheirSharedOverlap() throws {
        let f = try Fixture()
        var model = f.model
        var groups = f.map.groups
        for (name, seconds, offset) in [("Early", 16, -3), ("Late", 12, 8)] {
            let speaker = Speaker(name: name)
            let epoch = RecordingEpoch(label: name)
            let group = RecorderGroup(name: name, epochs: [epoch])
            let source = SourceRecord(displayNameHint: "\(name).wav",
                observations: .init(channelCount: .known(1)),
                placement: .init(recorderGroupID: group.id, epochID: epoch.id),
                role: .primary, roleConfirmation: .userConfirmed)
            let occurrence = try SourceOccurrence(source: source.id, nominalRate: NominalRate(16000),
                frameCount: Int64(seconds * 16000))
            let segment = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(Int64(seconds)),
                rateRatio: .one, alignedOffset: ExactRational(Int64(offset)))
            groups.append(try GroupTimeMap(group: group.id, reference: f.map.reference, epochs: [
                EpochClockMap(epoch: epoch.id, mapping: .mapped(segments: [segment],
                    provenance: .manual(.init(basis: .numericEntry)))),
            ], placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                EpochSpan(startFrame: 0, endFrame: occurrence.frameCount, epoch: epoch.id, groupClockOffset: .zero),
            ])]))
            model.speakers.append(speaker)
            model.episodes[0].recorderGroups.append(group)
            model.episodes[0].sources.append(source)
            model.episodes[0].speakerAssignments.append(SpeakerAssignment(speakerID: speaker.id,
                primary: ChannelReference(sourceID: source.id, statedChannel: 0), primaryConfirmation: .userConfirmed))
        }
        let map = try AlignedTimelineMap(reference: f.map.reference, groups: groups)
        let original = model
        func plan() -> PrimaryCleanupPlan {
            PrimaryCleanupPlan.make(model: model, episode: model.episodes[0].id, map: map)
        }
        #expect(plan().isReady && plan().alignedRange == -3...20)
        #expect(plan().lanes.map { $0.start...$0.end } == [0...10, -3...13, 8...20])
        for lane in plan().lanes {
            #expect(lane.sourceRange(start: lane.start, end: lane.end) == 0..<lane.sourceFrames)
        }
        #expect(model == original && model.episodes[0].cleanup == nil)
        for (start, end, expected) in [
            (1.0 as Double?, nil as Double?, [1.0...10, 1.0...13, 8.0...20]),
            (nil, 14.0, [0.0...10, -3.0...13, 8.0...14]),
            (1.0, 14.0, [1.0...10, 1.0...13, 8.0...14]),
        ] {
            model.episodes[0].cleanup = EpisodeCleanup(workingRange:
                EpisodeWorkingRange(alignmentRevision: 1, tracksIn: start, tracksOut: end))
            #expect(plan().isReady)
            #expect(plan().lanes.map { $0.start...$0.end } == expected)
        }
    }

    @Test func emptyLegacyMarkersDoNotRequireReviewOrBlockTheAutomaticRange() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].cleanup = EpisodeCleanup(workingRange: EpisodeWorkingRange(alignmentRevision: 999))
        let before = fixture.model
        #expect(fixture.plan.isReady && fixture.plan.blockers.isEmpty)
        #expect(fixture.plan.alignedRange == 0...10)
        #expect(fixture.model == before)
    }

    @Test func automaticBoundariesCannotSilentlyOmitUnplacedSourceAudio() throws {
        let f = try Fixture()
        let referenceEpoch = RecordingEpochID(), referenceGroup = RecorderGroupID()
        let referenceSource = try SourceOccurrence(source: SourceID(),
            nominalRate: NominalRate(16000), frameCount: 160000)
        let reference = TimelineReference(group: referenceGroup, epoch: referenceEpoch, occurrence: referenceSource.id)
        let identity = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(10),
            rateRatio: .one, alignedOffset: .zero)
        let referenceMap = try GroupTimeMap(group: referenceGroup, reference: reference, epochs: [
            EpochClockMap(epoch: referenceEpoch, mapping: .mapped(segments: [identity], provenance: .timelineReference)),
        ], placements: [OccurrencePlacement(occurrence: referenceSource, spans: [
            EpochSpan(startFrame: 0, endFrame: 160000, epoch: referenceEpoch, groupClockOffset: .zero),
        ])])
        let mapped = try AffineClockSegment(groupClockStart: ExactRational(2), groupClockEnd: ExactRational(8),
            rateRatio: .one, alignedOffset: ExactRational(-1))
        let group = try GroupTimeMap(group: f.group.id, reference: reference, epochs: [
            EpochClockMap(epoch: f.group.epochs[0].id, mapping: .mapped(segments: [mapped],
                provenance: .manual(.init(basis: .numericEntry)))),
        ], placements: [OccurrencePlacement(occurrence: f.placement.occurrence, spans: [
            EpochSpan(startFrame: 32000, endFrame: 128000, epoch: f.group.epochs[0].id, groupClockOffset: .zero),
        ])])
        let map = try AlignedTimelineMap(reference: reference, groups: [referenceMap, group])
        let plan = PrimaryCleanupPlan.make(model: f.model, episode: f.model.episodes[0].id, map: map)
        #expect(!plan.isReady && plan.blockers.contains { $0.contains("alignment does not cover all audio") })
        #expect(plan.lanes[0].start == 1 && plan.lanes[0].end == 7)
    }

    @Test func oneAlignedPrimaryNeverAuthorizesAnUnalignedOrMissingSecondPrimary() throws {
        var fixture = try Fixture()
        let guest = Speaker(name: "Guest")
        fixture.model.speakers.append(guest)
        fixture.model.episodes[0].speakerAssignments.append(SpeakerAssignment(speakerID: guest.id))
        #expect(!fixture.plan.isReady)
        #expect(fixture.plan.blockers.contains { $0.contains("Guest") })
        var unplaced = SourceRecord(displayNameHint: "Unplaced", role: .primary, roleConfirmation: .userConfirmed)
        unplaced.placement = SourcePlacement(recorderGroupID: fixture.group.id, epochID: fixture.group.epochs[0].id)
        fixture.model.episodes[0].sources.append(unplaced)
        fixture.model.episodes[0].speakerAssignments[1].primary = ChannelReference(sourceID: unplaced.id, statedChannel: 0)
        fixture.model.episodes[0].speakerAssignments[1].primaryConfirmation = .userConfirmed
        #expect(!fixture.plan.isReady)
        #expect(fixture.plan.blockers.contains { $0.contains("no unique accepted placement") })
    }

    @Test func backupsAndUnconfirmedAssignmentsNeverBecomeTranscriptionInputs() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].sources[0].role = .backup
        #expect(!fixture.plan.isReady)
        #expect(fixture.plan.lanes.isEmpty)
        fixture.model.episodes[0].sources[0].role = .primary
        fixture.model.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        #expect(!fixture.plan.isReady)
    }

    @Test func anUnassignedPrimaryAlsoBlocksTheWholeEpisode() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].sources.append(SourceRecord(displayNameHint: "Forgotten Primary", role: .primary))
        #expect(!fixture.plan.isReady)
        #expect(fixture.plan.blockers.contains { $0.contains("Forgotten Primary") })
    }

    @Test func aKnownOutOfRangeChannelCannotBecomeReady() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].speakerAssignments[0].primary =
            ChannelReference(sourceID: fixture.source.id, statedChannel: 1)
        #expect(!fixture.plan.isReady)
        #expect(fixture.plan.lanes.isEmpty)
    }

    @Test func choosingAMonoPrimaryConfirmsItAndResolvesItsOnlyChannelWithoutAnotherStep() throws {
        var fixture = try Fixture()
        let primary = ChannelReference(sourceID: fixture.source.id, channel: .unknown)
        fixture.model.episodes[0].speakerAssignments[0].primary = nil
        fixture.model.episodes[0].speakerAssignments[0].backups = [primary]
        fixture.model.episodes[0].sources[0].role = .backup
        fixture.model = try fixture.model.settingPrimary(
            primary, for: fixture.speaker.id, in: fixture.model.episodes[0].id)
        let chosen = fixture.model
        #expect(fixture.plan.isReady)
        #expect(fixture.plan.lanes.first?.primary.channel == .known(0))
        #expect(fixture.model == chosen, "Readiness must not rewrite saved assignments")
        #expect(chosen.episodes[0].speakerAssignments[0].primary?.channel == .unknown)
        #expect(chosen.episodes[0].speakerAssignments[0].primaryConfirmation == .userConfirmed)
        #expect(chosen.episodes[0].sources[0].roleConfirmation == .userConfirmed)
    }

    @Test func unknownMultichannelChoiceRequestsAChannelNotRedundantPrimaryConfirmation() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].sources[0].observations.channelCount = .known(2)
        fixture.model.episodes[0].speakerAssignments[0].primary?.channel = .unknown
        #expect(!fixture.plan.isReady && fixture.plan.lanes.isEmpty)
        #expect(fixture.plan.blockers.contains { $0.contains("choose a valid speaker channel") })
        #expect(!fixture.plan.blockers.contains { $0.contains("confirm") })
    }

    @Test func resolvedMonoReferencesCannotAliasAnotherSpeakersPrimaryOrABackup() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].speakerAssignments[0].primary?.channel = .unknown
        fixture.model.episodes[0].speakerAssignments[0].backups = [
            ChannelReference(sourceID: fixture.source.id, statedChannel: 0),
        ]
        #expect(!fixture.plan.isReady && fixture.plan.lanes.isEmpty)
        fixture.model.episodes[0].speakerAssignments[0].backups = []
        let other = Speaker(name: "Other")
        fixture.model.speakers.append(other)
        fixture.model.episodes[0].speakerAssignments.append(SpeakerAssignment(speakerID: other.id,
            primary: ChannelReference(sourceID: fixture.source.id, statedChannel: 0),
            primaryConfirmation: .userConfirmed))
        #expect(!fixture.plan.isReady && fixture.plan.lanes.isEmpty)
        #expect(fixture.plan.blockers.contains { $0.contains("unique Primary speaker channel") })
    }

    @Test func numericalBoundariesDoNotCreateGapsButFramesAndEpochsDo() throws {
        let f = try Fixture()
        let epoch = f.group.epochs[0].id
        func lane(gap: Double = 0, nextEpoch: RecordingEpochID? = nil) -> CleanupSpeakerLane {
            CleanupSpeakerLane(speaker: f.speaker.id, name: "Host",
                primary: ChannelReference(sourceID: f.source.id, statedChannel: 0),
                sourceName: "Original", sourceRate: 16000, sourceFrames: 160000, regions: [
                    CleanupTimingRegion(occurrence: f.placement.occurrence.id, epoch: epoch,
                        sourceStart: 0, sourceEnd: 0.1 + 0.2, alignedStart: 0, rate: 1),
                    CleanupTimingRegion(occurrence: f.placement.occurrence.id, epoch: nextEpoch ?? epoch,
                        sourceStart: 0.3 + gap, sourceEnd: 10, alignedStart: 0.3 + gap, rate: 1),
                ], start: 0, end: 10)
        }
        #expect(lane().sourceRange(start: 0, end: 10) == 0..<160000)
        #expect(lane(gap: 1 / 16000).sourceRange(start: 0, end: 10) == nil)
        #expect(lane(nextEpoch: RecordingEpochID()).sourceRange(start: 0, end: 10) == nil)
        #expect(lane().sourceRange(start: .nan, end: 10) == nil)
    }

    @Test func subRecognizerRangesBlockAndWorkingBoundsStayOnTheRenderGrid() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].cleanup = EpisodeCleanup(workingRange:
            EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 1, tracksOut: 1.05))
        #expect(!fixture.plan.isReady)
        fixture.model.episodes[0].cleanup?.workingRange?.tracksOut = 1.123456789
        #expect(fixture.plan.isReady)
        #expect(fixture.plan.lanes[0].end <= 1.123456789)
        #expect(abs(fixture.plan.lanes[0].end * 48_000 - (fixture.plan.lanes[0].end * 48_000).rounded()) < 1e-8)
    }

    @Test func markerRevisionChangesBlockAndRangeClampsEveryLane() throws {
        var fixture = try Fixture()
        fixture.model.episodes[0].cleanup = EpisodeCleanup(workingRange:
            EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 2, tracksOut: 8))
        #expect(fixture.plan.isReady)
        #expect(fixture.plan.lanes[0].start == 2)
        #expect(fixture.plan.lanes[0].end == 8)
        fixture.model.episodes[0].cleanup?.workingRange?.alignmentRevision = 2
        #expect(!fixture.plan.isReady)
        fixture.model.episodes[0].cleanup?.workingRange = EpisodeWorkingRange(alignmentRevision: 1, tracksIn: 11)
        #expect(!fixture.plan.isReady)
    }
}
