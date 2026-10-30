import Foundation
import Testing
import WWCommonEdit
import WWCore

@Suite("Clip-local amplitude envelope")
struct AudioEnvelopeEvaluatorTests {
    private let curve = AudioClipEnvelope(points: [
        .init(frame: 10, amplitude: 0), .init(frame: 30, amplitude: 1),
        .init(frame: 50, amplitude: 1), .init(frame: 90, amplitude: 0),
    ])

    @Test func unitySilenceHeldEndpointsAndExactLinearAmplitude() throws {
        let unity = try AudioEnvelopeEvaluator(envelope: .init(), durationFrames: 100)
        let silent = try AudioEnvelopeEvaluator(
            envelope: .init(points: [.init(frame: 50, amplitude: 0)]),
            durationFrames: 100)
        let evaluator = try AudioEnvelopeEvaluator(envelope: curve, durationFrames: 100)
        for frame: Int64 in 0...100 {
            #expect(try unity.amplitude(atLocalFrame: frame) == 1)
            #expect(try silent.amplitude(atLocalFrame: frame) == 0)
        }
        for (frame, amplitude): (Int64, Double) in [
            (0, 0), (10, 0), (15, 0.25), (20, 0.5), (30, 1),
            (40, 1), (50, 1), (60, 0.75), (70, 0.5), (90, 0), (100, 0),
        ] {
            #expect(try evaluator.amplitude(atLocalFrame: frame) == amplitude)
        }
        #expect(throws: AudioEnvelopeError.outsideClip(-1)) { try evaluator.amplitude(atLocalFrame: -1) }
        #expect(throws: AudioEnvelopeError.outsideClip(101)) { try evaluator.amplitude(atLocalFrame: 101) }
    }

    @Test func seeksAndAnyChunkPartitionEvaluateTheSameCurve() throws {
        let evaluator = try AudioEnvelopeEvaluator(envelope: curve, durationFrames: 100)
        let whole = try (Int64(0)..<100).map { try evaluator.amplitude(atLocalFrame: $0) }
        for width: Int64 in [1, 3, 7, 16, 51, 100] {
            var chunked: [Double] = []
            for start in stride(from: Int64(0), to: 100, by: Int(width)) {
                chunked += try (start..<min(100, start + width)).map {
                    try evaluator.amplitude(atLocalFrame: $0)
                }
            }
            #expect(chunked == whole)
        }
        for frame: Int64 in [99, 0, 50, 15, 90, 10, 31, 1] {
            #expect(try evaluator.amplitude(atLocalFrame: frame) == whole[Int(frame)])
        }
    }

    @Test func slicesRetainExactBoundarySupportAndSplitsShareTheSeam() throws {
        let evaluator = try AudioEnvelopeEvaluator(envelope: curve, durationFrames: 100)
        let slice = try evaluator.sliced(to: 20..<70)
        #expect(slice.points == curve.points)
        #expect(try slice.window?.offset == AudioEnvelopeCoordinate(numerator: 20))
        let retained = try AudioEnvelopeEvaluator(envelope: slice, durationFrames: 50)
        for frame: Int64 in 0...50 {
            #expect(
                abs(
                    try retained.amplitude(atLocalFrame: frame)
                        - evaluator.amplitude(atLocalFrame: frame + 20)) < 1e-14)
        }
        for seam: Int64 in 1..<100 {
            let split = try evaluator.split(atLocalFrame: seam)
            let leading = try AudioEnvelopeEvaluator(envelope: split.leading, durationFrames: seam)
            let trailing = try AudioEnvelopeEvaluator(envelope: split.trailing, durationFrames: 100 - seam)
            #expect(try leading.amplitude(atLocalFrame: seam) == trailing.amplitude(atLocalFrame: 0))
            for frame: Int64 in 0...100 {
                let result =
                    try frame <= seam
                    ? leading.amplitude(atLocalFrame: frame)
                    : trailing.amplitude(atLocalFrame: frame - seam)
                #expect(abs(try result - evaluator.amplitude(atLocalFrame: frame)) < 1e-14)
            }
        }
        #expect(evaluator.envelope == curve)
        #expect(
            try AudioEnvelopeEvaluator(envelope: .init(), durationFrames: 10)
                .sliced(to: 1..<2) == AudioClipEnvelope())
    }

    @Test func nativeTrimsKeepTheirGridAndExactFractionalCurvePhase() throws {
        let asset = AudioAsset(source: SourceID(), frameCount: 441, sampleRate: 44_100, channelCount: 2)
        let clip = AudioClip(
            track: AudioTrackID(), source: asset.source,
            trim: .init(startFrame: 0, endFrame: 441), anchor: .programOrigin(frame: 0),
            envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)]))
        let trim = AudioSourceTrim(startFrame: 147, endFrame: 294)
        let envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: clip, asset: asset, to: trim)
        #expect(envelope.points == clip.envelope.points)
        #expect(try envelope.window?.offset == AudioEnvelopeCoordinate(numerator: 160))
        let evaluator = try AudioEnvelopeEvaluator(envelope: envelope, durationFrames: 160)
        #expect(try evaluator.amplitude(atLocalFrame: 0) == 1.0 / 3)
        #expect(try evaluator.amplitude(atLocalFrame: 160) == 2.0 / 3)
        #expect(clip.trim == .init(startFrame: 0, endFrame: 441))
        #expect(asset.frameCount == 441)
        let offGrid = try AudioEnvelopeEvaluator.trimmedEnvelope(
            of: clip, asset: asset,
            to: .init(startFrame: 1, endFrame: 441))
        #expect(try offGrid.window?.offset == AudioEnvelopeCoordinate(numerator: 160, denominator: 147))
        #expect(
            try AudioEnvelopeEvaluator(envelope: offGrid, durationFrames: 479).amplitude(atLocalFrame: 0) == 1.0 / 441)
        let roundedEnd = try AudioEnvelopeEvaluator.trimmedEnvelope(
            of: clip, asset: asset,
            to: .init(startFrame: 147, endFrame: 295))
        #expect(
            try AudioEnvelopeEvaluator(envelope: roundedEnd, durationFrames: 162).amplitude(atLocalFrame: 162)
                == 322.0 / 480)
        #expect(throws: AudioEnvelopeError.invalidNativeTrim) {
            try AudioEnvelopeEvaluator.trimmedEnvelope(
                of: clip, asset: asset,
                to: .init(startFrame: 0, endFrame: 442))
        }
    }

    @Test func fractionalTrimFadeEditsFurtherTrimNativeSplitAndReopenPreserveTheContinuousCurve() throws {
        let asset = AudioAsset(source: SourceID(), frameCount: 4_410, sampleRate: 44_100, channelCount: 2)
        let original = AudioClip(
            track: AudioTrackID(), source: asset.source,
            trim: .init(startFrame: 0, endFrame: 4_410), anchor: .programOrigin(frame: 0),
            envelope: .init(points: [
                .init(frame: 0, amplitude: 0), .init(frame: 2_400, amplitude: 0.75),
                .init(frame: 4_800, amplitude: 0),
            ]))
        var first = original
        first.trim.startFrame = 1
        first.envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: original, asset: asset, to: first.trim)
        let firstDuration = try #require(first.durationFrames(asset: asset))
        let beforeEdit = try AudioEnvelopeEvaluator(envelope: first.envelope, durationFrames: firstDuration)
        first.envelope = try beforeEdit.settingPoint(atLocalFrame: 10, amplitude: 0.25)
        var edited = try AudioEnvelopeEvaluator(envelope: first.envelope, durationFrames: firstDuration)
        first.envelope = try edited.settingPoint(atLocalFrame: 10, amplitude: 0.5)
        edited = try AudioEnvelopeEvaluator(envelope: first.envelope, durationFrames: firstDuration)
        first.envelope = try edited.settingPoint(atLocalFrame: firstDuration, amplitude: 0)
        #expect(first.envelope.points.count == original.envelope.points.count + 2)
        let fade = try #require(first.envelope.points.first { $0.amplitude == 0.5 })
        #expect(fade.frame == 11)
        #expect(try fade.fraction == AudioEnvelopeCoordinate(numerator: 13, denominator: 147))
        edited = try AudioEnvelopeEvaluator(envelope: first.envelope, durationFrames: firstDuration)
        #expect(try edited.amplitude(atLocalFrame: 10) == 0.5)
        #expect(try edited.amplitude(atLocalFrame: firstDuration) == 0)
        var second = first
        second.trim = .init(startFrame: 2, endFrame: 4_400)
        second.envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: first, asset: asset, to: second.trim)
        let split = try AudioEnvelopeEvaluator.splitEnvelope(of: second, asset: asset, atNativeFrame: 147)
        var leading = second
        var trailing = second
        leading.trim.endFrame = 147
        leading.envelope = split.leading
        trailing.trim.startFrame = 147
        trailing.envelope = split.trailing
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for clip in [first, second, leading, trailing] {
            let reopened = try decoder.decode(AudioClip.self, from: encoder.encode(clip))
            #expect(reopened == clip)
            let duration = try #require(clip.durationFrames(asset: asset))
            let evaluator = try AudioEnvelopeEvaluator(envelope: reopened.envelope, durationFrames: duration)
            let delta = try AudioEnvelopeCoordinate(numerator: (clip.trim.startFrame - 1) * 48_000, denominator: 44_100)
            for frame: Int64 in [0, 1, min(10, duration), duration / 2, duration - 1] {
                let coordinate = try delta.adding(AudioEnvelopeCoordinate(numerator: frame))
                #expect(try evaluator.amplitude(atLocalFrame: frame) == edited.amplitude(atLocalCoordinate: coordinate))
            }
            for fraction in [
                try AudioEnvelopeCoordinate(numerator: 1, denominator: 3),
                try AudioEnvelopeCoordinate(numerator: 7, denominator: 11),
            ] {
                #expect(
                    try evaluator.amplitude(atLocalCoordinate: fraction)
                        == edited.amplitude(atLocalCoordinate: delta.adding(fraction)))
            }
        }
        var successive = first
        for start: Int64 in 2...148 {
            let trim = AudioSourceTrim(startFrame: start, endFrame: first.trim.endFrame)
            successive.envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: successive, asset: asset, to: trim)
            successive.trim = trim
            successive = try decoder.decode(AudioClip.self, from: encoder.encode(successive))
        }
        let direct = try AudioEnvelopeEvaluator.trimmedEnvelope(of: first, asset: asset, to: successive.trim)
        #expect(successive.envelope == direct, "No new rounded boundary amplitudes may accumulate")
        #expect(original.envelope.window == nil)
        #expect(original.trim.startFrame == 0)
    }

    @Test func nativeSplitCEILOwnershipDoesNotPretendToBeSampleForSampleDSPConcatenation() throws {
        let asset = AudioAsset(source: SourceID(), frameCount: 441, sampleRate: 44_100, channelCount: 1)
        let original = AudioClip(
            track: AudioTrackID(), source: asset.source,
            trim: .init(startFrame: 0, endFrame: 441), anchor: .programOrigin(frame: 0),
            envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)]))
        let split = try AudioEnvelopeEvaluator.splitEnvelope(of: original, asset: asset, atNativeFrame: 1)
        var leading = original
        var trailing = original
        leading.trim.endFrame = 1
        leading.envelope = split.leading
        trailing.trim.startFrame = 1
        trailing.envelope = split.trailing
        #expect(original.durationFrames(asset: asset) == 480)
        #expect(leading.durationFrames(asset: asset) == 2)
        #expect(trailing.durationFrames(asset: asset) == 479)
        #expect(
            try #require(leading.durationFrames(asset: asset)) + #require(trailing.durationFrames(asset: asset)) == 481)
        let right = try AudioEnvelopeEvaluator(envelope: trailing.envelope, durationFrames: 479)
        let whole = try AudioEnvelopeEvaluator(envelope: original.envelope, durationFrames: 480)
        #expect(try right.amplitude(atLocalFrame: 0) == 1.0 / 441)
        #expect(try right.amplitude(atLocalFrame: 0) != whole.amplitude(atLocalFrame: 2))
        #expect(try trailing.envelope.window?.offset == AudioEnvelopeCoordinate(numerator: 160, denominator: 147))
    }

    @Test(arguments: [8_000, 12_345, 44_100, 48_000, 88_200, 96_000, 191_999, 192_000])
    func supportedNativeRatesRetainEditableExactPhasesThroughRepeatedTrimsAndReopen(_ rate: Int) throws {
        let asset = AudioAsset(source: SourceID(), frameCount: Int64(rate), sampleRate: rate, channelCount: 1)
        var clip = AudioClip(
            track: AudioTrackID(), source: asset.source,
            trim: .init(startFrame: 0, endFrame: Int64(rate)), anchor: .programOrigin(frame: 0),
            envelope: .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 48_000, amplitude: 1)]))
        for start: Int64 in 1...12 {
            let trim = AudioSourceTrim(startFrame: start, endFrame: Int64(rate))
            clip.envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: clip, asset: asset, to: trim)
            clip.trim = trim
            let duration = try #require(clip.durationFrames(asset: asset))
            var evaluator = try AudioEnvelopeEvaluator(envelope: clip.envelope, durationFrames: duration)
            clip.envelope = try evaluator.settingPoint(atLocalFrame: 10, amplitude: 0.25)
            evaluator = try AudioEnvelopeEvaluator(envelope: clip.envelope, durationFrames: duration)
            clip.envelope = try evaluator.settingPoint(atLocalFrame: duration, amplitude: 0)
            let reopened = try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(clip))
            #expect(reopened == clip)
            let final = try AudioEnvelopeEvaluator(envelope: reopened.envelope, durationFrames: duration)
            #expect(try final.amplitude(atLocalFrame: 10) == 0.25)
            #expect(try final.amplitude(atLocalFrame: duration) == 0)
            #expect(
                try clip.envelope.window?.offset
                    == AudioEnvelopeCoordinate(numerator: start * 48_000, denominator: Int64(rate)))
        }
    }

    @Test func dayBoundsAndTrulyUnrepresentableExternalPhasesHaveVisibleOutcomes() throws {
        let day = AudioArrangement.frameLimit
        let evaluator = try AudioEnvelopeEvaluator(
            envelope: .init(
                points: [
                    .init(frame: 0, amplitude: 0), .init(frame: day * 2, amplitude: 1),
                ], window: .init(offset: try .init(numerator: day))), durationFrames: day)
        #expect(try evaluator.amplitude(atLocalFrame: 0) == 0.5)
        #expect(try evaluator.amplitude(atLocalFrame: day) == 1)
        #expect(throws: AudioEnvelopeError.outsideClip(.max)) { try evaluator.amplitude(atLocalFrame: .max) }
        #expect(throws: AudioEnvelopeError.invalidAmplitude) {
            try evaluator.settingPoint(atLocalFrame: 1, amplitude: .nan)
        }
        let asset = AudioAsset(source: SourceID(), frameCount: 441, sampleRate: 44_100, channelCount: 1)
        let clip = AudioClip(
            track: AudioTrackID(), source: asset.source,
            trim: .init(startFrame: 0, endFrame: 441), anchor: .programOrigin(frame: 0),
            envelope: .init(
                points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)],
                window: .init(offset: try .init(numerator: 1, denominator: 191_999))))
        #expect(throws: AudioEnvelopeError.coordinate(.unrepresentableDenominator)) {
            try AudioEnvelopeEvaluator.trimmedEnvelope(
                of: clip, asset: asset,
                to: .init(startFrame: 1, endFrame: 441))
        }
        let negative = try AudioEnvelopeCoordinate(numerator: -1)
        #expect(throws: AudioEnvelopeError.outsideClipCoordinate(negative)) {
            try evaluator.amplitude(atLocalCoordinate: negative)
        }
    }

    @Test func invalidShapesDurationsAndSlicesHaveTypedFailures() throws {
        for duration: Int64 in [0, -1, .max, AudioArrangement.frameLimit + 1] {
            #expect(throws: AudioEnvelopeError.invalidDuration(duration)) {
                try AudioEnvelopeEvaluator(envelope: .init(), durationFrames: duration)
            }
        }
        for points: [AudioEnvelopePoint] in [
            [.init(frame: -1, amplitude: 1)], [.init(frame: 11, amplitude: 0)],
            [.init(frame: 0, amplitude: .nan)], [.init(frame: 0, amplitude: .infinity)],
            [.init(frame: 0, amplitude: -0.1)], [.init(frame: 0, amplitude: 1.01)],
            [.init(frame: 1, amplitude: 0), .init(frame: 1, amplitude: 1)],
            [.init(frame: 2, amplitude: 0), .init(frame: 1, amplitude: 1)],
        ] {
            #expect(throws: AudioEnvelopeError.self) {
                try AudioEnvelopeEvaluator(envelope: .init(points: points), durationFrames: 10)
            }
        }
        let evaluator = try AudioEnvelopeEvaluator(envelope: curve, durationFrames: 100)
        for frames: Range<Int64> in [-1..<10, 10..<10, 90..<101] {
            #expect(throws: AudioEnvelopeError.invalidSlice(frames)) { try evaluator.sliced(to: frames) }
        }
        for frame: Int64 in [0, 100, .min, .max] {
            #expect(throws: AudioEnvelopeError.outsideClip(frame)) { try evaluator.split(atLocalFrame: frame) }
        }
    }
}
