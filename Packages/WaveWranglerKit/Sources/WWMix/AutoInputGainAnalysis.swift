import Accelerate
import Foundation
import WWCore
import WWDecode
import WWDerived

public enum AutoInputGainFailure: LocalizedError, Sendable {
    case invalidTarget
    case invalidAudio
    case insufficientActivity
    case insufficientAttenuation
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .invalidTarget: "Choose an Auto Input Gain target from -36 to -12 dBFS RMS in Settings."
        case .invalidAudio: "This recording has incomplete or invalid audio. No gain was changed."
        case .insufficientActivity: "Not enough audio above the quiet gate to estimate an input gain. Adjust the gain manually."
        case .insufficientAttenuation: "This recording needs more attenuation than the input gain supports. No gain was changed."
        case .notAuthorized: "Confirm this speaker's Primary and enable local source access before analyzing its gain."
        }
    }
}

public struct AutoInputGainResult: Sendable, Equatable {
    public let targetDBFS: Double
    public let activeRMSDBFS: Double
    public let samplePeakDBFS: Double
    /// Four-times oversampled windowed-sinc estimate, not a certified BS.1770 meter.
    public let estimatedTruePeakDBFS: Double
    public let gainDB: Double
    public let peakLimited: Bool
    public let gainLimited: Bool
    public let activeSeconds: Double

    public var predictedTruePeakDBFS: Double { estimatedTruePeakDBFS + gainDB }
}

/// Bounded streaming analysis. Quiet gating is level-based, not semantic voice detection: noise,
/// crosstalk and music above the gate also contribute. Peaks always cover the entire recording.
public struct AutoInputGainAnalyzer: Sendable {
    public static let peakCeilingDBFS: Double = -6
    public static let peakSafetyMarginDB: Double = 0.5
    private static let minimumWindowDBFS: Double = -60
    private static let histogramFloor: Double = -100
    private static let histogramStep: Double = 0.1
    private let sampleRate: Int
    private let windowFrames: Int
    private let target: Double
    private var windowEnergy: Double = 0
    private var windowCount = 0
    private var energies = [Double](repeating: 0, count: 9_001)
    private var frames = [Int64](repeating: 0, count: 9_001)
    private var peak: Double = 0
    private var truePeak = OversampledPeak()

    public init(sampleRate: Int, targetDBFS: Double) throws {
        guard AutoInputGainTarget.isValid(targetDBFS) else { throw AutoInputGainFailure.invalidTarget }
        guard (8_000...384_000).contains(sampleRate) else { throw AutoInputGainFailure.invalidAudio }
        self.sampleRate = sampleRate
        windowFrames = max(1, sampleRate * 2 / 5)
        target = targetDBFS
    }

    public mutating func append(_ samples: ArraySlice<Float>) throws {
        try Task.checkCancellation()
        guard samples.allSatisfy(\.isFinite) else { throw AutoInputGainFailure.invalidAudio }
        let values = samples.map(Double.init)
        truePeak.append(values)
        for value in values {
            peak = max(peak, abs(value))
            windowEnergy += value * value
            windowCount += 1
            if windowCount == windowFrames { finishWindow() }
        }
    }

    public mutating func finish() throws -> AutoInputGainResult {
        try Task.checkCancellation()
        if windowCount > 0 { finishWindow() }
        // Use the upper active-level percentile rather than a single loud transient to set the gate.
        let minimumBin = bin(Self.minimumWindowDBFS)
        let candidateFrames = frames[minimumBin...].reduce(Int64(0), +)
        guard candidateFrames >= Int64(windowFrames) else { throw AutoInputGainFailure.insufficientActivity }
        var accumulated: Int64 = 0
        var upperBin = minimumBin
        for index in minimumBin..<frames.count {
            accumulated += frames[index]
            if Double(accumulated) >= Double(candidateFrames) * 0.95 {
                upperBin = index
                break
            }
        }
        let gateDB = max(Self.minimumWindowDBFS,
                         Self.histogramFloor + Double(upperBin) * Self.histogramStep - 20)
        // Round upward so the entire accepted bin is above the gate.
        let first = min(frames.count - 1, Int(ceil((gateDB - Self.histogramFloor) / Self.histogramStep)))
        let activeFrames = frames[first...].reduce(Int64(0), +)
        let energy = energies[first...].reduce(0, +)
        guard activeFrames >= Int64(windowFrames), energy > 0 else {
            throw AutoInputGainFailure.insufficientActivity
        }
        let level = 10 * log10(energy / Double(activeFrames))
        let measuredPeak = max(peak, truePeak.finish())
        guard measuredPeak > 0 else { throw AutoInputGainFailure.insufficientActivity }
        let peakDB = 20 * log10(measuredPeak)
        let desired = target - level
        let safe = Self.peakCeilingDBFS - Self.peakSafetyMarginDB - peakDB
        let gain = min(desired, safe, EpisodeMixState.gainRangeDB.upperBound)
        guard gain >= EpisodeMixState.gainRangeDB.lowerBound else {
            throw AutoInputGainFailure.insufficientAttenuation
        }
        return AutoInputGainResult(
            targetDBFS: target, activeRMSDBFS: level, samplePeakDBFS: 20 * log10(peak),
            estimatedTruePeakDBFS: peakDB, gainDB: gain,
            peakLimited: safe < desired, gainLimited: EpisodeMixState.gainRangeDB.upperBound < min(desired, safe),
            activeSeconds: Double(activeFrames) / Double(sampleRate))
    }

    private func bin(_ db: Double) -> Int {
        min(frames.count - 1, max(0, Int(floor((db - Self.histogramFloor) / Self.histogramStep))))
    }

    private mutating func finishWindow() {
        let db = windowEnergy > 0 ? 10 * log10(windowEnergy / Double(windowCount)) : Self.histogramFloor
        let index = bin(db)
        energies[index] += windowEnergy
        frames[index] += Int64(windowCount)
        windowEnergy = 0
        windowCount = 0
    }
}

private struct OversampledPeak: Sendable {
    private static let taps = 48
    private static let filters: [[Double]] = [0.25, 0.5, 0.75].map { fraction in
        let coefficients = (0..<taps).map { index -> Double in
            let x = Double(index) - 23 - fraction
            let sinc = sin(.pi * x) / (.pi * x)
            let window = 0.42 + 0.5 * cos(.pi * x / 24) + 0.08 * cos(2 * .pi * x / 24)
            return sinc * window
        }
        let sum = coefficients.reduce(0, +)
        return coefficients.map { $0 / sum }
    }
    private var history = [Double](repeating: 0, count: taps - 1)
    private var maximum: Double = 0

    mutating func append(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let input = history + values
        var output = [Double](repeating: 0, count: values.count)
        for filter in Self.filters {
            vDSP_convD(input, 1, filter, 1, &output, 1,
                       vDSP_Length(values.count), vDSP_Length(Self.taps))
            var peak: Double = 0
            vDSP_maxmgvD(output, 1, &peak, vDSP_Length(output.count))
            maximum = max(maximum, peak)
        }
        history = Array(input.suffix(Self.taps - 1))
    }

    mutating func finish() -> Double {
        append([Double](repeating: 0, count: Self.taps - 1))
        return maximum
    }
}

public enum AutoInputGainAnalysis {
    /// One explicitly authorized channel. No source discovery, effect loading or persistent PCM cache.
    @concurrent
    public static func analyze(
        _ admission: SourceReadAdmission, decoder: SourceDecoder, channel: Int, targetDBFS: Double,
        progress: @escaping @Sendable (Double) async throws -> Void = { _ in }
    ) async throws -> AutoInputGainResult {
        guard admission.authorization?.source == admission.source, admission.availability == .on else {
            throw AutoInputGainFailure.notAuthorized
        }
        try await admission.validateCurrentAccess()
        let result = try await decoder.withWitnessBoundDecodingCursor(
            admission.location, source: admission.source, matching: admission.witness
        ) { cursor in
            let format = cursor.interpretation
            guard channel >= 0, channel < format.channelCount else { throw AutoInputGainFailure.invalidAudio }
            try SourceChannelOrder.require(format, legacyWavePCM: cursor.legacyWavePCMChannelOrder,
                                           m4aCodec: cursor.m4aCodecChannelOrder)
            var analyzer = try AutoInputGainAnalyzer(sampleRate: format.sourceSampleRate, targetDBFS: targetDBFS)
            var processed: Int64 = 0
            while let chunk = try await cursor.next() {
                try Task.checkCancellation()
                try await admission.validateCurrentAccess()
                guard chunk.firstSourceFrame == processed, chunk.channelCount == format.channelCount else {
                    throw AutoInputGainFailure.invalidAudio
                }
                try analyzer.append(chunk.channel(channel))
                processed += Int64(chunk.frameCount)
                try await progress(Double(processed) / Double(max(1, format.frames.validFrames)))
            }
            guard processed == format.frames.validFrames else { throw AutoInputGainFailure.invalidAudio }
            return try analyzer.finish()
        }
        try await admission.validateCurrentAccess()
        try Task.checkCancellation()
        return result
    }
}
