import Foundation
import Testing
import WWCommonEdit
import WWCore

@Suite("Reviewable clip fade editing")
struct AudioEnvelopeEditingTests {
    private func editing(_ envelope: AudioClipEnvelope = .init(), duration: Int64 = 480) throws -> AudioEnvelopeEditing {
        try .init(envelope: envelope, durationFrames: duration)
    }

    @Test func fullLowSilenceAndReverseSequencesCaptureCurrentLevelAndHold() throws {
        var curve = try editing().fade(from: 100, to: 200, direction: .fadeOut, target: 0.25)
            .confirmed(replacing: false)
        var evaluator = try editing(curve).evaluator
        #expect(try evaluator.amplitude(atLocalFrame: 0) == 1)
        #expect(try evaluator.amplitude(atLocalFrame: 150) == 0.625)
        #expect(try evaluator.amplitude(atLocalFrame: 300) == 0.25)
        curve = try editing(curve).fade(from: 300, to: 400, direction: .fadeOut, target: 0)
            .confirmed(replacing: false)
        evaluator = try editing(curve).evaluator
        #expect(curve.points.map(\.frame) == [100, 200, 300, 400])
        for (frame, value): (Int64, Double) in [(0, 1), (250, 0.25), (300, 0.25), (350, 0.125), (480, 0)] {
            #expect(try evaluator.amplitude(atLocalFrame: frame) == value)
        }
        curve = try editing().fade(from: 0, to: 100, direction: .fadeIn, target: 0.25,
                                    initialAmplitude: 0).confirmed(replacing: false)
        curve = try editing(curve).fade(from: 200, to: 300, direction: .fadeIn, target: 1)
            .confirmed(replacing: false)
        curve = try editing(curve).fade(from: 400, to: 480, direction: .fadeOut, target: 0)
            .confirmed(replacing: false)
        evaluator = try editing(curve).evaluator
        for (frame, value): (Int64, Double) in [(0, 0), (50, 0.125), (150, 0.25), (250, 0.625), (350, 1), (440, 0.5), (480, 0)] {
            #expect(try evaluator.amplitude(atLocalFrame: frame) == value)
        }
        let bytes = try JSONEncoder().encode(curve)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("inf"))
        #expect(try JSONDecoder().decode(AudioClipEnvelope.self, from: bytes) == curve)
    }

    @Test func rampIntersectionsAndLaterStartReplacementRequireExplicitReview() throws {
        let curve = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 1), .init(frame: 100, amplitude: 0.5),
            .init(frame: 200, amplitude: 0.5), .init(frame: 300, amplitude: 1),
            .init(frame: 400, amplitude: 0),
        ])
        let edit = try editing(curve).fade(from: 50, to: 150, direction: .fadeOut, target: 0.25)
        #expect(edit.overlapsRamp && edit.requiresReplacement)
        #expect(edit.replacedPoints == [curve.points[1], curve.points[2]])
        #expect(throws: AudioEnvelopeEditError.replacementRequired) { try edit.confirmed(replacing: false) }
        #expect(try edit.heldUntil == AudioEnvelopeCoordinate(numerator: 200))
        let result = try edit.confirmed(replacing: true)
        #expect(result.points.suffix(2) == curve.points.suffix(2), "Later ramp endpoints are never dropped.")
        let evaluator = try editing(result).evaluator
        #expect(try evaluator.amplitude(atLocalFrame: 50) == 0.75, "Capture the evaluated level, not the preceding stored knot.")
        #expect(try evaluator.amplitude(atLocalFrame: 175) == 0.25, "Hold the new endpoint until the next ramp start.")
        #expect(try evaluator.amplitude(atLocalFrame: 250) == 0.625)
        #expect(curve.points[2].amplitude == 0.5, "Preview never changes the original value.")
        let earlier = try editing(curve).fade(from: 10, to: 50, direction: .fadeOut, target: 0.25)
        #expect(try earlier.heldUntil == AudioEnvelopeCoordinate(numerator: 200))
        #expect(earlier.replacedPoints == [curve.points[1], curve.points[2]])
        let held = try editing(earlier.confirmed(replacing: true)).evaluator
        #expect(try held.amplitude(atLocalFrame: 75) == 0.25)
        #expect(try held.amplitude(atLocalFrame: 175) == 0.25,
                "Do not invent a bridging ramp across the overwritten ramp's tail or a later hold.")
    }

    @Test func explicitEndpointsFadeUnityAndPreserveAudioBeforeCustomStarts() throws {
        let unity = try editing().fade(from: 0, to: 100, direction: .fadeIn,
            target: 1, initialAmplitude: 0).confirmed(replacing: false)
        let unityEvaluator = try editing(unity).evaluator
        #expect(try unityEvaluator.amplitude(atLocalFrame: 0) == 0)
        #expect(try unityEvaluator.amplitude(atLocalFrame: 50) == 0.5)
        #expect(try unityEvaluator.amplitude(atLocalFrame: 100) == 1)
        let original = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 0.25), .init(frame: 200, amplitude: 1),
        ])
        let helper = try editing(original)
        for (direction, initial, target): (AudioFadeDirection, Double, Double) in [
            (.fadeIn, 0.1, 0.8), (.fadeOut, 0.8, 0.1),
        ] {
            let edit = try helper.fade(from: 100, to: 150, direction: direction,
                target: target, initialAmplitude: initial)
            #expect(edit.requiresReplacement)
            let evaluator = try editing(edit.confirmed(replacing: true)).evaluator
            for frame: Int64 in 0..<100 {
                #expect(abs(try evaluator.amplitude(atLocalFrame: frame)
                    - helper.evaluator.amplitude(atLocalFrame: frame)) < 1e-12)
            }
            #expect(try evaluator.amplitude(atLocalFrame: 100) == initial)
            #expect(abs(try evaluator.amplitude(atLocalFrame: 125) - (initial + target) / 2) < 1e-12)
            #expect(try evaluator.amplitude(atLocalFrame: 150) == target)
            #expect(try evaluator.amplitude(atLocalFrame: 480) == target)
        }
    }

    @Test func retainedFractionalOriginsOutsideSupportAndOutputOwnershipSurviveFadesAndSplits() throws {
        let asset = AudioAsset(source: SourceID(), frameCount: 441, sampleRate: 44_100, channelCount: 2)
        var clip = AudioClip(track: AudioTrackID(), source: asset.source, trim: .init(startFrame: 0, endFrame: 441),
            anchor: .programOrigin(frame: 0), envelope: .init(points: [
                .init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1),
            ]))
        let trim = AudioSourceTrim(startFrame: 1, endFrame: 441)
        clip.envelope = try AudioEnvelopeEvaluator.trimmedEnvelope(of: clip, asset: asset, to: trim)
        clip.trim = trim
        let cropped = try AudioEnvelopeEvaluator(envelope: clip.envelope, durationFrames: 479).sliced(to: 2..<400)
        clip = try clip.selectingOutputFrames(2..<400, asset: asset, envelope: cropped)
        let before = clip
        let duration = try #require(clip.durationFrames(asset: asset))
        let edit = try editing(clip.envelope, duration: duration)
            .fade(from: 10, to: 20, direction: .fadeOut, target: 0)
        clip.envelope = try edit.confirmed(replacing: true)
        #expect(clip.trim == before.trim && clip.outputWindow == before.outputWindow)
        #expect(clip.envelope.window == before.envelope.window)
        #expect(clip.envelope.points.first == before.envelope.points.first)
        #expect(clip.envelope.points.last == before.envelope.points.last, "Outside-trim support stays byte-exact.")
        let evaluator = try editing(clip.envelope, duration: duration).evaluator
        #expect(try evaluator.amplitude(atLocalFrame: 20) == 0)
        #expect(try evaluator.amplitude(atLocalFrame: duration) == 0)
        let point = try #require(clip.envelope.points.first { $0.amplitude == 0 && $0 != before.envelope.points.first })
        let offset = try #require(before.envelope.window?.offset)
        #expect(try point.coordinate() == offset.adding(.init(numerator: 20)))
        let split = try evaluator.split(atLocalFrame: 2)
        let trailing = try editing(split.trailing, duration: duration - 2).evaluator
        for frame: Int64 in 0..<(duration - 2) {
            #expect(try trailing.amplitude(atLocalFrame: frame) == evaluator.amplitude(atLocalFrame: frame + 2))
        }
        #expect(try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(clip)) == clip)
    }

    @Test func numericPointEditsPreserveExactFractionsAndReviewCollisionsAndRemoval() throws {
        let offset = try AudioEnvelopeCoordinate(numerator: 160, denominator: 147)
        let curve = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 0), .init(frame: 100, amplitude: 0.5), .init(frame: 480, amplitude: 1),
        ], window: .init(offset: offset))
        let helper = try editing(curve, duration: 400)
        let local = try helper.localCoordinate(of: curve.points[1])
        #expect(try local == AudioEnvelopeCoordinate(numerator: 14_540, denominator: 147))
        let level = try helper.editingPoint(at: 1, to: local, amplitude: 0.25)
        #expect(level.envelope.points[1].fraction == nil && level.envelope.points[1].frame == 100)
        #expect(level.requiresReplacement)
        #expect(try level.confirmed(replacing: true).window == curve.window)
        #expect(throws: AudioEnvelopeEditError.retainedSupportIsReadOnly) { try helper.removingPoint(at: 0) }
        #expect(throws: AudioEnvelopeEditError.retainedSupportIsReadOnly) { try helper.removingPoint(at: 2) }
        let uncut = try editing(.init(points: [.init(frame: 0, amplitude: 0), .init(frame: 100, amplitude: 1)]))
        let collision = try uncut.editingPoint(at: 0, to: .init(numerator: 100), amplitude: 0.25)
        #expect(collision.replacedPoints.count == 2 && collision.envelope.points.count == 1)
        let removal = try editing(collision.envelope).removingPoint(at: 0)
        #expect(removal.envelope == .init())
        #expect(try editing(removal.envelope).evaluator.amplitude(atLocalFrame: 0) == 1)
    }

    @Test func graphicalTimingKeepsAmplitudeAndFractionalPhaseAndStopsBeforeNeighbors() throws {
        let fraction = try AudioEnvelopeCoordinate(numerator: 1, denominator: 2)
        let curve = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 1), .init(frame: 100, amplitude: 0.25, fraction: fraction),
            .init(frame: 200, amplitude: 0.25), .init(frame: 480, amplitude: 0),
        ], window: .init(offset: try .init(numerator: 1, denominator: 3)))
        let helper = try editing(curve, duration: 400)
        let moved = try helper.movingPointTime(at: 1, byFrames: 10)
        #expect(moved.points[1].frame == 110 && moved.points[1].fraction == fraction)
        #expect(moved.points[1].amplitude == 0.25 && moved.window == curve.window)
        #expect(moved.points[0] == curve.points[0] && moved.points.suffix(2) == curve.points.suffix(2))
        let right = try helper.movingPointTime(at: 1, byFrames: .max)
        #expect(right.points[1].frame == 199 && right.points[1].fraction == fraction)
        let left = try helper.movingPointTime(at: 1, byFrames: .min)
        #expect(left.points[1].frame == 0 && left.points[1].fraction == fraction)
        #expect(try helper.movingPointTime(at: 1, byFrames: 0) == curve)
        #expect(throws: AudioEnvelopeEditError.retainedSupportIsReadOnly) {
            try helper.movingPointTime(at: 0, byFrames: 10)
        }
    }

    @Test func graphicalFlatLevelsMoveBothEndpointsButNeverTheirTimesOrOtherKnots() throws {
        let curve = AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 1), .init(frame: 100, amplitude: 0.25),
            .init(frame: 200, amplitude: 0.25), .init(frame: 400, amplitude: 0),
        ])
        let helper = try editing(curve)
        let moved = try helper.settingFlatLevel(first: 1, last: 2, amplitude: 0.5)
        #expect(moved.points.map(\.frame) == curve.points.map(\.frame))
        #expect(moved.points.map(\.amplitude) == [1, 0.5, 0.5, 0])
        #expect(try helper.settingFlatLevel(first: 3, last: 3, amplitude: 0.1).points.map(\.amplitude)
            == [1, 0.25, 0.25, 0.1])
        #expect(throws: AudioEnvelopeEditError.invalidInterval) {
            try helper.settingFlatLevel(first: 0, last: 1, amplitude: 0.5)
        }
        #expect(throws: AudioEnvelopeEditError.invalidInterval) {
            try helper.settingFlatLevel(first: 1, last: 1, amplitude: 0.5)
        }
        #expect(throws: AudioEnvelopeEditError.invalidInterval) {
            try editing(curve, duration: 400).settingFlatLevel(first: 3, last: 3, amplitude: 0.5)
        }
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            #expect(throws: AudioEnvelopeError.invalidAmplitude) {
                try helper.settingFlatLevel(first: 1, last: 2, amplitude: value)
            }
        }
    }

    @Test func invalidFiniteBoundsDirectionsAndInputsRefuseWithoutChangingTheCurve() throws {
        let helper = try editing()
        for (start, end): (Int64, Int64) in [(-1, 100), (0, 0), (100, 99), (0, 481), (.min, .max), (480, 481)] {
            #expect(throws: AudioEnvelopeEditError.invalidInterval) {
                try helper.fade(from: start, to: end, direction: .fadeOut, target: 0)
            }
        }
        for target in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            #expect(throws: AudioEnvelopeError.invalidAmplitude) {
                try helper.fade(from: 0, to: 10, direction: .fadeOut, target: target)
            }
        }
        #expect(throws: AudioEnvelopeEditError.invalidDirection) {
            try helper.fade(from: 0, to: 10, direction: .fadeIn, target: 1)
        }
        #expect(throws: AudioEnvelopeEditError.invalidDirection) {
            try helper.fade(from: 0, to: 10, direction: .fadeOut, target: 1)
        }
        for initial in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            #expect(throws: AudioEnvelopeError.invalidAmplitude) {
                try helper.fade(from: 0, to: 10, direction: .fadeIn, target: 1, initialAmplitude: initial)
            }
        }
        for (direction, initial, target): (AudioFadeDirection, Double, Double) in [
            (.fadeIn, 0.8, 0.2), (.fadeOut, 0.2, 0.8), (.fadeIn, 0.5, 0.5), (.fadeOut, 0.5, 0.5),
        ] {
            #expect(throws: AudioEnvelopeEditError.invalidDirection) {
                try helper.fade(from: 0, to: 10, direction: direction, target: target, initialAmplitude: initial)
            }
        }
        #expect(throws: AudioEnvelopeEditError.unknownPoint) { try helper.removingPoint(at: 0) }
        #expect(helper.evaluator.envelope == .init())
    }
}
