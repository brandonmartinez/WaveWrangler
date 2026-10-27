import CryptoKit
import Foundation
import WWCore
import WWDerived
import WWTimeMap

/// Presentation only. Source admission and measured-overview verification must precede reuse.
struct AlignmentWaveformPreparationCache: Sendable {
    static let asset = AssetSpec(kind: "ww.waveform.presentation", revision: 1)
    let coordinator: DerivedJobCoordinator

    struct Result: Sendable {
        let index: AlignmentWaveformStrokeIndex
        let reused: Bool
        let repaired: Bool
    }

    private struct Inputs: Encodable {
        let group: RecorderGroupID
        let epoch: RecordingEpochID
        let map: GroupTimeMap?
        let correction: SourceTimingCorrection?
        let removals: [Range<Int64>]
        let mappedOnly: Bool
    }

    enum Failure: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): "Saved waveform display unavailable: \(reason)"
            }
        }
    }

    static func key(track: AlignmentWaveformTrack, overviewKey: DerivedAssetKey,
                    map: AlignedTimelineMap?, correction: SourceTimingCorrection?,
                    cuts: ManualCutTimeline, mappedOnly: Bool = false) throws -> DerivedAssetKey {
        let inputs = Inputs(group: track.group, epoch: track.epoch,
            map: map?.groups.first { $0.group == track.group }, correction: correction,
            removals: cuts.removals, mappedOnly: mappedOnly)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(inputs)).map { String(format: "%02x", $0) }.joined()
        return DerivedAssetKey(asset: asset, sources: overviewKey.sources, format: overviewKey.format,
            coverage: digest, upstream: [overviewKey])
    }

    func prepare(track: AlignmentWaveformTrack, overviewKey: DerivedAssetKey, episode: EpisodeID,
                 map: AlignedTimelineMap?, correction: SourceTimingCorrection?,
                 cuts: ManualCutTimeline, mappedOnly: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let key = try Self.key(track: track, overviewKey: overviewKey, map: map, correction: correction,
            cuts: cuts, mappedOnly: mappedOnly)
        let scope = mappedOnly ? "mapped" : "all"
        let slot = DerivedSlot("ww.waveform.presentation.\(episode).\(track.id).\(overviewKey.asset.kind).\(scope)")
        await coordinator.setAssetRevision(Self.asset)
        let work: @Sendable () async throws -> Data = {
            try Task.checkCancellation()
            var strokes = try AlignmentWaveformProjection.strokes(
                track: track, map: map, correction: correction, cuts: cuts)
            if mappedOnly { strokes.removeAll { !$0.mapped } }
            let index = AlignmentWaveformStrokeIndex(strokes: strokes)
            try Task.checkCancellation()
            return try index.cachedPayload()
        }
        for attempt in 0..<2 {
            let job = await coordinator.submit(slot, key: key, work: work)
            let outcome = await job.outcome
            try Task.checkCancellation()
            switch outcome {
            case .published, .reused: break
            case .canceled: throw CancellationError()
            case .discardedStale: throw Failure.unavailable("recordings or timing changed during preparation")
            case .failed(let reason): throw Failure.unavailable(reason)
            }
            guard let payload = await coordinator.readyPayload(for: slot, matching: key) else {
                throw Failure.unavailable("the verified display cache is no longer current")
            }
            if let index = try? AlignmentWaveformStrokeIndex(cachedPayload: payload) {
                return Result(index: index, reused: outcome == .reused(key), repaired: attempt > 0)
            }
            guard attempt == 0 else { throw Failure.unavailable("the rebuilt display cache failed validation") }
            await coordinator.invalidate(slot)
        }
        throw Failure.unavailable("the display cache could not be restored")
    }
}
