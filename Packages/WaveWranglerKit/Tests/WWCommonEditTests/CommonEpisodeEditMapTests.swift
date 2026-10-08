import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
import WWTimeMap
@testable import WWCommonEdit

@Suite("Common episode edit map (synthetic, provisional)")
struct CommonEpisodeEditMapTests {
    private let fx = Fixture()

    private func make(
        _ alignment: AlignedTimelineMap,
        frames: Int64 = 480_000,
        rate: Int64 = 48_000,
        removals: [RemovedFrameSpan] = [],
        alignmentRevision: UInt64 = 2,
        editRevision: UInt64 = 3
    ) throws -> CommonEpisodeEditMap {
        try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: alignmentRevision, editRevision: editRevision,
            outputRate: NominalRate(rate), alignedFrameCount: frames, removals: removals
        )
    }

    @Test func everyOccurrenceSharesTheSameExactGridAndPadding() throws {
        let epoch = RecordingEpochID()
        let source = SourceID()
        let a = try SourceOccurrence(source: source, nominalRate: NominalRate(44_100), frameCount: 441_000)
        let b = try SourceOccurrence(source: source, nominalRate: NominalRate(44_100), frameCount: 441_000)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(0), q(10), .one, .zero)])],
            placements: [a, b].map { OccurrencePlacement(occurrence: $0, spans: [span(0, 441_000, epoch)]) }
        )
        let alignment = try fx.timeline([group])
        let cuts = [RemovedFrameSpan(start: 48_000, end: 96_000), RemovedFrameSpan(start: 144_000, end: 192_000)]
        let map = try make(alignment, frames: 528_000, removals: cuts) // 10 s source + 1 s common padding
        #expect(map.outputFrameCount == 432_000)
        #expect(map.outputDuration == q(9))
        #expect(map.keptSpans == [
            KeptFrameSpan(alignedStart: 0, alignedEnd: 48_000, outputStart: 0),
            KeptFrameSpan(alignedStart: 96_000, alignedEnd: 144_000, outputStart: 48_000),
            KeptFrameSpan(alignedStart: 192_000, alignedEnd: 528_000, outputStart: 96_000),
        ])
        #expect(map.alignedInstant(atOutputFrame: 48_000) == q(2))
        #expect(map.alignedInstant(atOutputFrame: 96_000) == q(4))
        #expect(map.alignedInstant(atOutputFrame: 431_999) == q(527_999, 48_000))
        for frame in stride(from: Int64(0), to: map.outputFrameCount, by: 1237) {
            let instant = try #require(map.alignedInstant(atOutputFrame: frame))
            for occurrence in [fx.refOccurrence, a.id, b.id] {
                let inverse = try map.sourceFrame(atOutputFrame: frame, in: occurrence)
                if instant < q(10) {
                    guard case .source(let position) = inverse else {
                        Issue.record("covered occurrence did not invert at \(frame)")
                        continue
                    }
                    #expect(position.occurrence == occurrence)
                    #expect(try position.exactFrame.subtracting(ExactRational(position.frame)).magnitude <= q(1, 2))
                    if occurrence != fx.refOccurrence {
                        #expect(position.epoch == epoch)
                    }
                } else {
                    #expect(inverse == .outsideCoverage) // padding, never synthetic source samples
                }
                #expect(try map.outputPosition(atAlignedInstant: instant) == .mapped(
                    CommonOutputPosition(exactFrame: ExactRational(frame), nearestFrame: frame)
                ))
            }
        }
        #expect(try map.outputPosition(atAlignedInstant: q(3, 2)) == .removed(cuts[0]))
        #expect(try map.outputPosition(atAlignedInstant: q(3)) == .removed(cuts[1]))
        #expect(try map.outputPosition(atAlignedInstant: q(11)) == .outsideCoverage)
        #expect(map.alignedInstant(atOutputFrame: map.outputFrameCount) == nil)
    }

    @Test func occurrencesAreDistinctAndRemovedFramesHaveNoInverse() throws {
        let alignment = try fx.timeline([])
        let removal = RemovedFrameSpan(start: 100, end: 200)
        let map = try make(alignment, frames: 480_000, removals: [removal])
        let reference = fx.refOccurrence
        if case .removed(let aligned, let span) = try map.outputFrame(ofSourceFrame: 150, in: reference) {
            #expect(aligned.epoch == fx.refEpoch)
            #expect(span == removal)
        } else { Issue.record("removed source should not be mapped") }
        if case .mapped(let position, let aligned) = try map.outputFrame(ofSourceFrame: 200, in: reference) {
            #expect(position.exactFrame == q(100))
            #expect(aligned.epoch == fx.refEpoch)
        } else { Issue.record("seam must select the following kept span") }
        #expect(try map.outputFrame(ofSourceFrame: -1, in: reference) == .outsideCoverage)
        let unknown = SourceOccurrenceID()
        #expect(throws: TimeMapError.unknownOccurrence(unknown)) {
            try map.outputFrame(ofSourceFrame: 0, in: unknown)
        }
        #expect(throws: TimeMapError.unknownOccurrence(unknown)) {
            try map.sourceFrame(atOutputFrame: -1, in: unknown)
        }
    }

    @Test func nonUnitEpochRatioAndMixedNominalRateStayExactUntilOneQuantisation() throws {
        let epoch = RecordingEpochID()
        let source = fx.occurrence(frames: 176_400, rate: 44_100)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(0), q(4), q(10_001, 10_000), .zero)])],
            placements: [OccurrencePlacement(occurrence: source, spans: [span(0, 176_400, epoch)])]
        )
        let map = try make(fx.timeline([group]), removals: [RemovedFrameSpan(start: 48_000, end: 96_000)])
        if case .removed(let aligned, _) = try map.outputFrame(ofSourceFrame: 44_100, in: source.id) {
            #expect(aligned.instant == q(10_001, 10_000))
            #expect(aligned.epoch == epoch)
        } else { Issue.record("sloped frame inside the removal gained an inverse") }
        if case .mapped(let position, let aligned) = try map.outputFrame(ofSourceFrame: 88_200, in: source.id) {
            #expect(aligned.instant == q(10_001, 5_000))
            #expect(position.exactFrame == q(240_048, 5))
            #expect(position.nearestFrame == 48_010)
            #expect(try position.exactFrame.subtracting(ExactRational(position.nearestFrame)).magnitude <= q(1, 2))
        } else { Issue.record("sloped kept frame lost its exact position") }
    }

    @Test func gapsAndUnsupportedEpochsRemainPartialAfterEdits() throws {
        let before = RecordingEpochID(), after = RecordingEpochID(), unknown = RecordingEpochID()
        let occurrence = fx.occurrence(frames: 192_000)
        let group = try fx.otherGroup(
            epochs: [
                mapped(before, [seg(q(0), q(1), .one, .zero)]),
                mapped(after, [seg(q(2), q(3), .one, .zero)]),
                EpochClockMap(epoch: unknown, mapping: .unsupported(.estimatorAbstained)),
            ],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                span(0, 48_000, before), span(48_000, 96_000, unknown),
                span(96_000, 144_000, after),
            ])]
        )
        let map = try make(fx.timeline([group]), removals: [RemovedFrameSpan(start: 24_000, end: 36_000)])
        #expect(try map.outputFrame(ofSourceFrame: 60_000, in: occurrence.id) == .unsupported(epoch: unknown, reason: .estimatorAbstained))
        #expect(try map.sourceFrame(atOutputFrame: 60_000, in: occurrence.id).regionState == .unsupported(.estimatorAbstained))

        let gapped = fx.occurrence(frames: 192_000)
        let gapGroup = try fx.otherGroup(
            epochs: [mapped(before, [seg(q(0), q(1), .one, .zero)]), mapped(after, [seg(q(2), q(3), .one, .zero)])],
            placements: [OccurrencePlacement(occurrence: gapped, spans: [span(0, 48_000, before), span(96_000, 144_000, after)])]
        )
        let gapMap = try make(fx.timeline([gapGroup]), removals: [RemovedFrameSpan(start: 24_000, end: 36_000)])
        if case .gap(let boundary) = try gapMap.sourceFrame(atOutputFrame: 60_000, in: gapped.id) {
            #expect(boundary.occurrence == gapped.id)
            #expect(boundary.precedingEpoch == before)
            #expect(boundary.precedingLastFrame == 47_999)
            #expect(boundary.followingEpoch == after)
            #expect(boundary.followingFirstFrame == 96_000)
            #expect(try gapMap.outputFrame(ofSourceFrame: 60_000, in: gapped.id) == .gap(boundary))
        } else { Issue.record("gap acquired an inverse") }
        if case .source(let source) = try gapMap.sourceFrame(atOutputFrame: 84_000, in: gapped.id) {
            #expect(source.epoch == after)
            #expect(source.frame == 96_000)
        } else { Issue.record("following epoch should retain its occurrence") }
    }

    @Test func exactOffGridInverseRoundsAtMostHalfAFrame() throws {
        let map = try make(fx.timeline([]), frames: 480_000, removals: [RemovedFrameSpan(start: 10, end: 20)])
        let instants = [q(1, 96_000), q(41, 96_000), q(19, 96_000), q(100_001, 96_000)]
        for instant in instants {
            switch try map.outputPosition(atAlignedInstant: instant) {
            case .mapped(let position):
                #expect(try position.exactFrame.subtracting(ExactRational(position.nearestFrame)).magnitude <= q(1, 2))
            case .removed: #expect(instant >= q(10, 48_000) && instant < q(20, 48_000))
            case .outsideCoverage: Issue.record("covered instant disappeared")
            }
        }
    }

    @Test func emptyFullAndIntersectingMapsAndUndoIdentity() throws {
        let alignment = try fx.timeline([])
        let original = try make(alignment, frames: 20)
        #expect(original.outputFrameCount == 20)
        let edited = try make(alignment, frames: 20, removals: [RemovedFrameSpan(start: 0, end: 20)], editRevision: 4)
        #expect(edited.outputFrameCount == 0)
        #expect(edited.keptSpans.isEmpty)
        #expect(edited.outputDuration == .zero)
        #expect(try edited.outputPosition(atAlignedInstant: q(1, 48_000)) == .removed(RemovedFrameSpan(start: 0, end: 20)))
        #expect(edited.alignedInstant(atOutputFrame: 0) == nil)
        #expect(try make(alignment, frames: 20) == original) // restoring a saved value is deterministic
        #expect(try make(alignment, frames: 20, alignmentRevision: 5) != original)
        #expect(try make(alignment, frames: 20, editRevision: 5) != original)
        #expect(throws: CommonEpisodeEditMapError.overlappingRemovals) {
            try make(alignment, frames: 20, removals: [RemovedFrameSpan(start: 2, end: 10), RemovedFrameSpan(start: 8, end: 12)])
        }
        #expect(throws: CommonEpisodeEditMapError.removalsOutOfOrder) {
            try make(alignment, frames: 20, removals: [RemovedFrameSpan(start: 10, end: 15), RemovedFrameSpan(start: 0, end: 5)])
        }
        #expect(throws: CommonEpisodeEditMapError.invalidRemoval(RemovedFrameSpan(start: 19, end: 21))) {
            try make(alignment, frames: 20, removals: [RemovedFrameSpan(start: 19, end: 21)])
        }
        #expect(try make(alignment, frames: 0).keptSpans.isEmpty)
    }

    @Test func allSmallNonIntersectingIntervalsRoundTripWithoutRipple() throws {
        let alignment = try fx.timeline([])
        for count: Int64 in 0...16 {
            for start: Int64 in 0...count {
                for end: Int64 in start...count {
                    let removals = start < end ? [RemovedFrameSpan(start: start, end: end)] : []
                    let map = try make(alignment, frames: count, removals: removals)
                    #expect(map.outputFrameCount == count - (end - start))
                    #expect(map.keptSpans.reduce(Int64(0)) { $0 + $1.outputEnd - $1.outputStart } == map.outputFrameCount)
                    for output in 0..<map.outputFrameCount {
                        let instant = try #require(map.alignedInstant(atOutputFrame: output))
                        #expect(try map.outputPosition(atAlignedInstant: instant) == .mapped(
                            CommonOutputPosition(exactFrame: ExactRational(output), nearestFrame: output)
                        ))
                    }
                }
            }
        }
    }
}

@Suite("Common render binding (synthetic preflight only)")
struct CommonRenderAdapterTests {
    private let fx = Fixture()

    private func fixture() throws -> (CommonEpisodeEditMap, [CommonRenderLaneKey], [CommonRenderLane]) {
        let other = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(48_000), frameCount: 480_000)
        let otherEpoch = RecordingEpochID()
        let otherGroup = try fx.otherGroup(
            epochs: [mapped(otherEpoch, [seg(q(0), q(10), .one, .zero)])],
            placements: [OccurrencePlacement(occurrence: other, spans: [span(0, 480_000, otherEpoch)])]
        )
        let map = try CommonEpisodeEditMap(
            alignment: fx.timeline([otherGroup]), alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: 480_000,
            removals: [RemovedFrameSpan(start: 100, end: 200)]
        )
        let primary = CommonRenderLaneKey(occurrence: fx.refOccurrence, decodedChannel: 0)
        let backup = CommonRenderLaneKey(occurrence: other.id, decodedChannel: 0)
        let silence = CommonRenderLaneKey(occurrence: other.id, decodedChannel: 1)
        let lanes = [
            CommonRenderLane(key: primary, backing: .aligned(assetVersion: "primary-7", frames: 0..<480_000)),
            CommonRenderLane(key: backup, backing: .aligned(assetVersion: "backup-7", frames: 0..<480_000)),
            CommonRenderLane(key: silence, backing: .explicitSilence(frames: 0..<480_000)),
        ]
        return (map, [primary, backup, silence], lanes)
    }

    private func inspect(
        _ map: CommonEpisodeEditMap,
        inventory: [CommonRenderLaneKey],
        lanes: [CommonRenderLane],
        protected: [CommonRenderLaneKey: [Range<Int64>]]? = nil,
        rounded: [RemovedFrameSpan]? = nil,
        fades: [RemovedFrameSpan]? = nil
    ) throws -> CommonRenderBinding {
        try CommonRenderAdapter.inspectSynthetic(
            map: map, inventory: inventory, lanes: lanes,
            protectedFrames: protected ?? Dictionary(uniqueKeysWithValues: Set(inventory).map { ($0, []) }),
            claimedRoundedRemovals: rounded ?? map.removals,
            fadeFootprints: fades ?? [RemovedFrameSpan(start: 90, end: 210)]
        )
    }

    @Test func productionRefusesEvenWithAValidSyntheticSnapshot() throws {
        let (map, keys, lanes) = try fixture()
        #expect(throws: CommonRenderRefusal.organizerAuthorityUnavailable) {
            try CommonRenderAdapter.prepare(map)
        }
        let binding = try inspect(map, inventory: keys, lanes: lanes)
        #expect(binding.lanes == lanes)
        #expect(binding.previewPrescription == map)
        #expect(binding.renderPrescription == binding.previewPrescription)
        #expect(binding.previewPrescription.outputFrameCount == 479_900)
        #expect(binding.previewPrescription.editRevision == 8)
        #expect(binding.previewPrescription.alignmentRevision == 7)
    }

    @Test func missingDuplicateUnexpectedAndUnmappedLanesRefuse() throws {
        let (map, keys, lanes) = try fixture()
        #expect(throws: CommonRenderRefusal.emptyLaneInventory) {
            try inspect(map, inventory: [], lanes: lanes)
        }
        #expect(throws: CommonRenderRefusal.duplicateLane(keys[0])) {
            try inspect(map, inventory: keys + [keys[0]], lanes: lanes)
        }
        #expect(throws: CommonRenderRefusal.missingLane(keys[2])) {
            try inspect(map, inventory: keys, lanes: Array(lanes.dropLast()))
        }
        #expect(throws: CommonRenderRefusal.duplicateLane(keys[0])) {
            try inspect(map, inventory: keys, lanes: lanes + [lanes[0]])
        }
        let unknown = CommonRenderLaneKey(occurrence: SourceOccurrenceID(), decodedChannel: 0)
        #expect(throws: CommonRenderRefusal.unknownOccurrence(unknown.occurrence)) {
            try inspect(map, inventory: keys + [unknown], lanes: lanes + [
                CommonRenderLane(key: unknown, backing: .explicitSilence(frames: 0..<480_000)),
            ])
        }
        #expect(throws: CommonRenderRefusal.unexpectedLane(keys[2])) {
            try inspect(map, inventory: Array(keys.dropLast()), lanes: lanes)
        }
        let invalid = CommonRenderLaneKey(occurrence: fx.refOccurrence, decodedChannel: -1)
        #expect(throws: CommonRenderRefusal.invalidChannel(invalid)) {
            try inspect(map, inventory: keys + [invalid], lanes: lanes + [
                CommonRenderLane(key: invalid, backing: .explicitSilence(frames: 0..<480_000)),
            ])
        }
    }

    @Test func backingAndProtectionEvidenceMustBePresentAndFullLength() throws {
        let (map, keys, lanes) = try fixture()
        let short = CommonRenderLane(key: keys[1], backing: .aligned(assetVersion: "backup-7", frames: 0..<479_999))
        #expect(throws: CommonRenderRefusal.invalidBacking(keys[1])) {
            try inspect(map, inventory: keys, lanes: [lanes[0], short, lanes[2]])
        }
        let blank = CommonRenderLane(key: keys[0], backing: .aligned(assetVersion: " ", frames: 0..<480_000))
        #expect(throws: CommonRenderRefusal.missingBacking(keys[0])) {
            try inspect(map, inventory: keys, lanes: [blank, lanes[1], lanes[2]])
        }
        #expect(throws: CommonRenderRefusal.missingProtection(keys[2])) {
            try inspect(map, inventory: keys, lanes: lanes, protected: [keys[0]: [], keys[1]: []])
        }
        let untimedSilence = CommonRenderLane(key: keys[2], backing: .explicitSilence(frames: 100..<480_000))
        #expect(throws: CommonRenderRefusal.invalidBacking(keys[2])) {
            try inspect(map, inventory: keys, lanes: [lanes[0], lanes[1], untimedSilence])
        }
        #expect(throws: CommonRenderRefusal.invalidProtection(keys[1])) {
            try inspect(map, inventory: keys, lanes: lanes, protected: [
                keys[0]: [], keys[1]: [200..<300, 250..<400], keys[2]: [],
            ])
        }
    }

    @Test func removalConsistencyAndFadeFootprintAreSeparateSyntheticChecksForEveryLane() throws {
        let (map, keys, lanes) = try fixture()
        #expect(throws: CommonRenderRefusal.removalMismatch) {
            try inspect(map, inventory: keys, lanes: lanes, rounded: [RemovedFrameSpan(start: 101, end: 200)])
        }
        #expect(throws: CommonRenderRefusal.fadeCountMismatch(expected: 1, actual: 0)) {
            try inspect(map, inventory: keys, lanes: lanes, fades: [])
        }
        #expect(throws: CommonRenderRefusal.invalidFade(RemovedFrameSpan(start: 110, end: 210))) {
            try inspect(map, inventory: keys, lanes: lanes, fades: [RemovedFrameSpan(start: 110, end: 210)])
        }
        #expect(throws: CommonRenderRefusal.unsafeRemoval(keys[1], map.removals[0])) {
            try inspect(map, inventory: keys, lanes: lanes, protected: [
                keys[0]: [], keys[1]: [150..<160], keys[2]: [],
            ])
        }
        #expect(throws: CommonRenderRefusal.unsafeFade(keys[2], RemovedFrameSpan(start: 90, end: 210))) {
            try inspect(map, inventory: keys, lanes: lanes, protected: [
                keys[0]: [], keys[1]: [], keys[2]: [205..<220],
            ])
        }
        let twoCuts = try CommonEpisodeEditMap(
            alignment: map.alignment, alignmentRevision: map.alignmentRevision,
            editRevision: map.editRevision, outputRate: map.outputRate,
            alignedFrameCount: map.alignedFrameCount,
            removals: map.removals + [RemovedFrameSpan(start: 220, end: 320)]
        )
        let firstFade = RemovedFrameSpan(start: 90, end: 230)
        let secondFade = RemovedFrameSpan(start: 210, end: 330)
        #expect(throws: CommonRenderRefusal.overlappingFades(firstFade, secondFade)) {
            try inspect(twoCuts, inventory: keys, lanes: lanes, fades: [firstFade, secondFade])
        }
    }
}

@Suite("Organizer-derived lane requirements (provisional, synthetic)")
struct ProvisionalLaneInventoryTests {
    private let fx = Fixture()

    private func fixture() throws -> (Episode, CommonEpisodeEditMap, SourceID, SourceID) {
        let backupSource = SourceID()
        let backup = try SourceOccurrence(
            source: backupSource, nominalRate: NominalRate(48_000), frameCount: 480_000
        )
        let backupEpoch = RecordingEpochID()
        let other = try fx.otherGroup(
            epochs: [mapped(backupEpoch, [seg(q(0), q(10), .one, .zero)])],
            placements: [OccurrencePlacement(occurrence: backup, spans: [span(0, 480_000, backupEpoch)])]
        )
        let alignment = try fx.timeline([other])
        let map = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: 480_000,
            removals: [RemovedFrameSpan(start: 100, end: 200)]
        )
        let primarySource = alignment.groups[0].placements[0].occurrence.source
        let acceptedJSON = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        let primary = SourceRecord(
            id: primarySource, displayNameHint: "primary",
            observations: SourceObservations(channelCount: .known(1)),
            placement: SourcePlacement(recorderGroupID: fx.group, epochID: fx.refEpoch),
            role: .primary
        )
        let backupRecord = SourceRecord(
            id: backupSource, displayNameHint: "backup",
            observations: SourceObservations(channelCount: .known(2)),
            placement: SourcePlacement(recorderGroupID: other.group, epochID: backupEpoch),
            role: .backup
        )
        let episode = Episode(
            title: "Synthetic",
            recorderGroups: [
                RecorderGroup(id: fx.group, name: "reference", epochs: [RecordingEpoch(id: fx.refEpoch, label: "ref")]),
                RecorderGroup(id: other.group, name: "other", epochs: [RecordingEpoch(id: backupEpoch, label: "backup")]),
            ],
            sources: [primary, backupRecord],
            speakerAssignments: [
                SpeakerAssignment(
                    speakerID: SpeakerID(),
                    primary: ChannelReference(sourceID: primarySource, statedChannel: 0),
                    backups: [ChannelReference(sourceID: backupSource, statedChannel: 0)]
                ),
            ],
            alignment: EpisodeAlignment(
                maps: [TimeMapVersion(
                    revision: 7, inputs: TimeMapInputs(sources: [
                        TimeMapSourceInput(sourceID: primarySource),
                        TimeMapSourceInput(sourceID: backupSource),
                    ]), map: acceptedJSON
                )],
                acceptedRevision: 7
            )
        )
        return (episode, map, primarySource, backupSource)
    }

    private func replacingOtherGroup(
        _ group: GroupTimeMap, in episode: inout Episode, map: CommonEpisodeEditMap,
        frames: Int64 = 480_000
    ) throws -> CommonEpisodeEditMap {
        let alignment = try AlignedTimelineMap(
            reference: map.alignment.reference, groups: [map.alignment.groups[0], group]
        )
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        return try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: map.alignmentRevision, editRevision: map.editRevision,
            outputRate: map.outputRate, alignedFrameCount: frames, removals: map.removals
        )
    }

    @Test func includesEveryOccurrenceChannelIncludingBackupAndUnassignedSilentCandidate() throws {
        let (episode, map, primary, backup) = try fixture()
        let inventory = try ProvisionalLaneInventory.inspect(episode: episode, map: map)
        #expect(inventory.episode == episode.id)
        #expect(inventory.alignmentRevision == 7)
        #expect(inventory.editRevision == 8)
        #expect(inventory.requirements.count == 3)
        #expect(Set(inventory.requirements.map(\.key)).count == 3)
        #expect(inventory.requirements.filter { $0.source == primary }.count == 1)
        #expect(inventory.requirements.filter { $0.source == backup }.map(\.key.decodedChannel) == [0, 1])
        #expect(inventory.requirements.filter { $0.source == backup }.allSatisfy { $0.sourceRole == .backup })
        #expect(inventory.requirements.allSatisfy { $0.epochs.count == 1 })
        #expect(throws: CommonRenderRefusal.organizerAuthorityUnavailable) {
            try CommonRenderAdapter.prepare(map)
        }

        let keys = inventory.requirements.map(\.key)
        let lanes = keys.dropLast().map {
            CommonRenderLane(key: $0, backing: .aligned(assetVersion: "synthetic", frames: 0..<480_000))
        }
        #expect(throws: CommonRenderRefusal.missingLane(keys[2])) {
            try CommonRenderAdapter.inspectSynthetic(
                map: map, inventory: keys, lanes: lanes,
                protectedFrames: Dictionary(uniqueKeysWithValues: keys.map { ($0, []) }),
                claimedRoundedRemovals: map.removals,
                fadeFootprints: [RemovedFrameSpan(start: 90, end: 210)]
            )
        }
    }

    @Test func missingOrNewSourceAndStaleMapRefuseRatherThanNarrowInventory() throws {
        let (episode, map, _, backup) = try fixture()
        var missing = episode
        missing.sources.removeLast()
        #expect(throws: ProvisionalLaneInventoryError.sourceMissing(backup)) {
            try ProvisionalLaneInventory.inspect(episode: missing, map: map)
        }
        var added = episode
        let unplaced = SourceRecord(displayNameHint: "other", observations: SourceObservations(channelCount: .known(1)))
        added.sources.append(unplaced)
        #expect(throws: ProvisionalLaneInventoryError.sourceNotPlaced(unplaced.id)) {
            try ProvisionalLaneInventory.inspect(episode: added, map: map)
        }
        var stale = episode
        stale.alignment?.acceptedRevision = nil
        #expect(throws: ProvisionalLaneInventoryError.alignmentNotAccepted) {
            try ProvisionalLaneInventory.inspect(episode: stale, map: map)
        }
        stale = episode
        stale.alignment?.maps[0].map = .null
        #expect(throws: ProvisionalLaneInventoryError.alignmentChanged) {
            try ProvisionalLaneInventory.inspect(episode: stale, map: map)
        }
        stale = episode
        stale.alignment?.maps[0].inputs.sources.removeLast()
        #expect(throws: ProvisionalLaneInventoryError.alignmentInputsChanged) {
            try ProvisionalLaneInventory.inspect(episode: stale, map: map)
        }
    }

    @Test func repeatedSourceUsesKeepDistinctOccurrenceKeys() throws {
        var (episode, map, _, backup) = try fixture()
        let group = map.alignment.groups[1]
        let epoch = group.placements[0].spans[0].epoch
        let repeated = try SourceOccurrence(
            source: backup, nominalRate: NominalRate(48_000), frameCount: 480_000
        )
        let extendedGroup = try GroupTimeMap(
            group: group.group, reference: map.alignment.reference, epochs: group.epochs,
            placements: group.placements + [
                OccurrencePlacement(occurrence: repeated, spans: [span(0, 480_000, epoch)]),
            ]
        )
        let alignment = try AlignedTimelineMap(
            reference: map.alignment.reference, groups: [map.alignment.groups[0], extendedGroup]
        )
        map = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: 480_000,
            removals: map.removals
        )
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        let requirements = try ProvisionalLaneInventory.inspect(episode: episode, map: map).requirements
        let backupKeys = requirements.filter { $0.source == backup }.map(\.key)
        #expect(backupKeys.count == 4)
        #expect(Set(backupKeys.map(\.occurrence)).count == 2)
        #expect(Set(backupKeys).count == 4)
    }

    @Test func anotherSpeakersPrimaryCannotBeOmittedFromRequirements() throws {
        var (episode, map, _, backup) = try fixture()
        let before = try ProvisionalLaneInventory.inspect(episode: episode, map: map).requirements
        episode.speakerAssignments.append(SpeakerAssignment(
            speakerID: SpeakerID(),
            primary: ChannelReference(sourceID: backup, statedChannel: 1)
        ))
        let requirements = try ProvisionalLaneInventory.inspect(episode: episode, map: map).requirements
        #expect(requirements == before)
        #expect(requirements.contains {
            $0.source == backup && $0.key.decodedChannel == 1 && $0.sourceRole == .backup
        })
        #expect(throws: CommonRenderRefusal.organizerAuthorityUnavailable) {
            try CommonRenderAdapter.prepare(map)
        }
    }

    @Test func sourceEpochMustBeStatedAndExactlyMatchEachOccurrence() throws {
        let (episode, map, primary, backup) = try fixture()
        for (index, source) in [(0, primary), (1, backup)] {
            var missing = episode
            missing.sources[index].placement.epochID = nil
            #expect(throws: ProvisionalLaneInventoryError.sourceEpochUnavailable(source)) {
                try ProvisionalLaneInventory.inspect(episode: missing, map: map)
            }
        }
        var changed = episode
        let otherEpoch = RecordingEpochID()
        changed.recorderGroups[1].epochs.append(RecordingEpoch(id: otherEpoch, label: "other"))
        changed.sources[1].placement.epochID = otherEpoch
        #expect(throws: ProvisionalLaneInventoryError.sourceReassignedEpoch(backup)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
    }

    @Test func everyMapEpochNeedsAnExactlyPlacedSourceEvenWithRepeatedOccurrences() throws {
        var (episode, map, _, backup) = try fixture()
        let group = map.alignment.groups[1]
        let firstEpoch = group.epochs[0].epoch
        let secondEpoch = RecordingEpochID()
        let secondMap = mapped(secondEpoch, [seg(q(10), q(20), .one, .zero)])
        episode.recorderGroups[1].epochs.append(RecordingEpoch(id: secondEpoch, label: "second"))
        let unplaced = try GroupTimeMap(
            group: group.group, reference: map.alignment.reference,
            epochs: group.epochs + [secondMap], placements: group.placements
        )
        map = try replacingOtherGroup(unplaced, in: &episode, map: map)
        #expect(throws: ProvisionalLaneInventoryError.epochNotPlaced(secondEpoch)) {
            try ProvisionalLaneInventory.inspect(episode: episode, map: map)
        }

        let spanning = try GroupTimeMap(
            group: group.group, reference: map.alignment.reference,
            epochs: unplaced.epochs,
            placements: [OccurrencePlacement(
                occurrence: group.placements[0].occurrence,
                spans: [
                    span(0, 240_000, firstEpoch),
                    EpochSpan(startFrame: 240_000, endFrame: 480_000, epoch: secondEpoch, groupClockOffset: q(5)),
                ]
            )]
        )
        map = try replacingOtherGroup(spanning, in: &episode, map: map, frames: 960_000)
        #expect(throws: ProvisionalLaneInventoryError.sourceReassignedEpoch(backup)) {
            try ProvisionalLaneInventory.inspect(episode: episode, map: map)
        }

        let repeated = try SourceOccurrence(
            source: backup, nominalRate: NominalRate(48_000), frameCount: 480_000
        )
        let secondSpan = EpochSpan(
            startFrame: 0, endFrame: 480_000, epoch: secondEpoch, groupClockOffset: q(10)
        )
        let repeatedPlacement = OccurrencePlacement(occurrence: repeated, spans: [secondSpan])
        let mixed = try GroupTimeMap(
            group: group.group, reference: map.alignment.reference,
            epochs: unplaced.epochs, placements: group.placements + [repeatedPlacement]
        )
        map = try replacingOtherGroup(mixed, in: &episode, map: map, frames: 960_000)
        #expect(throws: ProvisionalLaneInventoryError.sourceReassignedEpoch(backup)) {
            try ProvisionalLaneInventory.inspect(episode: episode, map: map)
        }

        let secondSource = SourceID()
        let placed = try GroupTimeMap(
            group: group.group, reference: map.alignment.reference,
            epochs: unplaced.epochs,
            placements: group.placements + [OccurrencePlacement(
                occurrence: try SourceOccurrence(
                    id: repeated.id, source: secondSource, nominalRate: repeated.nominalRate,
                    frameCount: repeated.frameCount
                ),
                spans: [secondSpan]
            )]
        )
        map = try replacingOtherGroup(placed, in: &episode, map: map, frames: 960_000)
        episode.sources.append(SourceRecord(
            id: secondSource, displayNameHint: "second",
            observations: SourceObservations(channelCount: .known(1)),
            placement: SourcePlacement(recorderGroupID: group.group, epochID: secondEpoch)
        ))
        episode.alignment?.maps[0].inputs.sources.append(TimeMapSourceInput(sourceID: secondSource))
        let requirements = try ProvisionalLaneInventory.inspect(episode: episode, map: map).requirements
        #expect(requirements.count == 4)
        #expect(requirements.filter { $0.source == backup }.allSatisfy { $0.epochs == [firstEpoch] })
        #expect(requirements.filter { $0.source == secondSource }.map(\.epochs) == [[secondEpoch]])
    }

    @Test func channelCannotHaveDuplicateRolesOrBelongToTwoSpeakers() throws {
        let (episode, map, primary, backup) = try fixture()
        let first = ChannelReference(sourceID: primary, statedChannel: 0)
        let second = ChannelReference(sourceID: backup, statedChannel: 0)
        var changed = episode
        changed.speakerAssignments[0].backups.append(first)
        #expect(throws: ProvisionalLaneInventoryError.ambiguousAssignment(first)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        changed.speakerAssignments[0].backups.append(second)
        #expect(throws: ProvisionalLaneInventoryError.ambiguousAssignment(second)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        changed.speakerAssignments.append(SpeakerAssignment(speakerID: SpeakerID(), backups: [first]))
        #expect(throws: ProvisionalLaneInventoryError.ambiguousAssignment(first)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        changed.speakerAssignments.append(SpeakerAssignment(speakerID: SpeakerID(), primary: second))
        #expect(throws: ProvisionalLaneInventoryError.ambiguousAssignment(second)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        changed.speakerAssignments.append(SpeakerAssignment(speakerID: SpeakerID(), backups: [second]))
        #expect(throws: ProvisionalLaneInventoryError.ambiguousAssignment(second)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
    }

    @Test func changedGroupEpochChannelAndSpeakerAssignmentRefuse() throws {
        let (episode, map, primary, backup) = try fixture()
        var changed = episode
        changed.sources[1].placement.recorderGroupID = fx.group
        #expect(throws: ProvisionalLaneInventoryError.sourceRegrouped(backup)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        let staleEpoch = RecordingEpochID()
        changed.sources[1].placement.epochID = staleEpoch
        #expect(throws: ProvisionalLaneInventoryError.sourceReassignedEpoch(backup)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        let missingEpoch = changed.recorderGroups[1].epochs.removeFirst().id
        #expect(throws: ProvisionalLaneInventoryError.epochMissing(missingEpoch)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        changed.recorderGroups[1].epochs.append(RecordingEpoch(id: fx.refEpoch, label: "duplicate"))
        #expect(throws: ProvisionalLaneInventoryError.duplicateEpoch(fx.refEpoch)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        changed.sources[1].observations.channelCount = .unknown
        #expect(throws: ProvisionalLaneInventoryError.channelCountUnavailable(backup)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        let ambiguous = ChannelReference(sourceID: backup, statedChannel: nil)
        changed.speakerAssignments[0].backups = [ambiguous]
        #expect(throws: ProvisionalLaneInventoryError.ambiguousAssignment(ambiguous)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
        changed = episode
        let duplicate = ChannelReference(sourceID: primary, statedChannel: 0)
        changed.speakerAssignments.append(SpeakerAssignment(speakerID: SpeakerID(), primary: duplicate))
        #expect(throws: ProvisionalLaneInventoryError.ambiguousPrimary(duplicate)) {
            try ProvisionalLaneInventory.inspect(episode: changed, map: map)
        }
    }
}

@Suite("Source-backed all-lane proof (synthetic WAV only)")
struct SourceBackedProofTests {
    private let fx = Fixture()
    private let cut = RemovedFrameSpan(start: 100, end: 200)
    private let fade = RemovedFrameSpan(start: 90, end: 210)

    private func fixture(repeated: Bool = false) throws -> (Episode, CommonEpisodeEditMap, SourceID, SourceID) {
        let primary = SourceID(), backup = SourceID()
        let reference = try SourceOccurrence(
            id: fx.refOccurrence, source: primary, nominalRate: NominalRate(48_000), frameCount: fx.refFrames
        )
        let own = try GroupTimeMap(
            group: fx.group, reference: fx.reference,
            epochs: [EpochClockMap(epoch: fx.refEpoch, mapping: .mapped(
                segments: [seg(q(0), q(10), .one, .zero)], provenance: .timelineReference
            ))],
            placements: [OccurrencePlacement(occurrence: reference, spans: [span(0, fx.refFrames, fx.refEpoch)])]
        )
        let backupEpoch = RecordingEpochID(), backupGroup = RecorderGroupID()
        let first = try SourceOccurrence(source: backup, nominalRate: NominalRate(48_000), frameCount: fx.refFrames)
        let second = try SourceOccurrence(source: backup, nominalRate: NominalRate(48_000), frameCount: fx.refFrames)
        let backupMap = try GroupTimeMap(
            group: backupGroup, reference: fx.reference,
            epochs: [mapped(backupEpoch, [seg(q(0), q(10), .one, .zero)])],
            placements: (repeated ? [first, second] : [first]).map {
                OccurrencePlacement(occurrence: $0, spans: [span(0, fx.refFrames, backupEpoch)])
            }
        )
        let alignment = try AlignedTimelineMap(reference: fx.reference, groups: [own, backupMap])
        let map = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: fx.refFrames, removals: [cut]
        )
        let encoded = try JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(alignment))
        let episode = Episode(
            title: "Synthetic", recorderGroups: [
                RecorderGroup(id: fx.group, name: "primary", epochs: [RecordingEpoch(id: fx.refEpoch, label: "first")]),
                RecorderGroup(id: backupGroup, name: "backup", epochs: [RecordingEpoch(id: backupEpoch, label: "second")]),
            ],
            sources: [
                SourceRecord(id: primary, displayNameHint: "primary",
                             observations: SourceObservations(channelCount: .known(1)),
                             placement: SourcePlacement(recorderGroupID: fx.group, epochID: fx.refEpoch), role: .primary),
                SourceRecord(id: backup, displayNameHint: "backup",
                             observations: SourceObservations(channelCount: .known(2)),
                             placement: SourcePlacement(recorderGroupID: backupGroup, epochID: backupEpoch), role: .backup),
            ],
            speakerAssignments: [
                SpeakerAssignment(speakerID: SpeakerID(),
                                  primary: ChannelReference(sourceID: primary, statedChannel: 0),
                                  backups: [ChannelReference(sourceID: backup, statedChannel: 0)]),
            ],
            alignment: EpisodeAlignment(
                maps: [TimeMapVersion(revision: 7, inputs: TimeMapInputs(sources: [
                    TimeMapSourceInput(sourceID: primary, formatInterpretationVersion: FormatInterpretation.currentVersion),
                    TimeMapSourceInput(sourceID: backup, formatInterpretationVersion: FormatInterpretation.currentVersion),
                ]), map: encoded)], acceptedRevision: 7
            )
        )
        return (episode, map, primary, backup)
    }

    private func inspect(
        _ episode: Episode, _ map: CommonEpisodeEditMap, _ urls: [SourceID: URL],
        fades: [RemovedFrameSpan]? = nil,
        knownProtected: [CommonRenderLaneKey: [Range<Int64>]] = [:]
    ) async throws -> ProvisionalSourceBackedProof {
        try await ProvisionalSourceBackedProof.inspect(
            episode: episode, map: map, sourceURLs: urls,
            decoder: SourceDecoder(access: SourceAccessContext()),
            finalFadeFootprints: fades ?? [fade],
            knownProtectedFrames: knownProtected
        )
    }

    private func replacingBackup(
        in episode: inout Episode, map: CommonEpisodeEditMap,
        rate: Int64, frames: Int64, segments: [AffineClockSegment]
    ) throws -> (CommonEpisodeEditMap, SourceOccurrenceID) {
        let group = map.alignment.groups[1]
        let original = group.placements[0].occurrence
        let replacement = try SourceOccurrence(
            id: original.id, source: original.source, nominalRate: NominalRate(rate), frameCount: frames
        )
        let updated = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [mapped(group.epochs[0].epoch, segments)],
            placements: [OccurrencePlacement(
                occurrence: replacement, spans: [span(0, frames, group.epochs[0].epoch)]
            )]
        )
        let alignment = try AlignedTimelineMap(
            reference: map.alignment.reference, groups: [map.alignment.groups[0], updated]
        )
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        let revised = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: map.alignmentRevision, editRevision: map.editRevision,
            outputRate: map.outputRate, alignedFrameCount: map.alignedFrameCount, removals: map.removals
        )
        return (revised, replacement.id)
    }

    @Test func everyDecodedChannelAndRepeatedOccurrenceHasIndependentSourceProof() async throws {
        let (episode, map, primary, backup) = try fixture(repeated: true)
        let files = try SyntheticWAVs()
        let urls = try files.write(primary: primary, backup: backup)
        let proof = try await inspect(episode, map, urls)
        #expect(proof.map == map)
        #expect(proof.lanes.count == 5)
        #expect(Set(proof.lanes.map(\.key)).count == 5)
        #expect(proof.lanes.filter(\.digitalSilence).count == 2)
        #expect(proof.lanes.filter { $0.source == backup }.count == 4)
        #expect(proof.lanes.allSatisfy { $0.interpretation.sourceFingerprint.fileSize.value != nil })
        #expect(throws: CommonRenderRefusal.organizerAuthorityUnavailable) {
            try CommonRenderAdapter.prepare(map)
        }
    }

    @Test func missingAndChangedSourcesNeverBecomeSilentOrSafe() async throws {
        var (episode, map, primary, backup) = try fixture()
        let files = try SyntheticWAVs()
        let urls = try files.write(primary: primary, backup: backup)
        await #expect(throws: SourceProofRefusal.sourceUnavailable(backup)) {
            try await inspect(episode, map, [primary: urls[primary]!])
        }
        episode.alignment?.maps[0].inputs.sources[1].formatInterpretationVersion = nil
        await #expect(throws: SourceProofRefusal.unverifiedMapInput(backup)) {
            try await inspect(episode, map, urls)
        }
        episode.alignment?.maps[0].inputs.sources[1].formatInterpretationVersion = FormatInterpretation.currentVersion
        let mismatched = try files.wav(channels: [[Int16](repeating: 0, count: 480_000)])
        await #expect(throws: SourceProofRefusal.formatChanged(backup)) {
            try await inspect(episode, map, [primary: urls[primary]!, backup: mismatched])
        }
        let drift = try files.wav(channels: [[Int16](repeating: 0, count: 479_999),
                                             [Int16](repeating: 0, count: 479_999)])
        await #expect(throws: SourceProofRefusal.formatChanged(backup)) {
            try await inspect(episode, map, [primary: urls[primary]!, backup: drift])
        }
    }

    @Test func protectedBackupOtherChannelAndMergedFadeAreCheckedFromSamples() async throws {
        let (episode, map, primary, backup) = try fixture(repeated: true)
        let files = try SyntheticWAVs()
        let primaryURL = try files.wav(channels: [SyntheticWAVs.signal(active: 1_000..<1_010)])
        let protectedBackup = try files.wav(channels: [
            SyntheticWAVs.signal(active: 1_000..<1_010),
            SyntheticWAVs.signal(active: 150..<151),
        ])
        let keys = map.alignment.groups[1].placements.map {
            CommonRenderLaneKey(occurrence: $0.occurrence.id, decodedChannel: 1)
        }
        await #expect(throws: SourceProofRefusal.unsafeRemoval(keys[0], cut)) {
            try await inspect(episode, map, [primary: primaryURL, backup: protectedBackup])
        }
        let fadedBackup = try files.wav(channels: [
            SyntheticWAVs.signal(active: 1_000..<1_010),
            SyntheticWAVs.signal(active: 205..<206),
        ])
        await #expect(throws: SourceProofRefusal.unsafeFade(keys[0], fade)) {
            try await inspect(episode, map, [primary: primaryURL, backup: fadedBackup])
        }
        let safe = try files.write(primary: primary, backup: backup)
        await #expect(throws: SourceProofRefusal.invalidFade(RemovedFrameSpan(start: 101, end: 210))) {
            try await inspect(episode, map, safe, fades: [RemovedFrameSpan(start: 101, end: 210)])
        }
        let twoCuts = try CommonEpisodeEditMap(
            alignment: map.alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: map.outputRate, alignedFrameCount: map.alignedFrameCount,
            removals: [cut, RemovedFrameSpan(start: 220, end: 300)]
        )
        let merged = [RemovedFrameSpan(start: 90, end: 230),
                      RemovedFrameSpan(start: 210, end: 330)]
        let proof = try await inspect(episode, twoCuts, safe, fades: merged)
        #expect(proof.lanes.count == 5)
        let silentKey = CommonRenderLaneKey(occurrence: keys[0].occurrence, decodedChannel: 1)
        await #expect(throws: SourceProofRefusal.unsafeRemoval(silentKey, cut)) {
            try await inspect(episode, map, safe, knownProtected: [silentKey: [150..<160]])
        }
        await #expect(throws: SourceProofRefusal.unsafeFade(silentKey, fade)) {
            try await inspect(episode, map, safe, knownProtected: [silentKey: [205..<206]])
        }
        let fadeProtected = try files.wav(channels: [
            SyntheticWAVs.signal(active: 1_000..<1_010),
            SyntheticWAVs.signal(active: 215..<216),
        ])
        await #expect(throws: SourceProofRefusal.unsafeFade(keys[0], RemovedFrameSpan(start: 90, end: 330))) {
            try await inspect(episode, twoCuts, [primary: primaryURL, backup: fadeProtected], fades: merged)
        }
    }

    @Test func mixedRateSourceUsesExactInverseBeforeCommonGridRounding() async throws {
        var (episode, map, primary, backup) = try fixture()
        let (revised, mixed) = try replacingBackup(
            in: &episode, map: map, rate: 44_100, frames: 441_000,
            segments: [
                seg(q(0), q(9), q(101, 100), .zero),
                seg(q(9), q(10), q(91, 100), q(9, 10)),
            ]
        )
        map = revised
        let files = try SyntheticWAVs()
        let primaryURL = try files.wav(channels: [SyntheticWAVs.signal(active: 1_000..<1_010)])
        let backupURL = try files.wav(channels: [
            [Int16](repeating: 0, count: 441_000),
            [Int16](repeating: 0, count: 441_000),
        ], sampleRate: 44_100)
        let urls = [primary: primaryURL, backup: backupURL]
        let proof = try await inspect(episode, map, urls)
        #expect(proof.lanes.count == 3)
        guard case .source(let position) = try map.alignment.sourceFrame(
            at: map.outputRate.instant(ofFrame: cut.start), in: mixed
        ) else { Issue.record("mixed-rate cut boundary failed inverse"); return }
        #expect(position.exactFrame == q(18_375, 202))
        #expect(try map.alignment.sourceFrame(
            at: map.outputRate.instant(ofFrame: 479_999), in: mixed
        ).regionState != .outsideCoverage)
        let protected = try files.wav(channels: [
            [Int16](repeating: 0, count: 441_000),
            {
                var channel = [Int16](repeating: 0, count: 441_000)
                channel[135] = 4_096
                return channel
            }(),
        ], sampleRate: 44_100)
        let key = CommonRenderLaneKey(occurrence: mixed, decodedChannel: 1)
        await #expect(throws: SourceProofRefusal.unsafeRemoval(key, cut)) {
            try await inspect(episode, map, [primary: primaryURL, backup: protected])
        }
    }

    @Test func equalDurationDoesNotProveLastMixedRateGridFrameHasAnInverse() async throws {
        var (episode, map, primary, backup) = try fixture()
        // Both recordings end at 10 s, but 479999/48000 is later than 440999/44100.
        let (revised, occurrence) = try replacingBackup(
            in: &episode, map: map, rate: 44_100, frames: 441_000,
            segments: [seg(q(0), q(10), .one, .zero)]
        )
        map = revised
        let files = try SyntheticWAVs()
        let urls = [
            primary: try files.wav(channels: [SyntheticWAVs.signal(active: 1_000..<1_010)]),
            backup: try files.wav(channels: [
                [Int16](repeating: 0, count: 441_000),
                [Int16](repeating: 0, count: 441_000),
            ], sampleRate: 44_100),
        ]
        #expect(map.outputRate.instant(ofFrame: map.alignedFrameCount) == q(10))
        #expect(try map.alignment.sourceFrame(
            at: map.outputRate.instant(ofFrame: 479_999), in: occurrence
        ) == .outsideCoverage)
        await #expect(throws: SourceProofRefusal.retainedFrameNotInvertible(occurrence, 479_999)) {
            try await inspect(episode, map, urls)
        }
        #expect(throws: CommonRenderRefusal.organizerAuthorityUnavailable) {
            try CommonRenderAdapter.prepare(map)
        }
    }

    @Test func trailingExclusiveCutEndNeedsNoPhantomSourceFrame() async throws {
        let (episode, original, primary, backup) = try fixture(repeated: true)
        let trailing = RemovedFrameSpan(start: 479_900, end: 480_000)
        let map = try CommonEpisodeEditMap(
            alignment: original.alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: original.outputRate, alignedFrameCount: original.alignedFrameCount,
            removals: [cut, trailing]
        )
        let files = try SyntheticWAVs()
        let urls = try files.write(primary: primary, backup: backup)
        let proof = try await inspect(
            episode, map, urls,
            fades: [RemovedFrameSpan(start: 90, end: 210), RemovedFrameSpan(start: 479_890, end: 480_000)]
        )
        #expect(proof.lanes.count == 5)
        #expect(map.keptSpans.last?.alignedEnd == trailing.start)
        for lane in proof.lanes {
            #expect(try map.alignment.sourceFrame(
                at: map.outputRate.instant(ofFrame: 479_899), in: lane.key.occurrence
            ).regionState != .outsideCoverage)
            #expect(try map.alignment.sourceFrame(
                at: map.outputRate.instant(ofFrame: trailing.end), in: lane.key.occurrence
            ) == .outsideCoverage)
        }
        #expect(throws: CommonRenderRefusal.organizerAuthorityUnavailable) {
            try CommonRenderAdapter.prepare(map)
        }
    }

    @Test func shiftedRepeatedOccurrenceCannotBorrowTheFirstOccurrencesInverse() async throws {
        var (episode, map, primary, backup) = try fixture(repeated: true)
        let group = map.alignment.groups[1]
        let epoch = group.epochs[0].epoch
        let first = group.placements[0]
        let second = group.placements[1].occurrence
        let shifted = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [mapped(epoch, [seg(q(0), q(480_001, 48_000), .one, .zero)])],
            placements: [first, OccurrencePlacement(occurrence: second, spans: [
                EpochSpan(startFrame: 0, endFrame: 480_000, epoch: epoch,
                          groupClockOffset: q(1, 48_000)),
            ])]
        )
        let alignment = try AlignedTimelineMap(
            reference: map.alignment.reference, groups: [map.alignment.groups[0], shifted]
        )
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        map = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: map.outputRate, alignedFrameCount: map.alignedFrameCount, removals: [cut]
        )
        let files = try SyntheticWAVs()
        let urls = try files.write(primary: primary, backup: backup)
        await #expect(throws: SourceProofRefusal.uncovered(second.id)) {
            try await inspect(episode, map, urls)
        }
    }

    @Test func sourceGapCannotBeReclassifiedAsDecodedSilence() async throws {
        var (episode, map, primary, backup) = try fixture()
        let group = map.alignment.groups[1]
        let firstEpoch = group.epochs[0].epoch
        let secondEpoch = RecordingEpochID()
        let occurrence = group.placements[0].occurrence
        let gapped = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [
                mapped(firstEpoch, [seg(q(0), q(5), .one, .zero)]),
                mapped(secondEpoch, [seg(q(5), q(10), .one, .zero)]),
            ],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                span(0, 240_000, firstEpoch), span(240_001, 480_000, secondEpoch),
            ])]
        )
        let alignment = try AlignedTimelineMap(
            reference: map.alignment.reference, groups: [map.alignment.groups[0], gapped]
        )
        episode.recorderGroups[1].epochs.append(RecordingEpoch(id: secondEpoch, label: "gap continuation"))
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        map = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: map.outputRate, alignedFrameCount: map.alignedFrameCount, removals: [cut]
        )
        #expect(try map.alignment.sourceFrame(
            at: map.outputRate.instant(ofFrame: 240_000), in: occurrence.id
        ).regionState == .gap)
        let files = try SyntheticWAVs()
        let urls = try files.write(primary: primary, backup: backup)
        await #expect(throws: ProvisionalLaneInventoryError.sourceReassignedEpoch(backup)) {
            try await inspect(episode, map, urls)
        }
    }

    @Test func unmappedInteriorAndSignedOffsetRefuseInsteadOfAssumingPadding() async throws {
        var (episode, map, _, _) = try fixture()
        let files = try SyntheticWAVs()
        let urls = try files.write(primary: episode.sources[0].id, backup: episode.sources[1].id)
        let group = map.alignment.groups[1]
        let unsupported = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [EpochClockMap(epoch: group.epochs[0].epoch, mapping: .unsupported(.estimatorAbstained))],
            placements: group.placements
        )
        let alignment = try AlignedTimelineMap(reference: map.alignment.reference,
                                               groups: [map.alignment.groups[0], unsupported])
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(alignment)
        )
        map = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: 480_000, removals: [cut]
        )
        let occurrence = group.placements[0].occurrence.id
        await #expect(throws: SourceProofRefusal.unsupportedEpoch(group.epochs[0].epoch)) {
            try await inspect(episode, map, urls)
        }
        let longSource = try SourceOccurrence(
            id: group.placements[0].occurrence.id, source: episode.sources[1].id,
            nominalRate: NominalRate(48_000), frameCount: 480_001
        )
        let longGroup = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [mapped(group.epochs[0].epoch, [seg(q(0), q(480_001, 48_000), .one, .zero)])],
            placements: [OccurrencePlacement(
                occurrence: longSource, spans: [span(0, 480_001, group.epochs[0].epoch)]
            )]
        )
        let longAlignment = try AlignedTimelineMap(
            reference: map.alignment.reference, groups: [map.alignment.groups[0], longGroup]
        )
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(longAlignment)
        )
        map = try CommonEpisodeEditMap(
            alignment: longAlignment, alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: 480_000, removals: [cut]
        )
        let longURL = try files.wav(channels: [[Int16](repeating: 0, count: 480_001),
                                               [Int16](repeating: 0, count: 480_001)])
        await #expect(throws: SourceProofRefusal.outsideEpisodeCoverage(occurrence)) {
            try await inspect(episode, map, [episode.sources[0].id: urls[episode.sources[0].id]!,
                                             episode.sources[1].id: longURL])
        }
        let negative = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [mapped(group.epochs[0].epoch, [seg(q(0), q(10), .one, q(-1, 10))])],
            placements: group.placements
        )
        let shifted = try AlignedTimelineMap(reference: map.alignment.reference,
                                             groups: [map.alignment.groups[0], negative])
        episode.alignment?.maps[0].map = try JSONDecoder().decode(
            EmbeddedJSON.self, from: JSONEncoder().encode(shifted)
        )
        map = try CommonEpisodeEditMap(
            alignment: shifted, alignmentRevision: 7, editRevision: 8,
            outputRate: NominalRate(48_000), alignedFrameCount: 480_000, removals: [cut]
        )
        await #expect(throws: SourceProofRefusal.negativeAlignedOrigin(occurrence)) {
            try await inspect(episode, map, urls)
        }
    }
}

private final class SyntheticWAVs {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ww-common-proof-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func signal(active: Range<Int>) -> [Int16] {
        var samples = [Int16](repeating: 0, count: 480_000)
        for frame in active { samples[frame] = 4_096 }
        return samples
    }

    func write(primary: SourceID, backup: SourceID) throws -> [SourceID: URL] {
        [
            primary: try wav(channels: [Self.signal(active: 1_000..<1_010)]),
            backup: try wav(channels: [Self.signal(active: 1_100..<1_110),
                                        [Int16](repeating: 0, count: 480_000)]),
        ]
    }

    func wav(channels: [[Int16]], sampleRate: UInt32 = 48_000) throws -> URL {
        let count = channels[0].count
        precondition(channels.allSatisfy { $0.count == count })
        let bytes = UInt32(count * channels.count * 2)
        var data = Data()
        func word(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); dword(bytes + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); dword(16)
        word(1); word(UInt16(channels.count)); dword(sampleRate)
        dword(sampleRate * UInt32(channels.count) * 2)
        word(UInt16(channels.count * 2)); word(16)
        data.append(contentsOf: "data".utf8); dword(bytes)
        for frame in 0..<count {
            for channel in channels { word(UInt16(bitPattern: channel[frame])) }
        }
        let url = directory.appendingPathComponent("\(UUID()).wav")
        try data.write(to: url)
        return url
    }
}

private extension ExactRational {
    var magnitude: ExactRational { numerator < 0 ? negated() : self }
}

private func q(_ numerator: Int64, _ denominator: Int64 = 1) -> ExactRational {
    try! ExactRational(numerator, denominator)
}

private func seg(_ first: ExactRational, _ last: ExactRational, _ ratio: ExactRational, _ offset: ExactRational) -> AffineClockSegment {
    try! AffineClockSegment(groupClockStart: first, groupClockEnd: last, rateRatio: ratio, alignedOffset: offset)
}

private func mapped(_ epoch: RecordingEpochID, _ segments: [AffineClockSegment]) -> EpochClockMap {
    EpochClockMap(epoch: epoch, mapping: .mapped(segments: segments, provenance: .manual(ManualCorrection(basis: .numericEntry))))
}

private func span(_ first: Int64, _ last: Int64, _ epoch: RecordingEpochID) -> EpochSpan {
    EpochSpan(startFrame: first, endFrame: last, epoch: epoch, groupClockOffset: .zero)
}

private struct Fixture {
    let group = RecorderGroupID()
    let refEpoch = RecordingEpochID()
    let refOccurrence = SourceOccurrenceID()
    let refFrames: Int64 = 480_000

    var reference: TimelineReference {
        TimelineReference(group: group, epoch: refEpoch, occurrence: refOccurrence)
    }

    func occurrence(_ id: SourceOccurrenceID = SourceOccurrenceID(), frames: Int64, rate: Int64 = 48_000) -> SourceOccurrence {
        try! SourceOccurrence(id: id, source: SourceID(), nominalRate: NominalRate(rate), frameCount: frames)
    }

    func otherGroup(epochs: [EpochClockMap], placements: [OccurrencePlacement]) throws -> GroupTimeMap {
        try GroupTimeMap(group: RecorderGroupID(), reference: reference, epochs: epochs, placements: placements)
    }

    func timeline(_ others: [GroupTimeMap]) throws -> AlignedTimelineMap {
        let own = try GroupTimeMap(
            group: group, reference: reference,
            epochs: [EpochClockMap(epoch: refEpoch, mapping: .mapped(
                segments: [seg(q(0), q(10), .one, .zero)], provenance: .timelineReference
            ))],
            placements: [OccurrencePlacement(occurrence: occurrence(refOccurrence, frames: refFrames), spans: [
                span(0, refFrames, refEpoch),
            ])]
        )
        return try AlignedTimelineMap(reference: reference, groups: [own] + others)
    }
}
