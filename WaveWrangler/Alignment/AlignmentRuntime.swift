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

    struct DependentCounts: Sendable, Equatable {
        var total: Int
        var stale: Int
    }

    let coordinator: DerivedJobCoordinator
    let pipeline: AlignmentPipeline
    private let showID: ShowID
    private let accessStore: any DeviceAccessStore
    private let access: SourceAccessContext
    private var sourceByEpoch: [EpisodeID: [RecordingEpochID: AlignmentSource]] = [:]
    private var reports: [EpisodeID: AlignmentAnalysisReport] = [:]
    #if DEBUG
    private var seededFixtureDependents: Set<EpisodeID> = []
    #endif

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
        try? await pipeline.activate(model: model, episode: episodeID)
        #if DEBUG
        await seedFixtureDependentIfRequested(model: model, episode: episodeID)
        #endif
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
            _ = await resolveSources(model.episode(episodeID)?.sources ?? [])
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
        _ = await resolveSources(model.episode(episodeID)?.sources ?? [])
        return try await pipeline.splitAcceptedOccurrence(
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
            let sampleRate = Double(cursor.interpretation.sourceSampleRate)
            let range = try AlignmentAuditionRequest.frameRange(
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                sampleRate: sampleRate,
                availableFrames: cursor.interpretation.frames.validFrames
            )
            var samples: [Float] = []
            samples.reserveCapacity(range.count)
            while await cursor.position < range.upperBound, let chunk = try await cursor.next() {
                try Task.checkCancellation()
                let chunkStart = chunk.firstSourceFrame
                let (chunkEnd, overflow) = chunkStart.addingReportingOverflow(Int64(chunk.frameCount))
                guard !overflow else {
                    throw AlignmentAuditionRequestError.tooManyFrames(
                        maximum: AlignmentAuditionRequest.maximumFrameCount
                    )
                }
                let lo = max(range.lowerBound, chunkStart)
                let hi = min(range.upperBound, chunkEnd)
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
            return AuditionClip(sampleRate: sampleRate, samples: samples)
        }
    }

    func dependentCounts(episode episodeID: EpisodeID) async -> DependentCounts {
        await coordinator.states().values.reduce(into: DependentCounts(total: 0, stale: 0)) { counts, state in
            guard state.key?.map?.episode == episodeID else { return }
            counts.total += 1
            if case .stale = state { counts.stale += 1 }
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

    #if DEBUG
    private func seedFixtureDependentIfRequested(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID
    ) async {
        guard UserDefaults.standard.bool(forKey: "WWUITestAlignmentFixture"),
              !seededFixtureDependents.contains(episodeID),
              let revision = model.episode(episodeID)?.alignment?.acceptedRevision
        else { return }
        seededFixtureDependents.insert(episodeID)
        let asset = AssetSpec(kind: "ww.uitest.alignment-dependent", revision: 1)
        let map = MapRevisionReference(episode: episodeID, revision: revision)
        await coordinator.setAssetRevision(asset)
        await coordinator.acceptMap(map)
        let job = await coordinator.submit(
            DerivedSlot("ww.uitest.alignment-dependent.\(episodeID)"),
            key: DerivedAssetKey(asset: asset, map: map)
        ) {
            Data("synthetic-dependent".utf8)
        }
        _ = await job.outcome
    }
    #endif
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
