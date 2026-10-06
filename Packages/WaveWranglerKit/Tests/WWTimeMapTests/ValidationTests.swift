import Foundation
import Testing
import WWCore
@testable import WWTimeMap

/// Every constructor refusal is a typed error; nothing invalid is silently repaired.
@Suite("Validation")
struct ValidationTests {
    let fx = Fixture()

    // MARK: Segments

    @Test func segmentParametersAreChecked() {
        #expect(throws: TimeMapError.nonPositiveRateRatio) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: .zero, alignedOffset: .zero) }
        #expect(throws: TimeMapError.nonPositiveRateRatio) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: q(-1), alignedOffset: .zero) }
        #expect(throws: TimeMapError.rateRatioOutsideEnvelope) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: q(3), alignedOffset: .zero) }
        #expect(throws: TimeMapError.rateRatioOutsideEnvelope) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: q(1, 3), alignedOffset: .zero) }
        #expect(throws: TimeMapError.rateRatioOutsideEnvelope) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: q128((Int128(1) << 41) + 1, Int128(1) << 41), alignedOffset: .zero) }
        #expect(throws: TimeMapError.nonPositiveSegmentLength) { try AffineClockSegment(groupClockStart: q(1), groupClockEnd: q(1), rateRatio: .one, alignedOffset: .zero) }
        #expect(throws: TimeMapError.nonPositiveSegmentLength) { try AffineClockSegment(groupClockStart: q(2), groupClockEnd: q(1), rateRatio: .one, alignedOffset: .zero) }
        #expect(throws: TimeMapError.parameterOutsideEnvelope("alignedOffset")) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: .one, alignedOffset: q((1 << 31) + 1)) }
        #expect(throws: TimeMapError.parameterOutsideEnvelope("alignedOffset")) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: .one, alignedOffset: q128(1, (Int128(1) << 40) + 1)) }
        #expect(throws: TimeMapError.parameterOutsideEnvelope("groupClockEnd")) { try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q((1 << 31) + 1), rateRatio: .one, alignedOffset: .zero) }
        // Envelope edges are accepted.
        #expect((try? AffineClockSegment(groupClockStart: q(-(1 << 31)), groupClockEnd: q(1 << 31), rateRatio: q(2), alignedOffset: q(1, 1 << 40))) != nil)
        #expect((try? AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: q(1, 2), alignedOffset: .zero)) != nil)
    }

    private func group(_ segments: [AffineClockSegment]) throws(TimeMapError) -> GroupTimeMap {
        let epoch = RecordingEpochID()
        return try fx.otherGroup(epochs: [mapped(epoch, segments)], placements: [OccurrencePlacement(occurrence: fx.occurrence(frames: 48000), spans: [span(0, 48000, epoch)])])
    }

    @Test func epochSegmentsMustBeOrderedContiguousAndContinuous() throws {
        let epoch = RecordingEpochID()
        #expect(throws: TimeMapError.emptyEpochMap(epoch)) { try fx.otherGroup(epochs: [mapped(epoch, [])], placements: []) }
        let outOfOrder = [seg(q(5), q(10), .one, .zero), seg(q(0), q(5), .one, .zero)]
        #expect(throws: TimeMapError.segmentsOutOfOrder(epoch)) { try fx.otherGroup(epochs: [mapped(epoch, outOfOrder)], placements: []) }
        let overlapping = [seg(q(0), q(5), .one, .zero), seg(q(4), q(10), .one, .zero)]
        #expect(throws: TimeMapError.overlappingSegments(epoch)) { try fx.otherGroup(epochs: [mapped(epoch, overlapping)], placements: []) }
        let holed = [seg(q(0), q(5), .one, .zero), seg(q(6), q(10), .one, .zero)]
        #expect(throws: TimeMapError.segmentsNotContiguous(epoch)) { try fx.otherGroup(epochs: [mapped(epoch, holed)], placements: []) }
        // A jump inside one epoch is a discontinuity: it must be a new epoch, never a bridged segment.
        let jump = [seg(q(0), q(5), .one, .zero), seg(q(5), q(10), .one, q(1, 1000))]
        #expect(throws: TimeMapError.discontinuityWithinEpoch(epoch)) { try fx.otherGroup(epochs: [mapped(epoch, jump)], placements: []) }
        // A continuous rate change is a valid piecewise map: 1*5 = 1.0001*5 + b  =>  b = -1/2000.
        let rateChange = [seg(q(0), q(5), .one, .zero), seg(q(5), q(10), q(10_001, 10_000), q(-1, 2000))]
        #expect((try? fx.otherGroup(epochs: [mapped(epoch, rateChange)], placements: [])) != nil)
    }

    @Test func epochsMustBeUniqueAndNonOverlapping() {
        let a = RecordingEpochID(), b = RecordingEpochID()
        #expect(throws: TimeMapError.duplicateEpoch(a)) { try fx.otherGroup(epochs: [mapped(a, [seg(q(0), q(1), .one, .zero)]), EpochClockMap(epoch: a, mapping: .unsupported(.notAttempted))], placements: []) }
        let overlap = [mapped(a, [seg(q(0), q(2), .one, .zero)]), mapped(b, [seg(q(0), q(1), .one, q(1))])]
        #expect(throws: TimeMapError.overlappingEpochs(a, b)) { try fx.otherGroup(epochs: overlap, placements: []) }
        // Touching images [0, 1) and [1, 2) are fine.
        let touching = [mapped(a, [seg(q(0), q(1), .one, .zero)]), mapped(b, [seg(q(0), q(1), .one, q(1))])]
        #expect((try? fx.otherGroup(epochs: touching, placements: [])) != nil)
    }

    // MARK: Placements

    @Test func placementsAreValidated() {
        let a = RecordingEpochID(), b = RecordingEpochID(), c = RecordingEpochID()
        let epochs = [
            mapped(a, [seg(q(0), q(10), .one, .zero)]),
            mapped(b, [seg(q(0), q(10), .one, q(20))]),
            mapped(c, [seg(q(0), q(10), .one, q(40))]),
        ]
        let occurrence = fx.occurrence(frames: 480_000)
        let id = occurrence.id
        func check(_ expected: TimeMapError, _ spans: [EpochSpan], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(throws: expected, sourceLocation: sourceLocation) {
                try fx.otherGroup(epochs: epochs, placements: [OccurrencePlacement(occurrence: occurrence, spans: spans)])
            }
        }
        check(.emptyPlacement(id), [])
        check(.nonPositiveSpanLength(id), [span(10, 10, a)])
        check(.nonPositiveSpanLength(id), [span(10, 5, a)])
        check(.spanOutsideSource(id), [span(-1, 10, a)])
        check(.spanOutsideSource(id), [span(0, 480_001, a)])
        check(.spansOutOfOrder(id), [span(100, 200, a), span(0, 50, b)])
        check(.overlappingSpans(id), [span(0, 200, a), span(100, 300, b)])
        // A gap (or any span boundary) inside one occurrence restarts the epoch.
        check(.gapMustRestartEpoch(id, a), [span(0, 100, a), span(200, 300, a)])
        check(.gapMustRestartEpoch(id, a), [span(0, 100, a), span(100, 300, a)])
        check(.epochReusedWithinOccurrence(id, a), [span(0, 100, a), span(100, 200, b), span(200, 300, a)])
        let unknown = RecordingEpochID()
        check(.unknownEpoch(unknown), [span(0, 100, unknown)])
        check(.placementNotCoveredByEpochMap(id, a), [span(0, 480_000, a, e: q(1))]) // u reaches 11 s > 10 s
        check(.placementNotCoveredByEpochMap(id, a), [span(0, 100, a, e: q(-1))]) // u starts before 0
        // The last frame's instant must be strictly inside the segment domain [u0, u1).
        check(.placementNotCoveredByEpochMap(id, a), [span(0, 480_000, a, e: q(1, 48000))])
        // Monotonic placement: later spans of an occurrence must land later on the aligned timeline.
        check(.nonMonotonicPlacement(id), [span(0, 100, b), span(200, 300, a)])
        check(.parameterOutsideEnvelope("groupClockOffset"), [span(0, 100, a, e: q128(1, (Int128(1) << 40) + 1))])
        let duplicate = OccurrencePlacement(occurrence: occurrence, spans: [span(0, 100, a)])
        #expect(throws: TimeMapError.duplicateOccurrence(id)) { try fx.otherGroup(epochs: epochs, placements: [duplicate, duplicate]) }
        // Valid: three epochs in increasing aligned order with gaps between them.
        #expect((try? fx.otherGroup(epochs: epochs, placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 100, a), span(200, 300, b), span(400, 500, c)])])) != nil)
    }

    // MARK: Reference identity

    @Test func referenceGroupMustAnchorTheTimeline() {
        let other = RecordingEpochID()
        let otherMap = mapped(other, [seg(q(100), q(110), .one, .zero)])
        // Reference epoch missing or unsupported.
        #expect(throws: TimeMapError.referenceEpochMissing(fx.refEpoch)) {
            try GroupTimeMap(group: fx.group, reference: fx.reference, epochs: [otherMap], placements: [])
        }
        #expect(throws: TimeMapError.referenceEpochMissing(fx.refEpoch)) {
            try GroupTimeMap(group: fx.group, reference: fx.reference, epochs: [EpochClockMap(epoch: fx.refEpoch, mapping: .unsupported(.notAttempted))], placements: [])
        }
        // Reference epoch with a non-identity formula or non-reference provenance.
        for (segments, provenance) in [
            ([seg(q(0), q(10), q(10_001, 10_000), .zero)], MapProvenance.timelineReference),
            ([seg(q(0), q(10), .one, q(1, 48000))], .timelineReference),
            ([seg(q(0), q(10), .one, .zero)], manualProvenance),
        ] {
            #expect(throws: TimeMapError.referenceEpochNotIdentity(fx.refEpoch)) {
                try GroupTimeMap(group: fx.group, reference: fx.reference, epochs: [EpochClockMap(epoch: fx.refEpoch, mapping: .mapped(segments: segments, provenance: provenance))], placements: [fx.referencePlacement])
            }
        }
        // Reference occurrence offset or absent.
        let shifted = OccurrencePlacement(occurrence: fx.occurrence(fx.refOccurrence, frames: fx.refFrames), spans: [span(0, 100, fx.refEpoch, e: q(1))])
        #expect(throws: TimeMapError.referenceOccurrenceNotAnchored(fx.refOccurrence)) {
            try GroupTimeMap(group: fx.group, reference: fx.reference, epochs: [fx.referenceEpochMap], placements: [shifted])
        }
        #expect(throws: TimeMapError.referenceOccurrenceNotAnchored(fx.refOccurrence)) {
            try GroupTimeMap(group: fx.group, reference: fx.reference, epochs: [fx.referenceEpochMap], placements: [])
        }
        // `.timelineReference` provenance anywhere else is refused (in the reference group or another).
        let misplaced = EpochClockMap(epoch: other, mapping: .mapped(segments: [seg(q(100), q(110), .one, .zero)], provenance: .timelineReference))
        #expect(throws: TimeMapError.misplacedTimelineReference(other)) { try fx.referenceGroup(extraEpochs: [misplaced]) }
        #expect(throws: TimeMapError.misplacedTimelineReference(other)) { try fx.otherGroup(epochs: [misplaced], placements: []) }
        #expect((try? fx.referenceGroup(extraEpochs: [otherMap])) != nil)
    }

    @Test func alignedTimelineOwnershipIsExclusive() throws {
        let reference = try fx.referenceGroup()
        let epoch = RecordingEpochID(), occurrence = fx.occurrence(frames: 48000)
        let otherID = RecorderGroupID()
        let other = try fx.otherGroup(otherID, epochs: [mapped(epoch, [seg(q(0), q(1), .one, .zero)])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, epoch)])])
        #expect((try? AlignedTimelineMap(reference: fx.reference, groups: [reference, other])) != nil)
        #expect(throws: TimeMapError.missingReferenceGroup(fx.group)) { try AlignedTimelineMap(reference: fx.reference, groups: [other]) }
        #expect(throws: TimeMapError.duplicateGroup(otherID)) { try AlignedTimelineMap(reference: fx.reference, groups: [reference, other, other]) }
        let sameEpoch = try fx.otherGroup(epochs: [mapped(epoch, [seg(q(0), q(1), .one, .zero)])], placements: [])
        #expect(throws: TimeMapError.epochInMultipleGroups(epoch)) { try AlignedTimelineMap(reference: fx.reference, groups: [reference, other, sameEpoch]) }
        let epoch2 = RecordingEpochID()
        let sameOccurrence = try fx.otherGroup(epochs: [mapped(epoch2, [seg(q(0), q(1), .one, .zero)])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, epoch2)])])
        #expect(throws: TimeMapError.occurrenceInMultipleGroups(occurrence.id)) { try AlignedTimelineMap(reference: fx.reference, groups: [reference, other, sameOccurrence]) }
        let foreignReference = TimelineReference(group: fx.group, epoch: RecordingEpochID(), occurrence: fx.refOccurrence)
        let foreign = try GroupTimeMap(group: RecorderGroupID(), reference: foreignReference, epochs: [], placements: [])
        #expect(throws: TimeMapError.referenceMismatch(foreign.group)) { try AlignedTimelineMap(reference: fx.reference, groups: [reference, foreign]) }
        let map = try AlignedTimelineMap(reference: fx.reference, groups: [reference, other])
        let stranger = SourceOccurrenceID()
        #expect(throws: TimeMapError.unknownOccurrence(stranger)) { try map.alignedTime(ofFrame: 0, in: stranger) }
        #expect(throws: TimeMapError.unknownOccurrence(stranger)) { try map.sourceFrame(at: .zero, in: stranger) }
    }

    // MARK: Exact-arithmetic envelope

    /// Pathological coprime denominators are refused at construction rather than trapping at query time.
    @Test func pathologicalDenominatorsAreRefusedNotTrapped() throws {
        let p40 = Int128(1) << 40
        let epoch = RecordingEpochID(), occurrence = fx.occurrence(frames: 48000)
        let segment = try AffineClockSegment(groupClockStart: q(-1), groupClockEnd: q(2), rateRatio: q128(p40, p40 - 1), alignedOffset: q128(1, p40 - 3))
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) {
            try fx.otherGroup(epochs: [mapped(epoch, [segment])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, epoch, e: q128(1, p40 - 2))])])
        }
        // A query whose exact inverse cannot be represented throws instead of trapping or rounding.
        let simple = try fx.otherGroup(epochs: [mapped(epoch, [seg(q(0), q(1), q(10_001, 10_000), q(1, 7))])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, epoch)])])
        let hostile = q128(Int128(1) << 100 + 1, (Int128(1) << 126) - 1)
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try simple.sourceFrame(at: try q(1, 7).adding(hostile), in: occurrence.id) }
    }

    /// Only an interior segment's frames overflow: the span's first and last frames (the hull) are in
    /// benign segments, so the per-piece endpoint proof is the only guard. Parameters were chosen
    /// (coprime prime denominators, aligned time near 2^127 / d) so the middle piece's
    /// `p*n + c` crosses Int128 between its first and last frame.
    @Test func interiorPieceOverflowIsRefusedAtConstruction() throws {
        let rate: Int64 = 1 << 20
        let bigE: Int128 = 1_099_511_627_689, bigU: Int128 = 1_076_896_741, bigA: Int128 = 1021
        let e = q128(295_147_357_600_819_710_678, bigE)
        let ub = q128(289_076_732_519_146_835, bigU)
        let uc = try ub.adding(q128(bigA, 1))
        let a2 = q128(bigA + 1, bigA)
        let b2 = try ExactRational.zero.subtracting(ub.divided(by: q128(bigA, 1)))
        let segments = [
            seg(e, ub, .one, .zero),
            seg(ub, uc, a2, b2),
            seg(uc, try uc.adding(q(2)), .one, .one),
        ]
        let frames: Int64 = 1_072_693_249
        let epoch = RecordingEpochID()
        let occurrence = try SourceOccurrence(id: SourceOccurrenceID(), source: SourceID(), nominalRate: NominalRate(rate), frameCount: frames)
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) {
            try fx.otherGroup(epochs: [mapped(epoch, segments)], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, frames, epoch, e: e)])])
        }
        // The same epoch is fine for a span that stays in the benign first segment.
        #expect((try? fx.otherGroup(epochs: [mapped(epoch, segments)], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, Int64(rate), epoch, e: e)])])) != nil)
    }

    /// Each term of the construction-time grid-inverse bound is necessary. These witness maps pass the
    /// other terms, and without the named term they would be constructible while inverting the named grid
    /// instant inside their hull overflows `Int128`. (Shown directly on the compiled piece below.)
    @Test func everyGridInverseBoundTermIsNecessary() throws {
        // |c|*G binds: hull within [0, 2) (H = 1) but the intercept a*e + b is about -2^30 s.
        do {
            let rate: Int64 = 1021, first: Int64 = 1_096_290_401_739, frames: Int64 = 1_096_290_402_760
            let a = q128(949_592_058_470, 949_592_057_873), b = q128(-168_333_397_947_921_325_304, 156_772_693_553)
            let occurrence = fx.occurrence(frames: frames, rate: rate), epoch = RecordingEpochID()
            #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) {
                try fx.otherGroup(epochs: [mapped(epoch, [seg(q(1_073_741_823), q(1_073_741_825), a, b)])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(first, frames, epoch)])])
            }
            let piece = try compiledPiece(a: a, b: b, e: .zero, rate: rate)
            let t = q(52, 48000)
            #expect(try piece.forward(Int128(first)) <= t && t <= piece.forward(Int128(frames - 1)))
            #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try piece.inverse(t) }
        }
        // p*G binds: F = 1 and frame 0 alone in a steep first segment (a ~ 2), so p ~ 2d exceeds d*H + |c|.
        do {
            let a1 = q128(859_439_030_096, 429_719_600_419), b1 = q128(-503_701_576, 264_781_151)
            let a2 = q128(1_289_158_459_773, 859_439_200_838), b2 = q128(-742_622_001, 529_562_302)
            let e = q128(370_326_455_231, 738_929_802_837)
            let occurrence = fx.occurrence(frames: 2, rate: 1), epoch = RecordingEpochID()
            #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) {
                try fx.otherGroup(epochs: [mapped(epoch, [seg(q(0), q(1), a1, b1), seg(q(1), q(3), a2, b2)])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 2, epoch, e: e)])])
            }
            let piece = try compiledPiece(a: a1, b: b1, e: e, rate: 1)
            let t = q(-943_717, 1 << 20)
            #expect(try piece.forward(0) <= t && t < a1.adding(b1))
            #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) { try piece.inverse(t) }
        }
    }

    /// The compiled `t = (p*n + c)/d` form of one segment, built exactly as construction does.
    private func compiledPiece(a: ExactRational, b: ExactRational, e: ExactRational, rate: Int64) throws -> CompiledPiece {
        let slope = try a.divided(by: q(rate)), intercept = try a.multiplied(by: e).adding(b)
        let g = Int128(ExactRational.gcd(slope.denominator.magnitude, intercept.denominator.magnitude))
        let d = try ExactRational.mul(slope.denominator / g, intercept.denominator)
        return CompiledPiece(
            frameLo: 0, frameHi: 0, imageLo: .zero, imageHi: .zero,
            p: try ExactRational.mul(slope.numerator, d / slope.denominator),
            c: try ExactRational.mul(intercept.numerator, d / intercept.denominator), d: d
        )
    }

    /// Review finding (PR #173): with hull-only checks this map was constructible, yet inverting the
    /// 48 kHz grid instant 5686619777/48000 inside its hull overflowed Int128. Construction now proves
    /// every instant with denominator <= 2^20 inside the hull inverts, so the map is refused instead.
    @Test func mapWhoseGridInverseCouldOverflowIsRefusedAtConstruction() throws {
        let frames: Int64 = 1 << 20
        let a = q128(1_000_996_938, 999_999_937)
        let e = q128(920_910_480_571, 1_099_511_627_689)
        let b = q128(124_199_676_144, 1_048_571)
        let occurrence = fx.occurrence(frames: frames, rate: 44100)
        let epoch = RecordingEpochID()
        let segments = [seg(q128(e.floor(), 1), q128(try e.adding(q(frames, 44100)).ceil(), 1), a, b)]
        let placement = OccurrencePlacement(occurrence: occurrence, spans: [span(0, frames, epoch, e: e)])
        #expect(throws: TimeMapError.exactArithmeticEnvelopeExceeded) {
            try fx.otherGroup(epochs: [mapped(epoch, segments)], placements: [placement])
        }
        // The probe instant really is inside the would-be hull (so refusal, not a coverage result, is right).
        let t = q128(5_686_619_777, 48000)
        let lo = try a.multiplied(by: e).adding(b)
        let hi = try a.multiplied(by: q(frames - 1, 44100).adding(e)).adding(b)
        #expect(lo <= t && t <= hi)
    }
}
