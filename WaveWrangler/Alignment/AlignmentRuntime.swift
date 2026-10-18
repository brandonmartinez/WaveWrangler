import CryptoKit
import Foundation
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWEpisodeSetup
import WWSources
import WWTimeMap
import WWSpeech

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

    func analyseSpeaker(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        targetEpoch: RecordingEpochID, speaker: SpeakerID,
        referenceSource: SourceID, targetSource: SourceID
    ) async throws -> AlignmentAnalysisReport {
        let sources = await resolveSources(model.episode(episodeID)?.sources ?? [])
        let authorization = sources.filter { $0.availability == .on }
            .map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
        if model.episode(episodeID)?.alignment?.acceptedRevision != nil {
            try await pipeline.activate(model: model, episode: episodeID)
        }
        let report = try await pipeline.analyseSpeaker(
            model: model, episode: episodeID, sources: sources, authorizations: authorization,
            targetEpoch: targetEpoch, speaker: speaker,
            referenceSource: referenceSource, targetSource: targetSource
        )
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

    func analyseAdaptiveSpeaker(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        targetEpoch: RecordingEpochID, pair: SpeakerMatchOption,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> AdaptiveAnalysisRecord {
        let sources = await resolveSources(model.episode(episodeID)?.sources ?? [])
        let authorizations = sources.filter { $0.availability == .on }
            .map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
        if model.episode(episodeID)?.alignment?.acceptedRevision != nil {
            try await pipeline.activate(model: model, episode: episodeID)
        }
        return try await pipeline.analyseAdaptiveSpeaker(
            model: model, episode: episodeID, sources: sources, authorizations: authorizations,
            targetEpoch: targetEpoch, speaker: pair.speaker,
            referenceSource: pair.reference.source, targetSource: pair.target, progress: progress
        )
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

    func acceptAdaptive(
        model: ShowDocumentModel, episode episodeID: EpisodeID, record: AdaptiveAnalysisRecord,
        includeEstimated: Bool = false
    ) async throws -> AcceptedAlignment {
        let sources = await resolveSources(model.episode(episodeID)?.sources ?? [])
        let authorizations = sources.filter { $0.availability == .on }
            .map { ContentWorkAuthorization.explicitUserRequest(for: $0.id) }
        return try await pipeline.acceptAdaptive(model: model, episode: episodeID, record: record,
            sources: sources, authorizations: authorizations, includeEstimated: includeEstimated)
    }

    func removeAdaptive(
        model: ShowDocumentModel, episode episodeID: EpisodeID, source: SourceID
    ) async throws -> AcceptedAlignment {
        _ = await resolveSources(model.episode(episodeID)?.sources ?? [])
        return try await pipeline.removeAdaptiveCorrection(model: model, episode: episodeID, source: source)
    }

    func accept(
        model: ShowDocumentModel,
        episode episodeID: EpisodeID,
        decisions: [RecordingEpochID: EpochMapDecision],
        requiringPlacementOf source: SourceID? = nil
    ) async throws -> AcceptedAlignment {
        let acceptsProposal = decisions.values.contains {
            switch $0 {
            case .acceptProposal, .extendProposalToEpoch: true
            default: false
            }
        }
        if acceptsProposal, let report = reports[episodeID] {
            _ = await resolveSources(model.episode(episodeID)?.sources ?? [])
            return try await pipeline.accept(model: model, episode: episodeID, report: report, decisions: decisions)
        }
        if model.episode(episodeID)?.alignment?.acceptedRevision != nil {
            _ = await resolveSources(model.episode(episodeID)?.sources ?? [])
            if let source {
                guard decisions.count == 1, let epoch = decisions.keys.first,
                      let report = reports[episodeID],
                      let planned = report.plan.epoch(epoch), planned.sources.contains(source),
                      report.facts[source] != nil
                else { throw AlignmentAcceptanceError.invalidMap("The selected recording has no eligible manual placement.") }
                let prior = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
                let alreadyPlaced = prior.groups.contains { group in
                    group.group == planned.group && group.placements.contains {
                        $0.occurrence.source == source && $0.spans.contains { $0.epoch == epoch }
                    }
                }
                if !alreadyPlaced {
                    let accepted = try await pipeline.accept(
                        model: model, episode: episodeID, report: report, decisions: decisions
                    )
                    guard accepted.map.reference == prior.reference,
                          prior.groups.allSatisfy({ oldGroup in
                              guard let updated = accepted.map.groups.first(where: { $0.group == oldGroup.group }) else {
                                  return false
                              }
                              return oldGroup.epochs.allSatisfy { oldEpoch in
                                  oldEpoch.epoch == epoch || updated.epochs.first(where: {
                                      $0.epoch == oldEpoch.epoch
                                  })?.mapping == oldEpoch.mapping
                              } && oldGroup.placements.allSatisfy { oldPlacement in
                                  updated.placements.contains(oldPlacement)
                              }
                          })
                    else {
                        throw AlignmentAcceptanceError.invalidMap(
                            "Adding this recording would change other accepted timing; no move was saved."
                        )
                    }
                    try Self.requireMappedPlacement(source: source, epoch: epoch, group: planned.group, map: accepted.map)
                    return accepted
                }
                let accepted = try await pipeline.reviseAcceptedMap(
                    model: model, episode: episodeID, decisions: decisions
                )
                try Self.requireMappedPlacement(source: source, epoch: epoch, group: planned.group, map: accepted.map)
                return accepted
            }
            return try await pipeline.reviseAcceptedMap(model: model, episode: episodeID, decisions: decisions)
        }
        guard let report = reports[episodeID] else { throw AlignmentAcceptanceError.noReference }
        let accepted = try await pipeline.accept(model: model, episode: episodeID, report: report, decisions: decisions)
        if let source, let epoch = decisions.keys.first, let planned = report.plan.epoch(epoch) {
            try Self.requireMappedPlacement(source: source, epoch: epoch, group: planned.group, map: accepted.map)
        }
        return accepted
    }

    private static func requireMappedPlacement(
        source: SourceID, epoch: RecordingEpochID, group: RecorderGroupID, map: AlignedTimelineMap
    ) throws {
        guard let groupMap = map.groups.first(where: { $0.group == group }),
              groupMap.placements.contains(where: {
                  $0.occurrence.source == source && $0.spans.contains { $0.epoch == epoch }
              }),
              let mapping = groupMap.epochs.first(where: { $0.epoch == epoch })?.mapping,
              case .mapped = mapping
        else { throw AlignmentAcceptanceError.noPlaceableSource(epoch) }
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
        onlySources: Set<SourceID>? = nil, decodedChannels: [SourceID: Int] = [:],
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
        let selectedSources = episode.sources.filter { onlySources?.contains($0.id) ?? true }
        for (index, record) in selectedSources.enumerated() {
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
                        sourceIndex: index, sourceCount: selectedSources.count,
                        decodedChannel: decodedChannels[record.id], progress: progress
                    )
                } else {
                    let sourceMap = map?.groups.first(where: {
                        $0.group == groupID && $0.placements.contains(where: { $0.occurrence.source == record.id })
                    })
                    let correction = episode.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == record.id }
                    envelope = try await WaveformWindowReader.readWindow(
                        sourceURL: admission.url, source: record.id,
                        matching: admission.witness, decoder: pipeline.decoder,
                        startSeconds: startSeconds, durationSeconds: durationSeconds,
                        groupMap: sourceMap, sourceCorrection: correction,
                        decodedChannel: decodedChannels[record.id]
                    )
                }
                try await reverify(admission)
                admissions[record.id] = admission
                tracks.append(AlignmentWaveformTrack(
                    group: groupID, epoch: epochID, name: record.displayNameHint,
                    groupName: group.name, envelope: envelope, sourceIdentity: admission.witness
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

    /// Timing-only edits reuse source-coordinate bins, but only after fresh gateway identity checks.
    func revalidateWaveforms(
        model: ShowDocumentModel, episode episodeID: EpisodeID, tracks retained: [AlignmentWaveformTrack]
    ) async throws -> AlignedTimelineMap? {
        guard let episode = model.episode(episodeID) else {
            throw AlignmentAcceptanceError.episodeNotFound(episodeID)
        }
        let sources = await resolveSources(episode.sources)
        var admissions: [SourceID: WaveformSourceAdmission] = [:]
        for track in retained {
            try Task.checkCancellation()
            let admission: WaveformSourceAdmission
            if let existing = admissions[track.id] {
                admission = existing
            } else {
                admission = try await waveformSource(track.id, sources: sources)
                admissions[track.id] = admission
            }
            guard track.sourceIdentity == admission.witness else { throw DecodeFailure.sourceIdentityMismatch }
        }
        let map: AlignedTimelineMap?
        if episode.alignment?.acceptedRevision != nil {
            try await pipeline.activate(model: model, episode: episodeID)
            map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        } else {
            map = nil
        }
        for admission in admissions.values { try await reverify(admission) }
        return map
    }

    private func cachedOverview(
        admission: WaveformSourceAdmission, episode: Episode, group: RecorderGroupID,
        map: AlignedTimelineMap?, sourceIndex: Int, sourceCount: Int, decodedChannel: Int?,
        progress: @escaping @Sendable (Double) async throws -> Void
    ) async throws -> WaveformEnvelope {
        guard let fingerprint = admission.record.recordedIdentity?.fingerprint else {
            throw DecodeFailure.sourceIdentityMismatch
        }
        let channelSuffix = decodedChannel.map { ".channel.\($0)" } ?? ""
        let asset = AssetSpec(kind: "ww.waveform.overview\(channelSuffix)", revision: 2)
        let source = admission.key.sourceID
        let groupMap = map?.groups.first(where: {
            $0.group == group && $0.placements.contains(where: { $0.occurrence.source == source })
        })
        let correction = episode.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == source }
        let coverage = try WaveformWindowReader.overviewCoverage(source: source, groupMap: groupMap, sourceCorrection: correction)
        let coverageDigest = coverage.map { ranges in
            let description = ranges.map { "\($0.lowerBound):\($0.upperBound)" }.joined(separator: ",")
            return SHA256.hash(data: Data(description.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        let key = DerivedAssetKey(
            asset: asset, sources: [.metadata(source, fingerprint: fingerprint)],
            format: .current, coverage: coverageDigest
        )
        let slot = DerivedSlot("ww.waveform.overview.\(episode.id).\(source)\(channelSuffix)")
        await coordinator.setAssetRevision(asset)
        let decoder = pipeline.decoder
        let accessStore = accessStore
        let sourceCount = max(1, sourceCount)
        let job = await coordinator.submit(slot, key: key) {
            let envelope = try await WaveformWindowReader.readOverview(
                sourceURL: admission.url, source: source,
                matching: admission.witness, decoder: decoder, groupMap: groupMap, sourceCorrection: correction,
                decodedChannel: decodedChannel
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
        try WaveformWindowReader.verifyOverviewCoverage(envelope: envelope, groupMap: groupMap, sourceCorrection: correction)
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
              reference.occurrence.source != target
        else { throw AlignmentAcceptanceError.noReference }
        let referenceAdmission = try await waveformSource(reference.occurrence.source, sources: sources)
        let targetAdmission = try await waveformSource(target, sources: sources)
        let left = try await AlignedAuditionWindowReader.readWindow(
            sourceURL: referenceAdmission.url, source: reference.occurrence.source,
            matching: referenceAdmission.witness, decoder: pipeline.decoder, groupMap: referenceGroup,
            decodedChannel: 0, startSeconds: startSeconds, durationSeconds: durationSeconds
        )
        let right: [Float]
        if episode.alignment?.acceptedMap?.sourceCorrections?.contains(where: { $0.source == target }) == true {
            let channels = try await pipeline.adaptiveAudioWindow(model: model, episode: episodeID, source: target,
                sourceURL: targetAdmission.url, matching: targetAdmission.witness,
                startSeconds: startSeconds, durationSeconds: durationSeconds)
            guard channels.indices.contains(targetChannel) else { throw WaveformWindowError.invalidSamples }
            right = channels[targetChannel]
        } else {
            guard let targetGroup = map.groups.first(where: { $0.placements.contains(where: { $0.occurrence.source == target }) })
            else { throw AlignmentAcceptanceError.noReference }
            right = try await AlignedAuditionWindowReader.readWindow(
                sourceURL: targetAdmission.url, source: target, matching: targetAdmission.witness,
                decoder: pipeline.decoder, groupMap: targetGroup, decodedChannel: targetChannel,
                startSeconds: startSeconds, durationSeconds: durationSeconds)
        }
        try await reverify(referenceAdmission)
        try await reverify(targetAdmission)
        _ = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        guard left.count == right.count else { throw WaveformWindowError.invalidSamples }
        return AuditionClip(
            sampleRate: Double(AlignedAuditionWindowReader.outputRate), samples: left + right, channelCount: 2
        )
    }

    func sourceAudition(
        model: ShowDocumentModel, episode episodeID: EpisodeID,
        source: SourceID, startSeconds: Double, durationSeconds: Double
    ) async throws -> AuditionClip {
        guard let episode = model.episode(episodeID) else { throw AlignmentAcceptanceError.episodeNotFound(episodeID) }
        let sources = await resolveSources(episode.sources)
        try await pipeline.activate(model: model, episode: episodeID)
        let map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        if episode.alignment?.acceptedMap?.sourceCorrections?.contains(where: { $0.source == source }) == true {
            let admission = try await waveformSource(source, sources: sources)
            let channels = try await pipeline.adaptiveAudioWindow(model: model, episode: episodeID, source: source,
                sourceURL: admission.url, matching: admission.witness,
                startSeconds: startSeconds, durationSeconds: durationSeconds)
            let channel = episode.statedChannel(of: source) ?? 0
            guard channels.indices.contains(channel) else { throw WaveformWindowError.invalidSamples }
            try await reverify(admission)
            return AuditionClip(sampleRate: 48000, samples: channels[channel])
        }
        guard let record = episode.source(source),
              let groupID = record.placement.recorderGroupID,
              let group = map.groups.first(where: { $0.group == groupID }),
              group.placements.contains(where: { $0.occurrence.source == source })
        else { throw WaveformWindowError.mapDoesNotMatchSource }
        let admission = try await waveformSource(source, sources: sources)
        let samples = try await AlignedAuditionWindowReader.readWindow(
            sourceURL: admission.url, source: source,
            matching: admission.witness, decoder: pipeline.decoder, groupMap: group,
            decodedChannel: episode.statedChannel(of: source) ?? 0,
            startSeconds: startSeconds, durationSeconds: durationSeconds
        )
        try await reverify(admission)
        _ = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        return AuditionClip(
            sampleRate: Double(AlignedAuditionWindowReader.outputRate), samples: samples
        )
    }

    func dependentCounts(episode episodeID: EpisodeID) async -> DependentCounts {
        await coordinator.states().values.reduce(into: DependentCounts(total: 0, stale: 0)) { counts, state in
            guard state.key?.map?.episode == episodeID else { return }
            counts.total += 1
            if case .stale = state { counts.stale += 1 }
        }
    }

    struct CleanupPreparation: Sendable {
        let plan: PrimaryCleanupPlan
        let identities: [SourceID: String]
    }

    struct CleanupAudio: Sendable {
        let start: Double
        let duration: Double
        let channels: [SpeakerID: [Float]]
    }

    struct CleanupTranscriptionWindow: Sendable {
        let coreFrames: Range<Int64>
        let audioFrames: Range<Int64>
    }

    static func cleanupTranscriptionWindows(start: Double, end: Double) throws -> [CleanupTranscriptionWindow] {
        guard start.isFinite, end.isFinite, (-86_400...86_400).contains(start),
              (-86_400...86_400).contains(end), end > start else {
            throw CleanupFailure(reason: "The transcription range must contain finite supported aligned times.")
        }
        let first = Int64((start * 48_000).rounded()), last = Int64((end * 48_000).rounded())
        guard last > first else { throw CleanupFailure(reason: "The transcription range contains no audio frames.") }
        var windows: [CleanupTranscriptionWindow] = []
        var cursor = first
        while cursor < last {
            let coreEnd = min(last, cursor + 28 * 48_000)
            windows.append(CleanupTranscriptionWindow(coreFrames: cursor..<coreEnd,
                audioFrames: max(first, cursor - 48_000)..<min(last, coreEnd + 48_000)))
            cursor = coreEnd
        }
        return windows
    }

    private struct CleanupFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    func prepareCleanup(
        model: ShowDocumentModel, episode episodeID: EpisodeID, requireReady: Bool = true
    ) async throws -> CleanupPreparation {
        guard let episode = model.episode(episodeID) else { throw AlignmentAcceptanceError.episodeNotFound(episodeID) }
        let sources = await resolveSources(episode.sources)
        try await pipeline.activate(model: model, episode: episodeID)
        let map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        let plan = PrimaryCleanupPlan.make(model: model, episode: episodeID, map: map)
        var identities: [SourceID: String] = [:]
        guard plan.isReady || !requireReady else { return CleanupPreparation(plan: plan, identities: identities) }
        for lane in plan.lanes {
            let admission = try await waveformSource(lane.primary.sourceID, sources: sources)
            let format = try await pipeline.decoder.withDecodingCursor(admission.url, source: lane.primary.sourceID) {
                $0.interpretation
            }
            guard let channel = lane.primary.channel.value, channel < format.channelCount,
                  format.sourceSampleRate == lane.sourceRate, format.frames.validFrames == lane.sourceFrames else {
                throw CleanupFailure(reason: "\(lane.name): the Primary's channel or measured format no longer matches its accepted placement.")
            }
            try await reverify(admission)
            identities[lane.primary.sourceID] = try cleanupIdentity(admission.witness)
        }
        return CleanupPreparation(plan: plan, identities: identities)
    }

    private func cleanupIdentity(_ witness: RawSourceIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(witness)).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupSamples(
        model: ShowDocumentModel, episode: EpisodeID, lane: CleanupSpeakerLane,
        admission: WaveformSourceAdmission, map: AlignedTimelineMap, start: Double, end: Double
    ) async throws -> [Float] {
        guard let channel = lane.primary.channel.value,
              lane.sourceRange(start: start, end: end) != nil
        else { throw CleanupFailure(reason: "\(lane.name): the requested audio crosses unsupported timing.") }
        let firstFrame = Int64((start * 48_000).rounded())
        let endFrame = Int64((end * 48_000).rounded())
        guard endFrame > firstFrame, endFrame - firstFrame <= 30 * 48_000 else {
            throw CleanupFailure(reason: "\(lane.name): the transcription audio window must contain at most 30 seconds.")
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(endFrame - firstFrame))
        var frame = firstFrame
        while frame < endFrame {
            try Task.checkCancellation()
            let count = min(Int64(5 * 48_000), endFrame - frame)
            let frames = frame..<(frame + count)
            let audio: [Float]
            if model.episode(episode)?.alignment?.acceptedMap?.sourceCorrections?
                .contains(where: { $0.source == lane.primary.sourceID }) == true {
                let channels = try await pipeline.adaptiveAudioWindow(
                    model: model, episode: episode, source: lane.primary.sourceID,
                    sourceURL: admission.url, matching: admission.witness,
                    outputFrames: frames)
                guard channels.indices.contains(channel) else { throw WaveformWindowError.invalidSamples }
                audio = channels[channel]
            } else {
                guard let group = map.groups.first(where: {
                    $0.placements.contains { $0.occurrence.source == lane.primary.sourceID }
                }) else { throw WaveformWindowError.mapDoesNotMatchSource }
                audio = try await AlignedAuditionWindowReader.readWindow(
                    sourceURL: admission.url, source: lane.primary.sourceID, matching: admission.witness,
                    decoder: pipeline.decoder, groupMap: group, decodedChannel: channel,
                    outputFrames: frames)
            }
            guard audio.count == count else { throw WaveformWindowError.invalidSamples }
            samples.append(contentsOf: audio)
            frame += count
        }
        try await reverify(admission)
        return samples
    }

    func cleanupPreview(
        model: ShowDocumentModel, episode episodeID: EpisodeID, start: Double, duration: Double,
        respectWorkingRange: Bool = true
    ) async throws -> CleanupAudio {
        let prepared = try await prepareCleanup(model: model, episode: episodeID, requireReady: respectWorkingRange)
        guard (!respectWorkingRange || prepared.plan.isReady), !prepared.plan.lanes.isEmpty,
              let episode = model.episode(episodeID) else {
            throw CleanupFailure(reason: prepared.plan.blockers.joined(separator: "\n"))
        }
        guard start.isFinite, duration.isFinite, duration > 0,
              abs(start) <= 86_400, abs(start + duration) <= 86_400 else {
            throw CleanupFailure(reason: "Choose a finite aligned window of at most 30 seconds within the supported timeline.")
        }
        let first = (start * 48_000).rounded(), last = ((start + duration) * 48_000).rounded()
        let start = first / 48_000, end = last / 48_000, duration = (last - first) / 48_000
        guard last > first, last - first <= 30 * 48_000 else {
            throw CleanupFailure(reason: "The preview window must contain between one frame and 30 seconds.")
        }
        let sources = await resolveSources(episode.sources)
        let map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        let count = Int(last - first)
        var channels: [SpeakerID: [Float]] = [:]
        for lane in prepared.plan.lanes {
            var output = [Float](repeating: 0, count: count)
            let admission = try await waveformSource(lane.primary.sourceID, sources: sources)
            for region in lane.regions {
                let lo = max(start, region.alignedStart, respectWorkingRange ? lane.start : -.infinity)
                let hi = min(end, region.alignedEnd, respectWorkingRange ? lane.end : .infinity)
                guard hi > lo, (hi * 48_000).rounded() > (lo * 48_000).rounded() else { continue }
                let samples = try await cleanupSamples(model: model, episode: episodeID, lane: lane,
                    admission: admission, map: map, start: lo, end: hi)
                let offset = max(0, Int((lo * 48_000).rounded() - first))
                let copied = min(samples.count, count - offset)
                guard copied >= 0 else { throw WaveformWindowError.invalidSamples }
                output.replaceSubrange(offset..<(offset + copied), with: samples.prefix(copied))
            }
            channels[lane.speaker] = output
        }
        _ = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        return CleanupAudio(start: start, duration: duration, channels: channels)
    }

    private actor CleanupLaneQueue {
        let count: Int
        private var cursor = 0
        init(count: Int) { self.count = count }
        func next() -> Int? {
            guard cursor < count else { return nil }
            defer { cursor += 1 }
            return cursor
        }
    }

    func transcribeCleanup(
        model: ShowDocumentModel, episode episodeID: EpisodeID, engine: LocalWhisper,
        concurrency: TranscriptionConcurrency = .one,
        workerPool: TranscriptionWorkerPool? = nil,
        progress: @escaping @Sendable (CleanupTranscriptionProgress) async -> Void
    ) async throws -> [SpeakerTranscript] {
        try await transcribeCleanup(model: model, episode: episodeID, modelRevision: engine.revision,
            concurrency: concurrency, workerPool: workerPool,
            transcribeWindow: { try await engine.transcribeWindow(pcm: $0, sampleRate: 48_000) },
            progress: progress)
    }

    func transcribeCleanup(
        model: ShowDocumentModel, episode episodeID: EpisodeID, modelRevision: String,
        concurrency: TranscriptionConcurrency = .one,
        workerPool: TranscriptionWorkerPool? = nil,
        transcribeWindow: @escaping @Sendable ([Float]) async throws -> PCMTranscript,
        progress: @escaping @Sendable (CleanupTranscriptionProgress) async -> Void
    ) async throws -> [SpeakerTranscript] {
        let preparation = try await prepareCleanup(model: model, episode: episodeID)
        guard preparation.plan.isReady, let revision = preparation.plan.alignmentRevision,
              let episode = model.episode(episodeID) else {
            throw CleanupFailure(reason: preparation.plan.blockers.joined(separator: "\n"))
        }
        let sources = await resolveSources(episode.sources)
        let map = try await pipeline.verifiedAcceptedMap(model: model, episode: episodeID)
        let total = preparation.plan.lanes.reduce(0.0) { $0 + $1.end - $1.start }
        let workerPool = workerPool ?? TranscriptionWorkerPool(concurrency: concurrency)
        let reporter = CleanupTranscriptionReporter(workerLimit: concurrency.rawValue, sink: progress)
        await reporter.report(CleanupTranscriptionProgress(stage: .waiting, speaker: "",
            speakerIndex: 0, speakerCount: preparation.plan.lanes.count,
            windowIndex: 0, windowCount: 0, alignedStart: 0, alignedEnd: 0,
            completedSeconds: 0, totalSeconds: total))
        let queue = CleanupLaneQueue(count: preparation.plan.lanes.count)
        let ordered = try await withThrowingTaskGroup(of: [(Int, SpeakerTranscript)].self) { group in
            for _ in 0..<min(concurrency.rawValue, preparation.plan.lanes.count) {
                group.addTask {
                    var results: [(Int, SpeakerTranscript)] = []
                    while let index = await queue.next() {
                        try Task.checkCancellation()
                        let transcript = try await workerPool.withAdmission {
                            try await self.transcribeCleanupLane(model: model, episodeID: episodeID,
                                lane: preparation.plan.lanes[index], laneIndex: index,
                                speakerCount: preparation.plan.lanes.count, sources: sources, map: map,
                                expectedIdentity: preparation.identities[preparation.plan.lanes[index].primary.sourceID],
                                revision: revision, modelRevision: modelRevision,
                                workingRange: episode.cleanup?.workingRange, total: total,
                                transcribeWindow: transcribeWindow, reporter: reporter)
                        }
                        results.append((index, transcript))
                    }
                    return results
                }
            }
            var results: [(Int, SpeakerTranscript)] = []
            for try await batch in group { results.append(contentsOf: batch) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        await reporter.report(CleanupTranscriptionProgress(stage: .verifying, speaker: "",
            speakerIndex: preparation.plan.lanes.count, speakerCount: preparation.plan.lanes.count,
            windowIndex: 0, windowCount: 0, alignedStart: 0, alignedEnd: 0,
            completedSeconds: total, totalSeconds: total))
        let final = try await prepareCleanup(model: model, episode: episodeID)
        guard final.plan.isReady, final.identities == preparation.identities else { throw DecodeFailure.sourceIdentityMismatch }
        return ordered
    }

    private func transcribeCleanupLane(
        model: ShowDocumentModel, episodeID: EpisodeID, lane: CleanupSpeakerLane, laneIndex: Int,
        speakerCount: Int, sources: [AlignmentSource], map: AlignedTimelineMap,
        expectedIdentity: String?, revision: Int, modelRevision: String,
        workingRange: EpisodeWorkingRange?, total: Double,
        transcribeWindow: @escaping @Sendable ([Float]) async throws -> PCMTranscript,
        reporter: CleanupTranscriptionReporter
    ) async throws -> SpeakerTranscript {
        var completed = 0.0
        let admission = try await waveformSource(lane.primary.sourceID, sources: sources)
        let identity = try cleanupIdentity(admission.witness)
        guard identity == expectedIdentity else { throw DecodeFailure.sourceIdentityMismatch }
        var words: [TranscriptWord] = []
        let windows = try Self.cleanupTranscriptionWindows(start: lane.start, end: lane.end)
        for (windowIndex, window) in windows.enumerated() {
            try Task.checkCancellation()
            let cursor = Double(window.coreFrames.lowerBound) / 48_000
            let coreEnd = Double(window.coreFrames.upperBound) / 48_000
            let start = Double(window.audioFrames.lowerBound) / 48_000
            let end = Double(window.audioFrames.upperBound) / 48_000
            func update(_ stage: CleanupTranscriptionProgress.Stage, completed: Double) -> CleanupTranscriptionProgress {
                CleanupTranscriptionProgress(stage: stage, speaker: lane.name,
                    speakerIndex: laneIndex + 1, speakerCount: speakerCount,
                    windowIndex: windowIndex + 1, windowCount: windows.count,
                    alignedStart: cursor, alignedEnd: coreEnd,
                    completedSeconds: completed, totalSeconds: total)
            }
            await reporter.report(update(.rendering, completed: completed))
            let pcm = try await cleanupSamples(model: model, episode: episodeID, lane: lane,
                admission: admission, map: map, start: start, end: end)
            await reporter.report(update(.recognizing, completed: completed))
            let transcript = try await transcribeWindow(pcm)
            try Task.checkCancellation()
            for segment in transcript.segments {
                if segment.text == "[BLANK_AUDIO]" { continue }
                if let a = segment.startSeconds, let b = segment.endSeconds {
                    let lo = start + a, hi = start + b, center = (lo + hi) / 2
                    guard center >= cursor, center < coreEnd else { continue }
                    if let range = lane.sourceRange(start: lo, end: hi) {
                        words.append(TranscriptWord(text: segment.text, sourceStartFrame: range.lowerBound,
                            sourceEndFrame: range.upperBound, alignedStart: lo, alignedEnd: hi))
                        continue
                    }
                }
                // Preserve recognized but untimed text; never spread it across neighbouring words.
                words.append(TranscriptWord(text: segment.text))
            }
            completed += Double(window.coreFrames.count) / 48_000
            await reporter.report(update(.completedWindow, completed: completed))
        }
        try await reverify(admission)
        return SpeakerTranscript(speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
            sourceIdentity: identity, alignmentRevision: revision, model: modelRevision,
            workingRange: workingRange, words: words)
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
                      let recorded = record?.recordedIdentity?.fingerprint
                else { return nil }
                return .verifiedMetadata(source.id, recorded: recorded, observed: metadata.fingerprint)
            }
            if let revision {
                await coordinator.updateSource(revision)
                values.append(AlignmentSource(
                    id: source.id, url: url, availability: .on,
                    recordedFingerprint: record?.recordedIdentity?.fingerprint
                ))
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
