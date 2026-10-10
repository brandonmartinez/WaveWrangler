import Foundation
import WWCore
import WWDecode
import WWSources
import WWTimeMap

public struct WaveformBin: Sendable, Equatable {
    public let firstFrame: Int64
    public let endFrame: Int64
    public let minimum: Float
    public let maximum: Float
}

public struct WaveformEnvelope: Sendable, Equatable {
    public let source: SourceID
    public let sampleRate: Int
    public let channelCount: Int
    public let totalFrames: Int64
    public let bins: [WaveformBin]
}

public enum WaveformWindowError: Error, LocalizedError, Sendable, Equatable {
    case invalidWindow
    case outsideSource
    case invalidSamples
    case mapDoesNotMatchSource
    case decodeBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidWindow: "Choose a finite audio window of at most 30 seconds."
        case .outsideSource: "This window is outside the recording."
        case .invalidSamples: "The recording contains invalid audio samples."
        case .mapDoesNotMatchSource: "The timing map does not match this recording."
        case .decodeBudgetExceeded: "This preview is limited to the first 10 source minutes. A later window requires random-access decoding, which is not available yet."
        }
    }
}

/// A display envelope, not PCM, a timing estimate or an edit authorization.
public enum WaveformWindowReader {
    public static let maximumDurationSeconds = 30.0
    public static let maximumBins = 2_048
    public static let maximumDecodedPrefixSeconds: Int64 = 600

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
        guard startSeconds.isFinite, startSeconds >= 0, startSeconds <= 86_400,
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
            try WaveformViewport.verifyDecodeBudget(ranges: ranges, rate: rate)
            let budget = maximumBins / max(1, ranges.count)
            var builders = ranges.map {
                WaveformEnvelopeBuilder(firstFrame: $0.lowerBound, endFrame: $0.upperBound, maximumBins: budget)
            }
            while await cursor.position < (ranges.last?.upperBound ?? 0), let chunk = try await cursor.next() {
                try Task.checkCancellation()
                for index in builders.indices { try builders[index].append(chunk) }
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
