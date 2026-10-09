import Foundation
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap

/// UNTRUSTED survey input. Neither model nor publication proves which show is open; only the app can
/// bind a private snapshot to its actual registered ShowDocument and verify its private on-disk base.
public struct EpisodeSourceSurveyInput: Sendable, Equatable {
    public let model: ShowDocumentModel
    public let publication: PublicationStamp

    public init(model: ShowDocumentModel, publication: PublicationStamp) {
        self.model = model
        self.publication = publication
    }
}

/// A metadata-only inventory of *declared* channels on every accepted-map occurrence. Not a content,
/// protection, or physical channel-count survey; it cannot authorize an edit or a render.
public struct EpisodeSourceLane: Sendable, Equatable, Hashable {
    public let source: SourceID
    public let channel: Int
    public let occurrence: SourceOccurrenceID
    public let epoch: RecordingEpochID
    public let group: RecorderGroupID
    public let fileRevision: SourceRevision
}

public enum EpisodeProtectionSurvey: Sendable, Equatable {
    case absent
}

public enum EpisodeCompleteCutBlocker: Sendable, Equatable {
    case protectionSurveyAbsent
    case fadeNotCertified
    case atomicPublicationNotCertified
}

public enum EpisodeCompleteCutPreparation: Sendable, Equatable {
    case refused([EpisodeCompleteCutBlocker])
}

/// UNTRUSTED metadata inventory. A caller may supply arbitrary survey documents; this value is never
/// a verified open-show publication, an access lease, a cut authorization or a protection survey.
public struct EpisodeSourceInventory: Sendable, Equatable {
    public let show: ShowID
    public let episode: EpisodeID
    public let publication: PublicationStamp
    public let acceptedMapKey: DerivedAssetKey
    public let lanes: [EpisodeSourceLane]
    public let protectionSurvey: EpisodeProtectionSurvey
    public var completeCutPreparation: EpisodeCompleteCutPreparation {
        .refused([.protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified])
    }

    // No public constructor: the package performs metadata observation, never trusted issuance.
    fileprivate init(show: ShowID, episode: EpisodeID, publication: PublicationStamp, acceptedMapKey: DerivedAssetKey, lanes: [EpisodeSourceLane]) {
        self.show = show
        self.episode = episode
        self.publication = publication
        self.acceptedMapKey = acceptedMapKey
        self.lanes = lanes
        protectionSurvey = .absent
    }
}

public enum EpisodeSourceAccessRefusal: Error, Sendable, Equatable {
    case wrongShow
    case episodeMissing
    case acceptedMapMissing
    case acceptedMapInvalid
    case acceptedMapStale
    case acceptedMapNotActive
    case incompleteOccurrences
    case duplicateOccurrence
    case unsupportedEpoch(RecordingEpochID)
    case undeclaredChannels(SourceID)
    case physicalIdentityUnknown(SourceID)
    case physicalAlias(SourceID, SourceID)
    case accessMissing(SourceID)
    case accessUnverified(SourceID)
    case sourceChanged(SourceID)
    case changedDuringVerification
}

/// An UNTRUSTED read-only lane survey. Its callback is caller-controlled and cannot attest the open
/// ShowDocument. Only the app-owned issuer may bind the resulting inventory to a live open document,
/// recheck it after awaits, and return a private snapshot (never a WWCutPolicy proof).
public struct EpisodeSourceInventorySurveyor: Sendable {
    public let showID: ShowID
    public let coordinator: DerivedJobCoordinator
    public let accessStore: any DeviceAccessStore
    public let access: SourceAccessContext

    public init(showID: ShowID, coordinator: DerivedJobCoordinator, accessStore: any DeviceAccessStore, access: SourceAccessContext) {
        self.showID = showID
        self.coordinator = coordinator
        self.accessStore = accessStore
        self.access = access
    }

    public func survey(
        episode episodeID: EpisodeID,
        currentDocument: @Sendable () async throws -> EpisodeSourceSurveyInput
    ) async throws -> EpisodeSourceInventory {
        try await verify(episode: episodeID, currentDocument: currentDocument)
    }

    public func resurvey(
        _ inventory: EpisodeSourceInventory,
        currentDocument: @Sendable () async throws -> EpisodeSourceSurveyInput
    ) async throws {
        try await reverify(inventory, currentDocument: currentDocument)
    }

    // Internal names retained for package fixture tests; app clients have only survey/resurvey.
    func verify(
        episode episodeID: EpisodeID,
        currentDocument: @Sendable () async throws -> EpisodeSourceSurveyInput
    ) async throws -> EpisodeSourceInventory {
        try Task.checkCancellation()
        let first = try await sample(episode: episodeID, currentDocument: currentDocument)
        let second = try await sample(episode: episodeID, currentDocument: currentDocument)
        try Task.checkCancellation()
        guard first == second else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
        return second.witness
    }

    func reverify(
        _ witness: EpisodeSourceInventory,
        currentDocument: @Sendable () async throws -> EpisodeSourceSurveyInput
    ) async throws {
        guard witness.show == showID else { throw EpisodeSourceAccessRefusal.wrongShow }
        let fresh = try await verify(episode: witness.episode, currentDocument: currentDocument)
        guard fresh == witness else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
    }

    private struct Sample: Equatable {
        let document: EpisodeSourceSurveyInput
        let accessRecords: [DeviceAccessRecord]
        let witness: EpisodeSourceInventory
    }

    private struct LaneAddress: Hashable {
        let source: SourceID
        let channel: Int
        let occurrence: SourceOccurrenceID
        let epoch: RecordingEpochID
    }

    private struct PhysicalFile: Hashable {
        let volume: String
        let identifier: UInt64
    }

    private func observe(
        _ source: SourceID, record: DeviceAccessRecord, evaluator: SourceAvailabilityEvaluator
    ) throws -> (revision: SourceRevision, physical: PhysicalFile) {
        let key = DeviceAccessKey(showID: showID, sourceID: source)
        let evaluation = evaluator.evaluate(key: key, record: record, setting: .off)
        guard evaluation.observation.access == .granted,
              evaluation.refreshedRecord == nil,
              evaluation.observation.identity == .matchesRecorded,
              evaluation.observation.location == .present,
              evaluation.observation.residency == .local,
              let url = evaluation.resolvedURL
        else { throw EpisodeSourceAccessRefusal.accessUnverified(source) }
        let current = access.withScopedAccess(to: url) { access.io.metadata(at: $0) }
        guard case let .success(metadata) = current,
              record.recordedIdentity?.fingerprint.compare(to: metadata.fingerprint) == .matches,
              metadata.isReadable.value == true
        else { throw EpisodeSourceAccessRefusal.sourceChanged(source) }
        guard let volume = metadata.fingerprint.volumeUUID.value,
              let identifier = metadata.fingerprint.fileIdentifier.value
        else { throw EpisodeSourceAccessRefusal.physicalIdentityUnknown(source) }
        return (
            SourceRevision.metadata(source, fingerprint: metadata.fingerprint),
            PhysicalFile(volume: volume, identifier: identifier)
        )
    }

    private func sample(
        episode episodeID: EpisodeID,
        currentDocument: @Sendable () async throws -> EpisodeSourceSurveyInput
    ) async throws -> Sample {
        try Task.checkCancellation()
        let document = try await currentDocument()
        try Task.checkCancellation()
        let model = document.model
        guard model.show.id == showID else { throw EpisodeSourceAccessRefusal.wrongShow }
        guard let episode = model.episode(episodeID) else { throw EpisodeSourceAccessRefusal.episodeMissing }
        guard let revision = episode.alignment?.acceptedRevision,
              let version = episode.alignment?.map(revision: revision)
        else { throw EpisodeSourceAccessRefusal.acceptedMapMissing }
        guard let map = try? model.timeMap(revision: revision, in: episodeID),
              let applicable = try? episode.applicability(ofMapRevision: revision),
              applicable.isCurrent
        else { throw EpisodeSourceAccessRefusal.acceptedMapInvalid }

        let inputs = await coordinator.inputs
        guard inputs.acceptedMaps[episodeID] == revision else { throw EpisodeSourceAccessRefusal.acceptedMapNotActive }
        guard MapDependencies.verify(
            version: version, map: map, episode: episode, registered: inputs.sources, format: inputs.format
        ).isEmpty else { throw EpisodeSourceAccessRefusal.acceptedMapStale }
        let identity: AcceptedMapIdentity
        do {
            identity = try AcceptedMapIdentity(
                revision: MapRevisionReference(episode: episodeID, revision: revision),
                version: version, map: map, registered: inputs.sources
            )
        } catch {
            throw EpisodeSourceAccessRefusal.acceptedMapStale
        }
        guard await coordinator.state(of: identity.slot) == .ready(identity.key) else {
            throw EpisodeSourceAccessRefusal.acceptedMapNotActive
        }

        let records = try await accessStore.records(in: showID)
        let latest = try await currentDocument()
        try Task.checkCancellation()
        guard latest.model == model, latest.publication == document.publication else {
            throw EpisodeSourceAccessRefusal.changedDuringVerification
        }
        guard records.count == Set(records.map(\.key)).count else {
            throw EpisodeSourceAccessRefusal.duplicateOccurrence
        }
        let sources = episode.sources
        let sourceIDs = Set(sources.map(\.id))
        guard sources.count == sourceIDs.count else { throw EpisodeSourceAccessRefusal.duplicateOccurrence }
        let placements = map.groups.flatMap { group in group.placements.map { (group, $0) } }
        guard placements.count == sources.count,
              Set(placements.map(\.1.occurrence.source)) == sourceIDs
        else { throw EpisodeSourceAccessRefusal.incompleteOccurrences }
        guard Set(placements.map(\.1.occurrence.id)).count == placements.count,
              Set(placements.map(\.1.occurrence.source)).count == placements.count
        else { throw EpisodeSourceAccessRefusal.duplicateOccurrence }
        guard Set(map.groups.map(\.group)) == Set(episode.recorderGroups.map(\.id)),
              map.groups.allSatisfy({ group in
                  guard let current = episode.recorderGroups.first(where: { $0.id == group.group }) else { return false }
                  let placedEpochs = Set(group.placements.flatMap { $0.spans.map(\.epoch) })
                  return placedEpochs == Set(group.epochs.map(\.epoch))
                      && placedEpochs == Set(current.epochs.map(\.id))
              })
        else { throw EpisodeSourceAccessRefusal.incompleteOccurrences }
        let evaluator = SourceAvailabilityEvaluator(context: access)
        var lanes: [EpisodeSourceLane] = []
        var usedRecords: [DeviceAccessRecord] = []
        var observedRevisions: [SourceID: String] = [:]
        var physicalOwners: [PhysicalFile: SourceID] = [:]
        for source in sources {
            guard let (group, placement) = placements.first(where: { $0.1.occurrence.source == source.id }),
                  source.placement.recorderGroupID == group.group,
                  let epoch = source.placement.epochID,
                  placement.spans.first?.epoch == epoch,
                  let first = placement.spans.first, first.startFrame == 0,
                  placement.spans.last?.endFrame == placement.occurrence.frameCount,
                  zip(placement.spans, placement.spans.dropFirst()).allSatisfy({ $0.endFrame == $1.startFrame })
            else { throw EpisodeSourceAccessRefusal.incompleteOccurrences }
            let epochs = Dictionary(uniqueKeysWithValues: group.epochs.map { ($0.epoch, $0.mapping) })
            for span in placement.spans {
                guard let mapping = epochs[span.epoch] else { throw EpisodeSourceAccessRefusal.incompleteOccurrences }
                if case .unsupported = mapping { throw EpisodeSourceAccessRefusal.unsupportedEpoch(span.epoch) }
            }
            guard let count = source.observations.channelCount.value, count > 0,
                  DecodeEnvelope.entries.contains(where: { $0.channelCounts.contains(count) }),
                  source.placement.channelLabels.allSatisfy({ $0.channel >= 0 && $0.channel < count }),
                  Set(source.placement.channelLabels.map(\.channel)).count == source.placement.channelLabels.count
            else { throw EpisodeSourceAccessRefusal.undeclaredChannels(source.id) }
            let key = DeviceAccessKey(showID: showID, sourceID: source.id)
            guard let record = records.first(where: { $0.key == key }) else {
                throw EpisodeSourceAccessRefusal.accessMissing(source.id)
            }
            let (fileRevision, physical) = try observe(source.id, record: record, evaluator: evaluator)
            if let other = physicalOwners.updateValue(source.id, forKey: physical) {
                throw EpisodeSourceAccessRefusal.physicalAlias(other, source.id)
            }
            observedRevisions[source.id] = fileRevision.token
            usedRecords.append(record)
            for span in placement.spans {
                for channel in 0..<count {
                    lanes.append(EpisodeSourceLane(
                        source: source.id, channel: channel, occurrence: placement.occurrence.id,
                        epoch: span.epoch, group: group.group, fileRevision: fileRevision
                    ))
                }
            }

        }
        guard Set(lanes.map {
            LaneAddress(source: $0.source, channel: $0.channel, occurrence: $0.occurrence, epoch: $0.epoch)
        }).count == lanes.count
        else { throw EpisodeSourceAccessRefusal.duplicateOccurrence }
        guard sources.allSatisfy({ observedRevisions[$0.id] == inputs.sources[$0.id] }),
              MapDependencies.verify(
                  version: version, map: map, episode: episode,
                  registered: observedRevisions, format: inputs.format
              ).isEmpty
        else { throw EpisodeSourceAccessRefusal.acceptedMapStale }

        // The last document callback is an await: a grant can be revoked or relinked there even
        // after the earlier records fetch. Recheck the exact ready key, then read the store again
        // and validate every observed identity against that final record before returning.
        let finalInputs = await coordinator.inputs
        guard finalInputs.acceptedMaps[episodeID] == revision,
              finalInputs.sources == inputs.sources,
              finalInputs.format == inputs.format,
              await coordinator.state(of: identity.slot) == .ready(identity.key)
        else { throw EpisodeSourceAccessRefusal.acceptedMapNotActive }
        let finalRecords = try await accessStore.records(in: showID)
        try Task.checkCancellation()
        guard finalRecords.count == Set(finalRecords.map(\.key)).count else {
            throw EpisodeSourceAccessRefusal.duplicateOccurrence
        }
        for (source, original) in zip(sources, usedRecords) {
            guard let record = finalRecords.first(where: { $0.key == original.key }) else {
                throw EpisodeSourceAccessRefusal.accessMissing(source.id)
            }
            guard record == original else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
            let (revision, physical) = try observe(source.id, record: record, evaluator: evaluator)
            guard revision.token == observedRevisions[source.id],
                  physicalOwners[physical] == source.id
            else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
        }
        // The final records read is an await: it can invalidate the coordinator even if it returns
        // unchanged records. Cancellation is checked after every suspension and immediately before return.
        let postRecordsInputs = await coordinator.inputs
        guard postRecordsInputs == inputs,
              await coordinator.state(of: identity.slot) == .ready(identity.key)
        else { throw EpisodeSourceAccessRefusal.acceptedMapNotActive }
        try Task.checkCancellation()
        return Sample(document: document, accessRecords: usedRecords, witness: EpisodeSourceInventory(
            show: showID, episode: episodeID, publication: document.publication, acceptedMapKey: identity.key, lanes: lanes
        ))
    }
}

// Legacy names are available to @testable package fixtures only, not external clients.
typealias EpisodeSourceAccessVerifier = EpisodeSourceInventorySurveyor
typealias EpisodeSourceDocument = EpisodeSourceSurveyInput
