import Foundation
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWSources

actor AlignmentRuntime {
    struct Prepared: Sendable {
        var sources: [AlignmentSource]
        var snapshot: AlignmentInspectionSnapshot?
    }

    struct AuditionClip: Sendable {
        var sampleRate: Double
        var samples: [Float]
    }

    let coordinator: DerivedJobCoordinator
    let pipeline: AlignmentPipeline
    private let showID: ShowID
    private let accessStore: any DeviceAccessStore
    private let access: SourceAccessContext
    private var sourceByEpoch: [EpisodeID: [RecordingEpochID: AlignmentSource]] = [:]
    private var reports: [EpisodeID: AlignmentAnalysisReport] = [:]

    init(showID: ShowID, accessStore: any DeviceAccessStore, access: SourceAccessContext) throws {
        self.showID = showID
        self.accessStore = accessStore
        self.access = access
        let root = PersistenceEnvironment.caches("Derived/\(showID)")
        let derived = try DerivedAssetStore(root: root, sourceLocations: [])
        coordinator = DerivedJobCoordinator(store: derived)
        pipeline = AlignmentPipeline(coordinator: coordinator, decoder: SourceDecoder(access: access))
    }

    func inspect(model: ShowDocumentModel, episode episodeID: EpisodeID) async -> Prepared {
        let records = model.episode(episodeID)?.sources ?? []
        let sources = await resolveLocations(records)
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var byEpoch: [RecordingEpochID: AlignmentSource] = Dictionary(
            records.compactMap { record in
                guard let epoch = record.placement.epochID, let source = byID[record.id], source.availability == .on else { return nil }
                return (epoch, source)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let snapshot = await pipeline.inspect(model: model, episode: episodeID, sources: sources)
        for group in snapshot?.acceptedMap?.groups ?? [] {
            for placement in group.placements {
                guard let source = byID[placement.occurrence.source], source.availability == .on else { continue }
                for span in placement.spans { byEpoch[span.epoch] = source }
            }
        }
        sourceByEpoch[episodeID] = byEpoch
        return Prepared(sources: sources, snapshot: snapshot)
    }

    func analyse(model: ShowDocumentModel, episode episodeID: EpisodeID) async throws -> AlignmentAnalysisReport {
        let sources = await resolveSources(model.episode(episodeID)?.sources ?? [])
        let authorization = sources
            .filter { $0.availability == .on }
            .map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
        guard let report = await pipeline.analyse(
            model: model, episode: episodeID, sources: sources, authorizations: authorization
        ) else { throw AlignmentAcceptanceError.episodeNotFound(episodeID) }
        reports[episodeID] = report
        return report
    }

    func accept(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        decisions: [RecordingEpochID: EpochMapDecision]
    ) async throws -> AcceptedAlignment {
        let acceptsProposal = decisions.values.contains {
            if case .acceptProposal = $0 { return true }
            return false
        }
        if acceptsProposal, let report = reports[episodeID] {
            return try await pipeline.accept(model: model, episode: episodeID, report: report, decisions: decisions)
        }
        if model.episode(episodeID)?.alignment?.acceptedRevision != nil {
            return try await pipeline.reviseAcceptedMap(model: model, episode: episodeID, decisions: decisions)
        }
        guard let report = reports[episodeID] else { throw AlignmentAcceptanceError.noReference }
        return try await pipeline.accept(model: model, episode: episodeID, report: report, decisions: decisions)
    }

    func split(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        group: RecorderGroupID,
        source: SourceID,
        epoch: RecordingEpochID,
        frame: Int64,
        newEpoch: RecordingEpochID
    ) async throws -> AcceptedAlignment {
        try await pipeline.splitAcceptedOccurrence(
            model: model, episode: episodeID, group: group, source: source,
            epoch: epoch, frame: frame, newEpoch: newEpoch
        )
    }

    func states(model: ShowDocumentModel, episode episodeID: EpisodeID) async -> [EpochAlignmentState] {
        guard let report = reports[episodeID] else { return [] }
        return await pipeline.states(model: model, episode: episodeID, report: report)
    }

    func activate(model: ShowDocumentModel, episode episodeID: EpisodeID) async throws {
        try await pipeline.activate(model: model, episode: episodeID)
    }

    func activate(_ accepted: AcceptedAlignment) async throws {
        try await pipeline.activate(accepted)
    }

    func audition(
        episode episodeID: EpisodeID,
        epoch: RecordingEpochID,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> AuditionClip {
        guard let source = sourceByEpoch[episodeID]?[epoch] else { throw DecodeFailure.notFound }
        return try await pipeline.decoder.withDecodingCursor(source.url, source: source.id) { cursor in
            let rate = Int64(cursor.interpretation.sourceSampleRate)
            let start = max(0, Int64((startSeconds * Double(rate)).rounded(.down)))
            let duration = max(1, Int64((durationSeconds * Double(rate)).rounded(.up)))
            let end = min(cursor.interpretation.frames.validFrames, start + duration)
            var samples: [Float] = []
            samples.reserveCapacity(Int(max(0, end - start)))
            var position: Int64 = 0
            while position < end, let chunk = try await cursor.next() {
                let chunkStart = position
                let chunkEnd = position + Int64(chunk.frameCount)
                position = chunkEnd
                let lo = max(start, chunkStart)
                let hi = min(end, chunkEnd)
                guard hi > lo else { continue }
                let first = Int(lo - chunkStart)
                let count = Int(hi - lo)
                for frame in first..<(first + count) {
                    var sum: Float = 0
                    for channel in 0..<chunk.channelCount {
                        sum += chunk.samples[channel * chunk.frameCount + frame]
                    }
                    samples.append(sum / Float(chunk.channelCount))
                }
            }
            try await cursor.verifyUnchanged()
            return AuditionClip(sampleRate: Double(rate), samples: samples)
        }
    }

    func dependentJobCount(episode episodeID: EpisodeID) async -> Int {
        await coordinator.states().values.reduce(into: 0) { count, state in
            if state.key?.map?.episode == episodeID { count += 1 }
        }
    }

    func shutdown() async {
        await coordinator.shutdown()
    }

    private func resolveSources(_ records: [SourceRecord]) async -> [AlignmentSource] {
        var values: [AlignmentSource] = []
        let evaluator = SourceAvailabilityEvaluator(context: access)
        for source in records {
            let key = DeviceAccessKey(showID: showID, sourceID: source.id)
            let record = try? await accessStore.record(for: key)
            let evaluation = evaluator.evaluate(key: key, record: record, setting: .on)
            if let refreshed = evaluation.refreshedRecord { try? await accessStore.save(refreshed) }
            guard let url = evaluation.resolvedURL else {
                values.append(AlignmentSource(id: source.id, url: URL(fileURLWithPath: "/"), availability: .off))
                await coordinator.removeSource(source.id)
                continue
            }
            let revision = access.withScopedAccess(to: url) { scoped -> SourceRevision? in
                guard case let .success(metadata) = access.io.metadata(at: scoped) else { return nil }
                return .metadata(source.id, fingerprint: metadata.fingerprint)
            }
            if let revision {
                await coordinator.updateSource(revision)
                values.append(AlignmentSource(id: source.id, url: url, availability: .on))
            } else {
                await coordinator.removeSource(source.id)
                values.append(AlignmentSource(id: source.id, url: url, availability: .off))
            }
        }
        return values
    }

    /// Resolves only the app's device-local access records. It never opens a source, reads source metadata or
    /// registers a revision; explicit Analyse/Audition actions perform those content-gateway preparations.
    private func resolveLocations(_ records: [SourceRecord]) async -> [AlignmentSource] {
        var values: [AlignmentSource] = []
        for source in records {
            let key = DeviceAccessKey(showID: showID, sourceID: source.id)
            let record = try? await accessStore.record(for: key)
            guard let bookmark = record?.bookmark else {
                values.append(AlignmentSource(id: source.id, url: URL(fileURLWithPath: "/"), availability: .off))
                continue
            }
            if case let .resolved(url, _) = access.io.resolveBookmark(bookmark) {
                values.append(AlignmentSource(id: source.id, url: url, availability: .on))
            } else {
                values.append(AlignmentSource(id: source.id, url: URL(fileURLWithPath: "/"), availability: .off))
            }
        }
        return values
    }
}

@MainActor
enum AlignmentRuntimeProvider {
    private static var runtimes: [ShowID: AlignmentRuntime] = [:]

    static func runtime(for showID: ShowID) throws -> AlignmentRuntime {
        if let existing = runtimes[showID] { return existing }
        let runtime = try AlignmentRuntime(showID: showID, accessStore: SetupEngineProvider.store, access: SetupEngineProvider.context)
        runtimes[showID] = runtime
        return runtime
    }
}
