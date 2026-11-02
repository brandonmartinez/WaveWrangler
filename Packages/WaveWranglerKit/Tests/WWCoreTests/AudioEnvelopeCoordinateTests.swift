import Foundation
import Testing
import WWCore

@Suite("Bounded exact envelope coordinates")
struct AudioEnvelopeCoordinateTests {
    @Test func reductionOrderingFractionsAndCanonicalCodableAreExact() throws {
        let value = try AudioEnvelopeCoordinate(numerator: 320, denominator: 294)
        #expect(value.numerator == 160 && value.denominator == 147)
        #expect(value.floorFrame == 1)
        #expect(try value.fractionalPart == AudioEnvelopeCoordinate(numerator: 13, denominator: 147))
        let negative = try AudioEnvelopeCoordinate(numerator: -160, denominator: 147)
        #expect(negative.floorFrame == -2)
        #expect(try negative.fractionalPart == AudioEnvelopeCoordinate(numerator: 134, denominator: 147))
        #expect(try value.adding(value) == AudioEnvelopeCoordinate(numerator: 320, denominator: 147))
        #expect(try value > AudioEnvelopeCoordinate(numerator: 1))
        #expect(try JSONDecoder().decode(AudioEnvelopeCoordinate.self, from: JSONEncoder().encode(value)) == value)
        #expect(throws: AudioEnvelopeCoordinateError.nonCanonical) {
            try JSONDecoder().decode(
                AudioEnvelopeCoordinate.self, from: Data(#"{"numerator":320,"denominator":294}"#.utf8))
        }
        #expect(throws: AudioEnvelopeCoordinateError.unrepresentableDenominator) {
            try AudioEnvelopeCoordinate(numerator: 1, denominator: 191_999)
                .adding(AudioEnvelopeCoordinate(numerator: 160, denominator: 147))
        }
        #expect(throws: AudioEnvelopeCoordinateError.outsideEnvelope) {
            try AudioEnvelopeCoordinate(numerator: .max)
        }
        #expect(throws: AudioEnvelopeCoordinateError.outsideEnvelope) {
            try AudioEnvelopeCoordinate(numerator: AudioEnvelopeCoordinate.maximumMagnitude)
                .adding(AudioEnvelopeCoordinate(numerator: 1))
        }
        #expect(throws: AudioEnvelopeCoordinateError.invalidDenominator) {
            try AudioEnvelopeCoordinate(numerator: 1, denominator: .min)
        }
    }

    @Test func oldIntegerBytesAndZeroDefaultsStayUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = AudioClipEnvelope(points: [.init(frame: 0, amplitude: 0), .init(frame: 100, amplitude: 1)])
        #expect(
            try String(decoding: encoder.encode(envelope), as: UTF8.self)
                == #"{"points":[{"amplitude":0,"frame":0},{"amplitude":1,"frame":100}]}"#)
        #expect(try JSONDecoder().decode(AudioClipEnvelope.self, from: encoder.encode(envelope)) == envelope)
        let point = AudioEnvelopePoint(frame: 0, amplitude: 0, fraction: .zero)
        #expect(point.fraction == nil)
        #expect(try String(decoding: encoder.encode(AudioEnvelopeWindow()), as: UTF8.self) == "{}")
        #expect(AudioClipEnvelope().isValid(durationFrames: 100))
    }

    @Test func currentClippedDomainAndNearestSupportKnotsAreValidated() throws {
        let phase = try AudioEnvelopeCoordinate(numerator: 160, denominator: 147)
        let curve = AudioClipEnvelope(
            points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)],
            window: .init(offset: phase))
        #expect(curve.isValid(durationFrames: 479))
        #expect(!AudioClipEnvelope(points: curve.points).isValid(durationFrames: 479))
        let fractional = try AudioClipEnvelope(points: [
            .init(frame: 0, amplitude: 0, fraction: AudioEnvelopeCoordinate(numerator: 1, denominator: 3)),
            .init(frame: 0, amplitude: 1, fraction: AudioEnvelopeCoordinate(numerator: 2, denominator: 3)),
        ])
        #expect(fractional.isValid(durationFrames: 1))
        var invalid = fractional
        invalid.points.reverse()
        #expect(!invalid.isValid(durationFrames: 1))
        invalid = fractional
        invalid.points[0].fraction = try .init(numerator: 4, denominator: 3)
        #expect(!invalid.isValid(durationFrames: 1))
        #expect(
            !AudioClipEnvelope(
                points: [.init(frame: 0, amplitude: 0), .init(frame: 1, amplitude: 1)],
                window: .init(offset: try .init(numerator: 2))
            ).isValid(durationFrames: 10))
        #expect(
            !AudioClipEnvelope(
                points: [.init(frame: 11, amplitude: 0), .init(frame: 12, amplitude: 1)],
                window: .init()
            ).isValid(durationFrames: 10))
        #expect(!AudioClipEnvelope(window: .init()).isValid(durationFrames: 10))
        #expect(
            !AudioClipEnvelope(
                points: [.init(frame: 0, amplitude: 0)],
                window: .init(offset: try .init(numerator: AudioArrangement.frameLimit + 1))
            ).isValid(durationFrames: 10))
        #expect(
            !AudioClipEnvelope(
                points: [.init(frame: 0, amplitude: 0)],
                window: .init(offset: try .init(numerator: -1))
            ).isValid(durationFrames: 10))
    }

    @Test func phaseAndFractionChangesInvalidateProgramInputsButNeverRecordingInputs() throws {
        let source = SourceRecord(displayNameHint: "Generated", purpose: .supplementalAudio)
        let track = AudioTrack(name: "Audio")
        let clip = AudioClip(
            track: track.id, source: source.id, trim: .init(startFrame: 0, endFrame: 441),
            anchor: .programOrigin(frame: 0), envelope: .init(points: [.init(frame: 10, amplitude: 0.5)]))
        let episode = Episode(
            title: "Audio only", sources: [source],
            audioArrangement: .init(
                assets: [.init(source: source.id, frameCount: 441, sampleRate: 44_100, channelCount: 1)],
                tracks: [track], clips: [clip]))
        for field in ["window", "fraction"] {
            var changed = episode
            if field == "window" {
                changed.audioArrangement?.clips[0].envelope.window = .init(
                    offset: try .init(numerator: 160, denominator: 147))
            } else {
                changed.audioArrangement?.clips[0].envelope.points[0].fraction = try .init(
                    numerator: 13, denominator: 147)
            }
            #expect(changed.audioArrangement?.validationIssues(in: changed).isEmpty == true)
            #expect(!EpisodeProcessingInputs(episode).hasSameProgramInputs(as: EpisodeProcessingInputs(changed)))
            #expect(EpisodeMediaInputs(episode) == EpisodeMediaInputs(changed))
        }
    }
}
