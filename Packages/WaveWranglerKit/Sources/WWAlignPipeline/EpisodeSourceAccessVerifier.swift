import Foundation
import WWCore
import WWDecode
import WWDerived
import WWSources
import WWTimeMap

/// A caller's freshly observed, independently verified document publication. Never a raw unsaved
/// ShowDocumentModel: the app must refuse when its live model differs from its verified publication.
public struct EpisodeSourceDocument: Sendable {
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
    case accessMissing(SourceID)
    case accessUnverified(SourceID)
    case sourceChanged(SourceID)
    case changedDuringVerification
}

/// The caller supplies the live document each time, not a cached manifest. Every call also re-reads the
/// device-local grants and the coordinator's accepted-map content identity. A future cut admission must
/// recheck after its own awaits and separately certify protection, fades, and atomic publication.
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

    private func sample(
        episode episodeID: EpisodeID,
        currentDocument: @Sendable () async throws -> EpisodeSourceDocument
    ) async throws -> Sample {
        let document = try await currentDocument()
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
        let evaluator = SourceAvailabilityEvaluator(context: access)
        var lanes: [EpisodeSourceLane] = []
        var usedRecords: [DeviceAccessRecord] = []
        for source in sources {
            guard let (group, placement) = placements.first(where: { $0.1.occurrence.source == source.id }),
                  source.placement.recorderGroupID == group.group,
                  let epoch = source.placement.epochID,
                  placement.spans.first?.epoch == epoch,
                  !placement.spans.isEmpty
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
            let evaluation = evaluator.evaluate(key: key, record: record, setting: .off)
            guard evaluation.observation.access == .granted,
                  evaluation.refreshedRecord == nil,
                  evaluation.observation.identity == .matchesRecorded,
                  evaluation.observation.location == .present,
                  evaluation.observation.residency == .local,
                  let url = evaluation.resolvedURL
            else { throw EpisodeSourceAccessRefusal.accessUnverified(source.id) }
            let current = access.withScopedAccess(to: url) { access.io.metadata(at: $0) }
            guard case let .success(metadata) = current,
                  record.recordedIdentity?.fingerprint.compare(to: metadata.fingerprint) == .matches,
                  metadata.isReadable.value == true
            else { throw EpisodeSourceAccessRefusal.sourceChanged(source.id) }
            let fileRevision = SourceRevision.metadata(source.id, fingerprint: metadata.fingerprint)
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
        return Sample(document: document, accessRecords: usedRecords, witness: EpisodeSourceAccessWitness(
            show: showID, episode: episodeID, publication: document.publication, acceptedMapKey: identity.key, lanes: lanes
        ))
    }
}

extension EpisodeSourceDocument: Equatable {}
