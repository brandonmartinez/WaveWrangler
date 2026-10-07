import Accelerate
import Foundation
import WWDecode

/// Streams decoded chunks into a mono, integer-decimated analysis buffer for one source-frame range, holding
/// only the output plus a short filter history (bounded memory: the full-rate source is never buffered).
///
/// Design (version `designVersion`, part of the analysis recipe):
/// * mono = arithmetic mean of every decoded channel (no gain beyond 1/channels, no channel selection);
/// * factor `D` = the largest divisor of the source rate `F` with `F / D >= minimumRate`, so the analysis
///   rate `F / D` is an exact integer and analysis sample `j` sits exactly at source frame `start + j·D`;
/// * anti-alias low-pass: centred Blackman-windowed sinc, `8·D` taps each side, cutoff `0.45 / D` cycles per
///   source sample, normalised to unit DC gain (`D == 1` is an exact passthrough);
/// * frames outside `[0, sourceFrames)` count as zero (the filter's edge context only).
struct AnalysisDecimator {
    static let designVersion = 1

    enum Refusal: Error, Equatable {
        case rateBelowMinimum(rate: Int, minimum: Int)
        case emptyRange
    }

    let sourceRate: Int
    let factor: Int
    let halfTaps: Int
    let outputCount: Int
    let range: Range<Int64>
    private let taps: [Float]
    private(set) var output: [Float]
    /// Mono samples for source frames `[historyStart, historyStart + history.count)`.
    private var history: [Float] = []
    private var historyStart: Int64
    private var nextOutput = 0
    private var consumedEnd: Int64 = 0

    var outputRate: Int { sourceRate / factor }

    /// The source frames whose samples influence the output (clamped below at zero).
    var neededInput: Range<Int64> {
        let lo = Swift.max(0, range.lowerBound - Int64(halfTaps))
        let lastCenter = range.lowerBound + Int64(outputCount - 1) * Int64(factor)
        return lo ..< (lastCenter + Int64(halfTaps) + 1)
    }

    static func factor(sourceRate: Int, minimumRate: Int) throws(Refusal) -> Int {
        guard sourceRate >= minimumRate else { throw .rateBelowMinimum(rate: sourceRate, minimum: minimumRate) }
        var best = 1
        var d = 1
        while sourceRate / d >= minimumRate {
            if sourceRate % d == 0 { best = d }
            d += 1
        }
        return best
    }

    /// Output samples a range of `frames` source frames produces at `factor`.
    static func outputCount(frames: Int64, factor: Int) -> Int {
        Int((frames + Int64(factor) - 1) / Int64(factor))
    }

    init(sourceRate: Int, minimumRate: Int, range: Range<Int64>) throws(Refusal) {
        guard !range.isEmpty, range.lowerBound >= 0 else { throw .emptyRange }
        self.sourceRate = sourceRate
        factor = try Self.factor(sourceRate: sourceRate, minimumRate: minimumRate)
        halfTaps = factor == 1 ? 0 : 8 * factor
        taps = Self.design(factor: factor, halfTaps: halfTaps)
        self.range = range
        outputCount = Self.outputCount(frames: Int64(range.count), factor: factor)
        output = []
        output.reserveCapacity(outputCount)
        historyStart = Swift.max(0, range.lowerBound - Int64(halfTaps))
    }

    static func design(factor: Int, halfTaps: Int) -> [Float] {
        guard factor > 1 else { return [1] }
        let cutoff = 0.45 / Double(factor)
        let length = 2 * halfTaps + 1
        var h = [Double](repeating: 0, count: length)
        for n in 0 ..< length {
            let k = Double(n - halfTaps)
            let x = 2 * cutoff * k
            let sinc = k == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let phase = 2 * Double.pi * Double(n) / Double(length - 1)
            let window = 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
            h[n] = 2 * cutoff * sinc * window
        }
        let sum = h.reduce(0, +)
        return h.map { Float($0 / sum) }
    }

    var isComplete: Bool { nextOutput == outputCount }

    /// Consumes the next decoded chunk (chunks arrive in source order). Frames outside `neededInput` are
    /// skipped without being mixed.
    mutating func consume(_ chunk: DecodedChunk) {
        let needed = neededInput
        let chunkStart = chunk.firstSourceFrame
        let chunkEnd = chunkStart + Int64(chunk.frameCount)
        consumedEnd = Swift.max(consumedEnd, chunkEnd)
        let lo = Swift.max(chunkStart, historyStart + Int64(history.count))
        let hi = Swift.min(chunkEnd, needed.upperBound)
        if lo < hi {
            let offset = Int(lo - chunkStart)
            let count = Int(hi - lo)
            var mono = [Float](repeating: 0, count: count)
            chunk.samples.withUnsafeBufferPointer { samples in
                mono.withUnsafeMutableBufferPointer { out in
                    for c in 0 ..< chunk.channelCount {
                        let base = samples.baseAddress! + c * chunk.frameCount + offset
                        vDSP_vadd(out.baseAddress!, 1, base, 1, out.baseAddress!, 1, vDSP_Length(count))
                    }
                    var scale = 1 / Float(chunk.channelCount)
                    vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(count))
                }
            }
            history.append(contentsOf: mono)
        }
        produce(final: false)
    }

    /// Completes the buffer after the last chunk (frames past the end of the source count as zero).
    mutating func finish() -> [Float] {
        produce(final: true)
        precondition(isComplete)
        history = []
        return output
    }

    private mutating func produce(final: Bool) {
        let available = historyStart + Int64(history.count)
        let m = Int64(halfTaps)
        let tapCount = taps.count
        var scratch = [Float](repeating: 0, count: tapCount)
        while nextOutput < outputCount {
            let center = range.lowerBound + Int64(nextOutput) * Int64(factor)
            if !final, center + m >= available { break }
            let first = center - m
            let value: Float
            if first >= historyStart, center + m < available {
                let offset = Int(first - historyStart)
                value = history.withUnsafeBufferPointer { h in
                    taps.withUnsafeBufferPointer { t in
                        var result: Float = 0
                        vDSP_dotpr(h.baseAddress! + offset, 1, t.baseAddress!, 1, &result, vDSP_Length(tapCount))
                        return result
                    }
                }
            } else {
                // Edge: frames before the source start, or past what was decoded at the end, count as zero.
                for i in 0 ..< tapCount {
                    let frame = first + Int64(i)
                    scratch[i] = frame >= historyStart && frame < available ? history[Int(frame - historyStart)] : 0
                }
                var result: Float = 0
                vDSP_dotpr(scratch, 1, taps, 1, &result, vDSP_Length(tapCount))
                value = result
            }
            output.append(value)
            nextOutput += 1
        }
        // Drop history no future output needs (amortised).
        let nextCenter = range.lowerBound + Int64(nextOutput) * Int64(factor)
        let keepFrom = Swift.max(historyStart, nextCenter - m)
        let drop = Swift.min(Int(keepFrom - historyStart), history.count)
        if drop > 65_536 || (drop > 0 && drop >= history.count / 2) {
            history.removeFirst(drop)
            historyStart += Int64(drop)
        }
    }
}
