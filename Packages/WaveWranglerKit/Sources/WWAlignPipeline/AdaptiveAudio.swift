import Foundation
import WWCore
import WWDecode
import WWDerived
import WWSources
import WWTimeMap

struct AdaptivePCM: Sendable, Codable {
    let firstFrame: Int64
    let channels: [[Float]]
}

public enum AdaptiveAudioRenderFailure: Error, LocalizedError, Sendable, Equatable {
    case inputShape(expectedChannels: Int, expectedFrames: Int, actualFrames: [Int])
    case outputCoverage(alignedFrame: Int64, outputRate: Int, segment: Int, sample: Int, availableFrames: Int)
    case processing(PitchPreservingAudio.Failure)
    case invalidTile

    public var errorDescription: String? {
        switch self {
        case let .inputShape(channels, frames, actual):
            "Aligned audio preparation expected \(channels) channels of \(frames) frames but received channel lengths \(actual). No partial audio was used."
        case let .outputCoverage(frame, rate, segment, sample, available):
            "Aligned audio rendering did not cover \(String(format: "%.6f", Double(frame) / Double(rate))) seconds (timing interval \(segment + 1), sample \(sample), \(available) processed frames). This is a rendering failure, not evidence that the original recording is corrupt."
        case let .processing(failure): failure.errorDescription
        case .invalidTile: "The cached aligned-audio tile has an invalid shape or non-finite samples. No substitute audio was used."
        }
    }
}

extension AlignmentPipeline {
    public static func adaptiveAudioReservationBytes(channels: Int, sourceRate: Int, outputRate: Int = 48000) throws -> Int {
        guard channels > 0, (8000...192000).contains(sourceRate), (8000...192000).contains(outputRate) else {
            throw WaveformWindowError.invalidWindow
        }
        let perChannel = (sourceRate * 15 + outputRate * 6) * 4 * 8
        guard channels <= (Int.max - (32 << 20)) / perChannel else { throw WaveformWindowError.invalidWindow }
        return channels * perChannel + (32 << 20)
    }

    /// The same canonical, witnessed five-second tiles serve listening and aligned derived assets.
    public func adaptiveAudioWindow(
        model: ShowDocumentModel, episode episodeID: EpisodeID, source: SourceID,
        sourceURL: URL, matching witness: RawSourceIdentity,
        startSeconds: Double, durationSeconds: Double, outputRate: Int = 48000
    ) async throws -> [[Float]] {
        guard startSeconds.isFinite, (-86400...86400).contains(startSeconds),
              durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 5,
              (8000...192000).contains(outputRate) else { throw WaveformWindowError.invalidWindow }
        let first = Int64(floor(startSeconds * Double(outputRate)))
        let count = Int64(ceil(durationSeconds * Double(outputRate)))
        return try await adaptiveAudioWindow(model: model, episode: episodeID, source: source,
            sourceURL: sourceURL, matching: witness, outputFrames: first..<(first + count), outputRate: outputRate)
    }

    public func adaptiveAudioWindow(
        model: ShowDocumentModel, episode episodeID: EpisodeID, source: SourceID,
        sourceURL: URL, matching witness: RawSourceIdentity,
        outputFrames: Range<Int64>, outputRate: Int = 48000
    ) async throws -> [[Float]] {
        _ = try await verifiedAcceptedMap(model: model, episode: episodeID)
        guard let version = model.episode(episodeID)?.alignment?.acceptedMap,
              let correction = version.sourceCorrections?.first(where: { $0.source == source }),
              correction.isValid, (8000...192000).contains(outputRate),
              (-86400 * Int64(outputRate)...86400 * Int64(outputRate)).contains(outputFrames.lowerBound),
              outputFrames.upperBound > outputFrames.lowerBound,
              outputFrames.upperBound <= outputFrames.lowerBound + 5 * Int64(outputRate)
        else { throw WaveformWindowError.invalidWindow }
        let first = outputFrames.lowerBound
        let count = Int(outputFrames.upperBound - first)
        var output = (0..<correction.channelCount).map { _ in [Float](repeating: 0, count: count) }
        let tileFrames = Int64(outputRate) * 5
        let firstTile = GroupRenderJob.floorDiv(first, tileFrames)
        let lastTile = GroupRenderJob.floorDiv(first + Int64(count) - 1, tileFrames)
        for index in firstTile...lastTile {
            let tile = try await adaptiveTile(model: model, episode: episodeID, correction: correction,
                sourceURL: sourceURL, witness: witness, index: index, outputRate: outputRate)
            let lo = max(first, tile.firstFrame), hi = min(first + Int64(count), tile.firstFrame + tileFrames)
            guard hi > lo else { continue }
            for channel in output.indices {
                output[channel].replaceSubrange(Int(lo - first)..<Int(hi - first),
                    with: tile.channels[channel][Int(lo - tile.firstFrame)..<Int(hi - tile.firstFrame)])
            }
        }
        _ = try await verifiedAcceptedMap(model: model, episode: episodeID)
        try Task.checkCancellation()
        return output
    }

    private func adaptiveTile(
        model: ShowDocumentModel, episode episodeID: EpisodeID, correction: SourceTimingCorrection,
        sourceURL: URL, witness: RawSourceIdentity, index: Int64, outputRate: Int
    ) async throws -> AdaptivePCM {
        let map = try await verifiedAcceptedMap(model: model, episode: episodeID)
        guard let version = model.episode(episodeID)?.alignment?.acceptedMap else { throw AlignmentAcceptanceError.noReference }
        let revision = MapRevisionReference(episode: episodeID, revision: version.revision)
        let identity = try mapIdentity(revision: revision, version: version, map: map,
                                      registered: await coordinator.inputs.sources)
        guard let token = identity.sources.first(where: { $0.source == correction.source })?.token else {
            throw AlignmentWorkFailure.sourceFactsMismatch
        }
        let asset = AssetSpec(kind: "ww.adaptive-audio-tile", revision: PitchPreservingAudio.renderRecipeVersion)
        let recipe = RecipeReference(name: "\(PitchPreservingAudio.identifier);rate=\(outputRate);tile=\(index);seconds=5;fade=4ms;v5-output-grid-coverage;contiguous-crossfade=duration-bounded-8ms",
                                     revision: PitchPreservingAudio.renderRecipeVersion)
        let key = DerivedAssetKey(asset: asset, sources: identity.sources, format: .current,
            occurrence: alignmentOccurrenceID(for: correction.source), map: revision,
            recipe: recipe, upstream: [identity.key])
        let slot = DerivedSlot("adaptive-audio/\(episodeID)/\(correction.source)/\(outputRate)/\(index)")
        await coordinator.setAssetRevision(asset)
        await coordinator.setRecipe(recipe)
        try Task.checkCancellation()
        guard await coordinator.staleReasons(for: key).isEmpty else {
            throw AlignmentWorkFailure.acceptedMapChanged
        }
        let cacheKey = AdaptiveAudioPCMCache.Key(asset: key, witness: witness)
        let tile: AdaptivePCM
        if let cached = await adaptivePCMCache.tile(for: cacheKey) {
            tile = cached
        } else {
            let decoder = decoder, gate = gate
            let admittedBytes = try Self.adaptiveAudioReservationBytes(channels: correction.channelCount,
                sourceRate: correction.sourceRate, outputRate: outputRate)
            let result = await coordinator.run(slot, key: key) { () throws(AlignmentWorkFailure) -> Data in
                do {
                    return try await gate.withAdmission(bytes: admittedBytes) {
                        let rendered = try await Self.renderAdaptiveTile(
                            correction: correction, url: sourceURL, witness: witness,
                            decoder: decoder, index: index, outputRate: outputRate
                        )
                        return try JSONEncoder().encode(rendered)
                    }
                } catch { throw workFailure(error) }
            }
            try Task.checkCancellation()
            guard result.isAvailable, await coordinator.staleReasons(for: key).isEmpty,
                  let bytes = await coordinator.readyPayload(for: slot, matching: key) else {
                if case let .adaptiveAudio(failure)? = result.typedFailure { throw failure }
                throw result.typedFailure ?? AlignmentWorkFailure.encoding("Adaptive audio became unavailable or stale.")
            }
            tile = try JSONDecoder().decode(AdaptivePCM.self, from: bytes)
            guard tile.firstFrame == index * Int64(outputRate) * 5,
                  tile.channels.count == correction.channelCount,
                  tile.channels.allSatisfy({ $0.count == outputRate * 5 && $0.allSatisfy(\.isFinite) }) else {
                throw AdaptiveAudioRenderFailure.invalidTile
            }
        }
        // Cache hits must still witness the actual file, not merely trust a previously registered token.
        try await decoder.withWitnessBoundDecodingCursor(sourceURL, source: correction.source, matching: witness) { cursor in
            try SourceProbe.verify(cursor.interpretation, source: correction.source, token: token)
            try await cursor.verifyUnchanged()
        }
        try Task.checkCancellation()
        guard await coordinator.staleReasons(for: key).isEmpty else {
            throw AlignmentWorkFailure.acceptedMapChanged
        }
        await adaptivePCMCache.insert(tile, for: cacheKey)
        return tile
    }

    private static func renderAdaptiveTile(
        correction: SourceTimingCorrection, url: URL, witness: RawSourceIdentity,
        decoder: SourceDecoder, index: Int64, outputRate: Int
    ) async throws -> AdaptivePCM {
        try await AdaptiveAudioRendering.tile(correction: correction, index: index, outputRate: outputRate) { range in
            guard !range.isEmpty, range.count <= correction.sourceRate * 15 else { throw WaveformWindowError.invalidWindow }
            return try await decoder.withWitnessBoundDecodingCursor(
                url, source: correction.source, matching: witness
            ) { cursor in
                guard cursor.interpretation.sourceSampleRate == correction.sourceRate,
                      cursor.interpretation.frames.validFrames == correction.sourceFrames,
                      cursor.interpretation.channelCount == correction.channelCount else {
                    throw WaveformWindowError.mapDoesNotMatchSource
                }
                try WaveformViewport.verifyDecodeBudget(ranges: [range], rate: correction.sourceRate,
                                                        randomAccess: cursor.supportsRandomAccess)
                if cursor.supportsRandomAccess { try await cursor.seek(toSourceFrame: range.lowerBound) }
                var samples = (0..<correction.channelCount).map { _ in [Float]() }
                while await cursor.position < range.upperBound,
                      let chunk = try await cursor.next(upToSourceFrame: range.upperBound) {
                    try Task.checkCancellation()
                    let lo = max(range.lowerBound, chunk.firstSourceFrame)
                    let hi = min(range.upperBound, chunk.firstSourceFrame + Int64(chunk.frameCount))
                    guard hi > lo else { continue }
                    for channel in samples.indices {
                        let start = channel * chunk.frameCount + Int(lo - chunk.firstSourceFrame)
                        samples[channel].append(contentsOf: chunk.samples[start..<start + Int(hi - lo)])
                    }
                }
                try await cursor.verifyUnchanged()
                guard samples.allSatisfy({ $0.count == range.count }) else {
                    throw AdaptiveAudioRenderFailure.inputShape(expectedChannels: correction.channelCount,
                        expectedFrames: range.count, actualFrames: samples.map(\.count))
                }
                return samples
            }
        }
    }
}

enum AdaptiveAudioRendering {
    /// Native phase state follows source-region blocks, never transport or five-second cache cuts.
    static func tile(
        correction: SourceTimingCorrection, index: Int64, outputRate: Int,
        load: @Sendable (Range<Int64>) async throws -> [[Float]]
    ) async throws -> AdaptivePCM {
        guard correction.isValid, (8000...192000).contains(outputRate),
              (-17281...17281).contains(index) else { throw WaveformWindowError.invalidWindow }
        let tileStart = Double(index) * 5, tileEnd = tileStart + 5
        let firstFrame = index * Int64(outputRate) * 5
        let rate = Double(correction.sourceRate), destinationRate = Double(outputRate)
        var output = (0..<correction.channelCount).map { _ in [Float](repeating: 0, count: outputRate * 5) }
        func joins(_ left: SourceTimingSegment, _ right: SourceTimingSegment) -> Bool {
            correction.version >= 3 && abs(left.sourceEnd - right.sourceStart) <= 1e-9
                && abs(left.alignedEnd - right.alignedStart) <= 1e-9
        }
        func crossfadeHalfWidth(_ left: SourceTimingSegment, _ right: SourceTimingSegment) -> Double {
            min(0.004, (left.alignedEnd - left.alignedStart) / 2, (right.alignedEnd - right.alignedStart) / 2)
        }
        for (index, segment) in correction.segments.enumerated() {
            let leading = index > 0 && joins(correction.segments[index - 1], segment)
            let trailing = index + 1 < correction.segments.count && joins(segment, correction.segments[index + 1])
            let leadingWidth = leading ? crossfadeHalfWidth(correction.segments[index - 1], segment) : 0
            let trailingWidth = trailing ? crossfadeHalfWidth(segment, correction.segments[index + 1]) : 0
            let renderStart = segment.alignedStart - leadingWidth
            let renderEnd = segment.alignedEnd + trailingWidth
            guard renderStart < tileEnd, renderEnd > tileStart else { continue }
            let sourceLo = segment.sourceStart + (max(tileStart, renderStart) - segment.alignedStart) / segment.rateRatio
            let sourceHi = segment.sourceStart + (min(tileEnd, renderEnd) - segment.alignedStart) / segment.rateRatio
            let firstBlock = max(0, Int(floor((sourceLo - segment.sourceStart - 0.12) / 12)))
            let lastBlock = Int(floor((sourceHi - segment.sourceStart) / 12))
            for block in firstBlock...max(firstBlock, lastBlock) {
                try Task.checkCancellation()
                let blockStart = segment.sourceStart + Double(block) * 12
                let start = blockStart - (block == 0 ? leadingWidth / segment.rateRatio : 0)
                let end = min(segment.sourceEnd + trailingWidth / segment.rateRatio, blockStart + 12.12)
                let alignedStart = segment.alignedStart + (start - segment.sourceStart) * segment.rateRatio
                let alignedEnd = segment.alignedStart + (end - segment.sourceStart) * segment.rateRatio
                let lo = max(firstFrame, Int64(ceil(alignedStart * destinationRate)))
                let hi = min(firstFrame + Int64(outputRate * 5), Int64(ceil(alignedEnd * destinationRate)))
                guard hi > lo else { continue }
                let range = max(0, Int64(floor((start - 0.12) * rate)))..<min(
                    correction.sourceFrames, Int64(ceil((end + 0.12) * rate)))
                guard !range.isEmpty, range.count <= correction.sourceRate * 15 else { throw WaveformWindowError.invalidWindow }
                let input = try await load(range)
                guard input.count == correction.channelCount, input.allSatisfy({ $0.count == range.count }) else {
                    throw AdaptiveAudioRenderFailure.inputShape(expectedChannels: correction.channelCount,
                        expectedFrames: range.count, actualFrames: input.map(\.count))
                }
                let origin = segment.alignedStart + (Double(range.lowerBound) / rate - segment.sourceStart) * segment.rateRatio
                let requiredFrames = Int((Double(hi - 1) - origin * destinationRate).rounded()) + 1
                let rendered = try await PitchPreservingAudio.stretch(input, sampleRate: correction.sourceRate,
                    rateRatio: segment.rateRatio, outputRate: outputRate, minimumOutputFrames: requiredFrames)
                for frame in lo..<hi {
                    let at = Int((Double(frame) - origin * destinationRate).rounded())
                    guard at >= 0, at < rendered[0].count else {
                        throw AdaptiveAudioRenderFailure.outputCoverage(alignedFrame: frame, outputRate: outputRate,
                            segment: index, sample: at, availableFrames: rendered[0].count)
                    }
                    let time = Double(frame) / destinationRate
                    let source = segment.sourceStart + (time - segment.alignedStart) / segment.rateRatio
                    let head = block == 0 ? 1 : min(1, max(0, (source - blockStart) / 0.12))
                    let tail = min(1, max(0, (blockStart + 12.12 - source) / 0.12))
                    let fadeIn = (time - renderStart) / (leading ? 2 * leadingWidth : 0.004)
                    let fadeOut = (renderEnd - time) / (trailing ? 2 * trailingWidth : 0.004)
                    let fade = min(1, max(0, min(fadeIn, fadeOut)))
                    let weight = Float(head * tail * fade)
                    for channel in output.indices {
                        output[channel][Int(frame - firstFrame)] += rendered[channel][at] * weight
                    }
                }
            }
        }
        return AdaptivePCM(firstFrame: firstFrame, channels: output)
    }
}
