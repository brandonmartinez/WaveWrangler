import Foundation
import Testing
import WWCore
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
