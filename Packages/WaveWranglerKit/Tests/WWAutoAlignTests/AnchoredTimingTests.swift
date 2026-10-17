import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWAutoAlign

@Suite("Anchor-guided short passage recovery")
struct AnchoredTimingTests {
    func timing(leftOffset: Double = 0.2, rightOffset: Double = 0.22) -> AdaptiveTimingResult {
        AdaptiveTimingResult(regions: [
            AdaptiveTimingRegion(sourceStart: 100, sourceEnd: 106, rateRatio: 1, offsetSeconds: leftOffset,
                                 measurements: 7, maximumResidualMilliseconds: 0),
            AdaptiveTimingRegion(sourceStart: 110, sourceEnd: 116, rateRatio: 1, offsetSeconds: rightOffset,
                                 measurements: 7, maximumResidualMilliseconds: 0),
        ], attemptedWindows: 20, usableWindows: 14, measuredStart: 100, measuredEnd: 118)
    }

    func point(_ center: Double, offset: Double = 0.21, score: Double = 0.85) -> AnchoredTimingObservation {
        AnchoredTimingObservation(leftRegion: 0, center: center, status: "eligible", offset: offset,
            score: score, second: 0.1, phatOffset: offset, phatRatio: 0.1, polarity: 1,
            canonical: TemporalCorroboration(targetCenter: center, offsetSeconds: offset, score: score,
                competingScore: 0.1, polarity: 1, windowSeconds: 0.25),
            canonicalPhatOffset: offset, canonicalPhatRatio: 0.1)
    }

    @Test func freshChecksKeepExistingAnchorsAndReplayTheirSeparateProvenance() throws {
        let base = timing()
        let points = [106.15, 106.45, 106.75, 107.05].map { point($0) }
        let recovered = try AnchoredTiming.recovering(base, observations: points)
        #expect(recovered.regions == base.regions && recovered.usableWindows == base.usableWindows)
        #expect(recovered.attemptedWindows == base.attemptedWindows && recovered.quietTransitions == base.quietTransitions)
        let region = try #require(recovered.anchoredRecovery?.regions.first)
        #expect(region.observations == [0, 1, 2, 3])
        #expect(abs(region.sourceStart - 106.025) < 1e-9 && abs(region.sourceEnd - 107.175) < 1e-9)
        #expect(recovered.referenceIntervals.filter { $0.kind == .anchorGuided }.count == 1)
        #expect(try AnchoredTiming.recovering(recovered, observations: points) == recovered)
        #expect(try JSONDecoder().decode(AdaptiveTimingResult.self, from: JSONEncoder().encode(recovered)) == recovered)
        #expect(recovered.referenceTime(at: 108) == nil)
        #expect(recovered.referenceTime(at: 108, includeEstimated: true) != nil)
        #expect(recovered.referenceTime(at: 99, includeEstimated: true) == nil)
        #expect(recovered.referenceTime(at: 117, includeEstimated: true) == nil)
    }

    @Test func isolatedWeakOverlappingAndContradictoryChecksCannotBridgeUnmeasuredAudio() throws {
        for points in [
            [point(106.15)],
            [point(106.15), point(106.45, score: 0.64), point(106.75)],
            [point(106.15), point(106.45, score: 0.74), point(106.75)],
            [point(106.15), point(106.35)],
            [point(106.15), point(106.45, offset: 0.24)],
        ] {
            let recovery = try #require(AnchoredTiming.recovering(timing(), observations: points).anchoredRecovery)
            #expect(recovery.regions.allSatisfy { $0.sourceEnd - $0.sourceStart <= 0.250001 })
            #expect(recovery.regions.allSatisfy { $0.observations.count == 1 },
                    "a single confirmed quarter may play, but cannot bridge failed or overlapping checks")
        }
        #expect(throws: (any Error).self) {
            try AnchoredTiming.recovering(timing(), observations: [point(106.45), point(106.15)])
        }
        #expect(throws: (any Error).self) {
            try AnchoredTiming.recovering(timing(), observations: [point(106.15, offset: 7200)])
        }
    }

    @Test func estimatesAreBoundedMonotoneAndNeverExtendEndsOrBecomeMeasurements() throws {
        let base = timing()
        let segments = base.referenceIntervals
        let estimate = try #require(base.estimatedIntervals.first)
        #expect(estimate.sourceStart == 106 && estimate.sourceEnd == 110 && estimate.kind == .estimated)
        #expect(estimate.alignedStart == segments[0].alignedEnd && estimate.alignedEnd <= segments[1].alignedStart)
        #expect(base.referenceTime(at: 108) == nil)
        #expect(!base.containsPlayableInterval(from: 107, to: 109))
        #expect(base.containsPlayableInterval(from: 107, to: 109, includeEstimated: true))
        let wrong = [segments[0], SourceTimingSegment(sourceStart: 110, sourceEnd: 116,
            alignedStart: 111, rateRatio: 1)]
        #expect(AnchoredTiming.estimatedIntervals(between: wrong).isEmpty)
        let distant = [segments[0], SourceTimingSegment(sourceStart: 410, sourceEnd: 420,
            alignedStart: 410.2, rateRatio: 1)]
        #expect(AnchoredTiming.estimatedIntervals(between: distant).isEmpty)
        let tiny = [segments[0], SourceTimingSegment(sourceStart: 106.001, sourceEnd: 110,
            alignedStart: segments[0].alignedEnd + 0.001, rateRatio: 1)]
        #expect(AnchoredTiming.estimatedIntervals(between: tiny).isEmpty,
                "two join crossfades must not overlap into a three-segment gain bump")
    }

    @Test func boundedFreshWaveformsRejectUnrelatedPeriodicAndSilentContent() throws {
        let search = try #require(AnchoredTiming.searches(in: timing()).first)
        let centers = [106.15, 106.45, 106.75]
        let reference = try SyntheticSpeech.track(start: 105, duration: 6, noiseLevel: 0)
        let target = try SyntheticSpeech.track(start: 105, duration: 6, offset: 0.21, noiseLevel: 0)
        let measured = try AnchoredTiming.measure(search: search, centers: centers,
            hints: [0.21, 0.21, 0.21], reference: reference, target: target)
        #expect(measured.allSatisfy { $0.isEligible })
        #expect(measured.allSatisfy { abs(($0.offset ?? .infinity) - 0.21) < 0.001 })
        let unrelated = try SyntheticSpeech.track(start: 105, duration: 6, seed: 998, noiseLevel: 0)
        #expect(try AnchoredTiming.measure(search: search, centers: centers, hints: [0.21, 0.21, 0.21],
            reference: reference, target: unrelated).allSatisfy { !$0.isEligible })
        let silent = try SyntheticSpeech.track(start: 105, duration: 6, noiseLevel: 0, gain: 0)
        #expect(try AnchoredTiming.measure(search: search, centers: centers, hints: [0.21, 0.21, 0.21],
            reference: reference, target: silent).allSatisfy { !$0.isEligible })
        let inverted = try SyntheticSpeech.track(start: 105, duration: 6, offset: 0.21, noiseLevel: 0, gain: -0.25)
        #expect(try AnchoredTiming.measure(search: search, centers: centers, hints: [0.21, 0.21, 0.21],
            reference: reference, target: inverted).allSatisfy { $0.isEligible && $0.polarity == -1 })
        let tone = try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
            groupClockStart: ExactRational(105, 1),
            buffer: SampleBuffer(samples: (0..<48000).map { Float(0.2 * sin(2 * .pi * 220 * Double($0) / 8000)) },
                                 sampleRate: 8000))
        #expect(try AnchoredTiming.measure(search: search, centers: centers, hints: [0.21, 0.21, 0.21],
            reference: tone, target: tone).allSatisfy { !$0.isEligible })
        #expect(throws: (any Error).self) {
            try AnchoredTiming.measure(search: search, centers: centers, hints: [1e308, 0.21, 0.21],
                reference: reference, target: target)
        }
    }

    @Test func overlappingHalfSecondsCannotBorrowOneSharedBurstAsTwoCanonicalSupports() throws {
        var samples = [Float](repeating: 0, count: 48000)
        for index in 9840..<10160 { samples[index] = Float(SyntheticSpeech.noise(132, Int64(index)) * 0.3) }
        let track = try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
            groupClockStart: ExactRational(105, 1), buffer: SampleBuffer(samples: samples, sampleRate: 8000))
        let search = AnchoredTimingSearch(leftRegion: 0, sourceStart: 106, sourceEnd: 110, leftOffset: 0, rightOffset: 0)
        let points = try AnchoredTiming.measure(search: search, centers: [106.15, 106.45], hints: [0, 0],
                                              reference: track, target: track)
        #expect(points.filter { $0.isEligible }.count <= 1)
        let recovery = try #require(AnchoredTiming.recovering(timing(leftOffset: 0, rightOffset: 0),
            observations: points).anchoredRecovery)
        #expect(recovery.regions.allSatisfy { $0.sourceEnd - $0.sourceStart <= 0.250001 && $0.observations.count == 1 })
    }

    @Test func featurePathIsDeterministicBoundedGuidanceRatherThanAcousticEvidence() throws {
        let bands = (0..<6).map { band in
            (0..<6000).map { index in Float(SyntheticSpeech.noise(UInt64(band + 1), Int64(index)) * 3) }
        }
        let reference = SpectralFingerprint(duration: 120, bands: bands, energy: Array(repeating: 0.1, count: 6000))
        let target = SpectralFingerprint(duration: 120,
            bands: bands.map { Array($0.dropFirst(10)) + Array(repeating: 0, count: 10) },
            energy: Array(repeating: 0.1, count: 6000))
        let search = try #require(AnchoredTiming.searches(in: timing()).first)
        let centers = Array(stride(from: 106.15, to: 109.9, by: 0.3))
        let hints = try AnchoredTiming.featureHints(search: search, centers: centers, reference: reference, target: target)
        #expect(hints.count == centers.count)
        #expect(zip(centers, hints).allSatisfy { abs($0.1 - search.prediction(at: $0.0)) <= 0.040001 })
        #expect(hints == (try AnchoredTiming.featureHints(search: search, centers: centers, reference: reference, target: target)))
        #expect(try AnchoredTiming.recovering(timing(), observations: []).anchoredRecovery == nil)
    }
}
