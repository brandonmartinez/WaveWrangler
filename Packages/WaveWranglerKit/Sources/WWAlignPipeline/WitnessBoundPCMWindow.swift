import Foundation
import WWCore
import WWDecode
import WWSources

public enum WitnessBoundPCMWindowFailure: Error, Sendable, Equatable {
    case invalidChannel
    case invalidRange
    case unsupportedSampleRate(Int)
    case incompleteWindow
    case invalidSamples
    case discontinuousSource
}

public struct WitnessBoundPCMWindow: Sendable, Equatable {
    public let source: SourceID
    public let firstSourceFrame: Int64
    public let sampleRate: Int
    public let sourceFrameCount: Int64
    public let channelCount: Int
    public let sourceFingerprint: FileSystemFingerprint
    public let samples: [Float]
}

/// Mechanical read, not an access grant: the app must bind the witness to the current confirmed
/// Primary, device record and open show before calling, and reverify them before using the result.
/// Unsupported source rates refuse; this does not silently resample or open another channel.
public struct WitnessBoundPCMWindowReader: Sendable {
    public static let sampleRate = 16_000
    public static let frameCount = 32_000
    public static let maximumSourceFrames: Int64 = 10 * 60 * 16_000

    private let decoder: SourceDecoder

    public init(access: SourceAccessContext) {
        decoder = SourceDecoder(access: access)
    }

    public func readWindow(
        _ url: URL, source: SourceID, matching witness: RawSourceIdentity,
        channel: Int, startFrame: Int64
    ) async throws -> WitnessBoundPCMWindow {
        guard channel >= 0 else { throw WitnessBoundPCMWindowFailure.invalidChannel }
        guard startFrame >= 0,
              startFrame <= Self.maximumSourceFrames - Int64(Self.frameCount)
        else { throw WitnessBoundPCMWindowFailure.invalidRange }
        return try await decoder.withWitnessBoundDecodingCursor(url, source: source, matching: witness) { cursor in
            let format = cursor.interpretation
            guard format.source == source else { throw WitnessBoundPCMWindowFailure.discontinuousSource }
            guard channel < format.channelCount else { throw WitnessBoundPCMWindowFailure.invalidChannel }
            guard format.sourceSampleRate == Self.sampleRate else {
                throw WitnessBoundPCMWindowFailure.unsupportedSampleRate(format.sourceSampleRate)
            }
            let end = startFrame + Int64(Self.frameCount)
            guard format.frames.validFrames <= Self.maximumSourceFrames, end <= format.frames.validFrames else {
                throw WitnessBoundPCMWindowFailure.invalidRange
            }

            var samples: [Float] = []
            samples.reserveCapacity(Self.frameCount)
            var next: Int64 = 0
            while samples.count < Self.frameCount {
                try Task.checkCancellation()
                guard let chunk = try await cursor.next() else { throw WitnessBoundPCMWindowFailure.incompleteWindow }
                guard chunk.firstSourceFrame == next, chunk.channelCount == format.channelCount else {
                    throw WitnessBoundPCMWindowFailure.discontinuousSource
                }
                next += Int64(chunk.frameCount)
                let low = max(chunk.firstSourceFrame, startFrame)
                let high = min(next, end)
                if high > low {
                    let base = channel * chunk.frameCount
                    let range = (base + Int(low - chunk.firstSourceFrame))..<(base + Int(high - chunk.firstSourceFrame))
                    guard chunk.samples[range].allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
                        throw WitnessBoundPCMWindowFailure.invalidSamples
                    }
                    samples.append(contentsOf: chunk.samples[range])
                }
            }
            try Task.checkCancellation()
            return WitnessBoundPCMWindow(
                source: source, firstSourceFrame: startFrame, sampleRate: Self.sampleRate,
                sourceFrameCount: format.frames.validFrames, channelCount: format.channelCount,
                sourceFingerprint: format.sourceFingerprint, samples: samples
            )
        }
    }
}
