import Foundation
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWEpisodeSetup
import WWSources
import WWTimeMap

actor AlignmentRuntime {
    struct Prepared: Sendable {
        var sources: [AlignmentSource]
        var snapshot: AlignmentInspectionSnapshot?
        var reconciliationWarning: String?
    }

    struct AuditionClip: Sendable {
        var sampleRate: Double
        var samples: [Float]
        var channelCount: Int = 1
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
    private var reconciliationFailures: [EpisodeID: String] = [:]
    private var openedDocuments = OpenedDocumentPublications()
    private var publicationReconcilers: [EpisodeID: VerifiedDocumentReconciler] = [:]
    #if DEBUG
    private var seededFixtureDependents: Set<EpisodeID> = []
    #endif

    private init(
        showID: ShowID,
        accessStore: any DeviceAccessStore,
        access: SourceAccessContext,
        derived: DerivedAssetStore
    ) {
        self.showID = showID
        self.accessStore = accessStore
        self.access = access
        coordinator = DerivedJobCoordinator(store: derived)
        pipeline = AlignmentPipeline(coordinator: coordinator, decoder: SourceDecoder(access: access))
    }

    nonisolated static func make(
        showID: ShowID,
        accessStore: any DeviceAccessStore,
        access: SourceAccessContext
    ) async throws -> AlignmentRuntime {
        let root = PersistenceEnvironment.caches("Derived/\(showID)")
        let derived = try await Task.detached(priority: .userInitiated) {
            try DerivedAssetStore(root: root, sourceLocations: [])
        }.value
        return AlignmentRuntime(
            showID: showID,
            accessStore: accessStore,
            access: access,
            derived: derived
        )
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
        #if DEBUG
        await seedFixtureDependentIfRequested(model: model, episode: episodeID)
        #endif
        return Prepared(
            sources: sources,
            snapshot: snapshot,
            reconciliationWarning: reconciliationFailures[episodeID]
        )
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

    func prepareManual(model: ShowDocumentModel, episode episodeID: EpisodeID) async throws -> AlignmentAnalysisReport {
        let sources = await resolveSources(model.episode(episodeID)?.sources ?? [])
        let authorizations = sources.filter { $0.availability == .on }
            .map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
        let report = try await pipeline.prepareManual(
            model: model, episode: episodeID, sources: sources, authorizations: authorizations
        )
        reports[episodeID] = report
        return report
    }

    func shiftGroup(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        group: RecorderGroupID, microseconds: Int64
    ) async throws -> AcceptedAlignment {
        _ = await resolveSources(model.episode(episodeID)?.sources ?? [])
        return try await pipeline.shiftAcceptedGroup(
            model: model, episode: episodeID, group: group, microseconds: microseconds
        )
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
        guard let episode = model.episode(episodeID) else {
            try await pipeline.activate(model: model, episode: episodeID)
            return
        }
        let reconciler = publicationReconciler(for: episodeID)
        _ = try await reconciler.reconcile(
            resolve: { [self] in
                if episode.alignment?.acceptedRevision != nil {
                    _ = await resolveSources(episode.sources)
                }
            },
            publish: { [self] in
                try await pipeline.activate(model: model, episode: episodeID)
            }
        )
    }

    func activate(_ accepted: AcceptedAlignment) async throws {
        let episodeID = accepted.revision.episode
        let reconciler = publicationReconciler(for: episodeID)
        _ = try await reconciler.reconcile(
            resolve: {},
            publish: { [self] in
                try await pipeline.activate(accepted)
            }
        )
    }

    /// Reconciles only the model independently verified by the document open path. This performs metadata-only
    /// source revision verification through the gateway, never decode or analysis, before publishing identity.
    func activateOpened(
        _ model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        documentID: ObjectIdentifier,
        publication: PublicationStamp
    ) async {
        guard let episode = model.episode(episodeID) else { return }
        guard openedDocuments.begin(
            episode: episodeID, documentID: documentID, publication: publication
        ) else { return }
        let reconciler = publicationReconciler(for: episodeID)
        do {
            let published = try await reconciler.reconcile(
                resolve: { [self] in
                    if episode.alignment?.acceptedRevision != nil {
                        _ = await resolveSources(episode.sources)
                    }
                },
                publish: { [self] in
                    try await pipeline.activate(model: model, episode: episodeID)
                }
            )
            if openedDocuments.owns(episode: episodeID, documentID: documentID, publication: publication) {
                if published {
                    reconciliationFailures[episodeID] = nil
                } else {
                    openedDocuments.retry(episode: episodeID, documentID: documentID, publication: publication)
                }
            }
        } catch {
            if openedDocuments.owns(episode: episodeID, documentID: documentID, publication: publication) {
                openedDocuments.retry(episode: episodeID, documentID: documentID, publication: publication)
                if !(error is CancellationError) {
                    reconciliationFailures[episodeID] = String(describing: error)
                }
            }
        }
    }

    func audition(
        episode episodeID: EpisodeID,
        epoch: RecordingEpochID,
        startSeconds: Double,
        durationSeconds: Double,
        progress: @escaping @Sendable (Double) -> Void
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
            var lastReportedProgress = -1.0
            if range.lowerBound > 0 { progress(0) }
            while await cursor.position < range.upperBound, let chunk = try await cursor.next() {
                try Task.checkCancellation()
                let position = await cursor.position
                if position < range.lowerBound {
                    let value = AlignmentAuditionRequest.seekProgress(
                        position: position,
                        target: range.lowerBound
                    )
                    if value - lastReportedProgress >= 0.01 {
                        progress(value)
                        lastReportedProgress = value
                    }
                } else if lastReportedProgress < 1 {
                    progress(1)
                    lastReportedProgress = 1
                }
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

    func waveformTracks(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        startSeconds: Double, durationSeconds: Double, overview: Bool = false,
        progress: @escaping @Sendable (Double) async throws -> Void = { _ in }
    ) async throws -> AlignmentWaveformLoad {
        guard let episode = model.episode(episodeID) else {
            throw AlignmentAcceptanceError.episodeNotFound(episodeID)
        }
        let sources = await resolveSources(episode.sources)
        var map: AlignedTimelineMap?
        var mapWarning: String?
        if episode.alignment?.acceptedRevision != nil {
            do {
                try await pipeline.activate(model: model, episode: episodeID)
                map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
            } catch {
                try Task.checkCancellation()
                mapWarning = "Stored timing is unavailable: \(error). These are unplaced source-origin previews."
            }
        }
        var tracks: [AlignmentWaveformTrack] = []
        var refusals: [AlignmentWaveformRefusal] = []
        var admissions: [SourceID: WaveformSourceAdmission] = [:]
        for (index, record) in episode.sources.enumerated() {
            try Task.checkCancellation()
            guard let groupID = record.placement.recorderGroupID,
                  let epochID = record.placement.epochID,
                  let group = episode.recorderGroup(groupID)
            else { continue }
            do {
                let admission = try await waveformSource(record.id, sources: sources)
                let envelope: WaveformEnvelope
                if overview {
                    envelope = try await cachedOverview(
                        admission: admission, episode: episode, group: groupID, map: map,
                        sourceIndex: index, progress: progress
                    )
                } else {
                    envelope = try await WaveformWindowReader.readWindow(
                        sourceURL: admission.url, source: record.id,
                        matching: admission.witness, decoder: pipeline.decoder,
                        startSeconds: startSeconds, durationSeconds: durationSeconds,
                        groupMap: map?.groups.first(where: {
                            $0.group == groupID && $0.placements.contains(where: { $0.occurrence.source == record.id })
                        })
                    )
                }
                try await reverify(admission)
                admissions[record.id] = admission
                tracks.append(AlignmentWaveformTrack(
                    group: groupID, epoch: epochID, name: record.displayNameHint,
                    groupName: group.name, envelope: envelope
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                refusals.append(AlignmentWaveformRefusal(
                    id: record.id, name: record.displayNameHint,
                    reason: error is LocalizedError ? error.localizedDescription : String(describing: error)
                ))
            }
        }
        for track in tracks {
            guard let admission = admissions[track.id] else { throw DecodeFailure.sourceIdentityMismatch }
            try await reverify(admission)
        }
        if map != nil {
            _ = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        }
        return AlignmentWaveformLoad(tracks: tracks, refusals: refusals, map: map, mapWarning: mapWarning)
    }

    private func cachedOverview(
        admission: WaveformSourceAdmission, episode: Episode, group: RecorderGroupID,
        map: AlignedTimelineMap?, sourceIndex: Int,
        progress: @escaping @Sendable (Double) async throws -> Void
    ) async throws -> WaveformEnvelope {
        guard let fingerprint = admission.record.recordedIdentity?.fingerprint else {
            throw DecodeFailure.sourceIdentityMismatch
        }
        let asset = AssetSpec(kind: "ww.waveform.overview", revision: 1)
        let source = admission.key.sourceID
        let key = DerivedAssetKey(
            asset: asset, sources: [.metadata(source, fingerprint: fingerprint)],
            format: .current,
            map: map.flatMap { _ in
                episode.alignment?.acceptedRevision.map {
                    MapRevisionReference(episode: episode.id, revision: $0)
                }
            }
        )
        let slot = DerivedSlot("ww.waveform.overview.\(episode.id).\(source)")
        await coordinator.setAssetRevision(asset)
        if let mapRevision = key.map { await coordinator.acceptMap(mapRevision) }
        let decoder = pipeline.decoder
        let accessStore = accessStore
        let sourceCount = max(1, episode.sources.count)
        let groupMap = map?.groups.first(where: {
            $0.group == group && $0.placements.contains(where: { $0.occurrence.source == source })
        })
        let job = await coordinator.submit(slot, key: key) {
            let envelope = try await WaveformWindowReader.readOverview(
                sourceURL: admission.url, source: source,
                matching: admission.witness, decoder: decoder, groupMap: groupMap
            ) { fraction in
                guard try await accessStore.record(for: admission.key) == admission.record else {
                    throw DecodeFailure.sourceIdentityMismatch
                }
                try await progress((Double(sourceIndex) + fraction) / Double(sourceCount))
            }
            return try JSONEncoder().encode(envelope)
        }
        switch await job.outcome {
        case .published, .reused: break
        case .cancelled: throw CancellationError()
        case .discardedStale: throw DecodeFailure.sourceIdentityMismatch
        case let .failed(reason): throw SourceAdmissionError(reason: reason)
        }
        guard let payload = await coordinator.readyPayload(for: slot, matching: key),
              let envelope = try? JSONDecoder().decode(WaveformEnvelope.self, from: payload),
              envelope.source == source, envelope.sampleRate > 0, envelope.channelCount > 0,
              envelope.totalFrames >= 0, envelope.bins.count <= WaveformWindowReader.maximumBins,
              envelope.bins.allSatisfy({
                  $0.firstFrame >= 0 && $0.firstFrame < $0.endFrame
                      && $0.endFrame <= envelope.totalFrames
                      && $0.minimum.isFinite && $0.maximum.isFinite
                      && $0.minimum <= $0.maximum
              })
        else { throw SourceAdmissionError(reason: "The cached waveform overview is invalid; refresh its source.") }
        try await reverify(admission)
        try await progress(Double(sourceIndex + 1) / Double(sourceCount))
        return envelope
    }

    private struct WaveformSourceAdmission: Sendable {
        let key: DeviceAccessKey
        let record: DeviceAccessRecord
        let url: URL
        let witness: RawSourceIdentity
    }

    private struct SourceAdmissionError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private func waveformSource(
        _ source: SourceID, sources: [AlignmentSource]
    ) async throws -> WaveformSourceAdmission {
        guard let resolved = sources.first(where: { $0.id == source }), resolved.availability == .on else {
            let key = DeviceAccessKey(showID: showID, sourceID: source)
            let record = try await accessStore.record(for: key)
            let observation = SourceAvailabilityEvaluator(context: access).evaluate(
                key: key, record: record, setting: .on
            ).observation
            throw SourceAdmissionError(reason: WWSourcesStatusMapping.audioAdmissionIssue(observation)
                ?? "Source details changed during admission. Check this source in Setup and reload its audio.")
        }
        let key = DeviceAccessKey(showID: showID, sourceID: source)
        guard let record = try await accessStore.record(for: key),
              let fingerprint = record.recordedIdentity?.fingerprint
        else { throw DecodeFailure.sourceIdentityMismatch }
        let witness = try await pipeline.decoder.captureRawIdentity(resolved.url, matching: fingerprint)
        let admission = WaveformSourceAdmission(key: key, record: record, url: resolved.url, witness: witness)
        try await reverify(admission)
        return admission
    }

    private func reverify(_ admission: WaveformSourceAdmission) async throws {
        guard try await accessStore.record(for: admission.key) == admission.record,
              let fingerprint = admission.record.recordedIdentity?.fingerprint
        else { throw DecodeFailure.sourceIdentityMismatch }
        let present = try await pipeline.decoder.captureRawIdentity(admission.url, matching: fingerprint)
        guard present == admission.witness,
              try await accessStore.record(for: admission.key) == admission.record
        else { throw DecodeFailure.sourceIdentityMismatch }
        try Task.checkCancellation()
    }

    func alignedAudition(
        model: ShowDocumentModel, episode episodeID: EpisodeID, target: SourceID,
        targetChannel: Int, startSeconds: Double, durationSeconds: Double
    ) async throws -> AuditionClip {
        guard let episode = model.episode(episodeID) else {
            throw AlignmentAcceptanceError.episodeNotFound(episodeID)
        }
        let sources = await resolveSources(episode.sources)
        try await pipeline.activate(model: model, episode: episodeID)
        let map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        guard let referenceGroup = map.groups.first(where: { $0.group == map.reference.group }),
              let reference = referenceGroup.placements.first(where: { $0.occurrence.id == map.reference.occurrence }),
              let targetGroup = map.groups.first(where: { $0.placements.contains(where: { $0.occurrence.source == target }) }),
              reference.occurrence.source != target
        else { throw AlignmentAcceptanceError.noReference }
        let referenceAdmission = try await waveformSource(reference.occurrence.source, sources: sources)
        let targetAdmission = try await waveformSource(target, sources: sources)
        let left = try await AlignedAuditionWindowReader.readWindow(
            sourceURL: referenceAdmission.url, source: reference.occurrence.source,
            matching: referenceAdmission.witness, decoder: pipeline.decoder, groupMap: referenceGroup,
            decodedChannel: 0, startSeconds: startSeconds, durationSeconds: durationSeconds
        )
        let right = try await AlignedAuditionWindowReader.readWindow(
            sourceURL: targetAdmission.url, source: target, matching: targetAdmission.witness,
            decoder: pipeline.decoder, groupMap: targetGroup, decodedChannel: targetChannel,
            startSeconds: startSeconds, durationSeconds: durationSeconds
        )
        try await reverify(referenceAdmission)
        try await reverify(targetAdmission)
        _ = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        guard left.count == right.count else { throw WaveformWindowError.invalidSamples }
        return AuditionClip(
            sampleRate: Double(AlignedAuditionWindowReader.outputRate), samples: left + right, channelCount: 2
        )
    }

    func mixedAudition(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        enabled: [SourceID], startSeconds: Double, durationSeconds: Double
    ) async throws -> AuditionClip {
        guard let episode = model.episode(episodeID), !enabled.isEmpty else {
            throw AlignmentAcceptanceError.noReference
        }
        let sources = await resolveSources(episode.sources)
        try await pipeline.activate(model: model, episode: episodeID)
        let map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        var mixed: [Float]?
        var admissions: [WaveformSourceAdmission] = []
        for sourceID in enabled {
            try Task.checkCancellation()
            guard let record = episode.source(sourceID),
                  let groupID = record.placement.recorderGroupID,
                  let group = map.groups.first(where: { $0.group == groupID }),
                  group.placements.contains(where: { $0.occurrence.source == sourceID })
            else { throw WaveformWindowError.mapDoesNotMatchSource }
            let admission = try await waveformSource(sourceID, sources: sources)
            let channel = episode.statedChannel(of: sourceID) ?? 0
            let samples = try await AlignedAuditionWindowReader.readWindow(
                sourceURL: admission.url, source: sourceID,
                matching: admission.witness, decoder: pipeline.decoder, groupMap: group,
                decodedChannel: channel, startSeconds: startSeconds, durationSeconds: durationSeconds
            )
            var buffer = mixed ?? [Float](repeating: 0, count: samples.count)
            guard buffer.count == samples.count else { throw WaveformWindowError.invalidSamples }
            for index in samples.indices { buffer[index] += samples[index] / Float(enabled.count) }
            mixed = buffer
            admissions.append(admission)
        }
        for admission in admissions { try await reverify(admission) }
        _ = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        return AuditionClip(
            sampleRate: Double(AlignedAuditionWindowReader.outputRate), samples: mixed ?? []
        )
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

    func openedEpisodes(for documentID: ObjectIdentifier) -> [EpisodeID] {
        openedDocuments.episodes(for: documentID)
    }

    private func publicationReconciler(for episodeID: EpisodeID) -> VerifiedDocumentReconciler {
        if let reconciler = publicationReconcilers[episodeID] { return reconciler }
        let reconciler = VerifiedDocumentReconciler()
        publicationReconcilers[episodeID] = reconciler
        return reconciler
    }

    private func resolveSources(_ records: [SourceRecord]) async -> [AlignmentSource] {
        var values: [AlignmentSource] = []
        let evaluator = SourceAvailabilityEvaluator(context: access)
        for source in records {
            let key = DeviceAccessKey(showID: showID, sourceID: source.id)
            let record = try? await accessStore.record(for: key)
            let evaluation = evaluator.evaluate(key: key, record: record, setting: .on)
            if let refreshed = evaluation.refreshedRecord { try? await accessStore.save(refreshed) }
            guard let url = evaluation.resolvedURL,
                  evaluation.observation.access == .granted,
                  evaluation.observation.identity == .matchesRecorded,
                  evaluation.observation.location == .present,
                  evaluation.observation.residency == .local
            else {
                values.append(AlignmentSource(id: source.id, url: URL(fileURLWithPath: "/"), availability: .off))
                await coordinator.removeSource(source.id)
                continue
            }
            let revision = access.withScopedAccess(to: url) { scoped -> SourceRevision? in
                guard case let .success(metadata) = access.io.metadata(at: scoped),
                      metadata.isReadable.value == true,
                      record?.recordedIdentity?.fingerprint.compare(to: metadata.fingerprint) == .matches
                else { return nil }
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
    private static var creations: [ShowID: Task<AlignmentRuntime, Error>] = [:]

    static func runtime(
        for document: ShowDocument,
        episode episodeID: EpisodeID
    ) async throws -> AlignmentRuntime {
        let showID = document.store.model.show.id
        let runtime: AlignmentRuntime
        if let existing = runtimes[showID] {
            runtime = existing
        } else if let creation = creations[showID] {
            runtime = try await creation.value
        } else {
            let creation = Task { @MainActor in
                try await AlignmentRuntime.make(
                    showID: showID,
                    accessStore: SetupEngineProvider.store,
                    access: SetupEngineProvider.context
                )
            }
            creations[showID] = creation
            do {
                runtime = try await creation.value
                runtimes[showID] = runtime
                creations[showID] = nil
            } catch {
                creations[showID] = nil
                throw error
            }
        }
        if let verified = document.verifiedModel, let publication = document.publication {
            await runtime.activateOpened(
                verified,
                episode: episodeID,
                documentID: ObjectIdentifier(document),
                publication: publication
            )
        }
        return runtime
    }

    /// Only the app may bind an untrusted package inventory to its actual open ShowDocument. This
    /// private snapshot is not an edit authorization or a protection/fade/publication proof.
    static func sourceInventorySnapshot(
        for document: ShowDocument, episode episodeID: EpisodeID
    ) async throws -> OpenEpisodeSourceSnapshot {
        try await OpenEpisodeSourceSnapshot.issue(for: document, episode: episodeID)
    }

    static func reconcileActive(for document: ShowDocument) {
        guard let runtime = runtimes[document.store.model.show.id],
              let model = document.verifiedModel, let publication = document.publication else { return }
        let documentID = ObjectIdentifier(document)
        Task {
            for episode in await runtime.openedEpisodes(for: documentID) {
                await runtime.activateOpened(
                    model, episode: episode, documentID: documentID, publication: publication
                )
            }
        }
    }
}
