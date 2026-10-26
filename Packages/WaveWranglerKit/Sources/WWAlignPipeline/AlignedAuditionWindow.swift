import Foundation
import WWCore
import WWDecode
import WWDerived
import WWRender
import WWSources
import WWTimeMap

/// Internal listening PCM only. Map gaps are explicit silence; this never authorizes an edit or export.
public enum AlignedAuditionWindowReader {
    public static let outputRate = 48_000
    public static let maximumDurationSeconds = 5.0

    /// The same witnessed cursor as listening, for freezing actual format/channel facts before
    /// graph construction. This grants no access and never exposes a content reader to the caller.
    @concurrent
    public static func inspectFormat(
        sourceURL: URL, source: SourceID, matching witness: RawSourceIdentity, decoder: SourceDecoder
    ) async throws -> FormatInterpretation {
        try await decoder.withWitnessBoundDecodingCursor(sourceURL, source: source, matching: witness) { cursor in
            try await cursor.verifyUnchanged()
            return cursor.interpretation
        }
    }

    @concurrent
    public static func readWindow(
        sourceURL: URL, source: SourceID, matching witness: RawSourceIdentity,
        decoder: SourceDecoder, groupMap: GroupTimeMap, decodedChannel: Int,
        startSeconds: Double, durationSeconds: Double
    ) async throws -> [Float] {
        guard startSeconds.isFinite, (-86_400...86_400).contains(startSeconds),
              durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= maximumDurationSeconds
        else { throw WaveformWindowError.invalidWindow }
        let first = Int64((startSeconds * Double(outputRate)).rounded(.down))
        let count = Int64((durationSeconds * Double(outputRate)).rounded(.up))
        return try await readWindow(sourceURL: sourceURL, source: source, matching: witness,
            decoder: decoder, groupMap: groupMap, decodedChannel: decodedChannel,
            outputFrames: first..<(first + count))
    }

    /// Frame-domain callers retain their exact start and exclusive end through rendering.
    @concurrent
    public static func readWindow(
        sourceURL: URL, source: SourceID, matching witness: RawSourceIdentity,
        decoder: SourceDecoder, groupMap: GroupTimeMap, decodedChannel: Int,
        outputFrames: Range<Int64>, cache: AlignedAuditionPCMCache? = nil,
        revision: MapRevisionReference? = nil
    ) async throws -> [Float] {
        guard (-86_400 * Int64(outputRate)...86_400 * Int64(outputRate)).contains(outputFrames.lowerBound),
              outputFrames.upperBound > outputFrames.lowerBound,
              outputFrames.upperBound <= outputFrames.lowerBound + 5 * Int64(outputRate),
              let placement = groupMap.placements.first(where: { $0.occurrence.source == source })
        else { throw WaveformWindowError.invalidWindow }
        let count = outputFrames.upperBound - outputFrames.lowerBound
        let startSeconds = Double(outputFrames.lowerBound) / Double(outputRate)
        let durationSeconds = Double(count) / Double(outputRate)
        let result = try await decoder.withWitnessBoundDecodingCursor(
            sourceURL, source: source, matching: witness
        ) { cursor in
            guard placement.occurrence.nominalRate.framesPerSecond == cursor.interpretation.sourceSampleRate,
                  placement.occurrence.frameCount == cursor.interpretation.frames.validFrames
            else { throw WaveformWindowError.mapDoesNotMatchSource }
            guard decodedChannel >= 0, decodedChannel < cursor.interpretation.channelCount else {
                throw SampleStreamFailure.invalidChannel(decodedChannel)
            }
            let key = AlignedAuditionPCMCache.Key(
                witness: witness, interpretation: cursor.interpretation, map: groupMap,
                revision: revision, channel: decodedChannel, frames: outputFrames
            )
            if let samples = await cache?.samples(for: key) {
                try await cursor.verifyUnchanged()
                return (samples: samples, key: key, cached: true)
            }
            let ranges = try WaveformViewport.frameRanges(
                source: source, rate: cursor.interpretation.sourceSampleRate,
                totalFrames: cursor.interpretation.frames.validFrames, groupMap: groupMap,
                startSeconds: startSeconds, durationSeconds: durationSeconds
            )
            try WaveformViewport.verifyDecodeBudget(
                ranges: ranges, rate: cursor.interpretation.sourceSampleRate, randomAccess: cursor.supportsRandomAccess
            )
            let stream = SourceSampleStream(
                cursor: cursor, channelCount: cursor.interpretation.channelCount,
                history: CursorSampleProvider.history(for: .m2Candidate), seekForSkippedFrames: true
            )
            let request = RenderRequest(
                groupMap: groupMap, outputRate: try NominalRate(Int64(outputRate)),
                outputFrames: outputFrames,
                channels: [RenderChannel(
                    occurrence: placement.occurrence.id, decodedChannel: decodedChannel,
                    statedChannel: .known(decodedChannel)
                )],
                inputAssets: [RenderInputAsset(
                    occurrence: placement.occurrence.id, assetVersion: "witness-bound-internal-audition"
                )]
            )
            let rendered = try await GroupRenderer.render(
                request, provider: CursorSampleProvider(streams: [source: stream])
            ) { CollectingSink(manifest: $0) }
            try Task.checkCancellation()
            guard rendered.product.count == 1, rendered.product[0].count == Int(count) else {
                throw RenderFailure.providerShapeMismatch(placement.occurrence.id)
            }
            return (samples: rendered.product[0], key: key, cached: false)
        }
        try Task.checkCancellation()
        if !result.cached { await cache?.insert(result.samples, for: result.key) }
        return result.samples
    }
}
