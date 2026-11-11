import Foundation

public enum NominalPCMFailure: Error, Sendable, Equatable {
    case invalidRequest
    case incompletePCM
    case nonfinitePCM
}

/// Absolute nominal source phase, independent of seeks, clip splits, and producer chunk boundaries.
/// Uses the existing sinc prototype; only taps outside the retained native trim are explicit zero.
public enum NominalPCMRenderer {
    public static let version = 1
    public static let maximumOutputFrames = 4096

    /// Exact native coverage, including sinc support, for batching a caller's source reads.
    /// This only computes bounds; rendering remains limited to `maximumOutputFrames`.
    public static func sourceFrames(
        sampleRate: Int, support: Range<Int64>, outputFrames: Range<Int64>
    ) throws -> Range<Int64> {
        guard (8_000...192_000).contains(sampleRate), support.lowerBound >= 0, !support.isEmpty,
              support.upperBound <= Int64(sampleRate) * 86_400,
              outputFrames.lowerBound >= 0, !outputFrames.isEmpty else { throw NominalPCMFailure.invalidRequest }
        let rate = Int64(sampleRate)
        guard outputFrames.upperBound <= ((support.upperBound - support.lowerBound) * 48_000 + rate - 1) / rate
        else { throw NominalPCMFailure.invalidRequest }
        let identity = sampleRate == 48_000
        let scale = min(1, 48_000 / Double(sampleRate))
        let halfTaps = identity ? 0 : Int(ceil(Double(KaiserSincKernel.m2Candidate.halfWidth) / scale))
        let first = (support.lowerBound * 48_000 + outputFrames.lowerBound * rate) / 48_000
        let last = (support.lowerBound * 48_000 + (outputFrames.upperBound - 1) * rate) / 48_000
        let lower = max(support.lowerBound, first - Int64(halfTaps) + (identity ? 0 : 1))
        return lower..<min(support.upperBound, last + Int64(halfTaps) + 1)
    }

    @concurrent
    public static func render(
        sampleRate: Int, support: Range<Int64>, outputFrames: Range<Int64>, channels: [Int],
        samples provideSamples: @Sendable (Range<Int64>, [Int]) async throws -> [[Float]]
    ) async throws -> [[Float]] {
        guard outputFrames.lowerBound >= 0, !outputFrames.isEmpty,
              outputFrames.count <= maximumOutputFrames,
              !channels.isEmpty, channels.count <= 2, Set(channels).count == channels.count,
              channels.allSatisfy({ (0..<64).contains($0) }) else { throw NominalPCMFailure.invalidRequest }
        let rate = Int64(sampleRate)
        func position(_ frame: Int64) -> Int64 { support.lowerBound * 48_000 + frame * rate }
        let need = try sourceFrames(sampleRate: sampleRate, support: support, outputFrames: outputFrames)
        try Task.checkCancellation()
        let identity = sampleRate == 48_000
        let scale = min(1, 48_000 / Double(sampleRate))
        let kernel = KaiserSincKernel.m2Candidate
        let halfTaps = identity ? 0 : Int(ceil(Double(kernel.halfWidth) / scale))
        let samples = try await provideSamples(need, channels)
        try Task.checkCancellation()
        guard samples.count == channels.count, samples.allSatisfy({ $0.count == need.count }) else {
            throw NominalPCMFailure.incompletePCM
        }
        guard samples.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw NominalPCMFailure.nonfinitePCM }
        if identity { return samples }
        var result = Array(repeating: [Float](repeating: 0, count: outputFrames.count), count: channels.count)
        var weights = [Double](repeating: 0, count: 2 * halfTaps)
        for (index, frame) in outputFrames.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            let numerator = position(frame), whole = numerator / 48_000, remainder = numerator % 48_000
            kernel.weights(fraction: Double(remainder) / 48_000, scale: scale,
                           halfTaps: halfTaps, into: &weights)
            let tapStart = whole - Int64(halfTaps) + 1
            let lo = Int(max(0, need.lowerBound - tapStart))
            let hi = Int(min(Int64(weights.count), need.upperBound - tapStart))
            for channel in samples.indices {
                var sum = 0.0
                for tap in lo..<hi {
                    sum += weights[tap] * Double(samples[channel][Int(tapStart + Int64(tap) - need.lowerBound)])
                }
                result[channel][index] = Float(sum)
            }
        }
        guard result.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw NominalPCMFailure.nonfinitePCM }
        return result
    }
}
