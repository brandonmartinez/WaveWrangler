import Foundation
import WWCore
import WWTimeMap

// MARK: - Input and output contracts

/// One request for decoded samples: frames `[frames.lowerBound, frames.upperBound)` of the listed decoded
/// channels of one occurrence. Within a render, requests for an occurrence are strictly ascending and never
/// overlap, so each decoded frame is requested at most once.
public struct RenderSampleRequest: Sendable, Hashable {
    public let occurrence: SourceOccurrenceID
    public let source: SourceID
    public let frames: Range<Int64>
    /// Ascending decoded channel indices.
    public let decodedChannels: [Int]
}

/// Supplies plain decoded samples (binary32, planar). The renderer never opens files: a caller-owned
/// provider (for example one backed by the WWDecode gateway or a decoded cache) does.
public protocol RenderSampleProvider: Sendable {
    /// Returns `request.decodedChannels.count` arrays of exactly `request.frames.count` finite samples.
    func samples(for request: RenderSampleRequest) async throws -> [[Float]]
}

/// A block of rendered output: `frameCount` frames starting at aligned output frame `firstOutputFrame`, for
/// every output channel, planar (`samples[channel * frameCount + frame]`), binary32.
public struct RenderedChunk: Sendable, Equatable {
    public let firstOutputFrame: Int64
    public let frameCount: Int
    public let channelCount: Int
    public let samples: [Float]

    public func sample(channel: Int, frame: Int) -> Float { samples[channel * frameCount + frame] }
}

/// Receives rendered chunks in output order, then exactly one of `finish` (the render completed) or
/// `abandon` (any failure or cancellation after the sink was made). Only `finish`'s value is published.
public protocol RenderOutputSink {
    associatedtype Product: Sendable
    mutating func append(_ chunk: RenderedChunk) throws
    mutating func finish() throws -> Product
    /// Discard everything appended. Sinks that stage output elsewhere must remove it here.
    mutating func abandon()
}

extension RenderOutputSink {
    public mutating func abandon() {}
}

/// What one completed render did (resource bounds, for audit and the memory gate).
public struct RenderReport: Sendable, Equatable {
    public var chunks: Int
    public var providerRequests: Int
    public var providerFrames: Int64
    /// Largest number of decoded frames held for any one occurrence at once.
    public var peakWindowFrames: Int
    /// Largest renderer-held sample memory at once: decoded windows, one output chunk and tap weights.
    public var peakWorkingSetBytes: Int
}

public struct RenderResult<Product: Sendable>: Sendable {
    public let manifest: RenderManifest
    public let report: RenderReport
    public let product: Product
}

// MARK: - Renderer

/// Applies ONE group transform (the group's time map) to every requested channel, streaming bounded output
/// chunks off the main thread. No gain, mix, proxy or stretch is ever applied.
public enum GroupRenderer {
    /// Validates the request and returns the exact plan it would render, without reading any samples.
    public static func plan(_ request: RenderRequest) throws(RenderFailure) -> RenderManifest {
        try RenderPlan.make(request).manifest
    }

    @concurrent
    public static func render<Provider: RenderSampleProvider, Sink: RenderOutputSink>(
        _ request: RenderRequest,
        provider: Provider,
        makeSink: @escaping @Sendable (RenderManifest) throws -> Sink
    ) async throws(RenderFailure) -> RenderResult<Sink.Product> {
        try checkCancellation()
        let plan = try RenderPlan.make(request)
        let kernel = KaiserSincKernel(request.recipe.kernel)
        try checkCancellation()

        var sink: Sink
        do { sink = try makeSink(plan.manifest) } catch { throw .sinkFailed(String(describing: error)) }
        do throws(RenderFailure) {
            var engine = RenderEngine(plan: plan, kernel: kernel, chunkFrames: request.recipe.outputChunkFrames, channelCount: request.channels.count)
            try await engine.run(provider: provider, sink: &sink)
            try checkCancellation()
            let product: Sink.Product
            do { product = try sink.finish() } catch { throw .sinkFailed(String(describing: error)) }
            return RenderResult(manifest: plan.manifest, report: engine.report, product: product)
        } catch {
            sink.abandon()
            throw error
        }
    }

    static func checkCancellation() throws(RenderFailure) {
        if Task.isCancelled { throw .cancelled }
    }
}

// MARK: - Engine

/// Decoded frames `[start, start + count)` of one occurrence's requested channels.
private struct SampleWindow {
    var start: Int64 = 0
    var channels: [[Float]]

    var count: Int { channels.first?.count ?? 0 }
    var end: Int64 { start + Int64(count) }
}

private struct RenderEngine {
    let plan: RenderPlan
    let kernel: KaiserSincKernel
    let chunkFrames: Int
    let channelCount: Int
    var windows: [SampleWindow]
    var weights: [Double]
    var report = RenderReport(chunks: 0, providerRequests: 0, providerFrames: 0, peakWindowFrames: 0, peakWorkingSetBytes: 0)

    init(plan: RenderPlan, kernel: KaiserSincKernel, chunkFrames: Int, channelCount: Int) {
        self.plan = plan
        self.kernel = kernel
        self.chunkFrames = chunkFrames
        self.channelCount = channelCount
        windows = plan.occurrences.map { SampleWindow(channels: Array(repeating: [], count: $0.decodedChannels.count)) }
        let maxHalfTaps = plan.occurrences.flatMap(\.runs).map(\.halfTaps).max() ?? 0
        weights = [Double](repeating: 0, count: 2 * maxHalfTaps)
    }

    mutating func run<Provider: RenderSampleProvider, Sink: RenderOutputSink>(provider: Provider, sink: inout Sink) async throws(RenderFailure) {
        let k0 = plan.manifest.outputStartFrame
        let k1 = k0 + plan.manifest.outputFrameCount
        var chunkStart = k0
        while chunkStart < k1 {
            try GroupRenderer.checkCancellation()
            let chunkEnd = chunkStart + Int64(Swift.min(Int64(chunkFrames), k1 - chunkStart))
            let frames = Int(chunkEnd - chunkStart)
            var output = [Float](repeating: 0, count: channelCount * frames)
            for index in plan.occurrences.indices {
                let occurrence = plan.occurrences[index]
                let runs = occurrence.runs.filter { $0.outputEnd > chunkStart && $0.outputStart < chunkEnd }
                guard !runs.isEmpty else { continue }
                // One occurrence-wide tap reach keeps the needed source range monotone across segment and span
                // boundaries, so the window only ever moves forward. Needs are computed per span, so frames
                // outside every span (gaps between spans) are never requested.
                let reach = Int64(occurrence.tapReach)
                var groupStart = 0
                while groupStart < runs.count {
                    var groupEnd = groupStart + 1
                    while groupEnd < runs.count, runs[groupEnd].spanStart == runs[groupStart].spanStart { groupEnd += 1 }
                    var needLo = Int64.max
                    var needHi = Int64.min
                    for run in runs[groupStart ..< groupEnd] {
                        let first = run.floorPosition(Swift.max(run.outputStart, chunkStart))
                        let last = run.floorPosition(Swift.min(run.outputEnd, chunkEnd) - 1)
                        needLo = Swift.min(needLo, Swift.max(run.spanStart, first - reach + 1))
                        needHi = Swift.max(needHi, Swift.min(run.spanEnd, last + reach + 1))
                    }
                    try await ensureWindow(index, occurrence, needLo ..< needHi, provider: provider)
                    for run in runs[groupStart ..< groupEnd] {
                        let frameRange = Swift.max(run.outputStart, chunkStart) ..< Swift.min(run.outputEnd, chunkEnd)
                        render(run, occurrence, window: windows[index], frames: frameRange, chunkStart: chunkStart, chunkFrames: frames, into: &output)
                    }
                    groupStart = groupEnd
                }
            }
            let workingSet = windows.reduce(0) { $0 + $1.count * $1.channels.count } * MemoryLayout<Float>.size
                + output.count * MemoryLayout<Float>.size + weights.count * MemoryLayout<Double>.size
            report.peakWorkingSetBytes = Swift.max(report.peakWorkingSetBytes, workingSet)
            try GroupRenderer.checkCancellation()
            do {
                try sink.append(RenderedChunk(firstOutputFrame: chunkStart, frameCount: frames, channelCount: channelCount, samples: output))
            } catch {
                throw .sinkFailed(String(describing: error))
            }
            report.chunks += 1
            chunkStart = chunkEnd
            await Task.yield()
        }
    }

    /// Makes `windows[index]` hold `needed`, requesting only frames never requested before.
    private mutating func ensureWindow<Provider: RenderSampleProvider>(_ index: Int, _ occurrence: PlannedOccurrence, _ needed: Range<Int64>, provider: Provider) async throws(RenderFailure) {
        guard !needed.isEmpty else { return }
        var window = windows[index]
        if window.count == 0 || needed.lowerBound >= window.end {
            window.start = needed.lowerBound
            for c in window.channels.indices { window.channels[c].removeAll(keepingCapacity: true) }
        } else {
            // Positions only move forward, so a request can never need frames already discarded.
            guard needed.lowerBound >= window.start else { throw .mapInverseMismatch(occurrence.occurrence, outputFrame: needed.lowerBound) }
            let drop = Int(needed.lowerBound - window.start)
            if drop > 0 {
                for c in window.channels.indices { window.channels[c].removeFirst(drop) }
                window.start = needed.lowerBound
            }
        }
        if needed.upperBound > window.end {
            let request = RenderSampleRequest(occurrence: occurrence.occurrence, source: occurrence.source, frames: window.end ..< needed.upperBound, decodedChannels: occurrence.decodedChannels)
            try GroupRenderer.checkCancellation()
            let samples: [[Float]]
            do {
                samples = try await provider.samples(for: request)
            } catch {
                if Task.isCancelled { throw .cancelled }
                throw .providerFailed(String(describing: error))
            }
            let count = Int(request.frames.count)
            guard samples.count == occurrence.decodedChannels.count, samples.allSatisfy({ $0.count == count }) else {
                throw .providerShapeMismatch(occurrence.occurrence)
            }
            for channel in samples {
                guard channel.allSatisfy(\.isFinite) else { throw .nonFiniteInput(occurrence.occurrence) }
            }
            for c in window.channels.indices { window.channels[c].append(contentsOf: samples[c]) }
            report.providerRequests += 1
            report.providerFrames += Int64(count)
        }
        report.peakWindowFrames = Swift.max(report.peakWindowFrames, window.count)
        windows[index] = window
    }

    private mutating func render(_ run: PlannedSourceRun, _ occurrence: PlannedOccurrence, window: SampleWindow, frames: Range<Int64>, chunkStart: Int64, chunkFrames: Int, into output: inout [Float]) {
        let windowStart = window.start
        let windowEnd = window.end
        if run.isIdentity {
            for k in frames {
                let m = run.floorPosition(k)
                let slot = Int(k - chunkStart)
                for route in occurrence.routes {
                    output[route.output * chunkFrames + slot] = window.channels[route.input][Int(m - windowStart)]
                }
            }
            return
        }
        let halfTaps = run.halfTaps
        var lastRemainder: Int128 = -1
        for k in frames {
            let j = Int128(k - run.outputStart)
            let numerator = run.positionNumerator + j * run.stepNumerator
            let i = numerator / run.denominator
            let remainder = numerator - i * run.denominator
            if remainder != lastRemainder {
                // One phase per output frame per occurrence, shared by every channel (common rounding).
                kernel.weights(fraction: Double(remainder) / Double(run.denominator), scale: run.kernelScale, halfTaps: halfTaps, into: &weights)
                lastRemainder = remainder
            }
            let firstTap = Int64(i) - Int64(halfTaps) + 1
            // Taps outside the span (and so outside the window) read explicit zero.
            let tapLo = Int(Swift.max(0, Swift.max(run.spanStart, windowStart) - firstTap))
            let tapHi = Int(Swift.min(Int64(2 * halfTaps), Swift.min(run.spanEnd, windowEnd) - firstTap))
            let slot = Int(k - chunkStart)
            let base = Int(firstTap - windowStart)
            weights.withUnsafeBufferPointer { w in
                for route in occurrence.routes {
                    var acc = 0.0
                    window.channels[route.input].withUnsafeBufferPointer { x in
                        var t = tapLo
                        while t < tapHi {
                            acc += w[t] * Double(x[base + t])
                            t += 1
                        }
                    }
                    output[route.output * chunkFrames + slot] = Float(acc)
                }
            }
        }
    }
}

extension PlannedSourceRun {
    /// floor(x(k)). Positions inside a span are non-negative, so integer division is the floor.
    func floorPosition(_ k: Int64) -> Int64 {
        Int64((positionNumerator + Int128(k - outputStart) * stepNumerator) / denominator)
    }
}
