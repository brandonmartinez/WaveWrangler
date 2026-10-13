import Foundation
import WWCore
import WWDecode
import WWRender
import WWSources
import WWTimeMap

/// Internal listening PCM only. Map gaps are explicit silence; this never authorizes an edit or export.
public enum AlignedAuditionWindowReader {
    public static let outputRate = 48_000
    public static let maximumDurationSeconds = 5.0

    @concurrent
    public static func readWindow(
        sourceURL: URL, source: SourceID, matching witness: RawSourceIdentity,
        decoder: SourceDecoder, groupMap: GroupTimeMap, decodedChannel: Int,
        startSeconds: Double, durationSeconds: Double
    ) async throws -> [Float] {
        guard startSeconds.isFinite, startSeconds >= 0, startSeconds <= 86_400,
              durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= maximumDurationSeconds,
              let placement = groupMap.placements.first(where: { $0.occurrence.source == source })
        else { throw WaveformWindowError.invalidWindow }
        let first = Int64((startSeconds * Double(outputRate)).rounded(.down))
        let count = Int64((durationSeconds * Double(outputRate)).rounded(.up))
        return try await decoder.withWitnessBoundDecodingCursor(
            sourceURL, source: source, matching: witness
        ) { cursor in
            guard placement.occurrence.nominalRate.framesPerSecond == cursor.interpretation.sourceSampleRate,
                  placement.occurrence.frameCount == cursor.interpretation.frames.validFrames
            else { throw WaveformWindowError.mapDoesNotMatchSource }
            guard decodedChannel >= 0, decodedChannel < cursor.interpretation.channelCount else {
                throw SampleStreamFailure.invalidChannel(decodedChannel)
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
                outputFrames: first..<(first + count),
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
            return rendered.product[0]
        }
    }
}
