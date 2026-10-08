import Accelerate
import Foundation
import WWDecode
import WWDerived

/// Output frames are at 16 kHz. Center source frame for output frame `n` is
/// `n * sourceFramesPerOutputFrame`; the last short hop is not padded into a
/// fictitious source frame. `filterSourceFrames` includes the real source frames
/// that may contribute to this chunk (outside the source is zero).
public struct PrimaryPCMChunk: Sendable, Equatable {
    public let outputFrames: Range<Int>
    public let sourceFrames: Range<Int64>
    public let filterSourceFrames: Range<Int64>

    fileprivate init(
        outputFrames: Range<Int>, sourceFrames: Range<Int64>,
        filterSourceFrames: Range<Int64>
    ) {
        self.outputFrames = outputFrames
        self.sourceFrames = sourceFrames
        self.filterSourceFrames = filterSourceFrames
    }
}

/// A private, immutable, in-memory proxy derived from a single WWDecode cursor,
/// never an accepted timeline occurrence or a credential to run an ASR worker.
/// Only integral downsampling to 16 kHz is supported by this version of the
/// filter; no clock map, channel mixing, sample write or temporary file exists.
public struct SelectedPrimaryPCMProxy: Sendable {
    public static let sampleRate = 16_000
    public static let proxyAsset = AssetSpec(kind: "ww.speech-primary-pcm-16k", revision: 1)
    public static let chunkFrames = 16_000

    public let selection: PrimarySpeechSelection
    public let interpretation: FormatInterpretation
    public let sourceRevision: SourceRevision
    public let inputAssetRevision: Int
    public let proxyAssetRevision: Int
    public let sourceFramesPerOutputFrame: Int
    public let chunks: [PrimaryPCMChunk]
    package let samples: [Float]

    public var frameCount: Int { samples.count }

    /// No file-backed proxy identity or qualified offline runtime is established.
    public func offlinePlan(stage: URL, scratch: URL) throws(SpeechAdmissionRefusal)
        -> OfflineWhisperPlan
    {
        throw .primaryProxyNotProven
    }

    fileprivate init(input: ProvisionalPrimarySpeechInput, plan: PCMProxyPlan, samples: [Float]) {
        selection = input.selection
        interpretation = input.interpretation
        sourceRevision = input.sourceRevision
        inputAssetRevision = input.inputAssetRevision
        proxyAssetRevision = Self.proxyAsset.revision
        sourceFramesPerOutputFrame = plan.factor
        chunks = plan.chunks
        self.samples = samples
    }

    static func make(from input: ProvisionalPrimarySpeechInput) throws(SpeechAdmissionRefusal)
        -> Self
    {
        let plan = try PCMProxyPlan(
            sourceFrames: input.interpretation.frames.validFrames,
            sourceRate: input.interpretation.sourceSampleRate,
            chunkFrames: chunkFrames)
        guard input.samples.count == Int(input.interpretation.frames.validFrames),
            input.interpretation.output.sampleRate == input.interpretation.sourceSampleRate,
            input.interpretation.output.channelCount == input.interpretation.channelCount,
            input.interpretation.origin.sourceFrameOfFirstDecodedFrame == 0,
            input.interpretation.origin.decodedFrameCount
                == input.interpretation.frames.validFrames,
            input.samples.allSatisfy(\.isFinite)
        else { throw .sourceRevisionChanged }
        var output: [Float] = []
        output.reserveCapacity(plan.outputFrames)
        var completed = false
        defer {
            if !completed {
                output.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
                output.removeAll(keepingCapacity: false)
            }
        }
        if plan.factor == 1 {
            output.append(contentsOf: input.samples)
        } else {
            let taps = filter(factor: plan.factor)
            let half = 8 * plan.factor
            let failure = input.samples.withUnsafeBufferPointer {
                source -> SpeechAdmissionRefusal? in
                taps.withUnsafeBufferPointer { coefficients -> SpeechAdmissionRefusal? in
                    for n in 0..<plan.outputFrames {
                        if n % 4_096 == 0, Task.isCancelled { return .decode(.cancelled) }
                        let center = n * plan.factor
                        let start = center - half
                        let value: Float
                        if start >= 0, center + half < source.count {
                            var sum: Float = 0
                            vDSP_dotpr(
                                source.baseAddress! + start, 1, coefficients.baseAddress!, 1,
                                &sum, vDSP_Length(coefficients.count))
                            value = sum
                        } else {
                            var sum: Float = 0
                            for tap in 0..<coefficients.count {
                                let frame = start + tap
                                if frame >= 0, frame < source.count {
                                    sum += source[frame] * coefficients[tap]
                                }
                            }
                            value = sum
                        }
                        guard value.isFinite else { return .sourceRevisionChanged }
                        output.append(value)
                    }
                    return nil
                }
            }
            if let failure { throw failure }
        }
        guard !Task.isCancelled else { throw .decode(.cancelled) }
        completed = true
        return Self(input: input, plan: plan, samples: output)
    }

    private static func filter(factor: Int) -> [Float] {
        let half = 8 * factor
        let cutoff = 0.45 / Double(factor)
        let count = 2 * half + 1
        var taps = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let k = Double(i - half)
            let x = 2 * cutoff * k
            let sinc = k == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let window =
                0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(count - 1))
                + 0.08 * cos(4 * .pi * Double(i) / Double(count - 1))
            taps[i] = 2 * cutoff * sinc * window
        }
        let gain = taps.reduce(0, +)
        return taps.map { Float($0 / gain) }
    }
}

/// Checked coordinate plan, separate from allocation so extreme inputs can be
/// refused before any arithmetic, indexing or PCM allocation.
package struct PCMProxyPlan {
    package let factor: Int
    package let outputFrames: Int
    package let chunks: [PrimaryPCMChunk]

    package init(sourceFrames: Int64, sourceRate: Int, chunkFrames: Int)
        throws(SpeechAdmissionRefusal)
    {
        guard sourceRate >= SelectedPrimaryPCMProxy.sampleRate,
            sourceRate <= 192_000,
            sourceRate % SelectedPrimaryPCMProxy.sampleRate == 0
        else { throw .proxyRateUnsupported }
        guard sourceFrames > 0, sourceFrames < Int64.max else { throw .proxyFrameOverflow }
        guard sourceFrames <= Int64(PrimarySpeechInputAdapter.maximumFrames) else {
            throw .inputTooLarge
        }
        guard chunkFrames > 0, chunkFrames <= SelectedPrimaryPCMProxy.chunkFrames else {
            throw .proxyChunkOverflow
        }
        factor = sourceRate / SelectedPrimaryPCMProxy.sampleRate
        let count = sourceFrames / Int64(factor) + (sourceFrames % Int64(factor) == 0 ? 0 : 1)
        guard count > 0, count <= Int.max else { throw .proxyFrameOverflow }
        outputFrames = Int(count)
        let half = factor == 1 ? 0 : Int64(8 * factor)
        var planned: [PrimaryPCMChunk] = []
        planned.reserveCapacity(outputFrames / chunkFrames + 1)
        var start = 0
        while start < outputFrames {
            let end = start + min(chunkFrames, outputFrames - start)
            let first = Int64(start) * Int64(factor)
            let last = Int64(end - 1) * Int64(factor)
            let sourceEnd = min(sourceFrames, Int64(end) * Int64(factor))
            planned.append(
                PrimaryPCMChunk(
                    outputFrames: start..<end,
                    sourceFrames: first..<sourceEnd,
                    filterSourceFrames: max(0, first - half)..<min(sourceFrames, last + half + 1)
                ))
            start = end
        }
        chunks = planned
    }
}
