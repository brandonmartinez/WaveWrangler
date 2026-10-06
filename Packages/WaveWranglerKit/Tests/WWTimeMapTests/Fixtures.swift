import Foundation
import WWCore
@testable import WWTimeMap

/// Small hand-built maps for convention, validation and gap tests (48 kHz unless stated).
struct Fixture {
    let group = RecorderGroupID()
    let refEpoch = RecordingEpochID()
    let refOccurrence = SourceOccurrenceID()
    let rate = try! NominalRate(48000)
    /// Reference occurrence length (10 s).
    let refFrames: Int64 = 480_000

    var reference: TimelineReference { TimelineReference(group: group, epoch: refEpoch, occurrence: refOccurrence) }

    func occurrence(_ id: SourceOccurrenceID = SourceOccurrenceID(), frames: Int64, rate: Int64 = 48000) -> SourceOccurrence {
        try! SourceOccurrence(id: id, source: SourceID(), nominalRate: NominalRate(rate), frameCount: frames)
    }

    var referenceEpochMap: EpochClockMap {
        EpochClockMap(epoch: refEpoch, mapping: .mapped(segments: [seg(q(0), q(refFrames, 48000), .one, .zero)], provenance: .timelineReference))
    }

    var referencePlacement: OccurrencePlacement {
        OccurrencePlacement(occurrence: occurrence(refOccurrence, frames: refFrames), spans: [EpochSpan(startFrame: 0, endFrame: refFrames, epoch: refEpoch, groupClockOffset: .zero)])
    }

    func referenceGroup(extraEpochs: [EpochClockMap] = [], extraPlacements: [OccurrencePlacement] = []) throws(TimeMapError) -> GroupTimeMap {
        try GroupTimeMap(group: group, reference: reference, epochs: [referenceEpochMap] + extraEpochs, placements: [referencePlacement] + extraPlacements)
    }

    /// A non-reference group with the given epochs and placements.
    func otherGroup(_ id: RecorderGroupID = RecorderGroupID(), epochs: [EpochClockMap], placements: [OccurrencePlacement]) throws(TimeMapError) -> GroupTimeMap {
        try GroupTimeMap(group: id, reference: reference, epochs: epochs, placements: placements)
    }

    func timeline(_ others: [GroupTimeMap]) throws(TimeMapError) -> AlignedTimelineMap {
        try AlignedTimelineMap(reference: reference, groups: [try referenceGroup()] + others)
    }
}

func seg(_ u0: ExactRational, _ u1: ExactRational, _ a: ExactRational, _ b: ExactRational) -> AffineClockSegment {
    try! AffineClockSegment(groupClockStart: u0, groupClockEnd: u1, rateRatio: a, alignedOffset: b)
}

let manualProvenance = MapProvenance.manual(ManualCorrection(basis: .numericEntry))

func mapped(_ epoch: RecordingEpochID, _ segments: [AffineClockSegment], _ provenance: MapProvenance = manualProvenance) -> EpochClockMap {
    EpochClockMap(epoch: epoch, mapping: .mapped(segments: segments, provenance: provenance))
}

func span(_ start: Int64, _ end: Int64, _ epoch: RecordingEpochID, e: ExactRational = .zero) -> EpochSpan {
    EpochSpan(startFrame: start, endFrame: end, epoch: epoch, groupClockOffset: e)
}

func passingMeasurements() -> ClockGateMeasurements {
    try! ClockGateMeasurements(windowCount: 5, overlapSpanFraction: 0.8, eligibleWindowFraction: 0.6, residualP95Milliseconds: 5, residualMaxMilliseconds: 10)
}
