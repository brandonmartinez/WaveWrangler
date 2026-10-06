import Foundation
import WWAlignEstimate
import WWAlignSegment
import WWCore
import WWTimeMap

// Seeded synthetic generator for WW-017 calibration. Test code only; renders in memory, never touches a file.
//
// Model: an analytic acoustic SCENE (events in scene time) heard by the timeline reference (t = u, no delay)
// and by one target recorder group. The target occurrence's CLOCK TRUTH is piecewise over its frames:
// each mapped piece is t(n) = a·(n/F) + b (group-clock offset 0), and inserted pieces have NO truth (their
// frames were never recorded at any instant). Planted discontinuities change the piece: dropped samples,
// inserted samples (noise or a repeat of the previous frames), a clock step, a recorder restart (pause plus
// a new rate) and a mid-file rate change. The segmenter only sees samples; scoring compares its map against
// this truth, never against its own fit.

/// SplitMix64 (Steele, Lea, Flood 2014): small, fast, fully deterministic across platforms. Same
/// definition as the WW-016 generator (WWAlignEstimateTests), copied because test targets cannot share code.
struct SplitMix64: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992.0 }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * unit() }
    /// Log-uniform in a positive range (small and large sizes equally represented per decade).
    mutating func logUniform(_ range: ClosedRange<Double>) -> Double { exp(uniform(log(range.lowerBound)...log(range.upperBound))) }
    mutating func bool() -> Bool { next() & 1 == 1 }
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-300), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// Case seed: master seed mixed with the stratum name (FNV-1a 64) and the case index.
    static func caseSeed(master: UInt64, stratum: String, index: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in stratum.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        var mixer = SplitMix64(seed: master ^ hash ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15))
        return mixer.next()
    }
}

struct SceneEvent: Sendable {
    enum Shape: Sendable {
        case pulse(sigma: Double)
        case chirp(sigma: Double, centreHz: Double, sweepRate: Double, phase: Double)
    }
    let time: Double
    let amplitude: Double
    let shape: Shape

    var support: Double {
        switch shape {
        case .pulse(let s), .chirp(let s, _, _, _): 4.5 * s
        }
    }

    func value(at tau: Double) -> Double {
        let x = tau - time
        switch shape {
        case .pulse(let s):
            return amplitude * exp(-0.5 * x * x / (s * s))
        case .chirp(let s, let fc, let k, let phase):
            return amplitude * exp(-0.5 * x * x / (s * s)) * cos(2 * Double.pi * (fc * x + 0.5 * k * x * x) + phase)
        }
    }
}

struct Scene: Sendable {
    let events: [SceneEvent]

    /// Poisson events at `rate` per second over `range` (scene seconds), half pulses, half chirps.
    static func random(_ rng: inout SplitMix64, range: ClosedRange<Double>, rate: Double = 4) -> Scene {
        var events: [SceneEvent] = []
        var t = range.lowerBound
        while true {
            t += -log(max(rng.unit(), 1e-300)) / rate
            guard t < range.upperBound else { break }
            events.append(randomEvent(&rng, at: t))
        }
        return Scene(events: events)
    }

    static func randomEvent(_ rng: inout SplitMix64, at time: Double) -> SceneEvent {
        if rng.bool() {
            return SceneEvent(time: time, amplitude: rng.uniform(0.3...0.8), shape: .pulse(sigma: rng.uniform(0.0002...0.0006)))
        }
        let sigma = rng.uniform(0.010...0.040)
        let sweepHz = rng.uniform(600...900) * (rng.bool() ? 1 : -1)
        return SceneEvent(time: time, amplitude: rng.uniform(0.05...0.2),
                          shape: .chirp(sigma: sigma, centreHz: rng.uniform(600...1300), sweepRate: sweepHz / (4 * sigma), phase: rng.uniform(0...(2 * Double.pi))))
    }

    /// Strong events only the target hears: loud clicks and dense noise-like bursts (near-miss negatives).
    static func transients(_ rng: inout SplitMix64, range: ClosedRange<Double>, count: Int) -> Scene {
        var events: [SceneEvent] = []
        for _ in 0..<count {
            let t = rng.uniform(range)
            if rng.bool() {
                events.append(SceneEvent(time: t, amplitude: rng.uniform(1.5...3), shape: .pulse(sigma: rng.uniform(0.0003...0.001))))
            } else {
                let length = rng.uniform(0.2...0.5)
                for _ in 0..<Int(length * 600) {
                    events.append(SceneEvent(time: t + rng.uniform(0...length), amplitude: rng.uniform(-1.2...1.2), shape: .pulse(sigma: rng.uniform(0.0002...0.0005))))
                }
            }
        }
        return Scene(events: events)
    }

    func removing(_ range: ClosedRange<Double>) -> Scene { Scene(events: events.filter { !range.contains($0.time) }) }
}

enum PlantKind: String, CaseIterable, Sendable {
    case dropped, inserted, clockStep, restart, rateChange
}

/// One planted discontinuity, with its independent truth.
struct Plant: Sendable {
    let kind: PlantKind
    /// First frame after the discontinuity (for an insertion, the first inserted frame).
    let frame: Int
    /// Inserted frames (no truth), for `.inserted`.
    let inserted: Range<Int>?
    /// Planted change of aligned − group-clock time at the discontinuity, seconds (0 for a rate change).
    let stepSeconds: Double
    /// Planted change of rate, ppm (0 unless restart or rate change).
    let deltaPPM: Double
    /// For insertions: whether the inserted frames repeat the preceding frames (otherwise noise).
    let repeatsContent: Bool
}

/// Piecewise clock truth of the target occurrence (group-clock offset 0: u = n/F).
struct OccurrenceTruth: Sendable {
    enum Content: Sendable, Equatable {
        case mapped(a: Double, b: Double)
        case inserted(repeatsContent: Bool)
    }
    struct Piece: Sendable {
        let frames: Range<Int>
        let content: Content
    }
    let rate: Int
    let pieces: [Piece]

    var frameCount: Int { pieces.last!.frames.upperBound }

    func pieceIndex(ofFrame n: Int) -> Int { pieces.firstIndex { $0.frames.contains(n) }! }

    /// Aligned (reference) time of frame n, or nil for inserted frames.
    func time(ofFrame n: Int) -> Double? {
        guard case .mapped(let a, let b) = pieces[pieceIndex(ofFrame: n)].content else { return nil }
        return a * Double(n) / Double(rate) + b
    }

    /// Builds the truth from the first piece's clock and the plants (sorted by frame).
    static func build(rate: Int, frameCount: Int, ppm: Double, offset: Double, plants: [Plant], restartPPM: [Double]) -> OccurrenceTruth {
        let f = Double(rate)
        var pieces: [Piece] = []
        var a = 1 + ppm * 1e-6, b = offset
        var start = 0
        var restarts = restartPPM.makeIterator()
        for plant in plants {
            pieces.append(Piece(frames: start..<plant.frame, content: .mapped(a: a, b: b)))
            let u = Double(plant.frame) / f
            switch plant.kind {
            case .dropped, .clockStep:
                b += plant.stepSeconds
                start = plant.frame
            case .inserted:
                let range = plant.inserted!
                pieces.append(Piece(frames: range, content: .inserted(repeatsContent: plant.repeatsContent)))
                b += plant.stepSeconds
                start = range.upperBound
            case .restart:
                let newA = 1 + restarts.next()! * 1e-6
                b = a * u + b + plant.stepSeconds - newA * u
                a = newA
                start = plant.frame
            case .rateChange:
                let newA = a + plant.deltaPPM * 1e-6
                b = a * u + b - newA * u
                a = newA
                start = plant.frame
            }
        }
        pieces.append(Piece(frames: start..<frameCount, content: .mapped(a: a, b: b)))
        return OccurrenceTruth(rate: rate, pieces: pieces)
    }
}

struct TrackRender: Sendable {
    let scene: Scene
    let gain: Double
    let delay: Double
}

/// One fully specified case: everything needed to render both tracks and score the result.
struct SegmentCase: Sendable {
    let stratum: SegmentStratum
    let index: Int
    let seed: UInt64
    let lengthSeconds: Double
    let truth: OccurrenceTruth
    let plants: [Plant]
    let scene: Scene
    let target: [TrackRender]
    /// Target frames muted (noise floor only), for the muted silence-gap negative.
    let mute: Range<Int>?
    let referenceNoise: Double
    let targetNoise: Double
    let referenceNoiseSeed: UInt64
    let targetNoiseSeed: UInt64
    let searchDeviation: Double

    static let referenceRate = 8000
    static let referenceStart = -3.0

    var referenceDuration: Double { lengthSeconds + 10 }

    func renderReference() -> [Float] {
        let rate = Double(Self.referenceRate)
        let count = Int((referenceDuration * rate).rounded())
        var samples = [Double](repeating: 0, count: count)
        for event in scene.events {
            let nLo = max(0, Int(((event.time - event.support - Self.referenceStart) * rate).rounded(.down)))
            let nHi = min(count - 1, Int(((event.time + event.support - Self.referenceStart) * rate).rounded(.up)))
            guard nLo <= nHi else { continue }
            for n in nLo...nHi { samples[n] += event.value(at: Self.referenceStart + Double(n) / rate) }
        }
        var noise = SplitMix64(seed: referenceNoiseSeed)
        return samples.map { Float($0 + referenceNoise * noise.gaussian()) }
    }

    func renderTarget() -> [Float] {
        let f = Double(truth.rate)
        var samples = [Double](repeating: 0, count: truth.frameCount)
        for piece in truth.pieces {
            guard case .mapped(let a, let b) = piece.content else { continue }
            for hearing in target {
                for event in hearing.scene.events {
                    // Frames whose heard scene time a·u + b − delay falls within the event's support.
                    let uLo = (event.time - event.support + hearing.delay - b) / a
                    let uHi = (event.time + event.support + hearing.delay - b) / a
                    let nLo = max(piece.frames.lowerBound, Int((uLo * f).rounded(.down)))
                    let nHi = min(piece.frames.upperBound - 1, Int((uHi * f).rounded(.up)))
                    guard nLo <= nHi else { continue }
                    for n in nLo...nHi {
                        let tau = a * Double(n) / f + b - hearing.delay
                        samples[n] += hearing.gain * event.value(at: tau)
                    }
                }
            }
        }
        for piece in truth.pieces {
            guard case .inserted(let repeats) = piece.content, repeats else { continue }
            let length = piece.frames.count
            for n in piece.frames { samples[n] = samples[n - length] }
        }
        if let mute { for n in mute { samples[n] = 0 } }
        var noise = SplitMix64(seed: targetNoiseSeed)
        return samples.map { Float($0 + targetNoise * noise.gaussian()) }
    }

    /// The segmentation request for this case: one declared span covering the whole occurrence.
    func request() throws -> SegmentationRequest {
        let referenceGroup = RecorderGroupID(), targetGroup = RecorderGroupID()
        let referenceTrack = EstimatorTrack(
            group: referenceGroup, epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
            groupClockStart: try ExactRational(Int64(Self.referenceStart * 1000), 1000),
            buffer: try SampleBuffer(samples: renderReference(), sampleRate: Self.referenceRate))
        let occurrence = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(Int64(truth.rate)), frameCount: Int64(truth.frameCount))
        let buffer = try SampleBuffer(samples: renderTarget(), sampleRate: truth.rate)
        return SegmentationRequest(
            reference: referenceTrack, group: targetGroup, occurrence: occurrence, buffer: buffer,
            declaredSpans: [DeclaredSpan(frames: 0..<Int64(truth.frameCount), epoch: RecordingEpochID(), groupClockOffset: .zero)],
            search: try SearchRange(centerOffsetSeconds: 0, maximumDeviationSeconds: searchDeviation))
    }
}
