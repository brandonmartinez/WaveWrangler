import Accelerate
import Foundation

public enum ExportNormalization: Sendable, Equatable {
    case off
    case podcast
    case custom(targetLUFS: Double, ceilingDBTP: Double)

    public static let maximumBoostDB = 24.0

    func targets(channels: Int) throws -> (loudness: Double, ceiling: Double)? {
        switch self {
        case .off: return nil
        case .podcast: return (channels == 1 ? -19 : -16, -1)
        case .custom(let target, let ceiling):
            guard target.isFinite, ceiling.isFinite, (-36 ... -9).contains(target),
                  (-12 ... -0.1).contains(ceiling) else {
                throw ExportFailure.invalidSettings("Loudness target must be -36...-9 LUFS and ceiling -12...-0.1 dBTP")
            }
            return (target, ceiling)
        }
    }
}

public struct ExportLoudnessMeasurement: Sendable, Equatable {
    /// Nil for no complete, absolute-gated 400 ms block; never a fabricated silence value.
    public let integratedLUFS: Double?
    /// Nil only for digital silence. Includes reconstruction-filter flush, not additional output frames.
    public let truePeakDBTP: Double?
}

public struct ExportLoudnessReport: Sendable, Equatable {
    public enum TargetStatus: Sendable, Equatable {
        case off, achieved, peakLimited, boostLimited, unmeasurable, targetMissed
    }
    public let measurement: ExportLoudnessMeasurement
    public let requestedTargetLUFS: Double?
    public let ceilingDBTP: Double?
    public let appliedGainDB: Double
    public let correctiveAttenuationDB: Double
    public let correctionPasses: Int
    public let targetStatus: TargetStatus
}

actor ExportLoudnessAccumulator {
    private var meter: ExportLoudnessMeter
    init(settings: ExportSettings) {
        meter = .init(sampleRate: settings.sampleRate, channels: settings.channels)
    }
    func append(_ samples: [Float]) throws { try meter.append(samples) }
    func finish() -> ExportLoudnessMeasurement { meter.finish() }
}

/// BS.1770 K weighting and 400 ms / 100 ms overlapping gates for mono/stereo.
/// A 0.01 LU energy histogram bounds state independently of program duration.
struct ExportLoudnessMeter {
    /// Reserve for differing reconstruction filters at hard program boundaries.
    static let ceilingReserveDB = 0.7
    private let channels: Int
    private let blockFrames: Int
    private let hopFrames: Int
    private var filters: [KFilter]
    private var peak: TruePeak
    private var energies: [Double]
    private var position = 0
    private var frames = 0
    private var energy = 0.0
    private var histogramEnergy = [Double](repeating: 0, count: 90_001)
    private var histogramCount = [Int64](repeating: 0, count: 90_001)

    init(sampleRate: Int, channels: Int) {
        self.channels = channels
        blockFrames = sampleRate * 4 / 10
        hopFrames = sampleRate / 10
        energies = [Double](repeating: 0, count: blockFrames)
        filters = (0..<channels).map { _ in KFilter(rate: Double(sampleRate)) }
        peak = TruePeak(channels: channels)
    }

    mutating func append(_ samples: [Float]) throws {
        guard samples.count % channels == 0, samples.allSatisfy(\.isFinite) else {
            throw ExportFailure.invalidPCM("Loudness measurement requires complete finite PCM")
        }
        for first in stride(from: 0, to: samples.count, by: channels) {
            var sum = 0.0
            for channel in 0..<channels {
                let value = Double(samples[first + channel])
                let weighted = filters[channel].process(value)
                sum += weighted * weighted
                peak.append(value, channel: channel)
            }
            energy += sum - energies[position]
            energies[position] = sum
            position = (position + 1) % blockFrames
            frames += 1
            if frames >= blockFrames, (frames - blockFrames) % hopFrames == 0 {
                let mean = max(0, energy / Double(blockFrames))
                let loudness = mean > 0 ? -0.691 + 10 * log10(mean) : -.infinity
                if loudness >= -70 {
                    let bin = min(histogramCount.count - 1, Int((loudness + 70) * 100))
                    histogramCount[bin] += 1
                    histogramEnergy[bin] += mean
                }
            }
        }
    }

    mutating func finish() -> ExportLoudnessMeasurement {
        var sum = 0.0
        var count: Int64 = 0
        for index in histogramCount.indices {
            sum += histogramEnergy[index]
            count += histogramCount[index]
        }
        var integrated: Double?
        if count > 0, sum > 0 {
            let relative = -0.691 + 10 * log10(sum / Double(count)) - 10
            sum = 0
            count = 0
            for index in histogramCount.indices where histogramCount[index] > 0 {
                let mean = histogramEnergy[index] / Double(histogramCount[index])
                if -0.691 + 10 * log10(mean) >= relative {
                    sum += histogramEnergy[index]
                    count += histogramCount[index]
                }
            }
            if count > 0 { integrated = -0.691 + 10 * log10(sum / Double(count)) }
        }
        return .init(integratedLUFS: integrated, truePeakDBTP: peak.finish())
    }
}

private struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

private struct KFilter {
    var shelf: Biquad
    var highpass: Biquad
    init(rate: Double) {
        let k = tan(.pi * 1_681.974450955533 / rate)
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let q = 0.7071752369554196
        let a = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a,
            b1: 2 * (k * k - vh) / a, b2: (vh - vb * k / q + k * k) / a,
            a1: 2 * (k * k - 1) / a, a2: (1 - k / q + k * k) / a)
        let h = tan(.pi * 38.13547087602444 / rate)
        let d = 1 + h / 0.5003270373238773 + h * h
        highpass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (h * h - 1) / d,
                         a2: (1 - h / 0.5003270373238773 + h * h) / d)
    }
    mutating func process(_ value: Double) -> Double { highpass.process(shelf.process(value)) }
}

/// Four-times polyphase reconstruction, 64 input taps/phase, Blackman-windowed sinc.
/// Includes raw samples and zero-extension at both edges. Delay exists only inside the meter.
private struct TruePeak {
    private static let coefficients: [[Double]] = (0..<4).map { phase in
        var taps = (0..<64).map { index -> Double in
            let x = Double(63 - index) - 32 + Double(phase) / 4
            let sinc = abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
            let window = 0.42 + 0.5 * cos(.pi * x / 32) + 0.08 * cos(2 * .pi * x / 32)
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        for index in taps.indices { taps[index] /= sum }
        return taps
    }
    private var history: [[Double]]
    private var positions: [Int]
    private var maximum = 0.0
    init(channels: Int) {
        history = [[Double]](repeating: [Double](repeating: 0, count: 128), count: channels)
        positions = [Int](repeating: 0, count: channels)
    }
    mutating func append(_ value: Double, channel: Int) {
        maximum = max(maximum, abs(value))
        let position = positions[channel]
        history[channel][position] = value
        history[channel][position + 64] = value
        let start = (position + 1) % 64
        history[channel].withUnsafeBufferPointer { data in
            for taps in Self.coefficients {
                var result = 0.0
                taps.withUnsafeBufferPointer {
                    vDSP_dotprD(data.baseAddress! + start, 1, $0.baseAddress!, 1, &result, 64)
                }
                maximum = max(maximum, abs(result))
            }
        }
        positions[channel] = start
    }
    mutating func finish() -> Double? {
        for _ in 0..<64 {
            for channel in history.indices { append(0, channel: channel) }
        }
        return maximum > 0 ? 20 * log10(maximum) : nil
    }
}
