import Foundation
import WWCore
import WWDecode
import WWDerived
import WWTimeMap

/// Everything one analysis run produced: the metadata-only plan, the facts of every probed source, each
/// epoch's proposal or abstention (with full evidence) and every failure, typed.
public struct AlignmentAnalysisReport: Sendable {
    public let plan: AlignmentPlan
    /// Facts of every source probed in this run.
    public let facts: [SourceID: SourceFacts]
    public let probes: [SourceID: PipelineJobResult]
    public let analyses: [RecordingEpochID: PipelineJobResult]
    /// Decoded analysis payloads (proposal or abstention) of the analyses that are available.
    public let records: [RecordingEpochID: EpochAnalysisRecord]
    public let sourceFailures: [SourceID: AlignmentWorkFailure]
    public let epochFailures: [RecordingEpochID: AlignmentWorkFailure]
}

/// Why aligned assets were not rendered at all. Nothing was opened.
public enum AlignedAssetRefusal: Error, Sendable, Equatable {
    case episodeNotFound(EpisodeID)
    case noAcceptedMap
    /// The document's accepted revision is not the one the coordinator publishes for (activate it first).
    case acceptedMapNotActive(document: Int, coordinator: Int?)
    case mapNotApplicable([MapStaleness])
    case mapUnreadable(MapHistoryError)
    /// The map's timeline reference occurrence is not placed in it, so there is no output rate.
    case referenceNotPlaced
    case coordinatorShutDown
}

/// What one aligned-asset run did, per recorder group.
public struct AlignedAssetReport: Sendable, Equatable {
    public let revision: MapRevisionReference
    public let outputRate: Int
    public let groups: [GroupRenderReport]
    /// Placed sources whose channels were not rendered, and why.
    public let notRendered: [SourceID: NotRenderedReason]

    /// Every group rendered (or reused) every segment.
    public var isComplete: Bool { groups.allSatisfy { $0.failure == nil } }
}

/// The headless alignment pipeline (WW-021 / WW-023). It never runs on the main actor; all content access
/// goes through `SourceDecoder` cursors, only for eligible sources; every result publishes through the
/// coordinator. See `AlignmentPipelineConfiguration` for the module's hard rules.
public final class AlignmentPipeline: Sendable {
    public let coordinator: DerivedJobCoordinator
    public let decoder: SourceDecoder
    public let configuration: AlignmentPipelineConfiguration
    let gate: ResourceGate

    public init(coordinator: DerivedJobCoordinator, decoder: SourceDecoder, configuration: AlignmentPipelineConfiguration = AlignmentPipelineConfiguration()) {
        self.coordinator = coordinator
        self.decoder = decoder
        self.configuration = configuration
        gate = ResourceGate(permits: configuration.concurrency, budgetBytes: configuration.analysisMemoryBudgetBytes)
    }

    var environment: PipelineEnvironment {
        PipelineEnvironment(coordinator: coordinator, decoder: decoder, configuration: configuration, gate: gate)
    }

    // MARK: Plan (metadata only)

    /// Decides which epochs are analysed against which reference. Reads no content.
    ///
    /// - Parameters:
    ///   - sources: where each source is and its Setup availability.
    ///   - authorizations: the sources the person explicitly asked to align.
    ///   - preferredReference: the person's reference choice; otherwise the accepted map's reference, then
    ///     the first eligible source in episode order.
    public func plan(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        sources: [AlignmentSource],
        authorizations: [ContentWorkAuthorization],
        preferredReference: SourceID? = nil
    ) async -> AlignmentPlan? {
        guard let episode = model.episode(episodeID) else { return nil }
        let registered = await coordinator.inputs.sources
        let eligibility = ContentEligibility(sources: sources, authorizations: authorizations, registered: registered)
        return AlignmentPlanner.plan(
            episode: episode, eligibility: eligibility, preferredReference: preferredReference,
            priorReference: Self.acceptedMap(model: model, episode: episodeID).flatMap { Self.referenceSource(of: $0.map) }
        )
    }

    // MARK: Analysis (consent-gated decode → estimator → proposals/abstentions)

    /// Probes every eligible placed source (header only), then analyses each planned epoch against the
    /// reference. Results are derived assets keyed by every M2-C5 component; nothing becomes a map until a
    /// person accepts it. Returns `nil` when the episode does not exist.
    public func analyse(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        sources: [AlignmentSource],
        authorizations: [ContentWorkAuthorization],
        preferredReference: SourceID? = nil
    ) async -> AlignmentAnalysisReport? {
        guard let plan = await plan(model: model, episode: episodeID, sources: sources, authorizations: authorizations, preferredReference: preferredReference) else {
            return nil
        }
        let coordinator = coordinator
        let environment = environment
        for spec in AlignmentAssetKinds.all { await coordinator.setAssetRevision(spec) }
        let registered = await coordinator.inputs.sources
        let eligibility = ContentEligibility(sources: sources, authorizations: authorizations, registered: registered)

        // 1. Probes, only for eligible placed sources.
        let admitted = plan.eligiblePlacedSources.compactMap { id in eligibility.admitted(id).map { (id, $0.source, $0.token) } }
        let probeResults = await boundedMap(admitted, limit: configuration.concurrency) { entry in
            let (id, source, token) = entry
            return await coordinator.run(PipelineSlots.sourceFacts(id), key: SourceProbe.key(source: id, token: token)) { () throws(AlignmentWorkFailure) -> Data in
                let facts = try await SourceProbe.run(source, token: token, environment: environment)
                do { return try SourceFacts.encode(facts) } catch { throw .encoding(String(describing: error)) }
            }
        }
        var facts: [SourceID: SourceFacts] = [:]
        var probes: [SourceID: PipelineJobResult] = [:]
        var sourceFailures: [SourceID: AlignmentWorkFailure] = [:]
        for (entry, result) in zip(admitted, probeResults) {
            probes[entry.0] = result
            if let failure = result.typedFailure {
                sourceFailures[entry.0] = failure
            } else if let payload = coordinator.store.payload(for: result.key) {
                do { facts[entry.0] = try SourceFacts.decode(payload) } catch { sourceFailures[entry.0] = .encoding(String(describing: error)) }
            } else {
                sourceFailures[entry.0] = .encoding("the published source facts are missing from the store")
            }
        }

        // 2. One analysis unit per epoch to analyse.
        var units: [AnalysisUnit] = []
        var epochFailures: [RecordingEpochID: AlignmentWorkFailure] = [:]
        if let reference = plan.reference {
            for planned in plan.epochs {
                guard case let .analyse(targetID) = planned.disposition else { continue }
                guard let referenceFacts = facts[reference.source], let referenceSource = eligibility.admitted(reference.source)?.source else {
                    epochFailures[planned.epoch] = sourceFailures[reference.source] ?? .sourceFactsUnavailable(reference.source)
                    continue
                }
                guard let targetFacts = facts[targetID], let targetSource = eligibility.admitted(targetID)?.source else {
                    epochFailures[planned.epoch] = sourceFailures[targetID] ?? .sourceFactsUnavailable(targetID)
                    continue
                }
                units.append(AnalysisUnit(
                    referenceChoice: reference, reference: referenceSource, referenceFacts: referenceFacts,
                    targetGroup: planned.group, targetEpoch: planned.epoch, target: targetSource, targetFacts: targetFacts,
                    configuration: configuration, chunkFrames: decoder.configuration.chunkFrames
                ))
            }
        }
        for recipe in Set(units.map(\.recipe)) { await coordinator.setRecipe(recipe) }
        let analysisResults = await boundedMap(units, limit: configuration.concurrency) { unit in
            await coordinator.run(PipelineSlots.analysis(unit.targetEpoch), key: unit.key) { () throws(AlignmentWorkFailure) -> Data in
                try await unit.run(environment: environment)
            }
        }
        var analyses: [RecordingEpochID: PipelineJobResult] = [:]
        var records: [RecordingEpochID: EpochAnalysisRecord] = [:]
        for (unit, result) in zip(units, analysisResults) {
            analyses[unit.targetEpoch] = result
            if let failure = result.typedFailure {
                epochFailures[unit.targetEpoch] = failure
            } else if let payload = coordinator.store.payload(for: result.key) {
                do { records[unit.targetEpoch] = try EpochAnalysisRecord.decode(payload) } catch {
                    epochFailures[unit.targetEpoch] = .encoding(String(describing: error))
                }
            } else {
                epochFailures[unit.targetEpoch] = .encoding("the published analysis is missing from the store")
            }
        }
        return AlignmentAnalysisReport(
            plan: plan, facts: facts, probes: probes, analyses: analyses, records: records,
            sourceFailures: sourceFailures, epochFailures: epochFailures
        )
    }

    /// The engineering state of every planned epoch (inspection spec §1.1–1.2). Analysis records whose keys
    /// went stale since the run are dropped (shown as pending, never as a current proposal).
    public func states(model: ShowDocumentModel, episode episodeID: EpisodeID, report: AlignmentAnalysisReport) async -> [EpochAlignmentState] {
        let current = await currentRecords(report)
        var accepted: (map: AlignedTimelineMap, revision: Int)?
        if let prior = Self.acceptedMap(model: model, episode: episodeID),
           let episode = model.episode(episodeID),
           let applicability = try? episode.applicability(ofMapRevision: prior.revision), applicability.isCurrent {
            accepted = prior
        }
        return AlignmentStateResolver.resolve(
            plan: report.plan, acceptedMap: accepted, analyses: current,
            epochFailures: report.epochFailures, sourceFailures: report.sourceFailures
        )
    }

    // MARK: Accept / apply

    /// Records the person's decisions as a new map revision (derived from the accepted one) and marks it
    /// accepted in the returned document value. The coordinator is NOT changed: persist `model` through the
    /// show document's ordered save first, then call `activate(_:)`.
    ///
    /// Provenance is chosen here, never supplied: the reference epoch is `.timelineReference`, decided epochs
    /// are `.manual(...)` (an accepted proposal is `manual(.acceptedAcousticProposal)`; a rejected one is
    /// `unsupported(.notAttempted)`), undecided epochs keep the prior accepted mapping or, with none, carry a
    /// current proposal as `.acousticConsistentProposal`, and a prior `clockApproved` mapping is refused
    /// rather than carried.
    public func accept(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        report: AlignmentAnalysisReport,
        decisions: [RecordingEpochID: EpochMapDecision]
    ) async throws(AlignmentAcceptanceError) -> AcceptedAlignment {
        guard let episode = model.episode(episodeID), report.plan.episode == episodeID else { throw .episodeNotFound(episodeID) }
        if await coordinator.isShutdown { throw .coordinatorShutDown }
        let registered = await coordinator.inputs.sources
        let facts = report.facts.filter { registered[$0.key] == $0.value.revisionToken }
        let analyses = await currentRecords(report)

        var prior: AlignedTimelineMap?
        let priorRevision = episode.alignment?.acceptedRevision
        if let priorRevision {
            do throws(MapHistoryError) {
                prior = try model.timeMap(revision: priorRevision, in: episodeID)
            } catch {
                throw .priorMapUnreadable(error)
            }
        }
        let built = try MapAcceptance.build(plan: report.plan, facts: facts, analyses: analyses, decisions: decisions, prior: prior)
        do throws(MapHistoryError) {
            let (recorded, revision) = try model.recordingMap(
                built.map, in: episodeID, inputs: built.inputs,
                recipe: AlignmentAssetKinds.acceptanceRecipe, derivedFrom: priorRevision
            )
            let accepted = try recorded.acceptingMap(revision: revision.revision, in: episodeID)
            guard let updated = accepted.episode(episodeID) else { throw MapHistoryError.episodeNotFound(episodeID) }
            let applicability = try updated.applicability(ofMapRevision: revision.revision)
            guard applicability.isCurrent else {
                throw MapHistoryError.invalidMap("the episode changed since the analysis: \(applicability.staleness)")
            }
            return AcceptedAlignment(model: accepted, revision: revision, map: built.map)
        } catch {
            throw .history(error)
        }
    }

    /// Makes the coordinator publish for `accepted.revision`: everything derived from any other revision
    /// becomes stale and late results for it are discarded. Call after the document is saved.
    public func activate(_ accepted: AcceptedAlignment) async throws(AlignmentAcceptanceError) {
        let episodeID = accepted.revision.episode
        guard let episode = accepted.model.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard episode.alignment?.acceptedRevision == accepted.revision.revision else {
            throw .history(.mapNotFound(revision: accepted.revision.revision))
        }
        if await coordinator.isShutdown { throw .coordinatorShutDown }
        await coordinator.acceptMap(accepted.revision)
    }

    // MARK: Aligned assets

    /// Streams the accepted map's aligned audio for every same-group channel into the derived store (app
    /// cache). Refuses unless the document's accepted revision is the coordinator's active one and still
    /// applies to the episode. Internal derived assets only; export stays blocked (M4).
    public func renderAlignedAssets(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        sources: [AlignmentSource],
        authorizations: [ContentWorkAuthorization]
    ) async throws(AlignedAssetRefusal) -> AlignedAssetReport {
        guard let episode = model.episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard let revisionNumber = episode.alignment?.acceptedRevision else { throw .noAcceptedMap }
        if await coordinator.isShutdown { throw .coordinatorShutDown }
        let active = await coordinator.inputs.acceptedMaps[episodeID]
        guard active == revisionNumber else { throw .acceptedMapNotActive(document: revisionNumber, coordinator: active) }
        let map: AlignedTimelineMap
        let applicability: MapApplicability
        do throws(MapHistoryError) {
            applicability = try episode.applicability(ofMapRevision: revisionNumber)
            map = try model.timeMap(revision: revisionNumber, in: episodeID)
        } catch {
            throw .mapUnreadable(error)
        }
        guard applicability.isCurrent else { throw .mapNotApplicable(applicability.staleness) }
        guard let referenceOccurrence = map.groups.lazy.flatMap(\.placements).first(where: { $0.occurrence.id == map.reference.occurrence })?.occurrence else {
            throw .referenceNotPlaced
        }
        let revision = MapRevisionReference(episode: episodeID, revision: revisionNumber)
        for spec in AlignmentAssetKinds.all { await coordinator.setAssetRevision(spec) }
        let registered = await coordinator.inputs.sources
        let eligibility = ContentEligibility(sources: sources, authorizations: authorizations, registered: registered)
        let outputRate = Int(referenceOccurrence.nominalRate.framesPerSecond)

        var jobs: [GroupRenderJob] = []
        var notRendered: [SourceID: NotRenderedReason] = [:]
        var failedGroups: [GroupRenderReport] = []
        for group in map.groups {
            var mapped = Set<RecordingEpochID>()
            for epoch in group.epochs {
                if case .mapped = epoch.mapping { mapped.insert(epoch.epoch) }
            }
            var participants: [GroupRenderJob.Participant] = []
            for placement in group.placements {
                let id = placement.occurrence.source
                if let unmapped = placement.spans.first(where: { !mapped.contains($0.epoch) }) {
                    notRendered[id] = .epochUnsupported(unmapped.epoch)
                    continue
                }
                if let reason = eligibility.check(id) {
                    notRendered[id] = .ineligible(reason)
                    continue
                }
                guard let (source, token) = eligibility.admitted(id),
                      let payload = coordinator.store.payload(for: SourceProbe.key(source: id, token: token)),
                      let facts = try? SourceFacts.decode(payload),
                      facts.revisionToken == token,
                      Int64(facts.sampleRate) == placement.occurrence.nominalRate.framesPerSecond,
                      facts.frameCount == placement.occurrence.frameCount
                else {
                    notRendered[id] = .factsUnavailable
                    continue
                }
                participants.append(GroupRenderJob.Participant(source: source, facts: facts))
            }
            guard !participants.isEmpty else { continue }
            let hull: Range<Int64>?
            do throws(AlignmentWorkFailure) {
                hull = try GroupRenderJob.hull(
                    map: group, occurrences: participants.map(\.occurrence),
                    frameCounts: participants.map(\.facts.frameCount), outputRate: outputRate
                )
            } catch {
                var failed = GroupRenderReport(group: group.group, outputRate: outputRate, outputFrames: 0 ..< 0, segments: 0)
                failed.failure = error
                failedGroups.append(failed)
                continue
            }
            guard let hull, !hull.isEmpty else { continue }
            jobs.append(GroupRenderJob(
                episode: episodeID, revision: revision, map: group, nominalOutputRate: referenceOccurrence.nominalRate,
                participants: participants, outputFrames: hull,
                segmentFrames: Int64(configuration.renderSegmentSeconds) * Int64(outputRate),
                recipeBaseName: configuration.renderRecipeName
            ))
        }
        let environment = environment
        let reports = await boundedMap(jobs, limit: configuration.concurrency) { job in
            await AlignedAssetRun.run(job, environment: environment)
        }
        return AlignedAssetReport(revision: revision, outputRate: outputRate, groups: failedGroups + reports, notRendered: notRendered)
    }

    // MARK: Helpers

    /// Analysis records whose keys the coordinator still considers current.
    func currentRecords(_ report: AlignmentAnalysisReport) async -> [RecordingEpochID: EpochAnalysisRecord] {
        var current: [RecordingEpochID: EpochAnalysisRecord] = [:]
        for (epoch, record) in report.records {
            guard let result = report.analyses[epoch] else { continue }
            if await coordinator.staleReasons(for: result.key).isEmpty { current[epoch] = record }
        }
        return current
    }

    static func acceptedMap(model: ShowDocumentModel, episode: EpisodeID) -> (map: AlignedTimelineMap, revision: Int)? {
        guard let revision = model.episode(episode)?.alignment?.acceptedRevision,
              let map = try? model.timeMap(revision: revision, in: episode)
        else { return nil }
        return (map, revision)
    }

    static func referenceSource(of map: AlignedTimelineMap) -> SourceID? {
        map.groups.lazy.flatMap(\.placements).first { $0.occurrence.id == map.reference.occurrence }?.occurrence.source
    }
}

extension PipelineJobResult {
    /// The typed reason this job produced nothing; `nil` when its result is available.
    var typedFailure: AlignmentWorkFailure? {
        switch outcome {
        case .published, .reused: nil
        case .cancelled: .cancelled
        case let .discardedStale(reasons): .staleInputs(reasons)
        case let .failed(detail): failure ?? .encoding(detail)
        }
    }
}
