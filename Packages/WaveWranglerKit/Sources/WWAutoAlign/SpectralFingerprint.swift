import Foundation
import WWAlignEstimate

/// A time-indexed description of an entire channel, not a recording-identification hash.
public struct SpectralFingerprint: Sendable {
    public static let identifier = "ww-spectral-fingerprint/1"
    public static let framesPerSecond = 50
    public static let maximumSeconds = 7200
    public let duration: Double
    public let bands: [[Float]]
    public let energy: [Float]

    public var frameCount: Int { energy.count }
    public var byteCount: Int { frameCount * 7 * MemoryLayout<Float>.size }

    public func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(16 + byteCount)
        for word in [UInt32(1), UInt32(frameCount), UInt32(duration.bitPattern & 0xffff_ffff), UInt32(duration.bitPattern >> 32)] {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for array in bands + [energy] {
            for sample in array {
                var value = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public init(encoded data: Data) throws {
        guard data.count >= 16 else { throw AlignEstimateError.invalidParameter("truncated fingerprint") }
        func word(_ at: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
        }
        let count = Int(word(4))
        let seconds = Double(bitPattern: UInt64(word(8)) | UInt64(word(12)) << 32)
        guard word(0) == 1, count <= Self.maximumSeconds * Self.framesPerSecond,
              seconds.isFinite, seconds > 0, seconds <= Double(Self.maximumSeconds),
              abs(count - max(0, Int(floor((seconds - 0.04) * 50 + 1e-6)) + 1)) <= 1,
              data.count == 16 + count * 28 else {
            throw AlignEstimateError.invalidParameter("unsupported fingerprint shape")
        }
        var arrays: [[Float]] = []
        for band in 0..<7 {
            let samples = (0..<count).map { Float(bitPattern: word(16 + (band * count + $0) * 4)) }
            guard samples.allSatisfy(\.isFinite) else { throw AlignEstimateError.invalidParameter("non-finite fingerprint") }
            arrays.append(samples)
        }
        duration = seconds
        bands = Array(arrays.prefix(6))
        energy = arrays[6]
    }

    init(duration: Double, bands: [[Float]], energy: [Float]) {
        self.duration = duration
        self.bands = bands
        self.energy = energy
    }
}

/// Retains only the feature index and an unfinished frame, independent of decoder chunk boundaries.
public struct SpectralFingerprintBuilder {
    private let rate: Int
    private let frameLength: Int
    private let transform: Transform
    private let window: [Double]
    private let bins: [Range<Int>]
    private var pending: [Float] = []
    private var pendingStart = 0
    private var received = 0
    private var bands = [[Float]](repeating: [], count: 6)
    private var energy: [Float] = []

    public init(sampleRate: Int) throws {
        guard (8000...768_000).contains(sampleRate) else { throw AlignEstimateError.invalidSampleRate(sampleRate) }
        rate = sampleRate
        let length = Int((Double(sampleRate) * 0.04).rounded())
        frameLength = length
        transform = Transform(atLeast: length)
        window = (0..<length).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(length - 1)) }
        let edges = [100.0, 220, 400, 650, 950, 1350, 1800]
        let size = Double(transform.count) / Double(sampleRate)
        bins = (0..<6).map { Int(ceil(edges[$0] * size))..<Int(ceil(edges[$0 + 1] * size)) }
    }

    public mutating func append(_ samples: [Float]) throws {
        try Task.checkCancellation()
        guard samples.allSatisfy(\.isFinite),
              received + samples.count <= rate * SpectralFingerprint.maximumSeconds else {
            throw AlignEstimateError.invalidParameter("fingerprint exceeds finite two-hour channel envelope")
        }
        pending += samples
        received += samples.count
        var next = Int((Double(energy.count) * Double(rate) / 50).rounded())
        while next + frameLength <= received {
            if energy.count.isMultiple(of: 256) { try Task.checkCancellation() }
            let offset = next - pendingStart
            let frame = (0..<frameLength).map { Double(pending[offset + $0]) }
            let mean = frame.reduce(0, +) / Double(frameLength)
            energy.append(Float(sqrt(frame.reduce(0) { $0 + pow($1 - mean, 2) } / Double(frameLength))))
            let spectrum = transform.spectrum(zip(frame, window).map(*))
            let values = bins.map { range in
                log(1e-10 + range.reduce(0.0) { $0 + pow(spectrum.real[$1], 2) + pow(spectrum.imaginary[$1], 2) })
            }
            let common = values.reduce(0, +) / 6
            for band in 0..<6 { bands[band].append(Float(values[band] - common)) }
            next = Int((Double(energy.count) * Double(rate) / 50).rounded())
        }
        let discard = min(pending.count, next - pendingStart)
        pending.removeFirst(discard)
        pendingStart += discard
    }

    public func finish() throws -> SpectralFingerprint {
        try Task.checkCancellation()
        guard received > 0 else { throw AlignEstimateError.emptyBuffer }
        return SpectralFingerprint(duration: Double(received) / Double(rate), bands: bands, energy: energy)
    }
}

public struct FingerprintPassage: Sendable {
    public let station: Int
    public let start: Double
    public let offset: Double
}

public struct FingerprintPlan: Sendable {
    public let start: Double
    public let end: Double
    public let stations: Int
    public let passages: [FingerprintPassage]
    public let evidence: [DelayEvidence]
    public let sharedSilentStations: [Int]
    public let abstention: AutomaticAbstention?
    public var refinementRateRatio: Double = 1
}

/// Searches full-track features, then selects distinctive passages inside each temporal region.
public enum FingerprintAlignment {
    public static func plan(reference: SpectralFingerprint, target: SpectralFingerprint) throws -> FingerprintPlan {
        let matcher = FeatureMatcher(reference)
        let discovery = try matcher.matches(target, start: 0, end: target.duration, candidates: 1)
        let usable = discovery.filter { $0.status == "eligible" }
        func refused(_ reason: AbstentionReason, _ detail: String, _ evidence: [DelayEvidence]) -> FingerprintPlan {
            FingerprintPlan(start: 0, end: target.duration, stations: 16, passages: [], evidence: evidence, sharedSilentStations: [],
                            abstention: AutomaticAbstention(reason: reason, detail: detail))
        }
        guard usable.count >= 3 else {
            let reason: AbstentionReason = target.energy.allSatisfy { $0 < 1e-4 } ? .silent
                : discovery.contains { $0.status == "ambiguous" } ? .ambiguous : .weak
            return refused(reason, "Whole-track fingerprints did not find three distinct shared passages for discovery. No anchor is required to search; check the selected speaker channels or choose another shared speaker.", discovery)
        }
        let fit: AffineFit
        switch RobustFit.fit(usable, tolerance: 0.15, minimumPoints: 3) {
        case .success(let line): fit = line
        case .failure(let reason):
            return refused(reason, "Whole-track fingerprints support conflicting timing regions, not one reliable offset and rate.", discovery)
        }
        let offset = fit.offset(at: 0)
        let margin = 0.1 + 0.0005 * max(reference.duration, target.duration)
        let lower = max(0, -offset) + margin
        let upper = min(target.duration, reference.duration - offset) - margin
        guard upper - lower >= 20 else {
            return refused(.insufficientCoverage, "The fingerprints leave less than twenty seconds of shared audio for distributed verification.", discovery)
        }
        let evidence = try matcher.matches(target, start: lower, end: upper, candidates: 3, prediction: fit)
        let stations = min(16, Int((upper - lower) / 4))
        let passages = evidence.filter { $0.status == "eligible" }.map {
            FingerprintPassage(station: $0.station, start: $0.targetCenter - 2, offset: $0.offsetSeconds!)
        }
        let silent = (0..<stations).filter { station in
            let start = lower + (upper - lower) * Double(station) / Double(stations)
            let end = lower + (upper - lower) * Double(station + 1) / Double(stations)
            func quiet(_ fingerprint: SpectralFingerprint, _ lo: Double, _ hi: Double) -> Bool {
                let first = Int(floor(lo * 50)), last = Int(ceil(hi * 50))
                guard first >= 0, last < fingerprint.frameCount, first < last else { return false }
                return fingerprint.energy[first...last].allSatisfy { $0 < 1e-4 }
            }
            return quiet(target, start, end)
                && quiet(reference, start + fit.offset(at: start) - 0.5, end + fit.offset(at: end) + 0.5)
        }
        return FingerprintPlan(start: lower, end: upper, stations: stations, passages: passages,
                               evidence: discovery + evidence, sharedSilentStations: silent, abstention: nil,
                               refinementRateRatio: abs(fit.slope * 1e6) <= AutomaticAlignment.maximumPPM ? 1 + fit.slope : 1)
    }
}

private struct FeatureMatcher {
    let transform: Transform
    let spectra: [(real: [Double], imaginary: [Double])]
    let inverseEnergies: [[Double]]

    init(_ reference: SpectralFingerprint) {
        let bands = reference.bands.map { band in
            stride(from: 0, to: band.count - band.count % 5, by: 5).map { start in
                (start..<start + 5).reduce(0.0) { $0 + Double(band[$1]) } / 5
            }
        }
        let fft = Transform(atLeast: (bands.first?.count ?? 0) + 40)
        transform = fft
        spectra = bands.map { fft.spectrum($0) }
        inverseEnergies = bands.map { band in
            guard band.count >= 40 else { return [] }
            var sum = band.prefix(40).reduce(0, +), square = band.prefix(40).reduce(0) { $0 + $1 * $1 }
            return (0...band.count - 40).map { i in
                let value = 1 / sqrt(max(1e-12, square - sum * sum / 40))
                if i + 40 < band.count {
                    sum += band[i + 40] - band[i]
                    square += band[i + 40] * band[i + 40] - band[i] * band[i]
                }
                return value
            }
        }
    }

    func matches(
        _ target: SpectralFingerprint, start: Double, end: Double, candidates: Int, prediction: AffineFit? = nil
    ) throws -> [DelayEvidence] {
        let count = min(16, Int((end - start) / 4))
        guard count >= 5, let scoreCount = inverseEnergies.first?.count, scoreCount > 0 else { return [] }
        var evidence: [DelayEvidence] = []
        for station in 0..<count {
            try Task.checkCancellation()
            let lo = Int(ceil((start + (end - start) * Double(station) / Double(count)) * 50))
            let hi = min(target.frameCount - 200, Int(floor((start + (end - start) * Double(station + 1) / Double(count) - 4) * 50)))
            guard hi >= lo else { continue }
            var ranked: [(Int, Double)] = []
            for at in stride(from: lo, through: hi, by: 25) {
                let averageEnergy = target.energy[at..<at + 200].reduce(0, +) / 200
                guard averageEnergy > 1e-4 else { continue }
                let variance = target.bands.reduce(0.0) { value, band in
                    let samples = band[at..<at + 200].map(Double.init)
                    let mean = samples.reduce(0, +) / 200
                    return value + samples.reduce(0) { $0 + pow($1 - mean, 2) } / 200
                }
                ranked.append((at, variance * sqrt(Double(averageEnergy))))
            }
            ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            var chosen: [Int] = []
            for (at, _) in ranked where chosen.allSatisfy({ abs($0 - at) >= 200 }) {
                if chosen.count >= candidates { break }
                chosen.append(at)
                var scores = [Double](repeating: 0, count: scoreCount)
                for band in 0..<6 {
                    let x = Statistics.centered((0..<40).map { i in
                        (0..<5).reduce(0.0) { $0 + Double(target.bands[band][at + i * 5 + $1]) } / 5
                    })
                    let norm = sqrt(x.reduce(0) { $0 + $1 * $1 })
                    guard norm > 1e-6 else { continue }
                    let correlation = transform.correlation(x, spectrum: spectra[band])
                    for lag in scores.indices { scores[lag] += correlation[lag] * inverseEnergies[band][lag] / (6 * norm) }
                }
                let time = Double(at) / 50
                let lower: Int, upper: Int
                if let prediction {
                    let expected = time + prediction.offset(at: time + 2)
                    lower = max(0, Int(floor((expected - 0.5) * 10)))
                    upper = min(scoreCount, Int(ceil((expected + 0.5) * 10)) + 1)
                } else {
                    lower = 0
                    upper = scoreCount
                }
                guard lower < upper else { continue }
                let peak = Statistics.peak(Array(scores[lower..<upper]), exclusion: 3)
                let status = peak.value < 0.25 ? "weak" : peak.second >= 0.8 * peak.value ? "ambiguous" : "eligible"
                evidence.append(DelayEvidence(station: station, attempt: chosen.count - 1, targetCenter: time + 2,
                                              status: status, offsetSeconds: (Double(lower) + peak.refined) / 10 - time,
                                              nccScore: peak.value, nccSecond: peak.second,
                                              phatOffsetSeconds: nil, phatPeakRatio: nil, method: "whole-track-log-band"))
            }
        }
        return evidence
    }
}
