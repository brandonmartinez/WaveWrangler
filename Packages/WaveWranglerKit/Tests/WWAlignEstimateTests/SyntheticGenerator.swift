import Foundation

// Seeded synthetic generator for WW-016 calibration. Test code only; renders in memory, never touches a file.
//
// Model: an analytic acoustic SCENE (events in scene time). A recorder sample at group-clock time u has
// CLOCK TRUTH t = truth(u) (aligned/reference time; piecewise-affine) and hears every scene it is exposed to
// at scene time t - delay(u). The timeline reference has t = u and no delay. The estimator only sees samples;
// scoring compares its map against `ClockTruth`, never against its own fit or the acoustic delay.

/// SplitMix64 (Steele, Lea, Flood 2014): small, fast, fully deterministic across platforms.
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

    /// Uniform in [0, 1) with 53 random bits.
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992.0 }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * unit() }
    mutating func bool() -> Bool { next() & 1 == 1 }
    /// Standard normal (Box-Muller, one value per call).
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
        /// Gaussian click.
        case pulse(sigma: Double)
        /// Gaussian-windowed linear chirp: instantaneous frequency centreHz + sweepRate * x.
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

    /// The same event (fixed shape) repeated every `period` seconds: correlation cannot tell repeats apart.
    static func periodic(_ rng: inout SplitMix64, range: ClosedRange<Double>, period: Double) -> Scene {
        let a = randomEvent(&rng, at: 0, forceChirp: true)
        let b = randomEvent(&rng, at: 0.3 * period)
        var events: [SceneEvent] = []
        var t = range.lowerBound
        while t < range.upperBound {
            events.append(SceneEvent(time: t, amplitude: a.amplitude, shape: a.shape))
            events.append(SceneEvent(time: t + 0.3 * period, amplitude: b.amplitude, shape: b.shape))
            t += period
        }
        return Scene(events: events)
    }

    static func randomEvent(_ rng: inout SplitMix64, at time: Double, forceChirp: Bool = false) -> SceneEvent {
        if !forceChirp && rng.bool() {
            return SceneEvent(time: time, amplitude: rng.uniform(0.3...0.8), shape: .pulse(sigma: rng.uniform(0.0002...0.0006)))
        }
        let sigma = rng.uniform(0.010...0.040)
        let sweepHz = rng.uniform(600...900) * (rng.bool() ? 1 : -1) // across +/- 2 sigma
        return SceneEvent(time: time, amplitude: rng.uniform(0.05...0.2),
                          shape: .chirp(sigma: sigma, centreHz: rng.uniform(600...1300), sweepRate: sweepHz / (4 * sigma), phase: rng.uniform(0...(2 * Double.pi))))
    }
}

/// Independent clock truth: t = a*u + b, plus an optional undeclared step (dropped samples / clock jump).
struct ClockTruth: Sendable {
    let ppm: Double
    let offset: Double
    var step: (at: Double, amount: Double)?

    var a: Double { 1 + ppm * 1e-6 }
    func aligned(_ u: Double) -> Double {
        var t = a * u + offset
        if let step, u >= step.at { t += step.amount }
        return t
    }
    var stepBounds: (Double, Double) { (min(0, step?.amount ?? 0), max(0, step?.amount ?? 0)) }
}

/// Acoustic propagation delay heard by a recorder (seconds, as a function of its group-clock time).
enum DelayModel: Sendable {
    case none
    case constant(Double)
    /// Linear from `from` (at u0) to `to` (at u1), plus a slow sinusoid.
    case ramp(from: Double, to: Double, u0: Double, u1: Double, wobble: Double, wobblePeriod: Double)

    func delay(_ u: Double) -> Double {
        switch self {
        case .none: return 0
        case .constant(let d): return d
        case .ramp(let from, let to, let u0, let u1, let wobble, let period):
            let f = min(1, max(0, (u - u0) / (u1 - u0)))
            return from + (to - from) * f + wobble * sin(2 * Double.pi * u / period)
        }
    }

    var bounds: (Double, Double) {
        switch self {
        case .none: return (0, 0)
        case .constant(let d): return (d, d)
        case .ramp(let from, let to, _, _, let wobble, _): return (min(from, to) - abs(wobble), max(from, to) + abs(wobble))
        }
    }
}

struct Hearing: Sendable {
    let scene: Scene
    let gain: Double
    let delay: DelayModel
}

struct TrackRecipe: Sendable {
    let sampleRate: Int
    let duration: Double
    /// Group-clock time of sample 0.
    let groupClockStart: Double
    let truth: ClockTruth
    let hearings: [Hearing]
    let noiseRMS: Double
    let noiseSeed: UInt64

    var frameCount: Int { Int((duration * Double(sampleRate)).rounded()) }

    func render() -> [Float] {
        let rate = Double(sampleRate)
        let count = frameCount
        var samples = [Double](repeating: 0, count: count)
        let a = truth.a
        let (stepLo, stepHi) = truth.stepBounds
        for hearing in hearings {
            let (dLo, dHi) = hearing.delay.bounds
            for event in hearing.scene.events {
                // u range whose heard scene time t(u) - d(u) can fall within the event's support.
                let uLo = (event.time - event.support - truth.offset - stepHi + dLo) / a
                let uHi = (event.time + event.support - truth.offset - stepLo + dHi) / a
                let nLo = max(0, Int(((uLo - groupClockStart) * rate).rounded(.down)) - 1)
                let nHi = min(count - 1, Int(((uHi - groupClockStart) * rate).rounded(.up)) + 1)
                guard nLo <= nHi else { continue }
                for n in nLo...nHi {
                    let u = groupClockStart + Double(n) / rate
                    let tau = truth.aligned(u) - hearing.delay.delay(u)
                    let x = tau - event.time
                    if abs(x) <= event.support { samples[n] += hearing.gain * event.value(at: tau) }
                }
            }
        }
        var noise = SplitMix64(seed: noiseSeed)
        return samples.map { Float($0 + noiseRMS * noise.gaussian()) }
    }
}
