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
        origin: Int64 = 0,
        frames: Int64 = 480_000,
        rate: Int64 = 48_000,
        removals: [RemovedFrameSpan] = [],
        alignmentRevision: UInt64 = 2,
        editRevision: UInt64 = 3
    ) throws -> CommonEpisodeEditMap {
        try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: alignmentRevision, editRevision: editRevision,
            outputRate: NominalRate(rate), alignedFrameOrigin: origin, alignedFrameCount: frames,
            removals: removals
        )
    }

    @Test func negativeLeadingSourceFrameZeroRoundTripsWithoutRemovals() throws {
        let epoch = RecordingEpochID()
        let early = fx.occurrence(frames: 480_000)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(0), q(10), .one, q(-1, 10))])],
            placements: [OccurrencePlacement(occurrence: early, spans: [span(0, 480_000, epoch)])]
        )
        let map = try make(fx.timeline([group]), origin: -4_800, frames: 484_800)
        if case .mapped(let position, let aligned) = try map.outputFrame(ofSourceFrame: 0, in: early.id) {
            #expect(position == CommonOutputPosition(exactFrame: .zero, nearestFrame: 0))
            #expect(aligned.instant == q(-1, 10))
            #expect(aligned.epoch == epoch)
        } else { Issue.record("the leading source frame must map to output frame zero") }
        if case .source(let source) = try map.sourceFrame(atOutputFrame: 0, in: early.id) {
            #expect(source.frame == 0)
            #expect(source.occurrence == early.id)
        } else { Issue.record("the leading source frame must invert at output frame zero") }
    }

    @Test func negativeLeadingPlacementSurvivesWithoutRemovalsAndOccurrencesStayDistinct() throws {
        let source = SourceID()
        let rate = try NominalRate(48_000)
        let negativeEpoch = RecordingEpochID(), positiveEpoch = RecordingEpochID()
        let earlyA = try SourceOccurrence(source: source, nominalRate: rate, frameCount: 480_000)
        let earlyB = try SourceOccurrence(source: source, nominalRate: rate, frameCount: 480_000)
        let late = try SourceOccurrence(source: source, nominalRate: rate, frameCount: 480_000)
        let earlyGroup = try fx.otherGroup(
            epochs: [mapped(negativeEpoch, [seg(q(0), q(10), .one, q(-1, 10))])],
            placements: [earlyA, earlyB].map {
                OccurrencePlacement(occurrence: $0, spans: [span(0, 480_000, negativeEpoch)])
            }
        )
        let lateGroup = try fx.otherGroup(
            epochs: [mapped(positiveEpoch, [seg(q(0), q(10), .one, q(1, 20))])],
            placements: [OccurrencePlacement(occurrence: late, spans: [span(0, 480_000, positiveEpoch)])]
        )
        let map = try make(fx.timeline([earlyGroup, lateGroup]), origin: -4_800, frames: 487_200)
        #expect(map.alignedFrameOrigin == -4_800)
        #expect(map.alignedFrameEnd == 482_400)
        #expect(map.outputFrameCount == 487_200)
        #expect(map.keptSpans == [KeptFrameSpan(alignedStart: -4_800, alignedEnd: 482_400, outputStart: 0)])
        #expect(map.alignedInstant(atOutputFrame: 0) == q(-1, 10))
        #expect(map.alignedInstant(atOutputFrame: 4_800) == .zero)
        #expect(map.outputDuration == q(203, 20))
        for sourceFrame: Int64 in 0..<4_800 {
            for occurrence in [earlyA.id, earlyB.id] {
                guard case .mapped(let position, let aligned) = try map.outputFrame(ofSourceFrame: sourceFrame, in: occurrence),
                      case .source(let inverse) = try map.sourceFrame(atOutputFrame: sourceFrame, in: occurrence)
                else {
                    Issue.record("negative-leading source frame \(sourceFrame) lost its occurrence")
                    continue
                }
                #expect(position.exactFrame == ExactRational(sourceFrame))
                #expect(position.nearestFrame == sourceFrame)
                #expect(aligned.instant == rate.instant(ofFrame: sourceFrame - 4_800))
                #expect(inverse.occurrence == occurrence)
                #expect(inverse.frame == sourceFrame)
            }
        }
        #expect(try map.sourceFrame(atOutputFrame: 0, in: fx.refOccurrence) == .outsideCoverage)
        #expect(try map.sourceFrame(atOutputFrame: 0, in: late.id) == .outsideCoverage)
        if case .mapped(let position, _) = try map.outputFrame(ofSourceFrame: 0, in: late.id) {
            #expect(position.exactFrame == q(7_200))
        } else { Issue.record("positive-offset occurrence lost its placement") }
        if case .mapped(let position, _) = try map.outputFrame(ofSourceFrame: 479_999, in: late.id) {
            #expect(position.nearestFrame == 487_199)
            if case .source(let inverse) = try map.sourceFrame(atOutputFrame: 487_199, in: late.id) {
                #expect(inverse.frame == 479_999)
            } else { Issue.record("late trailing frame lost its inverse") }
        } else { Issue.record("late trailing frame was clipped by the episode domain") }
        if case .mapped(let position, let aligned) = try map.outputFrame(ofSourceFrame: 0, in: fx.refOccurrence) {
            #expect(position.exactFrame == q(4_800))
            #expect(position.nearestFrame == 4_800)
            #expect(aligned.instant == .zero)
            #expect(aligned.epoch == fx.refEpoch)
        } else { Issue.record("reference origin did not move on the output grid") }
    }

    @Test func signedDisjointRemovalsKeepAbsoluteAlignedCoordinates() throws {
        let epoch = RecordingEpochID()
        let early = fx.occurrence(frames: 480_000)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(0), q(10), .one, q(-1, 10))])],
            placements: [OccurrencePlacement(occurrence: early, spans: [span(0, 480_000, epoch)])]
        )
        let cuts = [RemovedFrameSpan(start: -2_400, end: -1_200), RemovedFrameSpan(start: 4_800, end: 9_600)]
        let map = try make(fx.timeline([group]), origin: -4_800, frames: 484_800, removals: cuts)
        #expect(map.keptSpans == [
            KeptFrameSpan(alignedStart: -4_800, alignedEnd: -2_400, outputStart: 0),
            KeptFrameSpan(alignedStart: -1_200, alignedEnd: 4_800, outputStart: 2_400),
            KeptFrameSpan(alignedStart: 9_600, alignedEnd: 480_000, outputStart: 8_400),
        ])
        #expect(map.outputFrameCount == 478_800)
        #expect(map.alignedInstant(atOutputFrame: 2_400) == q(-1_200, 48_000))
        #expect(map.alignedInstant(atOutputFrame: 8_400) == q(9_600, 48_000))
        #expect(try map.outputPosition(atAlignedInstant: q(-2_400, 48_000)) == .removed(cuts[0]))
        #expect(try map.outputPosition(atAlignedInstant: q(4_800, 48_000)) == .removed(cuts[1]))
        if case .removed(let aligned, let span) = try map.outputFrame(ofSourceFrame: 2_400, in: early.id) {
            #expect(aligned.instant == q(-2_400, 48_000))
            #expect(aligned.epoch == epoch)
            #expect(span == cuts[0])
        } else { Issue.record("negative removal gained an inverse") }
        if case .removed(let aligned, let span) = try map.outputFrame(ofSourceFrame: 9_600, in: early.id) {
            #expect(aligned.instant == q(4_800, 48_000))
            #expect(aligned.epoch == epoch)
            #expect(span == cuts[1])
        } else { Issue.record("positive removal gained an inverse") }
        for output in [Int64(0), 2_399, 2_400, 8_399, 8_400, map.outputFrameCount - 1] {
            let instant = try #require(map.alignedInstant(atOutputFrame: output))
            #expect(try map.outputPosition(atAlignedInstant: instant) == .mapped(
                CommonOutputPosition(exactFrame: ExactRational(output), nearestFrame: output)
            ))
        }
    }

    @Test func signedGridLimitsAndOffGridPositionsAreExplicit() throws {
        let alignment = try fx.timeline([])
        let rate = try NominalRate(48_000)
        let map = try make(alignment, origin: -4_800, frames: 484_800)
        #expect(try map.outputPosition(atAlignedInstant: q(-9_601, 96_000)) == .outsideCoverage)
        #expect(try map.outputPosition(atAlignedInstant: q(10)) == .outsideCoverage)
        #expect(try map.outputPosition(atAlignedInstant: q(-9_599, 96_000)) == .mapped(
            CommonOutputPosition(exactFrame: q(1, 2), nearestFrame: 1)
        ))
        #expect(try map.outputPosition(atAlignedInstant: q(959_999, 96_000)) == .mapped(
            CommonOutputPosition(exactFrame: q(969_599, 2), nearestFrame: 484_800)
        ))
        #expect(map.alignedInstant(atOutputFrame: -1) == nil)
        #expect(map.alignedInstant(atOutputFrame: map.outputFrameCount) == nil)
        #expect(throws: CommonEpisodeEditMapError.invalidRemoval(RemovedFrameSpan(start: -4_801, end: -4_800))) {
            try make(alignment, origin: -4_800, frames: 484_800, removals: [RemovedFrameSpan(start: -4_801, end: -4_800)])
        }
        #expect(throws: CommonEpisodeEditMapError.invalidRemoval(RemovedFrameSpan(start: 480_000, end: 480_001))) {
            try make(alignment, origin: -4_800, frames: 484_800, removals: [RemovedFrameSpan(start: 480_000, end: 480_001)])
        }
        #expect(throws: CommonEpisodeEditMapError.alignedFrameEndOverflow(origin: .max, count: 1)) {
            try make(alignment, origin: .max, frames: 1)
        }
        #expect(throws: CommonEpisodeEditMapError.invalidTimelineLength(-1)) {
            try make(alignment, origin: -4_800, frames: -1)
        }
        let tooLong = TimeMapEnvelope.maxFrameCount + 1
        #expect(throws: CommonEpisodeEditMapError.invalidTimelineLength(tooLong)) {
            try make(alignment, origin: -4_800, frames: tooLong)
        }
        let extreme = try make(alignment, origin: .min, frames: 2)
        #expect(extreme.alignedFrameEnd == Int64.min + 2)
        #expect(extreme.alignedInstant(atOutputFrame: 0) == rate.instant(ofFrame: .min))
        #expect(try extreme.outputPosition(atAlignedInstant: rate.instant(ofFrame: .min)) == .mapped(
            CommonOutputPosition(exactFrame: .zero, nearestFrame: 0)
        ))
    }

    @Test func negativeOriginDoesNotBridgeGapsOrUnsupportedRegions() throws {
        let first = RecordingEpochID(), last = RecordingEpochID(), unknown = RecordingEpochID()
        let gapped = fx.occurrence(frames: 144_000)
        let uncertain = fx.occurrence(frames: 144_000)
        let firstMap = mapped(first, [seg(q(0), q(1), .one, q(-1, 10))])
        let lastMap = mapped(last, [seg(q(2), q(3), .one, q(-1, 10))])
        let gapGroup = try fx.otherGroup(
            epochs: [firstMap, lastMap],
            placements: [OccurrencePlacement(occurrence: gapped, spans: [
                span(0, 48_000, first), span(96_000, 144_000, last),
            ])]
        )
        let unsupportedGroup = try fx.otherGroup(
            epochs: [firstMap, EpochClockMap(epoch: unknown, mapping: .unsupported(.estimatorAbstained)), lastMap],
            placements: [OccurrencePlacement(occurrence: uncertain, spans: [
                span(0, 48_000, first), span(48_000, 96_000, unknown), span(96_000, 144_000, last),
            ])]
        )
        let gapMap = try make(fx.timeline([gapGroup]), origin: -4_800, frames: 148_800)
        let unsupportedMap = try make(fx.timeline([unsupportedGroup]), origin: -4_800, frames: 148_800)
        if case .source(let position) = try gapMap.sourceFrame(atOutputFrame: 0, in: gapped.id) {
            #expect(position.frame == 0)
        } else { Issue.record("negative leading frame should invert") }
        if case .gap(let boundary) = try gapMap.sourceFrame(atOutputFrame: 60_000, in: gapped.id) {
            #expect(boundary.precedingEpoch == first)
            #expect(boundary.followingEpoch == last)
            #expect(try gapMap.outputFrame(ofSourceFrame: 60_000, in: gapped.id) == .gap(boundary))
        } else { Issue.record("signed domain bridged a known gap") }
        #expect(try unsupportedMap.sourceFrame(atOutputFrame: 60_000, in: uncertain.id).regionState == .unsupported(.estimatorAbstained))
        #expect(try unsupportedMap.outputFrame(ofSourceFrame: 60_000, in: uncertain.id) == .unsupported(
            epoch: unknown, reason: .estimatorAbstained
        ))
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
        for origin: Int64 in [-5, 0, 7] {
            for count: Int64 in 0...16 {
                for start: Int64 in 0...count {
                    for end: Int64 in start...count {
                        let removals = start < end ? [RemovedFrameSpan(start: origin + start, end: origin + end)] : []
                        let map = try make(alignment, origin: origin, frames: count, removals: removals)
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
