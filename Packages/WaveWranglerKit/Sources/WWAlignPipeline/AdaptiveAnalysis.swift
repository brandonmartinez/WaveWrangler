import Foundation
import WWAlignEstimate
import WWAutoAlign
import WWCore
import WWDecode
import WWDerived

/// Source-local evidence, accepted separately from recorder-group clock decisions.
public struct AdaptiveAnalysisRecord: Sendable, Equatable, Codable {
    public let version: Int
    public let estimator: String
    public let reference: AnalysisParticipant
    public let target: AnalysisParticipant
    public let timing: AdaptiveTimingResult
    public let windows: [WindowRecord]
    public let refusal: String?
    public let referenceRevision: Int?
    public let referenceToAlignedRate: Double
    public let referenceToAlignedOffset: Double
    public let referenceCoverageStart: Double
    public let referenceCoverageEnd: Double
    public let analysisKey: DerivedAssetKey?

    public init(
        version: Int = AdaptiveAlignment.version, estimator: String = AdaptiveAlignment.identifier,
        reference: AnalysisParticipant, target: AnalysisParticipant,
        timing: AdaptiveTimingResult, windows: [WindowRecord] = [], refusal: String? = nil,
        referenceRevision: Int? = nil, referenceToAlignedRate: Double = 1,
        referenceToAlignedOffset: Double = 0, referenceCoverageStart: Double = 0,
        referenceCoverageEnd: Double, analysisKey: DerivedAssetKey? = nil
    ) {
        self.version = version
        self.estimator = estimator
        self.reference = reference
        self.target = target
        self.timing = timing
        self.windows = windows
        self.refusal = refusal
        self.referenceRevision = referenceRevision
        self.referenceToAlignedRate = referenceToAlignedRate
        self.referenceToAlignedOffset = referenceToAlignedOffset
        self.referenceCoverageStart = referenceCoverageStart
        self.referenceCoverageEnd = referenceCoverageEnd
        self.analysisKey = analysisKey
    }

    public func playbackIntervals(includeEstimated: Bool = false) -> [SourceTimingSegment] {
        Self.projectedIntervals(timing: timing, scale: referenceToAlignedRate, translation: referenceToAlignedOffset,
            lower: referenceCoverageStart, upper: referenceCoverageEnd, includeEstimated: includeEstimated)
    }

    public var audioPreservation: Result<[SourceTimingSegment], SourceTimingSegment.AudioPreservationError> {
        do {
            return .success(try SourceTimingSegment.preservingAudio(
                in: playbackIntervals(), duration: Double(target.sourceFrames) / Double(target.sourceRate)))
        } catch { return .failure(error) }
    }

    public var audioPreservationError: SourceTimingSegment.AudioPreservationError? {
        if case let .failure(error) = audioPreservation { return error }
        return nil
    }

    static func projectedIntervals(
        timing: AdaptiveTimingResult, scale: Double, translation: Double, lower: Double, upper: Double,
        includeEstimated: Bool
    ) -> [SourceTimingSegment] {
        let confirmed = timing.referenceIntervals.compactMap { region -> SourceTimingSegment? in
            let offset = region.alignedStart - region.rateRatio * region.sourceStart
            let start = max(region.sourceStart, (lower - offset) / region.rateRatio)
            let end = min(region.sourceEnd, (upper - offset) / region.rateRatio)
            guard end > start else { return nil }
            return SourceTimingSegment(sourceStart: start, sourceEnd: end,
                alignedStart: (region.alignedStart + region.rateRatio * (start - region.sourceStart)) * scale + translation,
                rateRatio: region.rateRatio * scale, kind: region.kind)
        }
        return (confirmed + (includeEstimated ? AnchoredTiming.estimatedIntervals(between: confirmed) : []))
            .sorted { $0.sourceStart < $1.sourceStart }
    }

    public func alignedTime(at sourceSeconds: Double, includeEstimated: Bool = false) -> Double? {
        guard let segment = playbackIntervals(includeEstimated: includeEstimated).first(where: {
            $0.sourceStart <= sourceSeconds && sourceSeconds < $0.sourceEnd
        }) else { return nil }
        return segment.alignedStart + (sourceSeconds - segment.sourceStart) * segment.rateRatio
    }
}

extension AlignmentPipeline {
    /// Measures only the selected file against an eligible, already timed speaker reference. The
    /// result is kept separate from group-clock analyses and never approves or moves another source.
    public func analyzeAdaptiveSpeaker(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        sources: [AlignmentSource], authorizations: [ContentWorkAuthorization],
        targetEpoch: RecordingEpochID, speaker: SpeakerID, referenceSource: SourceID, targetSource: SourceID,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> AdaptiveAnalysisRecord {
        try Task.checkCancellation()
        await progress(0)
        let initial = try await analyzeSpeaker(
            model: model, episode: episodeID, sources: sources, authorizations: authorizations,
            targetEpoch: targetEpoch, speaker: speaker, referenceSource: referenceSource, targetSource: targetSource
        )
        return try await analyzeAdaptiveSpeaker(
            model: model, episode: episodeID, sources: sources, authorizations: authorizations,
            targetEpoch: targetEpoch, speaker: speaker, referenceSource: referenceSource,
            targetSource: targetSource, initial: initial, progress: progress
        )
    }

    func analyzeAdaptiveSpeaker(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        sources: [AlignmentSource], authorizations: [ContentWorkAuthorization],
        targetEpoch: RecordingEpochID, speaker: SpeakerID, referenceSource: SourceID, targetSource: SourceID,
        initial: AlignmentAnalysisReport, projectThroughAcceptedMap: Bool = true,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> AdaptiveAnalysisRecord {
        try Task.checkCancellation()
        await progress(0.1)
        if let failure = initial.epochFailures[targetEpoch] { throw failure }
        guard let seed = initial.records[targetEpoch], let dependency = initial.analyses[targetEpoch]?.key,
              let choice = initial.references[targetEpoch],
              let reference = sources.first(where: { $0.id == referenceSource }),
              let target = sources.first(where: { $0.id == targetSource }),
              let referenceFacts = initial.facts[referenceSource], let targetFacts = initial.facts[targetSource]
        else { throw AlignmentAcceptanceError.invalidMap("The current speaker analysis is unavailable; run Align first.") }
        func channel(_ source: SourceID) -> Int? {
            guard let assignment = model.episode(episodeID)?.assignment(for: speaker) else { return nil }
            return ([assignment.primary].compactMap { $0 } + assignment.backups)
                .first { $0.sourceID == source }?
                .resolvedChannel(channelCount: initial.facts[source]?.channelCount)
        }
        let unit = AnalysisUnit(
            referenceChoice: choice, reference: reference, referenceFacts: referenceFacts,
            targetGroup: seed.target.group, targetEpoch: targetEpoch, target: target, targetFacts: targetFacts,
            configuration: configuration, chunkFrames: decoder.configuration.chunkFrames,
            referenceChannel: channel(referenceSource), targetChannel: channel(targetSource)
        )
        guard unit.referenceChannel != nil, unit.targetChannel != nil else {
            throw AlignmentAcceptanceError.invalidMap("Choose a speaker channel for each multichannel recording before adaptive review.")
        }
        var scale = 1.0, offset = 0.0
        var lower = 0.0, upper = Double(referenceFacts.frameCount) / Double(referenceFacts.sampleRate)
        var dependencies = dependency.sources
        if initial.referenceRevision != nil, projectThroughAcceptedMap {
            let map = try await verifiedAcceptedMap(model: model, episode: episodeID)
            let registered = await coordinator.inputs.sources
            for source in Set(map.groups.flatMap { $0.placements.map(\.occurrence.source) })
                where !dependencies.contains(where: { $0.source == source }) {
                guard let token = registered[source] else { throw AlignmentWorkFailure.sourceChangedSinceRegistration }
                dependencies.append(SourceRevision(source: source, token: token))
            }
            guard let group = map.groups.first(where: { $0.group == choice.group }),
                  let epoch = group.epochs.first(where: { $0.epoch == choice.epoch }),
                  case let .mapped(segments, _) = epoch.mapping, segments.count == 1,
                  let segment = segments.first,
                  let placement = group.placements.first(where: { $0.occurrence.source == referenceSource }),
                  let span = placement.spans.first(where: { $0.epoch == choice.epoch })
            else { throw AlignmentAcceptanceError.invalidMap("The reference needs continuous accepted timing for adaptive review.") }
            scale = segment.rateRatio.approximateDouble
            offset = segment.alignedOffset.approximateDouble + scale * span.groupClockOffset.approximateDouble
            lower = max(Double(span.startFrame) / Double(referenceFacts.sampleRate),
                        segment.groupClockStart.approximateDouble - span.groupClockOffset.approximateDouble)
            upper = min(Double(span.endFrame) / Double(referenceFacts.sampleRate),
                        segment.groupClockEnd.approximateDouble - span.groupClockOffset.approximateDouble)
        }
        let asset = AssetSpec(kind: "ww.adaptive-alignment-analysis", revision: AdaptiveAlignment.version)
        let recipe = RecipeReference(name: "\(dependency.recipe?.name ?? "")[\(AdaptiveAlignment.identifier);dense=4s-3s-batch12;grids=0,.75,1.5@.5|.125,.75,1.375@.5|0,.67,1.34@.66;sequence=canonical-mid-.5-one-support;support=local-before-ordinary;shared-quiet=rms1e-4-rel30db-peak20db;spectral=600Hz-complete-grid-broad-mid.6-lag-veto;short=1s-three-quarter.6-canonical-half.6;independence=earliest-finish;bounds=independent-or-local;quiet=\(AdaptiveQuietTiming.identifier)-all-target-channels-raw100ms-guard200ms-gap60s-step50ms-rate1pct;recovery=\(AnchoredTiming.identifier)-gap300s-batch4x12s-logband-path-300ms-quarter.75-half.65-phat1ms-canonical-bounds;estimates=opt-in-gap300s-step50ms-rate1pct;fit=bounded-affine-feasibility;veto=all-strong;local=1ms-500ppm-3independent-max1.01s;scope=file;apply=none]", revision: 1)
        let key = DerivedAssetKey(
            asset: asset, sources: dependencies, format: .current, epoch: targetEpoch,
            occurrence: alignmentOccurrenceID(for: targetSource), channel: unit.targetChannel,
            map: initial.referenceRevision.map { MapRevisionReference(episode: episodeID, revision: $0) },
            recipe: recipe, upstream: [dependency]
        )
        await coordinator.setAssetRevision(asset)
        await coordinator.setRecipe(recipe)
        let environment = environment
        let result = await coordinator.run(DerivedSlot("adaptive/\(targetSource)"), key: key) {
            () throws(AlignmentWorkFailure) -> Data in
            do {
                let dense = try await AdaptiveAnalysis.run(unit: unit, environment: environment) {
                    await progress(0.1 + 0.9 * $0)
                }
                return try JSONEncoder().encode(dense)
            } catch { throw workFailure(error) }
        }
        try Task.checkCancellation()
        guard result.isAvailable, await coordinator.staleReasons(for: key).isEmpty,
              let data = coordinator.store.payload(for: key)
        else { throw result.typedFailure ?? AlignmentWorkFailure.encoding("Adaptive evidence did not publish or became stale.") }
        let dense = try JSONDecoder().decode(AdaptiveAnalysis.Payload.self, from: data)
        guard dense.version == AdaptiveAlignment.version else { throw AlignmentWorkFailure.encoding("Unsupported adaptive analysis version.") }
        await progress(1)
        return AdaptiveAnalysisRecord(
            version: dense.version, estimator: AdaptiveAlignment.identifier, reference: seed.reference, target: seed.target,
            timing: dense.timing, windows: dense.windows, refusal: dense.refusal, referenceRevision: initial.referenceRevision,
            referenceToAlignedRate: scale, referenceToAlignedOffset: offset,
            referenceCoverageStart: lower, referenceCoverageEnd: upper, analysisKey: key
        )
    }
}

enum AdaptiveAnalysis {
    struct Payload: Sendable, Codable {
        let version: Int
        let timing: AdaptiveTimingResult
        let windows: [WindowRecord]
        let refusal: String?
    }

    static func run(
        unit: AnalysisUnit, environment: PipelineEnvironment,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Payload {
        guard unit.referenceFacts.frameCount > 0, unit.targetFacts.frameCount > 0,
              Double(unit.referenceFacts.frameCount) / Double(unit.referenceFacts.sampleRate) <= AdaptiveAlignment.maximumSeconds,
              Double(unit.targetFacts.frameCount) / Double(unit.targetFacts.sampleRate) <= AdaptiveAlignment.maximumSeconds
        else { throw AlignEstimateError.invalidParameter("Adaptive analysis supports channels up to two hours.") }
        let chunks = 6 * unit.chunkFrames * max(unit.referenceFacts.channelCount, unit.targetFacts.channelCount) * MemoryLayout<Float>.size
        let referenceFactor = try AnalysisUnit.factor(unit.referenceFacts.sampleRate, unit.configuration.minimumAnalysisRate)
        let targetFactor = try AnalysisUnit.factor(unit.targetFacts.sampleRate, unit.configuration.minimumAnalysisRate)
        let rate = max(unit.referenceFacts.sampleRate / referenceFactor, unit.targetFacts.sampleRate / targetFactor)
        let energyBytes = 3 * Int(AdaptiveAlignment.maximumSeconds) * 9 * MemoryLayout<TemporalCorroboration.Energy?>.stride
        let spectralBytes = 3 * Int(AdaptiveAlignment.maximumSeconds)
            * (MemoryLayout<SpectralTimingWitness>.stride + 9 * MemoryLayout<TemporalCorroboration>.stride)
        let quietBytes = 80 << 20 // Energy profiles, quiet witnesses, bounded recovery and serialization.
        return try await environment.gate.withAdmission(bytes: (160 << 20) + energyBytes + spectralBytes + quietBytes + 48 * 10 * rate * 4 + 10 * rate * 32 + chunks) {
            let reference = try await FingerprintAnalysis.load(
                source: unit.reference, facts: unit.referenceFacts, channel: unit.referenceChannel,
                minimumRate: unit.configuration.minimumAnalysisRate, environment: environment
            )
            let target = try await FingerprintAnalysis.load(
                source: unit.target, facts: unit.targetFacts, channel: unit.targetChannel,
                minimumRate: unit.configuration.minimumAnalysisRate, environment: environment
            )
            let plan = try FingerprintAlignment.plan(reference: reference, target: target)
            if let abstention = plan.abstention {
                return Payload(
                    version: AdaptiveAlignment.version, timing: try AdaptiveAlignment.regions(observations: [], start: 0, end: target.duration),
                    windows: [], refusal: abstention.detail
                )
            }
            guard !plan.passages.isEmpty else {
                throw AlignEstimateError.invalidParameter("No bounded adaptive search seeds.")
            }
            let starts = Array(stride(from: plan.start, through: plan.end - 4, by: 3))
            var attempts: [DelayEvidence] = []
            for batch in stride(from: 0, to: starts.count, by: 12) {
                try Task.checkCancellation()
                let times = Array(starts[batch..<min(batch + 12, starts.count)])
                let offsets = try times.map { time in
                    guard let seed = plan.passages.min(by: { abs($0.start - time) < abs($1.start - time) }) else {
                        throw AlignEstimateError.invalidParameter("Missing adaptive search seed.")
                    }
                    return seed.offset
                }
                func frames(_ start: Double, _ end: Double, facts: SourceFacts) -> Range<Int64> {
                    let lo = max(0, Int64(ceil(start * Double(facts.sampleRate))))
                    let hi = max(lo, min(facts.frameCount, Int64(floor(end * Double(facts.sampleRate)))))
                    return lo..<hi
                }
                let targetRanges = times.map { frames($0, $0 + 4, facts: unit.targetFacts) }
                let referenceRanges = zip(times, offsets).map {
                    frames($0 + $1 - 0.37, $0 + $1 + 4.37, facts: unit.referenceFacts)
                }
                let targets = try await AutomaticAnalysis.buffers(
                    unit.target, facts: unit.targetFacts, ranges: targetRanges, channel: unit.targetChannel,
                    minimumRate: unit.configuration.minimumAnalysisRate, decoder: environment.decoder
                )
                let references = try await AutomaticAnalysis.buffers(
                    unit.reference, facts: unit.referenceFacts, ranges: referenceRanges, channel: unit.referenceChannel,
                    minimumRate: unit.configuration.minimumAnalysisRate, decoder: environment.decoder
                )
                for index in times.indices {
                    try Task.checkCancellation()
                    let tp = try unit.participant(unit.targetGroup, unit.targetEpoch, unit.target, unit.targetFacts, range: targetRanges[index])
                    let rp = try unit.participant(unit.referenceChoice.group, unit.referenceChoice.epoch, unit.reference, unit.referenceFacts, range: referenceRanges[index])
                    let fresh = try AdaptiveAlignment.measure(
                        reference: unit.track(samples: references[index], participant: rp),
                        target: unit.track(samples: targets[index], participant: tp), station: (batch + index) % 16,
                        predictedOffset: offsets[index], deviation: 0.35, rateRatio: plan.refinementRateRatio
                    )
                    attempts += fresh
                }
                await progress(0.85 * Double(batch + times.count) / Double(starts.count))
            }
            let measured = try AdaptiveAlignment.regions(observations: attempts, start: plan.start, end: plan.end)
            var timing = measured
            if measured.regions.count > 1 {
                let referenceEnergy = try await QuietTimingAnalysis.profile(
                    source: unit.reference, facts: unit.referenceFacts, channel: unit.referenceChannel,
                    allChannels: false, environment: environment)
                await progress(0.91)
                let targetEnergy = try await QuietTimingAnalysis.profile(
                    source: unit.target, facts: unit.targetFacts, channel: unit.targetChannel,
                    allChannels: true, environment: environment)
                await progress(0.94)
                timing = try AdaptiveQuietTiming.adding(to: measured, target: targetEnergy, reference: referenceEnergy)
                timing = try await AnchoredTimingAnalysis.run(timing: timing, unit: unit, environment: environment,
                    reference: reference, target: target) { await progress(0.94 + 0.05 * $0) }
                for (source, facts) in [(unit.reference, unit.referenceFacts), (unit.target, unit.targetFacts)] {
                    try await QuietTimingAnalysis.verifyCurrent(source: source, facts: facts, environment: environment)
                }
            }
            try Task.checkCancellation()
            await progress(1)
            return Payload(version: AdaptiveAlignment.version, timing: timing, windows: attempts.enumerated().map {
                let p = $0.element
                return WindowRecord(index: $0.offset, groupClockCenter: p.targetCenter, status: p.status,
                    peakScore: p.nccScore, secondPeakScore: p.nccSecond, periodicityScore: 0,
                    offsetSeconds: p.offsetSeconds, method: p.method, phatOffsetSeconds: p.phatOffsetSeconds,
                    phatPeakRatio: p.phatPeakRatio, polarity: p.polarity, corroborations: p.corroborations,
                    spectralWitness: p.spectralWitness)
            }, refusal: timing.regions.isEmpty ? "No local run has three independent, unambiguous windows. No timing was applied." : nil)
        }
    }
}
