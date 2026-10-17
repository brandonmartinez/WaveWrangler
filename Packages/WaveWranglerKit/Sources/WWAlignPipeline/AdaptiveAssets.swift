import Foundation
import WWCore
import WWDerived

extension AlignmentPipeline {
    func renderAdaptiveAssets(
        model: ShowDocumentModel, episode: EpisodeID, correction: SourceTimingCorrection,
        participant: GroupRenderJob.Participant, identity: AcceptedMapIdentity, outputRate: Int
    ) async -> GroupRenderReport {
        let first = Int64(floor(correction.segments[0].alignedStart / 5))
        let last = Int64(ceil(correction.segments[correction.segments.count - 1].alignedEnd / 5)) - 1
        let step = Int64(outputRate) * 5
        var report = GroupRenderReport(group: correction.group, outputRate: outputRate,
            outputFrames: first * step..<(last + 1) * step, segments: Int(last - first + 1))
        do {
            let witness = try await decoder.captureRawIdentity(participant.source.url,
                matching: participant.facts.interpretation.sourceFingerprint)
            for index in first...last {
                try Task.checkCancellation()
                _ = try await verifiedAcceptedMap(model: model, episode: episode)
                let recipe = RecipeReference(name: "\(PitchPreservingAudio.identifier);rate=\(outputRate);tile=\(index);seconds=5;fade=4ms;aligned-segment",
                    revision: PitchPreservingAudio.renderRecipeVersion)
                await coordinator.setRecipe(recipe)
                let entries = (0..<correction.channelCount).map { channel in
                    (slot: PipelineSlots.alignedSegment(group: correction.group, source: correction.source,
                                                       channel: channel, segment: index),
                     key: DerivedAssetKey(asset: AlignmentAssetKinds.adaptiveAlignedAudio,
                        sources: identity.sources, format: .current, occurrence: alignmentOccurrenceID(for: correction.source),
                        channel: channel, map: identity.revision, recipe: recipe, upstream: [identity.key]))
                }
                var allReady = true
                for entry in entries {
                    guard await coordinator.staleReasons(for: entry.key).isEmpty else {
                        throw AlignmentWorkFailure.acceptedMapChanged
                    }
                    if await coordinator.state(of: entry.slot) != .ready(entry.key) { allReady = false }
                }
                if allReady { report.segmentsReused += 1; continue }
                let channels = try await adaptiveAudioWindow(model: model, episode: episode, source: correction.source,
                    sourceURL: participant.source.url, matching: witness, startSeconds: Double(index) * 5,
                    durationSeconds: 5, outputRate: outputRate)
                for channel in channels.indices {
                    let samples = channels[channel]
                    let header = AlignedAudioSegment.Header(formatVersion: AlignedAudioSegment.formatVersion,
                        group: correction.group, source: correction.source, occurrence: participant.occurrence,
                        decodedChannel: channel, map: identity.revision, mapDigest: identity.digest,
                        outputRate: outputRate, segmentIndex: index, firstOutputFrame: index * step,
                        frameCount: samples.count, rendererVersion: 1, renderRecipeVersion: PitchPreservingAudio.renderRecipeVersion,
                        outputAssetFormatVersion: 1, processing: PitchPreservingAudio.identifier)
                    let gate = gate
                    let result = await coordinator.run(entries[channel].slot, key: entries[channel].key) { () throws(AlignmentWorkFailure) -> Data in
                        do {
                            return try await gate.withAdmission(bytes: samples.count * 12 + (1 << 20)) {
                                try AlignedAudioSegment.encode(header: header, samples: samples[...])
                            }
                        } catch { throw workFailure(error) }
                    }
                    report.results.append(result)
                    guard result.isAvailable else {
                        throw result.typedFailure ?? AlignmentWorkFailure.encoding("Adaptive aligned audio was not published.")
                    }
                }
                report.segmentsRendered += 1
            }
        } catch { report.failure = workFailure(error) }
        return report
    }
}
