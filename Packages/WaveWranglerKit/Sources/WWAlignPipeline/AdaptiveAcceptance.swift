import Foundation
import WWAutoAlign
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWTimeMap

extension AlignmentPipeline {
    public func acceptAdaptive(
        model: ShowDocumentModel, episode episodeID: EpisodeID, record: AdaptiveAnalysisRecord,
        sources: [AlignmentSource], authorizations: [ContentWorkAuthorization], includeEstimated: Bool = false
    ) async throws -> AcceptedAlignment {
        guard let episode = model.episode(episodeID), let key = record.analysisKey,
              record.version == AdaptiveAlignment.version, record.estimator == AdaptiveAlignment.identifier,
              record.referenceRevision == episode.alignment?.acceptedRevision,
              await coordinator.staleReasons(for: key).isEmpty,
              await coordinator.readyPayload(for: DerivedSlot("adaptive/\(record.target.source)"), matching: key) != nil,
              let payload = coordinator.store.payload(for: key),
              let baseKey = await coordinator.state(of: PipelineSlots.analysis(record.target.epoch)).key,
              key.upstream.contains(baseKey.digest), let base = coordinator.store.payload(for: baseKey) else {
            throw AlignmentAcceptanceError.invalidMap("Adaptive evidence is absent or stale. Analyze this pair again.")
        }
        let measured = try JSONDecoder().decode(AdaptiveAnalysis.Payload.self, from: payload)
        let seed = try EpochAnalysisRecord.decode(base)
        guard measured.version == AdaptiveAlignment.version, measured.timing == record.timing, measured.windows == record.windows,
              seed.reference == record.reference, seed.target == record.target,
              !record.timing.regions.isEmpty else {
            throw AlignmentAcceptanceError.invalidMap("Adaptive evidence does not match its measured result.")
        }
        let preparation = try await prepareManual(
            model: model, episode: episodeID, sources: sources, authorizations: authorizations
        )
        let map: AlignedTimelineMap
        if episode.alignment?.acceptedRevision != nil {
            map = try await verifiedAcceptedMap(model: model, episode: episodeID)
        } else {
            map = try MapAcceptance.build(
                plan: preparation.plan, facts: preparation.facts, analyses: [:], decisions: [:], prior: nil
            ).map
        }
        guard let facts = preparation.facts[record.target.source],
              facts.sampleRate == record.target.sourceRate, facts.frameCount == record.target.sourceFrames,
              facts.channelCount == record.target.channelCount,
              facts.revisionToken == record.target.revisionToken,
              preparation.facts[record.reference.source]?.revisionToken == record.reference.revisionToken,
              let reference = map.groups.first(where: { $0.group == record.reference.group }),
              let placement = reference.placements.first(where: { $0.occurrence.source == record.reference.source }),
              let span = placement.spans.first(where: { $0.epoch == record.reference.epoch }),
              let epoch = reference.epochs.first(where: { $0.epoch == span.epoch }),
              case let .mapped(segments, _) = epoch.mapping, segments.count == 1,
              let projection = segments.first,
              case let .success((group, targetEpoch))? = episode.source(record.target.source)
                .flatMap({ episode.alignmentPlacement(of: $0) }),
              group == record.target.group, targetEpoch == record.target.epoch else {
            throw AlignmentAcceptanceError.invalidMap("The target or continuous reference placement changed.")
        }
        let referenceRate = Double(placement.occurrence.nominalRate.framesPerSecond)
        let lower = max(Double(span.startFrame) / referenceRate,
                        projection.groupClockStart.approximateDouble - span.groupClockOffset.approximateDouble)
        let upper = min(Double(span.endFrame) / referenceRate,
                        projection.groupClockEnd.approximateDouble - span.groupClockOffset.approximateDouble)
        let scale = projection.rateRatio.approximateDouble
        let translation = projection.alignedOffset.approximateDouble + scale * span.groupClockOffset.approximateDouble
        let quietTiming = try AdaptiveQuietTiming.attaching(record.timing.quietTransitions ?? [], to: record.timing,
            targetChannels: facts.channelCount, targetDuration: Double(facts.frameCount) / Double(facts.sampleRate),
            referenceDuration: Double(record.reference.sourceFrames) / Double(record.reference.sourceRate))
        let timing = try AnchoredTiming.recovering(quietTiming, observations: record.timing.anchoredRecovery?.observations ?? [])
        guard timing == record.timing else {
            throw AlignmentAcceptanceError.invalidMap("Anchor-guided evidence does not reproduce its timing.")
        }
        let curve = AdaptiveAnalysisRecord.projectedIntervals(timing: timing, scale: scale, translation: translation,
                                                              lower: lower, upper: upper, includeEstimated: includeEstimated)
        let correction = SourceTimingCorrection(
            source: record.target.source, group: group, epoch: targetEpoch, reference: record.reference.source,
            sourceRate: facts.sampleRate, sourceFrames: facts.frameCount, channelCount: facts.channelCount,
            analysisDigest: key.digest, processing: PitchPreservingAudio.identifier, segments: curve
        )
        guard correction.isValid else { throw AlignmentAcceptanceError.invalidMap("No valid adaptive interval remains.") }
        var corrections = episode.alignment?.acceptedMap?.sourceCorrections ?? []
        corrections.removeAll { $0.source == correction.source }
        guard !corrections.contains(where: { $0.source == correction.reference || $0.reference == correction.source }) else {
            throw AlignmentAcceptanceError.invalidMap("Use an unchanged reference, not another adaptively corrected file.")
        }
        corrections.append(correction)
        for participant in [record.reference, record.target] {
            guard let source = sources.first(where: { $0.id == participant.source }) else {
                throw AlignmentAcceptanceError.invalidMap("A measured source is unavailable.")
            }
            try await decoder.withDecodingCursor(source.url, source: participant.source) { cursor in
                try SourceProbe.verify(cursor.interpretation, source: participant.source,
                    token: participant.revisionToken, recorded: source.recordedFingerprint)
                try await cursor.verifyUnchanged()
            }
        }
        guard await coordinator.staleReasons(for: key).isEmpty,
              await coordinator.state(of: PipelineSlots.analysis(record.target.epoch)).key == baseKey,
              await coordinator.readyPayload(for: DerivedSlot("adaptive/\(record.target.source)"), matching: key) != nil else {
            throw AlignmentAcceptanceError.invalidMap("Adaptive evidence changed during acceptance. Analyze again.")
        }
        let measuredTokens = preparation.facts.mapValues(\.revisionToken)
        return try await recordAdaptive(map: map, corrections: corrections, model: model, episode: episodeID,
                                        expectedSources: measuredTokens)
    }

    public func removeAdaptiveCorrection(
        model: ShowDocumentModel, episode episodeID: EpisodeID, source: SourceID
    ) async throws -> AcceptedAlignment {
        let map = try await verifiedAcceptedMap(model: model, episode: episodeID)
        guard var corrections = model.episode(episodeID)?.alignment?.acceptedMap?.sourceCorrections,
              corrections.contains(where: { $0.source == source }) else {
            throw AlignmentAcceptanceError.invalidMap("This file has no accepted adaptive correction.")
        }
        corrections.removeAll { $0.source == source }
        return try await recordAdaptive(map: map, corrections: corrections, model: model, episode: episodeID,
                                        expectedSources: await coordinator.inputs.sources)
    }

    private func recordAdaptive(
        map: AlignedTimelineMap, corrections: [SourceTimingCorrection],
        model: ShowDocumentModel, episode episodeID: EpisodeID, expectedSources: [SourceID: String]
    ) async throws -> AcceptedAlignment {
        guard let episode = model.episode(episodeID) else { throw AlignmentAcceptanceError.episodeNotFound(episodeID) }
        guard !corrections.contains(where: { !$0.isValid }) else {
            throw AlignmentAcceptanceError.invalidMap("Invalid adaptive correction.")
        }
        if await coordinator.isShutdown { throw AlignmentAcceptanceError.coordinatorShutDown }
        let registered = await coordinator.inputs
        guard EmbeddedTimeMapCodec.usedSources(map, corrections: corrections).allSatisfy({
            expectedSources[$0] != nil && registered.sources[$0] == expectedSources[$0]
        }) else { throw AlignmentAcceptanceError.analysisStale([.dependenciesMissing]) }
        guard let digest = MapDependencies.digest(map: map, tokens: registered.sources,
                                                  format: registered.format, corrections: corrections) else {
            throw AlignmentAcceptanceError.analysisStale([.dependenciesMissing])
        }
        let inputs = EmbeddedTimeMapCodec.usedSources(map, corrections: corrections).map {
            TimeMapSourceInput(sourceID: $0, formatInterpretationVersion: registered.format.interpretationVersion)
        }
        let recorded = try model.recordingMap(
            map, in: episodeID, inputs: inputs,
            recipe: MapDependencies.recipe(digest: digest,
                acceptedProposals: episode.alignment?.acceptedMap.map(MapDependencies.acceptedProposals) ?? [:]),
            derivedFrom: episode.alignment?.acceptedRevision,
            sourceCorrections: corrections.isEmpty ? nil : corrections
        )
        let updated = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: episodeID)
        guard let version = updated.episode(episodeID)?.alignment?.acceptedMap else {
            throw AlignmentAcceptanceError.invalidMap("The new adaptive revision is missing.")
        }
        let base = AcceptanceLedger.Snapshot(alignment: episode.alignment)
        let identity = try mapIdentity(revision: recorded.revision, version: version, map: map, registered: registered.sources)
        let token = try await ledger.issue(episode: episodeID, base: base)
        return AcceptedAlignment(model: updated, revision: recorded.revision, map: map, sourcesOutsideCoverage: [],
            identity: identity, token: token, base: base,
            result: AcceptanceLedger.Snapshot(alignment: updated.episode(episodeID)?.alignment))
    }
}
