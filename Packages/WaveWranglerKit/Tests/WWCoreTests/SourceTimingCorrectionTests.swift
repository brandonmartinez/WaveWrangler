import Foundation
import Testing
import WWCore

@Suite("Portable source-local timing corrections")
struct SourceTimingCorrectionTests {
    @Test func preservingAudioFillsEveryGapAndBothEndsWithoutChangingEvidence() throws {
        let original = correction()
        let preserved = try original.preservingAudio()
        #expect(!original.retainsAllAudio && preserved.retainsAllAudio)
        #expect(preserved.segments.filter { $0.kind != .estimated } == original.segments)
        #expect(preserved.segments.filter { $0.kind == .estimated }.count == 3)
        #expect(preserved.source == original.source && preserved.reference == original.reference)
        #expect(preserved.analysisDigest == original.analysisDigest && preserved.version == 3)
        for time in stride(from: 0.0, to: 20, by: 0.001) {
            #expect(preserved.alignedTime(at: time) != nil)
        }
        #expect(try preserved.preservingAudio() == preserved)
        #expect(try JSONDecoder().decode(SourceTimingCorrection.self, from: JSONEncoder().encode(preserved)) == preserved)
    }

    @Test func preservationIncludesTinyAndLongGapsButRefusesUnsafeOrReversedTiming() throws {
        for gap in [0.000125, 0.005, 0.01, 301, 600] {
            let segments = [
                SourceTimingSegment(sourceStart: 1, sourceEnd: 2, alignedStart: 0, rateRatio: 1),
                SourceTimingSegment(sourceStart: 2 + gap, sourceEnd: 3 + gap, alignedStart: 1 + gap, rateRatio: 1),
            ]
            let result = try SourceTimingSegment.preservingAudio(in: segments, duration: 4 + gap)
            #expect(result.filter { $0.kind == .estimated }.count == 3)
            #expect(result.first?.sourceStart == 0 && result.last?.sourceEnd == 4 + gap)
            #expect(result.filter { $0.kind == nil } == segments)
        }
        let unsafe = [
            SourceTimingSegment(sourceStart: 0, sourceEnd: 2, alignedStart: 0, rateRatio: 1),
            SourceTimingSegment(sourceStart: 3, sourceEnd: 4, alignedStart: 5, rateRatio: 1),
        ]
        #expect(throws: SourceTimingSegment.AudioPreservationError.unsafeTransition) {
            try SourceTimingSegment.preservingAudio(in: unsafe, duration: 5)
        }
        #expect(throws: SourceTimingSegment.AudioPreservationError.invalidTiming) {
            try SourceTimingSegment.preservingAudio(in: unsafe.reversed(), duration: 5)
        }
        #expect(throws: SourceTimingSegment.AudioPreservationError.invalidTiming) {
            try SourceTimingSegment.preservingAudio(in: [], duration: 5)
        }
    }

    @Test func steepShortGapsUseLabeledRampsInsteadOfDeletingAudioOrRelaxingNativeRateLimits() throws {
        let original = [
            SourceTimingSegment(sourceStart: 0, sourceEnd: 2, alignedStart: 0, rateRatio: 1),
            SourceTimingSegment(sourceStart: 2.001, sourceEnd: 6, alignedStart: 2.021, rateRatio: 1),
        ]
        let result = try SourceTimingSegment.preservingAudio(in: original, duration: 6)
        let ramp = try #require(result.first { $0.kind == .estimated })
        #expect(ramp.sourceStart < 2 && ramp.sourceEnd > 2.001)
        #expect((0.98...1.02).contains(ramp.rateRatio))
        #expect(result.first?.sourceStart == 0 && result.last?.sourceEnd == 6)
        #expect(zip(result, result.dropFirst()).allSatisfy { $0.sourceEnd == $1.sourceStart })
        for segment in result where segment.kind != .estimated {
            let measured = try #require(original.first {
                segment.sourceStart >= $0.sourceStart && segment.sourceEnd <= $0.sourceEnd
            })
            #expect(segment.rateRatio == measured.rateRatio)
            #expect(abs(segment.alignedStart - (measured.alignedStart
                + (segment.sourceStart - measured.sourceStart) * measured.rateRatio)) < 1e-12)
        }
        #expect(try SourceTimingSegment.preservingAudio(in: result, duration: 6) == result)
        let short = [
            SourceTimingSegment(sourceStart: 0, sourceEnd: 0.25, alignedStart: 0, rateRatio: 1),
            SourceTimingSegment(sourceStart: 0.251, sourceEnd: 0.5, alignedStart: 0.271, rateRatio: 1),
            SourceTimingSegment(sourceStart: 0.501, sourceEnd: 4, alignedStart: 0.521, rateRatio: 1),
        ]
        let expanded = try SourceTimingSegment.preservingAudio(in: short, duration: 4)
        #expect(expanded.first?.sourceStart == 0 && expanded.last?.sourceEnd == 4)
        #expect(expanded.allSatisfy { $0.kind == .estimated && (0.98...1.02).contains($0.rateRatio) })
    }

    func correction() -> SourceTimingCorrection {
        SourceTimingCorrection(source: SourceID(), group: RecorderGroupID(), epoch: RecordingEpochID(),
            reference: SourceID(), sourceRate: 8000, sourceFrames: 160000, channelCount: 7,
            analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
            segments: [
                SourceTimingSegment(sourceStart: 2, sourceEnd: 5, alignedStart: -1, rateRatio: 1.0002),
                SourceTimingSegment(sourceStart: 8, sourceEnd: 12, alignedStart: 5.02, rateRatio: 0.9998),
            ])
    }

    @Test func gapsEndsAndNegativeAlignedTimeAreExplicitAndPortable() throws {
        let value = correction()
        #expect(value.isValid)
        #expect(value.alignedTime(at: 2) == -1)
        #expect(value.alignedTime(at: 5) == nil && value.alignedTime(at: 7) == nil)
        #expect(value.alignedTime(at: 0) == nil && value.alignedTime(at: 12) == nil)
        #expect(value.alignedTime(at: .nan) == nil)
        #expect(try JSONDecoder().decode(SourceTimingCorrection.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func malformedProcessingIdentityAndOverlappingOrReversedAudioRefuse() {
        let original = correction()
        var invalid = original
        invalid.segments[1].sourceStart = 4
        #expect(!invalid.isValid)
        invalid = original
        invalid.segments[1].alignedStart = -0.5
        #expect(!invalid.isValid)
        invalid = original
        invalid.segments[0].rateRatio = .nan
        #expect(!invalid.isValid)
        invalid = original
        invalid.segments[0].sourceEnd = 21
        #expect(!invalid.isValid)
        invalid = original
        invalid.source = invalid.reference
        #expect(!invalid.isValid)
        invalid = original
        invalid.analysisDigest = String(repeating: "z", count: 64)
        #expect(!invalid.isValid)
        invalid = original
        invalid.processing = "ordinary-src"
        #expect(!invalid.isValid)
        invalid = original
        invalid.channelCount = 33
        #expect(!invalid.isValid)
    }

    @Test func quietProvenanceRequiresVersionTwoWhileLegacyMeasuredCurvesRemainVersionOne() throws {
        let original = correction()
        let originalJSON = try JSONEncoder().encode(original)
        #expect(original.version == 1 && original.segments.allSatisfy { $0.kind == nil })
        #expect(!String(decoding: originalJSON, as: UTF8.self).contains("\"kind\""))
        #expect(try JSONDecoder().decode(SourceTimingCorrection.self, from: originalJSON) == original)
        let segments = [original.segments[0],
            SourceTimingSegment(sourceStart: 5.5, sourceEnd: 7.5, alignedStart: 2.5,
                                rateRatio: 1.005, kind: .quietTransition), original.segments[1]]
        var quiet = SourceTimingCorrection(source: original.source, group: original.group, epoch: original.epoch,
            reference: original.reference, sourceRate: original.sourceRate, sourceFrames: original.sourceFrames,
            channelCount: original.channelCount, analysisDigest: original.analysisDigest,
            processing: original.processing, segments: segments)
        #expect(quiet.version == 2 && quiet.isValid)
        #expect(try JSONDecoder().decode(SourceTimingCorrection.self, from: JSONEncoder().encode(quiet)) == quiet)
        quiet.version = 1
        #expect(!quiet.isValid, "older applications must refuse quiet-derived timing, not mislabel it measured")
        quiet.version = 2
        quiet.segments[1].kind = nil
        #expect(!quiet.isValid)
    }

    @Test func guidedAndEstimatedTimingRequireVersionThreeAndRetainKindsOnDisk() throws {
        for kind in [SourceTimingSegment.Kind.anchorGuided, .estimated] {
            let original = correction()
            var value = SourceTimingCorrection(source: original.source, group: original.group,
                epoch: original.epoch, reference: original.reference, sourceRate: original.sourceRate,
                sourceFrames: original.sourceFrames, channelCount: original.channelCount,
                analysisDigest: original.analysisDigest, processing: original.processing,
                segments: [SourceTimingSegment(sourceStart: 2, sourceEnd: 5, alignedStart: 1, rateRatio: 1, kind: kind)])
            #expect(value.version == 3 && value.isValid)
            #expect(try JSONDecoder().decode(SourceTimingCorrection.self, from: JSONEncoder().encode(value)) == value)
            value.version = 2
            #expect(!value.isValid)
            value.version = 1
            #expect(!value.isValid)
        }
    }
}
