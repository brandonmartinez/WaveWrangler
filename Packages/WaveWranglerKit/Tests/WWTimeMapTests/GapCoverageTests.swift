import Foundation
import Testing
import WWCore
@testable import WWTimeMap

/// Known gaps and uncovered instants are reported, never inverted, bridged or extrapolated.
@Suite("Gaps and coverage")
struct GapCoverageTests {
    let fx = Fixture()

    /// Two epochs whose affine formulas are the SAME line (t = n/F) separated by a one-second dropout:
    /// a smooth bridge would be numerically trivial, so its absence is meaningful.
    private func dropoutMap() throws -> (GroupTimeMap, SourceOccurrence, RecordingEpochID, RecordingEpochID) {
        let before = RecordingEpochID(), after = RecordingEpochID()
        let occurrence = fx.occurrence(frames: 192_000)
        let group = try fx.otherGroup(
            epochs: [mapped(before, [seg(q(0), q(1), .one, .zero)]), mapped(after, [seg(q(2), q(4), .one, .zero)])],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, before), span(96000, 144_000, after)])]
        )
        return (group, occurrence, before, after)
    }

    @Test func noSilentBridgingAcrossADeclaredDiscontinuity() throws {
        let (group, occurrence, before, after) = try dropoutMap()
        let boundary = GapBoundary(occurrence: occurrence.id, precedingEpoch: before, precedingLastFrame: 47999, followingEpoch: after, followingFirstFrame: 96000)
        // Inverse inside the dropout: gap, even though extending either formula would "work".
        for t in [q(1), q(3, 2), q(95999, 48000), q(47999, 48000) + q(1, 96000)] {
            #expect(try group.sourceFrame(at: t, in: occurrence.id) == .gap(boundary))
        }
        // Forward from frames inside the dropout: gap, not a bridged instant.
        for frame: Int64 in [48000, 72000, 95999] {
            #expect(try group.alignedTime(ofFrame: frame, in: occurrence.id) == .gap(boundary))
        }
        // Both sides of the gap still invert exactly, and the following side reports its own epoch.
        if case .source(let p) = try group.sourceFrame(at: q(47999, 48000), in: occurrence.id) {
            #expect(p.frame == 47999 && p.epoch == before)
        } else { Issue.record("last covered frame did not invert") }
        if case .source(let p) = try group.sourceFrame(at: q(2), in: occurrence.id) {
            #expect(p.frame == 96000 && p.epoch == after)
        } else { Issue.record("first frame after the gap did not invert") }
        #expect(try group.sourceFrame(at: q(1), in: occurrence.id).regionState == .gap)
    }

    @Test func outsideCoverageIsNeverExtrapolated() throws {
        let (group, occurrence, _, _) = try dropoutMap()
        let id = occurrence.id
        #expect(try group.sourceFrame(at: q(-1, 48000), in: id) == .outsideCoverage)
        #expect(try group.sourceFrame(at: q(-1000), in: id) == .outsideCoverage)
        // After the last placed frame (143,999 at 2.999979 s) — still inside the epoch's segment domain
        // [2, 4) but not covered by this occurrence.
        #expect(try group.sourceFrame(at: q(3), in: id) == .outsideCoverage)
        #expect(try group.sourceFrame(at: q(7, 2), in: id) == .outsideCoverage)
        #expect(try group.sourceFrame(at: q(1000), in: id) == .outsideCoverage)
        #expect(try group.sourceFrame(at: q(3), in: id).regionState == .outsideCoverage)
        // Frames outside the occurrence or after its last span.
        for frame: Int64 in [-1, 144_000, 191_999, 192_000, .max] {
            #expect(try group.alignedTime(ofFrame: frame, in: id) == .outsideCoverage)
        }
    }

    @Test func leadingUncoveredFramesAreOutsideCoverage() throws {
        let epoch = RecordingEpochID(), occurrence = fx.occurrence(frames: 48000)
        let group = try fx.otherGroup(epochs: [mapped(epoch, [seg(q(0), q(1), .one, .zero)])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(1000, 48000, epoch)])])
        #expect(try group.alignedTime(ofFrame: 999, in: occurrence.id) == .outsideCoverage)
        #expect(try group.sourceFrame(at: q(999, 48000), in: occurrence.id) == .outsideCoverage)
        if case .aligned(let p) = try group.alignedTime(ofFrame: 1000, in: occurrence.id) { #expect(p.instant == q(1000, 48000)) } else { Issue.record("first covered frame did not map") }
    }

    @Test func unsupportedEpochsAreReportedNotInverted() throws {
        let a = RecordingEpochID(), u = RecordingEpochID(), b = RecordingEpochID()
        let occurrence = fx.occurrence(frames: 144_000)
        let group = try fx.otherGroup(
            epochs: [mapped(a, [seg(q(0), q(1), .one, .zero)]), EpochClockMap(epoch: u, mapping: .unsupported(.estimatorAbstained)), mapped(b, [seg(q(2), q(3), .one, .zero)])],
            placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, a), span(48000, 96000, u), span(96000, 144_000, b)])]
        )
        let forward = try group.alignedTime(ofFrame: 60000, in: occurrence.id)
        #expect(forward == .unsupported(epoch: u, reason: .estimatorAbstained))
        #expect(forward.regionState == .unsupported(.estimatorAbstained))
        // The unsupported span has no aligned image; instants between the mapped neighbours are a gap
        // whose boundary skips the unsupported span.
        let boundary = GapBoundary(occurrence: occurrence.id, precedingEpoch: a, precedingLastFrame: 47999, followingEpoch: b, followingFirstFrame: 96000)
        #expect(try group.sourceFrame(at: q(3, 2), in: occurrence.id) == .gap(boundary))
    }

    @Test func fullyUnsupportedOccurrenceNeverInverts() throws {
        let u = RecordingEpochID(), occurrence = fx.occurrence(frames: 48000)
        let group = try fx.otherGroup(epochs: [EpochClockMap(epoch: u, mapping: .unsupported(.insufficientOverlap))], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 48000, u)])])
        #expect(try group.alignedTime(ofFrame: 0, in: occurrence.id) == .unsupported(epoch: u, reason: .insufficientOverlap))
        for t in [q(0), q(1, 2), q(-5), q(5)] {
            #expect(try group.sourceFrame(at: t, in: occurrence.id) == .outsideCoverage)
        }
    }

    /// Inverse at segment boundaries inside one epoch picks the segment whose half-open image contains t.
    @Test func segmentBoundariesInvertWithinHalfAFrame() throws {
        let epoch = RecordingEpochID(), occurrence = fx.occurrence(frames: 480_000)
        let segments = [seg(q(0), q(5), .one, .zero), seg(q(5), q(10), q(10_001, 10_000), q(-1, 2000))]
        let group = try fx.otherGroup(epochs: [mapped(epoch, segments)], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, 480_000, epoch)])])
        for frame: Int64 in [239_999, 240_000, 240_001, 479_999] {
            guard case .aligned(let p) = try group.alignedTime(ofFrame: frame, in: occurrence.id) else { Issue.record("frame \(frame) not aligned"); continue }
            guard case .source(let s) = try group.sourceFrame(at: p.instant, in: occurrence.id) else { Issue.record("instant for \(frame) not inverted"); continue }
            #expect(s.frame == frame && s.exactFrame == q(frame))
        }
        // Boundary instant t = 5 s is frame 240,000 exactly under both formulas.
        if case .source(let s) = try group.sourceFrame(at: q(5), in: occurrence.id) { #expect(s.exactFrame == q(240_000)) } else { Issue.record("boundary not inverted") }
    }
}

private func + (lhs: ExactRational, rhs: ExactRational) -> ExactRational { try! lhs.adding(rhs) }
