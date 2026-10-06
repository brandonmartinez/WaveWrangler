import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWAlignSegment

/// Cheap tests for the parallel pass: no estimator work beyond trivially small buffers.
@Suite("Segmenter units")
struct SegmenterUnitTests {
    // MARK: segmentPoints

    static func points(_ count: Int, spacing: Double = 0.4, _ y: (Int, Double) -> Double) -> [Point] {
        (0..<count).map { i in
            let u = Double(i) * spacing
            return Point(u: u, y: y(i, u), window: i)
        }
    }

    /// Deterministic ±0.1 ms jitter.
    static func jitter(_ i: Int) -> Double { [0.0001, -0.00007, 0.00003, -0.0001, 0.00006][i % 5] }

    static func segments(_ pieces: [Piece]) -> [[Int]] {
        pieces.compactMap { if case .segment(let s) = $0 { s } else { nil } }
    }

    static func islands(_ pieces: [Piece]) -> [[Int]] {
        pieces.compactMap { if case .island(let s) = $0 { s } else { nil } }
    }

    @Test func oneLineStaysOneSegment() {
        let p = Self.points(60) { i, u in 0.1 + 40e-6 * u + Self.jitter(i) }
        let pieces = segmentPoints(p, tolerance: 0.0005, minimumPoints: 5)
        #expect(Self.segments(pieces) == [Array(0..<60)])
        #expect(Self.islands(pieces).isEmpty)
    }

    @Test func offsetStepSplitsExactlyAtTheJump() {
        for step in [0.002, -0.004, 0.25] {
            let p = Self.points(60) { i, u in 0.1 + 40e-6 * u + Self.jitter(i) + (i >= 23 ? step : 0) }
            let pieces = segmentPoints(p, tolerance: 0.0005, minimumPoints: 5)
            #expect(Self.segments(pieces) == [Array(0..<23), Array(23..<60)], "step \(step)")
        }
    }

    @Test func slopeChangeNeverFitsOneLine() {
        // 300 ppm change at u = 12 s: lines diverge by 3.6 ms over the following 12 s.
        let p = Self.points(60) { i, u in 0.1 + 40e-6 * u + (u > 12 ? 300e-6 * (u - 12) : 0) + Self.jitter(i) / 4 }
        let pieces = segmentPoints(p, tolerance: 0.0005, minimumPoints: 5)
        let segments = Self.segments(pieces)
        #expect(segments.count >= 2)
        for s in segments { #expect(fitLine(p, s).maxResidual <= 0.0005) }
    }

    @Test func islandBetweenAJumpIsNeverBridged() {
        // Outliers at the jump (windows straddling it measure neither side): the neighbours must stay apart.
        let p = Self.points(60) { i, u in
            switch i {
            case 29: 0.103
            case 30: 0.097
            default: 0.1 + (i >= 30 ? 0.01 : 0) + Self.jitter(i)
            }
        }
        let pieces = segmentPoints(p, tolerance: 0.0005, minimumPoints: 5)
        let segments = Self.segments(pieces)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { s in s.allSatisfy { $0 < 30 } || s.allSatisfy { $0 >= 30 } })
        for s in segments { #expect(fitLine(p, s).maxResidual <= 0.0005) }
    }

    @Test func lonelyOutlierInsideOneLineIsDroppedNotSplit() {
        let p = Self.points(60) { i, u in i == 31 ? 0.2 : 0.1 + 40e-6 * u + Self.jitter(i) }
        let pieces = segmentPoints(p, tolerance: 0.0005, minimumPoints: 5)
        #expect(Self.segments(pieces) == [Array(0..<31) + Array(32..<60)])
    }

    @Test func tooFewPointsAreAnIsland() {
        let p = Self.points(4) { _, _ in 0.1 }
        let pieces = segmentPoints(p, tolerance: 0.0005, minimumPoints: 5)
        #expect(Self.segments(pieces).isEmpty)
        #expect(Self.islands(pieces) == [[0, 1, 2, 3]])
        #expect(segmentPoints([], tolerance: 0.0005, minimumPoints: 5).isEmpty)
    }

    @Test func subtractHelper() {
        #expect(subtract(5..<10, from: 0..<20) == [0..<5, 10..<20])
        #expect(subtract(0..<10, from: 5..<20) == [10..<20])
        #expect(subtract(15..<30, from: 5..<20) == [5..<15])
        #expect(subtract(0..<30, from: 5..<20).isEmpty)
        #expect(subtract(30..<40, from: 5..<20) == [5..<20])
    }

    // MARK: Requests

    struct Fixture {
        let reference: EstimatorTrack
        let occurrence: SourceOccurrence
        let buffer: SampleBuffer

        init(seconds: Double = 2, rate: Int = 8000) throws {
            var rng = SplitMix64(seed: 0x17_0001)
            let referenceSamples = (0..<(8000 * 4)).map { _ in Float(0.01 * rng.gaussian()) }
            reference = EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(), buffer: try SampleBuffer(samples: referenceSamples, sampleRate: 8000))
            let count = Int(seconds * Double(rate))
            occurrence = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(Int64(rate)), frameCount: Int64(count))
            buffer = try SampleBuffer(samples: (0..<count).map { _ in Float(0.01 * rng.gaussian()) }, sampleRate: rate)
        }

        func request(group: RecorderGroupID = RecorderGroupID(), buffer: SampleBuffer? = nil, spans: [DeclaredSpan]? = nil) throws -> SegmentationRequest {
            SegmentationRequest(
                reference: reference, group: group, occurrence: occurrence, buffer: buffer ?? self.buffer,
                declaredSpans: spans ?? [DeclaredSpan(frames: 0..<occurrence.frameCount, epoch: RecordingEpochID(), groupClockOffset: .zero)],
                search: try SearchRange(maximumDeviationSeconds: 1))
        }
    }

    static func invalid(_ request: SegmentationRequest, parameters: SegmenterParameters = SegmenterParameters()) -> Bool {
        do throws(SegmentError) {
            _ = try DiscontinuitySegmenter.segment(request, parameters: parameters)
            return false
        } catch {
            if case .invalidRequest = error { return true }
            return false
        }
    }

    @Test func requestValidation() throws {
        let f = try Fixture()
        let n = f.occurrence.frameCount
        let e = RecordingEpochID()
        #expect(Self.invalid(try f.request(group: f.reference.group)), "target group is the reference group")
        #expect(Self.invalid(try f.request(buffer: try SampleBuffer(samples: [Float](repeating: 0, count: Int(n) - 1), sampleRate: 8000))), "frame count")
        #expect(Self.invalid(try f.request(buffer: try SampleBuffer(samples: [Float](repeating: 0, count: Int(n)), sampleRate: 16000))), "rate")
        #expect(Self.invalid(try f.request(spans: [])), "no spans")
        #expect(Self.invalid(try f.request(spans: [DeclaredSpan(frames: 10..<10, epoch: e, groupClockOffset: .zero)])), "empty span")
        #expect(Self.invalid(try f.request(spans: [DeclaredSpan(frames: 0..<(n + 1), epoch: e, groupClockOffset: .zero)])), "beyond occurrence")
        #expect(Self.invalid(try f.request(spans: [
            DeclaredSpan(frames: 0..<100, epoch: e, groupClockOffset: .zero),
            DeclaredSpan(frames: 99..<200, epoch: RecordingEpochID(), groupClockOffset: .zero),
        ])), "overlapping spans")
        #expect(Self.invalid(try f.request(spans: [
            DeclaredSpan(frames: 100..<200, epoch: e, groupClockOffset: .zero),
            DeclaredSpan(frames: 0..<100, epoch: RecordingEpochID(), groupClockOffset: .zero),
        ])), "descending spans")
        #expect(Self.invalid(try f.request(spans: [
            DeclaredSpan(frames: 0..<100, epoch: e, groupClockOffset: .zero),
            DeclaredSpan(frames: 100..<200, epoch: e, groupClockOffset: .zero),
        ])), "duplicate epochs")
        #expect(Self.invalid(try f.request(spans: [DeclaredSpan(frames: 0..<100, epoch: f.reference.epoch, groupClockOffset: .zero)])), "reference epoch")
        #expect(!Self.invalid(try f.request()))
    }

    @Test func parameterValidation() throws {
        let f = try Fixture()
        let request = try f.request()
        var p = SegmenterParameters()
        p.splitToleranceMilliseconds = 0
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.splitToleranceMilliseconds = 1.5   // looser than the estimator's own consistency tolerance
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.tileSeconds = 2
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.stepToleranceFactor = 0.5
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.minimumSegmentWindows = 2
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.minimumSupportedSeconds = 1
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.proposalAgreementMilliseconds = 6
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.slicePaddingSeconds = -1
        #expect(Self.invalid(request, parameters: p))
        p = SegmenterParameters()
        p.tileSeconds = .nan
        #expect(Self.invalid(request, parameters: p))
    }

    /// A span shorter than `minimumSupportedSeconds` is one unsupported region; nothing is guessed, the
    /// occurrence and its declared epochs are retained, and nothing inverts into it.
    @Test func shortSpansAreUnsupportedAndRetained() throws {
        let f = try Fixture(seconds: 3)
        let e1 = RecordingEpochID(), e2 = RecordingEpochID()
        let request = try f.request(spans: [
            DeclaredSpan(frames: 0..<8000, epoch: e1, groupClockOffset: .zero),
            DeclaredSpan(frames: 12000..<24000, epoch: e2, groupClockOffset: try ExactRational(1, 2)),
        ])
        let report = try DiscontinuitySegmenter.segment(request)
        #expect(report.segmenter == DiscontinuitySegmenter.identifier)
        #expect(report.estimator == AcousticEstimator.identifier)
        #expect(report.detections.isEmpty)
        #expect(report.regions.map(\.frames) == [0..<8000, 12000..<24000])
        #expect(report.regions.map(\.epoch) == [e1, e2])
        #expect(report.regions.map(\.declaredEpoch) == [e1, e2])
        for region in report.regions {
            #expect(region.outcome == .unsupported(.insufficientOverlap, .tooShort))
        }
        #expect(report.map.placements.count == 1)
        #expect(report.map.placements[0].occurrence == f.occurrence)
        #expect(report.map.placements[0].spans.map(\.epoch) == [e1, e2])
        #expect(report.map.placements[0].spans[1].groupClockOffset == (try ExactRational(1, 2)))
        #expect(try report.map.alignedTime(ofFrame: 100, in: f.occurrence.id) == .unsupported(epoch: e1, reason: .insufficientOverlap))
        if case .gap = try report.map.alignedTime(ofFrame: 10000, in: f.occurrence.id) {} else { Issue.record("frames between declared spans are a gap") }
        if case .source = try report.map.sourceFrame(at: .zero, in: f.occurrence.id) { Issue.record("an unsupported span inverted") }
        for epoch in report.map.epochs {
            if case .mapped = epoch.mapping { Issue.record("nothing may be mapped") }
        }
    }

    @Test func customParametersAreStamped() throws {
        let f = try Fixture()
        var p = SegmenterParameters()
        p.minimumSupportedSeconds = 3
        #expect(p != SegmenterParameters())
        #expect(try DiscontinuitySegmenter.segment(try f.request(), parameters: p).segmenter == DiscontinuitySegmenter.customIdentifier)
        #expect(try DiscontinuitySegmenter.segment(try f.request()).segmenter == DiscontinuitySegmenter.identifier)
    }
}
