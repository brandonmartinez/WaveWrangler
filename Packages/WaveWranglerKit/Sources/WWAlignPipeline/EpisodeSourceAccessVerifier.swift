import Foundation
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap

/// A publication read back from the current canonical show file against the document's verified base.
/// A caller cannot manufacture one from an in-memory model and a claimed publication stamp.
public struct EpisodeSourceDocument: Sendable {
    public let model: ShowDocumentModel
    public let publication: PublicationStamp
    private let url: URL?
    private let base: RevisionFingerprint?

    private init(model: ShowDocumentModel, publication: PublicationStamp, url: URL?, base: RevisionFingerprint?) {
        self.model = model
        self.publication = publication
        self.url = url
        self.base = base
    }

    /// The expected base must be the one the open document independently verified on read/save. This
    /// coordinated read verifies the complete on-disk envelope, not just the stamp or cached model.
    public static func current(
        at url: URL, expectedModel: ShowDocumentModel, expectedBase: RevisionFingerprint
    ) throws -> EpisodeSourceDocument {
        let opener = DocumentOpener(
            coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: nil,
            identityOf: { .show($0.show.id) }
        )
        guard case let .editable(decoded, fingerprint) = opener.open(
            url, key: .show(expectedModel.show.id)
        ), fingerprint == expectedBase, decoded.publication == expectedBase.publication,
           decoded.payload == expectedModel
        else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
        return EpisodeSourceDocument(
            model: decoded.payload, publication: decoded.publication, url: url.standardizedFileURL, base: fingerprint
        )
    }

    func requireCurrent() throws {
        guard let url, let base else { return }
        _ = try Self.current(at: url, expectedModel: model, expectedBase: base)
    }

    #if DEBUG
    // Test-only construction for in-memory invalid-map and grant fixtures; never exposed to app clients.
    init(model: ShowDocumentModel, publication: PublicationStamp) {
        self.init(model: model, publication: publication, url: nil, base: nil)
    }
    #endif
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

public struct EpisodeSourceAccessWitness: Sendable, Equatable {
    public let show: ShowID
    public let episode: EpisodeID
    public let publication: PublicationStamp
    public let acceptedMapKey: DerivedAssetKey
    public let lanes: [EpisodeSourceLane]
    public let protectionSurvey: EpisodeProtectionSurvey
    public var completeCutPreparation: EpisodeCompleteCutPreparation {
        .refused([.protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified])
    }

    // No public constructor: only the verifier can produce this read-only snapshot.
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

/// The document callback supplies the open document's verified base; file-backed values are independently
/// read back even if the callback returns a cached value. Device-local grants and the accepted-map content
/// identity are rechecked. Future cut admission must repeat the checks after its own awaits and separately
/// certify protection, fades and atomic publication.
public struct EpisodeSourceAccessVerifier: Sendable {
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

    public func verify(
        episode episodeID: EpisodeID,
        currentDocument: @Sendable () async throws -> EpisodeSourceDocument
    ) async throws -> EpisodeSourceAccessWitness {
        let first = try await sample(episode: episodeID, currentDocument: currentDocument)
        let second = try await sample(episode: episodeID, currentDocument: currentDocument)
        guard first == second else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
        return second.witness
    }

    public func reverify(
        _ witness: EpisodeSourceAccessWitness,
        currentDocument: @Sendable () async throws -> EpisodeSourceDocument
    ) async throws {
        guard witness.show == showID else { throw EpisodeSourceAccessRefusal.wrongShow }
        let fresh = try await verify(episode: witness.episode, currentDocument: currentDocument)
        guard fresh == witness else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
    }

    private struct Sample: Equatable {
        let document: EpisodeSourceDocument
        let accessRecords: [DeviceAccessRecord]
        let witness: EpisodeSourceAccessWitness
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
        currentDocument: @Sendable () async throws -> EpisodeSourceDocument
    ) async throws -> Sample {
        let document = try await currentDocument()
        try document.requireCurrent()
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
        try latest.requireCurrent()
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
        try latest.requireCurrent()
        return Sample(document: document, accessRecords: usedRecords, witness: EpisodeSourceAccessWitness(
            show: showID, episode: episodeID, publication: document.publication, acceptedMapKey: identity.key, lanes: lanes
        ))
    }
}

extension EpisodeSourceDocument: Equatable {}
