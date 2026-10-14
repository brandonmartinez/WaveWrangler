import Foundation
import WWCore
import WWDecode
import WWSources
import WWTimeMap

public struct WaveformBin: Sendable, Equatable, Codable {
    public let firstFrame: Int64
    public let endFrame: Int64
    public let minimum: Float
    public let maximum: Float

    public init(firstFrame: Int64, endFrame: Int64, minimum: Float, maximum: Float) {
        self.firstFrame = firstFrame
        self.endFrame = endFrame
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct WaveformEnvelope: Sendable, Equatable, Codable {
    public let source: SourceID
    public let sampleRate: Int
    public let channelCount: Int
    public let totalFrames: Int64
    public let bins: [WaveformBin]

    public init(source: SourceID, sampleRate: Int, channelCount: Int, totalFrames: Int64, bins: [WaveformBin]) {
        self.source = source
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.totalFrames = totalFrames
        self.bins = bins
    }
}

public enum WaveformWindowError: Error, LocalizedError, Sendable, Equatable {
    case invalidWindow
    case outsideSource
    case invalidSamples
    case mapDoesNotMatchSource
    case decodeBudgetExceeded
    case overviewRequiresPCM
    case overviewBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidWindow: "Choose a finite audio window of at most 30 seconds."
        case .outsideSource: "This window is outside the recording."
        case .invalidSamples: "The recording contains invalid audio samples."
        case .mapDoesNotMatchSource: "The timing map does not match this recording's placement or decoded sample rate/frame count. Refresh audio, then review source assignment and timing."
        case .decodeBudgetExceeded: "Random access is not established for this codec. Its preview is limited to the first 10 source minutes; use a PCM recording for later windows."
        case .overviewRequiresPCM: "Episode overview requires PCM with verified random access. Load a bounded window for this codec instead."
        case .overviewBudgetExceeded: "Episode overview supports up to 24 source hours and 2,048 distinct covered ranges per recording."
        }
    }
}

/// A display envelope, not PCM, a timing estimate or an edit authorization.
public enum WaveformWindowReader {
    public static let maximumDurationSeconds = 30.0
    public static let maximumBins = 2_048
    public static let maximumDecodedPrefixSeconds: Int64 = 600
    public static let maximumOverviewSourceSeconds: Int64 = 86_400

    /// The measured bins depend on these source-frame ranges, not on their aligned positions.
    public static func overviewCoverage(
        source: SourceID, groupMap: GroupTimeMap?
    ) throws -> [Range<Int64>]? {
        guard let groupMap else { return nil }
        guard let placement = groupMap.placements.first(where: { $0.occurrence.source == source })
        else { throw WaveformWindowError.mapDoesNotMatchSource }
        return try WaveformViewport.overviewRanges(
            source: source, rate: Int(placement.occurrence.nominalRate.framesPerSecond),
            totalFrames: placement.occurrence.frameCount, groupMap: groupMap
        )
    }

    public static func verifyOverviewCoverage(
        envelope: WaveformEnvelope, groupMap: GroupTimeMap?
    ) throws {
        _ = try WaveformViewport.overviewRanges(
            source: envelope.source, rate: envelope.sampleRate,
            totalFrames: envelope.totalFrames, groupMap: groupMap
        )
    }

    /// Explicit full-coverage scan. Every covered sample contributes; only bounded bins survive a successful read.
    @concurrent
    public static func readOverview(
        sourceURL: URL, source: SourceID, matching witness: RawSourceIdentity,
        decoder: SourceDecoder, groupMap: GroupTimeMap? = nil,
        progress: @Sendable (Double) async throws -> Void = { _ in }
    ) async throws -> WaveformEnvelope {
        try await decoder.withWitnessBoundDecodingCursor(
            sourceURL, source: source, matching: witness
        ) { cursor in
            guard cursor.supportsRandomAccess else { throw WaveformWindowError.overviewRequiresPCM }
            let rate = cursor.interpretation.sourceSampleRate
            let total = cursor.interpretation.frames.validFrames
            let ranges = try WaveformViewport.overviewRanges(
                source: source, rate: rate, totalFrames: total, groupMap: groupMap
            )
            let coveredFrames = ranges.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
            let availableBins = maximumBins - ranges.count
            var builders = ranges.map { range in
                let count = range.upperBound - range.lowerBound
                let budget = 1 + Int(Int128(availableBins) * Int128(count) / Int128(max(1, coveredFrames)))
                return WaveformEnvelopeBuilder(firstFrame: range.lowerBound, endFrame: range.upperBound, maximumBins: budget)
            }
            var completed: Int64 = 0
            try await progress(0)
            for index in ranges.indices {
                try await cursor.seek(toSourceFrame: ranges[index].lowerBound)
                while await cursor.position < ranges[index].upperBound,
                      let chunk = try await cursor.next(upToSourceFrame: ranges[index].upperBound) {
                    try Task.checkCancellation()
                    try builders[index].append(chunk)
                    completed += Int64(chunk.frameCount)
                    try await progress(Double(completed) / Double(max(1, coveredFrames)))
                }
            }
            try Task.checkCancellation()
            if coveredFrames == 0 { try await progress(1) }
            return WaveformEnvelope(
                source: source, sampleRate: rate, channelCount: cursor.interpretation.channelCount,
                totalFrames: total, bins: builders.flatMap(\.bins)
            )
        }
    }

    @concurrent
    public static func readWindow(
        sourceURL: URL,
        source: SourceID,
        matching witness: RawSourceIdentity,
        decoder: SourceDecoder,
        startSeconds: Double,
        durationSeconds: Double,
        groupMap: GroupTimeMap? = nil
    ) async throws -> WaveformEnvelope {
        guard startSeconds.isFinite, (-86_400...86_400).contains(startSeconds),
              durationSeconds.isFinite, durationSeconds > 0,
              durationSeconds <= maximumDurationSeconds
        else { throw WaveformWindowError.invalidWindow }
        return try await decoder.withWitnessBoundDecodingCursor(
            sourceURL, source: source, matching: witness
        ) { cursor in
            let rate = cursor.interpretation.sourceSampleRate
            let total = cursor.interpretation.frames.validFrames
            let ranges = try WaveformViewport.frameRanges(
                source: source, rate: rate, totalFrames: total, groupMap: groupMap,
                startSeconds: startSeconds, durationSeconds: durationSeconds
            )
            try WaveformViewport.verifyDecodeBudget(ranges: ranges, rate: rate, randomAccess: cursor.supportsRandomAccess)
            let budget = maximumBins / max(1, ranges.count)
            var builders = ranges.map {
                WaveformEnvelopeBuilder(firstFrame: $0.lowerBound, endFrame: $0.upperBound, maximumBins: budget)
            }
            if cursor.supportsRandomAccess {
                for index in ranges.indices {
                    try await cursor.seek(toSourceFrame: ranges[index].lowerBound)
                    while await cursor.position < ranges[index].upperBound,
                          let chunk = try await cursor.next(upToSourceFrame: ranges[index].upperBound) {
                        try Task.checkCancellation()
                        try builders[index].append(chunk)
                    }
                }
            } else {
                while await cursor.position < (ranges.last?.upperBound ?? 0), let chunk = try await cursor.next() {
                    try Task.checkCancellation()
                    for index in builders.indices { try builders[index].append(chunk) }
                }
            }
            return WaveformEnvelope(
                source: source, sampleRate: rate,
                channelCount: cursor.interpretation.channelCount,
                totalFrames: total, bins: builders.flatMap(\.bins)
            )
        }
    }
}

struct WaveformEnvelopeBuilder {
    let firstFrame: Int64
    let endFrame: Int64
    private let width: Int64
    private var extrema: [(Float, Float)?]

    init(firstFrame: Int64, endFrame: Int64, maximumBins: Int = WaveformWindowReader.maximumBins) {
        self.firstFrame = firstFrame
        self.endFrame = endFrame
        let count = max(0, endFrame - firstFrame)
        width = max(1, (count + Int64(maximumBins) - 1) / Int64(maximumBins))
        extrema = Array(repeating: nil, count: Int((count + width - 1) / width))
    }

    mutating func append(_ chunk: DecodedChunk) throws {
        guard chunk.channelCount > 0,
              chunk.samples.count == chunk.frameCount * chunk.channelCount
        else { throw WaveformWindowError.invalidSamples }
        let lower = max(firstFrame, chunk.firstSourceFrame)
        let upper = min(endFrame, chunk.firstSourceFrame + Int64(chunk.frameCount))
        guard lower < upper else { return }
        for frame in lower..<upper {
            let index = Int((frame - firstFrame) / width)
            let offset = Int(frame - chunk.firstSourceFrame)
            for channel in 0..<chunk.channelCount {
                let sample = chunk.samples[channel * chunk.frameCount + offset]
                guard sample.isFinite else { throw WaveformWindowError.invalidSamples }
                if let prior = extrema[index] {
                    extrema[index] = (min(prior.0, sample), max(prior.1, sample))
                } else {
                    extrema[index] = (sample, sample)
                }
            }
        }
    }

    var bins: [WaveformBin] {
        extrema.enumerated().compactMap { index, value in
            guard let value else { return nil }
            let start = firstFrame + Int64(index) * width
            return WaveformBin(
                firstFrame: start, endFrame: min(endFrame, start + width),
                minimum: value.0, maximum: value.1
            )
        }
    }
}
