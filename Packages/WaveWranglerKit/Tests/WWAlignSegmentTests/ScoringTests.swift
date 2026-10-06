import Foundation
import Testing
@testable import WWAlignEstimate
@testable import WWAlignSegment
import WWCore
import WWTimeMap

/// The scorer and gate checks must catch every failure they exist for. These tests segment nothing: they hand
/// `Scoring.score` fabricated reports whose maps are valid WWTimeMap group maps built from the case's own
/// truth lines, then deliberately wrong in one way each. Cheap (no audio is rendered), so they run in the
/// parallel pass. `@testable import WWAlignEstimate` only constructs a result value; the frozen tree is unchanged.
@Suite("Segment scoring self-check")
struct SegmentScoringTests {
    /// A planned region: frames and either a line t = a·u + b (mapped) or nil (unsupported).
    struct Planned {
        let frames: Range<Int>
        let line: (a: Double, b: Double)?
    }

    static func exact(_ value: Double) throws -> ExactRational {
        try ExactRational(Int64((value * 1_000_000_000).rounded()), 1_000_000_000)
    }

    /// A request for the case with a silent buffer: scoring reads only the occurrence and declared span.
    static func request(_ kase: SegmentCase) throws -> SegmentationRequest {
        let reference = EstimatorTrack(
            group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
            buffer: try SampleBuffer(samples: [Float](repeating: 0, count: 8000), sampleRate: 8000))
        let occurrence = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(Int64(kase.truth.rate)), frameCount: Int64(kase.truth.frameCount))
        return SegmentationRequest(
            reference: reference, group: RecorderGroupID(), occurrence: occurrence,
            buffer: try SampleBuffer(samples: [Float](repeating: 0, count: kase.truth.frameCount), sampleRate: kase.truth.rate),
            declaredSpans: [DeclaredSpan(frames: 0..<Int64(kase.truth.frameCount), epoch: RecordingEpochID(), groupClockOffset: .zero)],
            search: try SearchRange(maximumDeviationSeconds: 1))
    }

    static func report(
        _ kase: SegmentCase, _ request: SegmentationRequest, _ planned: [Planned], detections: [Discontinuity] = [],
        segmenter: String = DiscontinuitySegmenter.identifier, keepDeclaredEpoch: Bool = true
    ) throws -> SegmentationReport {
        let f = Double(kase.truth.rate)
        let span = request.declaredSpans[0]
        var regions: [SegmentRegion] = []
        var epochs: [EpochClockMap] = []
        for (k, p) in planned.enumerated() {
            let epoch = k == 0 && keepDeclaredEpoch ? span.epoch : RecordingEpochID()
            let outcome: RegionOutcome
            if let line = p.line {
                let segment = try AffineClockSegment(
                    groupClockStart: try ExactRational(Int64(p.frames.lowerBound), Int64(kase.truth.rate)),
                    groupClockEnd: try ExactRational(Int64(p.frames.upperBound), Int64(kase.truth.rate)),
                    rateRatio: try exact(line.a), alignedOffset: try exact(line.b))
                let provenance = try AcousticConsistencyProposal(estimator: AcousticEstimator.identifier)
                let center = (Double(p.frames.lowerBound) + Double(p.frames.upperBound)) / 2 / f
                outcome = .supported(AcousticProposal(
                    segment: segment, ppm: (line.a - 1) * 1e6, offsetAtCenterSeconds: (line.a - 1) * center + line.b,
                    acousticResidualP95Milliseconds: 0, acousticResidualMaxMilliseconds: 0, provenance: provenance))
                epochs.append(EpochClockMap(epoch: epoch, mapping: .mapped(segments: [segment], provenance: .acousticConsistentProposal(provenance))))
            } else {
                outcome = .unsupported(.nonlinear, .discontinuity([]))
                epochs.append(EpochClockMap(epoch: epoch, mapping: .unsupported(.nonlinear)))
            }
            regions.append(SegmentRegion(frames: Int64(p.frames.lowerBound)..<Int64(p.frames.upperBound), epoch: epoch, declaredEpoch: span.epoch, groupClockOffset: .zero, outcome: outcome))
        }
        let placement = OccurrencePlacement(occurrence: request.occurrence, spans: regions.map {
            EpochSpan(startFrame: $0.frames.lowerBound, endFrame: $0.frames.upperBound, epoch: $0.epoch, groupClockOffset: $0.groupClockOffset)
        })
        let reference = TimelineReference(group: request.reference.group, epoch: request.reference.epoch, occurrence: request.reference.occurrence)
        let map = try GroupTimeMap(group: request.group, reference: reference, epochs: epochs, placements: [placement])
        return SegmentationReport(segmenter: segmenter, estimator: AcousticEstimator.identifier, regions: regions, detections: detections, windows: [], map: map)
    }

    static func detection(_ kase: SegmentCase, frames: Range<Int>, epoch: RecordingEpochID) -> Discontinuity {
        let f = Double(kase.truth.rate)
        return Discontinuity(
            kind: .offsetStep, declaredEpoch: epoch, bracket: (Double(frames.lowerBound) / f)...(Double(frames.upperBound) / f),
            frames: Int64(frames.lowerBound)..<Int64(frames.upperBound), position: Double(frames.lowerBound + frames.upperBound) / 2 / f,
            stepMilliseconds: 0, slopeChangePPM: 0, leftWindowCount: 5, rightWindowCount: 5, unresolvedWindowCount: 0,
            leftResidualMaxMilliseconds: 0, rightResidualMaxMilliseconds: 0, leftMedianPeakScore: 1, rightMedianPeakScore: 1,
            bracketWindowStatus: [:])
    }

    static func line(_ piece: OccurrenceTruth.Piece) -> (a: Double, b: Double) {
        guard case .mapped(let a, let b) = piece.content else { preconditionFailure("inserted piece has no line") }
        return (a, b)
    }

    static func stepCase(_ seconds: Double) -> SegmentCase {
        SegmentPlan.make(.clockStep, index: 0, master: 0x5757_1700_5C0E_0000, override: .clockStep(seconds: seconds), length: 30)
    }

    /// The honest report (truth lines either side, the plant bracketed and unsupported) passes every check.
    @Test func truthfulSplitPasses() throws {
        let kase = Self.stepCase(0.005)
        let request = try Self.request(kase)
        let plant = kase.plants[0].frame, n = kase.truth.frameCount, margin = kase.truth.rate
        let left = Self.line(kase.truth.pieces[0]), right = Self.line(kase.truth.pieces[1])
        let report = try Self.report(kase, request, [
            Planned(frames: 0..<(plant - margin), line: left),
            Planned(frames: (plant - margin)..<(plant + margin), line: nil),
            Planned(frames: (plant + margin)..<n, line: right),
        ], detections: [Self.detection(kase, frames: (plant - margin)..<(plant + margin), epoch: request.declaredSpans[0].epoch)])
        let score = try Scoring.score(kase, request: request, report: report)
        #expect(score.hardFailures.isEmpty, "\(score.hardFailures)")
        #expect(score.silentBridges == 0 && score.bridgingRegions == 0)
        #expect(score.plants.map(\.status) == [.flagged])
        #expect(score.spuriousDetections == 0)
        #expect(score.residualMaxMilliseconds < 1e-3)
        #expect(SegmentRunner.gateFailures([score], maximumFalseSplitRate: 0).isEmpty)
    }

    /// Without a detection object the bracketed plant is unsupported (still not bridged); a detection that
    /// misses the plant is spurious.
    @Test func unsupportedAndSpuriousAreDistinguished() throws {
        let kase = Self.stepCase(0.005)
        let request = try Self.request(kase)
        let plant = kase.plants[0].frame, n = kase.truth.frameCount, margin = kase.truth.rate
        let left = Self.line(kase.truth.pieces[0]), right = Self.line(kase.truth.pieces[1])
        let report = try Self.report(kase, request, [
            Planned(frames: 0..<(plant - margin), line: left),
            Planned(frames: (plant - margin)..<(plant + margin), line: nil),
            Planned(frames: (plant + margin)..<n, line: right),
        ], detections: [Self.detection(kase, frames: 0..<margin, epoch: request.declaredSpans[0].epoch)])
        let score = try Scoring.score(kase, request: request, report: report)
        #expect(score.hardFailures.isEmpty, "\(score.hardFailures)")
        #expect(score.plants.map(\.status) == [.unsupported])
        #expect(score.spuriousDetections == 1)
    }

    /// One smooth line across a small step stays inside the WW-016 residual gate: that is silent bridging and
    /// must fail even though every residual looks fine.
    @Test func silentSmoothBridgeIsCaught() throws {
        let kase = Self.stepCase(0.005)
        let request = try Self.request(kase)
        let left = Self.line(kase.truth.pieces[0])
        let report = try Self.report(kase, request, [Planned(frames: 0..<kase.truth.frameCount, line: (left.a, left.b + 0.0025))])
        let score = try Scoring.score(kase, request: request, report: report)
        #expect(score.residualMaxMilliseconds <= Scoring.maxGate && score.residualP95Milliseconds <= Scoring.p95Gate)
        #expect(score.bridgingRegions == 1)
        #expect(score.silentBridges == 1)
        #expect(score.plants.map(\.status) == [.bridged])
        let failures = SegmentRunner.gateFailures([score], maximumFalseSplitRate: 0)
        #expect(failures.contains { $0.contains("silent smooth bridging") })
        #expect(failures.contains { $0.contains("span a planted discontinuity") })
    }

    /// A bridge with a large residual is a bridge too (not silent, still a failure).
    @Test func loudBridgeIsCaught() throws {
        let kase = Self.stepCase(0.2)
        let request = try Self.request(kase)
        let left = Self.line(kase.truth.pieces[0])
        let report = try Self.report(kase, request, [Planned(frames: 0..<kase.truth.frameCount, line: left)])
        let score = try Scoring.score(kase, request: request, report: report)
        #expect(score.bridgingRegions == 1 && score.silentBridges == 0)
        #expect(score.plants.map(\.status) == [.bridged])
        #expect(!SegmentRunner.gateFailures([score], maximumFalseSplitRate: 0).isEmpty)
    }

    /// Mapping inserted frames bridges them even when the regions either side are exact, and instants that
    /// invert into them fail the inverse check; a gap whose skipped instants invert into frames fails too.
    @Test func insertedFramesAndGapInversesAreCaught() throws {
        let inserted = SegmentPlan.make(.inserted, index: 0, master: 0x5757_1700_5C0E_0000, length: 30)
        let ins = try #require(inserted.plants[0].inserted)
        let request = try Self.request(inserted)
        let f = Double(inserted.truth.rate), n = inserted.truth.frameCount, second = inserted.truth.rate
        let left = Self.line(inserted.truth.pieces[0]), right = Self.line(inserted.truth.pieces[2])
        #expect(ins.count < second / 2, "the inserted image must fit between the grid instant and the right region")
        // Place the inserted frames' image over the first 0.5 s inverse-grid instant after the left region's end,
        // inside the 1 s of aligned time left free before the right region starts.
        let leftEnd = left.a * Double(ins.lowerBound) / f + left.b
        let gridStart = left.a * 0 + left.b
        let instant = gridStart + 0.5 * ((leftEnd + 0.01 - gridStart) / 0.5).rounded(.up)
        let start = instant - 0.005
        let leaky = try Self.report(inserted, request, [
            Planned(frames: 0..<ins.lowerBound, line: left),
            Planned(frames: ins, line: (left.a, start - left.a * Double(ins.lowerBound) / f)),
            Planned(frames: ins.upperBound..<(ins.upperBound + second), line: nil),
            Planned(frames: (ins.upperBound + second)..<n, line: right),
        ])
        let leakScore = try Scoring.score(inserted, request: request, report: leaky)
        #expect(leakScore.plants.map(\.status) == [.bridged])
        #expect(leakScore.bridgingRegions == 1)
        #expect(leakScore.inverseFailures.contains { $0.contains("inverted into inserted frame") }, "\(leakScore.inverseFailures)")

        // Dropped samples: two regions each inside one truth piece, but the right one keeps the old clock, so
        // the aligned instants the recorder skipped invert into its frames.
        let dropped = SegmentPlan.make(.dropped, index: 3, master: 0x5757_1700_5C0E_0000, length: 30)
        #expect(dropped.plants[0].stepSeconds > 0.02, "fixture must skip more than the probe margin")
        let dRequest = try Self.request(dropped)
        let plant = dropped.plants[0].frame
        let old = Self.line(dropped.truth.pieces[0])
        let continued = try Self.report(dropped, dRequest, [
            Planned(frames: 0..<plant, line: old),
            Planned(frames: plant..<dropped.truth.frameCount, line: (old.a, old.b)),
        ])
        let gapScore = try Scoring.score(dropped, request: dRequest, report: continued)
        #expect(gapScore.inverseFailures.contains { $0.hasPrefix("skipped instant") }, "\(gapScore.inverseFailures)")
        #expect(!gapScore.hardFailures.isEmpty)
    }

    /// Residuals outside the WW-016 gate inside one truth piece fail; inside it they pass.
    @Test func residualGateBoundary() throws {
        let kase = SegmentPlan.make(.clean, index: 0, master: 0x5757_1700_5C0E_0000, length: 30)
        let request = try Self.request(kase)
        let truth = Self.line(kase.truth.pieces[0])
        let inside = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<kase.truth.frameCount, line: (truth.a, truth.b + 0.004))]))
        #expect(inside.residualGateFailures.isEmpty)
        #expect(inside.hardFailures.isEmpty, "\(inside.hardFailures)")
        let outside = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<kase.truth.frameCount, line: (truth.a, truth.b + 0.006))]))
        #expect(!outside.residualGateFailures.isEmpty)
        #expect(!SegmentRunner.gateFailures([outside], maximumFalseSplitRate: 0).isEmpty)
    }

    /// Any detection or a second mapped region on a negative is a false split, and the rate gate fails.
    @Test func falseSplitsAreCaught() throws {
        let kase = SegmentPlan.make(.clean, index: 0, master: 0x5757_1700_5C0E_0000, length: 30)
        let request = try Self.request(kase)
        let truth = Self.line(kase.truth.pieces[0])
        let n = kase.truth.frameCount
        let whole = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<n, line: truth)]))
        #expect(!whole.falseSplit)
        let split = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [
            Planned(frames: 0..<(n / 2), line: truth), Planned(frames: (n / 2)..<n, line: truth),
        ]))
        #expect(split.falseSplit)
        #expect(split.hardFailures.isEmpty, "two exact regions are not a hard failure, only a false split")
        let flagged = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [
            Planned(frames: 0..<(n / 2), line: truth), Planned(frames: (n / 2)..<(n / 2 + 8000), line: nil), Planned(frames: (n / 2 + 8000)..<n, line: truth),
        ], detections: [Self.detection(kase, frames: (n / 2)..<(n / 2 + 8000), epoch: request.declaredSpans[0].epoch)]))
        #expect(flagged.falseSplit)
        let detectedOnly = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<n, line: truth)],
            detections: [Self.detection(kase, frames: (n / 2)..<(n / 2 + 8000), epoch: request.declaredSpans[0].epoch)]))
        #expect(detectedOnly.falseSplit, "a detection alone is a false split on a negative")
        #expect(SegmentRunner.gateFailures([whole, split], maximumFalseSplitRate: 0).contains { $0.hasPrefix("false-split rate") })
        #expect(SegmentRunner.gateFailures([whole, split], maximumFalseSplitRate: 0.5).isEmpty)
        #expect(SegmentRunner.gateFailures([whole], maximumFalseSplitRate: 0).isEmpty)
    }

    /// Retention: regions must tile the declared span, keep the declared epoch, and carry the frozen identifier.
    @Test func retentionFailuresAreCaught() throws {
        let kase = SegmentPlan.make(.clean, index: 0, master: 0x5757_1700_5C0E_0000, length: 30)
        let request = try Self.request(kase)
        let truth = Self.line(kase.truth.pieces[0])
        let n = kase.truth.frameCount
        let short = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<(n - 100), line: truth)]))
        #expect(short.retentionFailures.contains { $0.hasPrefix("regions end at") })
        let lost = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<n, line: truth)], keepDeclaredEpoch: false))
        #expect(lost.retentionFailures.contains("declared epoch missing"))
        let custom = try Scoring.score(kase, request: request, report: try Self.report(kase, request, [Planned(frames: 0..<n, line: truth)], segmenter: DiscontinuitySegmenter.customIdentifier))
        #expect(custom.retentionFailures.contains { $0.hasPrefix("segmenter identifier") })
        for score in [short, lost, custom] { #expect(!SegmentRunner.gateFailures([score], maximumFalseSplitRate: 0).isEmpty) }
    }

    /// Monotonic placement is enforced by WWTimeMap itself: overlapping images cannot even form a map. The
    /// scorer's own monotonic check is defence in depth behind this.
    @Test func overlappingImagesCannotFormAMap() throws {
        let kase = Self.stepCase(-0.2)
        let request = try Self.request(kase)
        let plant = kase.plants[0].frame
        let left = Self.line(kase.truth.pieces[0]), right = Self.line(kase.truth.pieces[1])
        do {
            _ = try Self.report(kase, request, [Planned(frames: 0..<plant, line: left), Planned(frames: plant..<kase.truth.frameCount, line: right)])
            Issue.record("overlapping images formed a map")
        } catch {
            switch error as? TimeMapError {
            case .overlappingEpochs?, .nonMonotonicPlacement?: break
            default: Issue.record("unexpected \(error)")
            }
        }
    }
}
