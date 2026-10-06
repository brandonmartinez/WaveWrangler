import Foundation
import Testing
import WWCore
@testable import WWTimeMap

/// Pins the documented sign and unit conventions with hand-computed values.
@Suite("Conventions")
struct ConventionTests {
    private func aligned(_ result: ForwardMapping) -> ExactRational? {
        if case .aligned(let p) = result { return p.instant }
        return nil
    }

    private func source(_ result: InverseMapping) -> SourcePosition? {
        if case .source(let p) = result { return p }
        return nil
    }

    /// Positive lag = event LATER in the target; aligning offset b = -lag/F brings it onto the reference.
    @Test func positiveLagMeansTargetIsLater() throws {
        let fx = Fixture()
        let lag = CorrelationLag(frames: 4800, rate: fx.rate)
        #expect(lag.aligningOffset == q(-1, 10))
        let epoch = RecordingEpochID(), target = fx.occurrence(frames: 480_000)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(0), q(10), .one, lag.aligningOffset)])],
            placements: [OccurrencePlacement(occurrence: target, spans: [span(0, 480_000, epoch)])]
        )
        let map = try fx.timeline([group])
        // Reference event at frame 48,000 (1 s) appears in the target at 48,000 + 4,800.
        let referenceInstant = try #require(aligned(try map.alignedTime(ofFrame: 48_000, in: fx.refOccurrence)))
        #expect(referenceInstant == q(1))
        #expect(aligned(try map.alignedTime(ofFrame: 52_800, in: target.id)) == referenceInstant)
        #expect(source(try map.sourceFrame(at: q(1), in: target.id))?.frame == 52_800)
        // A negative lag moves the other way.
        #expect(CorrelationLag(frames: -4800, rate: fx.rate).aligningOffset == q(1, 10))
    }

    /// ppm = 1e6 (a - 1); positive ppm = group clock slow; content lands LATER than n/F.
    @Test func positivePPMMeansSlowClockAndLaterContent() throws {
        let a = try AffineClockSegment.rateRatio(ppm: q(100))
        #expect(a == q(10_001, 10_000))
        #expect(try AffineClockSegment.rateRatio(ppm: q(-100)) == q(9_999, 10_000))
        let fx = Fixture()
        let epoch = RecordingEpochID(), target = fx.occurrence(frames: 2000 * 48000)
        let segment = seg(q(0), q(2000), a, .zero)
        #expect(segment.ppm == q(100))
        #expect(segment.clockPitchFactor == q(10_000, 10_001))
        #expect(try segment.outputFramesPerInputFrame(input: fx.rate, output: fx.rate) == a)
        #expect(try segment.outputFramesPerInputFrame(input: try NominalRate(44100), output: fx.rate) == q(10_001 * 480, 10_000 * 441))
        let group = try fx.otherGroup(epochs: [mapped(epoch, [segment])], placements: [OccurrencePlacement(occurrence: target, spans: [span(0, 2000 * 48000, epoch)])])
        // 1000 nominal seconds of content land at 1000.1 aligned seconds.
        #expect(aligned(try group.alignedTime(ofFrame: 1000 * 48000, in: target.id)) == q(10_001, 10))
        let negative = try AffineClockSegment(groupClockStart: q(0), groupClockEnd: q(1), rateRatio: q(9_999, 10_000), alignedOffset: .zero)
        #expect(negative.ppm == q(-100))
    }

    /// e and b are seconds, independent of the occurrence's nominal rate.
    @Test func offsetsAreSeconds() throws {
        let fx = Fixture()
        let epoch = RecordingEpochID()
        let a = fx.occurrence(frames: 44100, rate: 44100), b = fx.occurrence(frames: 96000, rate: 96000)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(3), q(5), .one, q(2))])],
            placements: [
                OccurrencePlacement(occurrence: a, spans: [span(0, 44100, epoch, e: q(3))]),
                OccurrencePlacement(occurrence: b, spans: [span(0, 96000, epoch, e: q(4))]),
            ]
        )
        // t = a*(n/F + e) + b: frame 0 at e=3 s, b=2 s -> 5 s regardless of F.
        #expect(aligned(try group.alignedTime(ofFrame: 0, in: a.id)) == q(5))
        #expect(aligned(try group.alignedTime(ofFrame: 22050, in: a.id)) == q(11, 2))
        #expect(aligned(try group.alignedTime(ofFrame: 0, in: b.id)) == q(6))
        #expect(aligned(try group.alignedTime(ofFrame: 48000, in: b.id)) == q(13, 2))
    }

    /// The exact inverse at k + 1/2 quantises half-up to k + 1, and reports the exact value.
    @Test func inverseQuantisesHalfUp() throws {
        let fx = Fixture()
        let epoch = RecordingEpochID(), target = fx.occurrence(frames: 48000)
        let group = try fx.otherGroup(
            epochs: [mapped(epoch, [seg(q(0), q(1), .one, q(1, 96000))])],
            placements: [OccurrencePlacement(occurrence: target, spans: [span(0, 48000, epoch)])]
        )
        let position = try #require(source(try group.sourceFrame(at: q(100, 48000), in: target.id)))
        #expect(position.exactFrame == q(199, 2))
        #expect(position.frame == 100)
        #expect(position.epoch == epoch)
        #expect(position.provenance == .manual)
    }

    @Test func identityAndEnvelopeTypesRefuseInvalidValues() {
        #expect(throws: TimeMapError.invalidNominalRate(0)) { try NominalRate(0) }
        #expect(throws: TimeMapError.invalidNominalRate(-48000)) { try NominalRate(-48000) }
        #expect(throws: TimeMapError.invalidNominalRate((1 << 20) + 1)) { try NominalRate((1 << 20) + 1) }
        let rate = try! NominalRate(48000)
        #expect(throws: TimeMapError.invalidFrameCount(0)) { try SourceOccurrence(source: SourceID(), nominalRate: rate, frameCount: 0) }
        #expect(throws: TimeMapError.invalidFrameCount((1 << 40) + 1)) { try SourceOccurrence(source: SourceID(), nominalRate: rate, frameCount: (1 << 40) + 1) }
        #expect(rate.instant(ofFrame: 72000) == q(3, 2))
    }

    /// Two occurrences of the same source are distinct occurrences with independent placements.
    @Test func repeatedSourceKeepsDistinctOccurrences() throws {
        let fx = Fixture()
        let source = SourceID(), epochA = RecordingEpochID(), epochB = RecordingEpochID()
        let first = try SourceOccurrence(source: source, nominalRate: fx.rate, frameCount: 48000)
        let second = try SourceOccurrence(source: source, nominalRate: fx.rate, frameCount: 48000)
        #expect(first.id != second.id)
        let group = try fx.otherGroup(
            epochs: [mapped(epochA, [seg(q(0), q(1), .one, .zero)]), mapped(epochB, [seg(q(0), q(1), .one, q(5))])],
            placements: [
                OccurrencePlacement(occurrence: first, spans: [span(0, 48000, epochA)]),
                OccurrencePlacement(occurrence: second, spans: [span(0, 48000, epochB)]),
            ]
        )
        #expect(aligned(try group.alignedTime(ofFrame: 0, in: first.id)) == q(0))
        #expect(aligned(try group.alignedTime(ofFrame: 0, in: second.id)) == q(5))
    }
}
