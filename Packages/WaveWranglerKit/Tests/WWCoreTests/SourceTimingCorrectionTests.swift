import Foundation
import Testing
import WWCore

@Suite("Portable source-local timing corrections")
struct SourceTimingCorrectionTests {
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
