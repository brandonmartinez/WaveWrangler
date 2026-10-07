import Foundation
import WWCore
import WWPersistence
import WWTimeMap

/// Why a map-history operation refused to produce a new value. Nothing is mutated on failure.
public enum MapHistoryError: Error, Sendable, Equatable {
    case episodeNotFound(EpisodeID)
    case mapNotFound(revision: Int)
    case invalidMap(String)
    /// The supplied inputs do not name exactly the sources placed in the map.
    case inputsDoNotMatchPlacedSources
}

/// Identifies one persisted map revision; part of the M2-C5 key of anything derived from it.
public struct MapRevisionReference: Sendable, Hashable, Codable {
    public var episode: EpisodeID
    public var revision: Int

    public init(episode: EpisodeID, revision: Int) {
        self.episode = episode
        self.revision = revision
    }
}

/// Typed, append-only operations over `Episode.alignment` (WW-020). Pure: each returns a new show value.
/// Recording never rewrites an earlier revision; accepting changes only `acceptedRevision`.
extension ShowDocumentModel {
    /// Appends `map` as the next revision (`latest + 1`, starting at 1).
    ///
    /// - Parameter inputs: per-source inputs; when `nil`, one input (no format version, no digest) per placed
    ///   source. Either way they must name exactly the placed sources.
    public func recordingMap(
        _ map: AlignedTimelineMap,
        in episodeID: EpisodeID,
        inputs: [TimeMapSourceInput]? = nil,
        recipe: RecipeReference? = nil,
        derivedFrom: Int? = nil
    ) throws(MapHistoryError) -> (model: ShowDocumentModel, revision: MapRevisionReference) {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        let encoded: EmbeddedJSON
        do { encoded = try EmbeddedTimeMapCodec.encode(map) } catch { throw .invalidMap(error.description) }
        let placed = EmbeddedTimeMapCodec.placedSources(map)
        let sourceInputs = inputs ?? placed.map { TimeMapSourceInput(sourceID: $0) }
        guard Set(sourceInputs.map(\.sourceID)) == Set(placed), sourceInputs.count == placed.count else {
            throw .inputsDoNotMatchPlacedSources
        }
        var alignment = episodes[index].alignment ?? EpisodeAlignment()
        if let derivedFrom, alignment.map(revision: derivedFrom) == nil { throw .mapNotFound(revision: derivedFrom) }
        let revision = (alignment.latestRevision ?? 0) + 1
        alignment.maps.append(TimeMapVersion(
            revision: revision,
            derivedFrom: derivedFrom,
            inputs: TimeMapInputs(sources: sourceInputs, recipe: recipe),
            map: encoded
        ))
        let issues = alignment.structuralIssues(episode: episodeID)
        guard issues.isEmpty else { throw .invalidMap(issues.map(\.description).joined(separator: "; ")) }
        var copy = self
        copy.episodes[index].alignment = alignment
        return (copy, MapRevisionReference(episode: episodeID, revision: revision))
    }

    /// Marks `revision` as the accepted map. Callers pass the result to `DerivedJobCoordinator.acceptMap(_:)`
    /// so work derived from any other revision becomes stale (REF-019).
    public func acceptingMap(revision: Int, in episodeID: EpisodeID) throws(MapHistoryError) -> ShowDocumentModel {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        guard var alignment = episodes[index].alignment, alignment.map(revision: revision) != nil else {
            throw .mapNotFound(revision: revision)
        }
        alignment.acceptedRevision = revision
        var copy = self
        copy.episodes[index].alignment = alignment
        return copy
    }

    public func timeMap(revision: Int, in episodeID: EpisodeID) throws(MapHistoryError) -> AlignedTimelineMap {
        guard let episode = episode(episodeID) else { throw .episodeNotFound(episodeID) }
        guard let version = episode.alignment?.map(revision: revision) else { throw .mapNotFound(revision: revision) }
        do { return try EmbeddedTimeMapCodec.decode(version.map) } catch { throw .invalidMap(error.description) }
    }
}

/// Why a persisted map no longer describes the episode as it is now. Computed, never repaired.
public enum MapStaleness: Sendable, Hashable {
    case sourceMissing(SourceID)
    case recorderGroupMissing(RecorderGroupID)
    case epochMissing(RecordingEpochID)
    /// The source is now placed in a different recorder group (or none) than the map's group.
    case sourceRegrouped(SourceID, mapGroup: RecorderGroupID, currentGroup: RecorderGroupID?)
}

public struct MapApplicability: Sendable, Equatable {
    public var revision: MapRevisionReference
    /// Empty when the map still matches the episode's sources, groups and epochs.
    public var staleness: [MapStaleness]

    public var isCurrent: Bool { staleness.isEmpty }
}

extension Episode {
    /// Metadata-only comparison of a persisted map with this episode's current structure.
    public func applicability(ofMapRevision revision: Int) throws(MapHistoryError) -> MapApplicability {
        guard let version = alignment?.map(revision: revision) else { throw .mapNotFound(revision: revision) }
        let map: AlignedTimelineMap
        do { map = try EmbeddedTimeMapCodec.decode(version.map) } catch { throw .invalidMap(error.description) }
        var staleness: [MapStaleness] = []
        func note(_ reason: MapStaleness) {
            if !staleness.contains(reason) { staleness.append(reason) }
        }
        for group in map.groups {
            guard let current = recorderGroup(group.group) else {
                note(.recorderGroupMissing(group.group))
                continue
            }
            let epochs = Set(current.epochs.map(\.id))
            for epoch in group.epochs.map(\.epoch) + group.placements.flatMap({ $0.spans.map(\.epoch) }) where !epochs.contains(epoch) {
                note(.epochMissing(epoch))
            }
            for placement in group.placements {
                let sourceID = placement.occurrence.source
                guard let record = source(sourceID) else {
                    note(.sourceMissing(sourceID))
                    continue
                }
                if record.placement.recorderGroupID != group.group {
                    note(.sourceRegrouped(sourceID, mapGroup: group.group, currentGroup: record.placement.recorderGroupID))
                }
            }
        }
        return MapApplicability(revision: MapRevisionReference(episode: id, revision: revision), staleness: staleness)
    }
}
