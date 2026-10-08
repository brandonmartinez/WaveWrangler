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
