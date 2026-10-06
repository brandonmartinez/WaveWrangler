import Foundation
import WWCore
import WWDerived
import WWTimeMap

/// Why an analysis, or an accepted map, no longer matches the inputs it was computed from. A map with any
/// change is stale: it is never accepted, activated or rendered.
public enum AlignmentDependencyChange: Sendable, Hashable {
    /// The source's registered revision is not the one the analysis (or the map) used.
    case sourceChanged(SourceID)
    /// The source has no registered revision, so its revision cannot be verified.
    case sourceNotRegistered(SourceID)
    /// The decoder's format interpretation or envelope version is not the one the source was probed with.
    case formatChanged(SourceID)
    /// The source is now placed in a different recorder group or epoch (or none).
    case sourceMoved(SourceID)
    /// The sources placed in this epoch are not the ones the analysis planned.
    case epochSourcesChanged(RecordingEpochID)
    /// The digest of revisions and placements recorded with the map no longer matches the current inputs.
    case dependenciesChanged
    /// The map revision carries no dependency record of this module, so it cannot be verified.
    case dependenciesMissing
}

/// The revisions and placements a map revision was accepted against, persisted as a digest in the map
/// revision's recipe name and re-verified before activation and before rendering.
enum MapDependencies {
    /// Where each placed source sits in the map: its group and the epochs of its spans.
    static func placements(of map: AlignedTimelineMap) -> [SourceID: (group: RecorderGroupID, epochs: [RecordingEpochID])] {
        var result: [SourceID: (group: RecorderGroupID, epochs: [RecordingEpochID])] = [:]
        for group in map.groups {
            for placement in group.placements {
                let epochs = Array(Set(placement.spans.map(\.epoch))).sorted { $0.description < $1.description }
                result[placement.occurrence.source] = (group.group, epochs)
            }
        }
        return result
    }

    /// Digest over every placed source's revision token, the format revision and its placement; `nil` when a
    /// placed source has no token.
    static func digest(map: AlignedTimelineMap, tokens: [SourceID: String], format: FormatRevision) -> String? {
        var entries: [SourceRevision] = []
        for (source, placement) in placements(of: map) {
            guard let token = tokens[source] else { return nil }
            let epochs = placement.epochs.map(\.description).joined(separator: ",")
            entries.append(SourceRevision(
                source: source,
                token: "\(token)|fiv=\(format.interpretationVersion)|env=\(format.envelopeVersion)|group=\(placement.group)|epochs=\(epochs)"
            ))
        }
        return DerivedAssetKey(asset: AssetSpec(kind: "ww.alignment-dependencies", revision: 1), sources: entries).digest
    }

    static func recipe(digest: String) -> RecipeReference {
        RecipeReference(name: AlignmentAssetKinds.acceptanceRecipePrefix + digest, revision: AlignmentAssetKinds.acceptanceRecipeRevision)
    }

    static func persistedDigest(_ version: TimeMapVersion) -> String? {
        guard let recipe = version.inputs.recipe,
              recipe.revision == AlignmentAssetKinds.acceptanceRecipeRevision,
              recipe.name.hasPrefix(AlignmentAssetKinds.acceptanceRecipePrefix)
        else { return nil }
        let digest = String(recipe.name.dropFirst(AlignmentAssetKinds.acceptanceRecipePrefix.count))
        return digest.isEmpty ? nil : digest
    }

    /// Every placed source must still be placed exactly where the map places it.
    static func placementChanges(map: AlignedTimelineMap, episode: Episode) -> [AlignmentDependencyChange] {
        var changes: [AlignmentDependencyChange] = []
        for (source, placement) in placements(of: map).sorted(by: { $0.key.description < $1.key.description }) {
            guard let record = episode.source(source),
                  case let .success((group, epoch))? = episode.alignmentPlacement(of: record),
                  group == placement.group, placement.epochs == [epoch]
            else {
                changes.append(.sourceMoved(source))
                continue
            }
        }
        return changes
    }

    /// Re-verifies a persisted map revision against the current episode, registered revisions and format.
    /// Empty when the map still describes exactly what it was accepted against.
    static func verify(
        version: TimeMapVersion,
        map: AlignedTimelineMap,
        episode: Episode,
        registered: [SourceID: String],
        format: FormatRevision
    ) -> [AlignmentDependencyChange] {
        var changes = placementChanges(map: map, episode: episode)
        for input in version.inputs.sources where input.formatInterpretationVersion != format.interpretationVersion {
            changes.append(.formatChanged(input.sourceID))
        }
        for source in placements(of: map).keys.sorted(by: { $0.description < $1.description }) where registered[source] == nil {
            changes.append(.sourceNotRegistered(source))
        }
        guard let persisted = persistedDigest(version) else { return changes + [.dependenciesMissing] }
        if digest(map: map, tokens: registered, format: format) != persisted, changes.isEmpty {
            changes.append(.dependenciesChanged)
        }
        return changes
    }

    /// The analysis plan must still describe the episode: same sources in the same epochs, and every probed
    /// fact measured on the current registered revision and format.
    static func analysisChanges(
        plan: AlignmentPlan,
        facts: [SourceID: SourceFacts],
        episode: Episode,
        registered: [SourceID: String],
        format: FormatRevision
    ) -> [AlignmentDependencyChange] {
        var changes: [AlignmentDependencyChange] = []
        var current: [RecordingEpochID: Set<SourceID>] = [:]
        var placementOf: [SourceID: (RecorderGroupID, RecordingEpochID)] = [:]
        for record in episode.sources {
            guard case let .success((group, epoch))? = episode.alignmentPlacement(of: record) else { continue }
            current[epoch, default: []].insert(record.id)
            placementOf[record.id] = (group, epoch)
        }
        var planned: [RecordingEpochID: Set<SourceID>] = [:]
        for epoch in plan.epochs {
            planned[epoch.epoch, default: []].formUnion(epoch.sources)
            for source in epoch.sources {
                guard let (group, placed) = placementOf[source], group == epoch.group, placed == epoch.epoch else {
                    if !changes.contains(.sourceMoved(source)) { changes.append(.sourceMoved(source)) }
                    continue
                }
            }
        }
        for epoch in Set(current.keys).union(planned.keys).sorted(by: { $0.description < $1.description })
        where current[epoch] ?? [] != planned[epoch] ?? [] {
            changes.append(.epochSourcesChanged(epoch))
        }
        for (source, fact) in facts.sorted(by: { $0.key.description < $1.key.description }) {
            guard let token = registered[source] else {
                changes.append(.sourceNotRegistered(source))
                continue
            }
            if token != fact.revisionToken { changes.append(.sourceChanged(source)) }
            if fact.formatInterpretationVersion != format.interpretationVersion || fact.envelopeVersion != format.envelopeVersion {
                changes.append(.formatChanged(source))
            }
        }
        return changes
    }
}

/// The verified content identity of one accepted map revision: a digest of its canonical persisted version
/// (map, inputs and dependency record). Two different maps never share an identity, even when they carry the
/// same revision number.
struct AcceptedMapIdentity: Sendable, Hashable {
    let revision: MapRevisionReference
    let digest: String

    init(revision: MapRevisionReference, version: TimeMapVersion) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = String(decoding: try encoder.encode(version), as: UTF8.self)
        self.revision = revision
        digest = DerivedAssetKey(asset: AssetSpec(kind: "ww.map-version-content", revision: 1), recipe: RecipeReference(name: canonical, revision: 1)).digest
    }

    var recipe: RecipeReference { RecipeReference(name: "ww.accepted-map;content=\(digest)", revision: 1) }

    /// The coordinator key published for the active map; every aligned segment names it as an upstream.
    var key: DerivedAssetKey {
        DerivedAssetKey(asset: AlignmentAssetKinds.acceptedMapIdentity, map: revision, recipe: recipe)
    }

    var slot: DerivedSlot { PipelineSlots.acceptedMapIdentity(revision.episode) }
}

/// Serializes acceptance per episode: the pipeline remembers the document state it last activated, refuses
/// accepting on any other (stale) snapshot, and lets only the latest acceptance issued on that state activate.
actor AcceptanceLedger {
    /// An episode's alignment as one document snapshot saw it.
    struct Snapshot: Sendable, Equatable {
        let alignment: EpisodeAlignment?
    }

    private var committed: [EpisodeID: Snapshot] = [:]
    private var issued: [EpisodeID: UInt64] = [:]
    private var activated: [EpisodeID: UInt64] = [:]
    private var nextToken: UInt64 = 0

    /// Records an acceptance built on `base`. Refused when `base` is not the state this pipeline last
    /// activated; supersedes any earlier acceptance of the episode that was not yet activated.
    func issue(episode: EpisodeID, base: Snapshot) throws(AlignmentAcceptanceError) -> UInt64 {
        if let known = committed[episode], known != base { throw .staleSnapshot }
        nextToken += 1
        issued[episode] = nextToken
        return nextToken
    }

    /// Admits activating `token` (built on `base`, producing `result`). Re-activating the acceptance that is
    /// already committed is idempotent (a retry after a failed activation).
    func activate(episode: EpisodeID, token: UInt64, base: Snapshot, result: Snapshot) throws(AlignmentAcceptanceError) {
        if let known = committed[episode], known == result, activated[episode] == token { return }
        if let known = committed[episode], known != base { throw .staleSnapshot }
        guard issued[episode] == token else { throw .supersededAcceptance }
        committed[episode] = result
        issued[episode] = nil
        activated[episode] = token
    }
}

/// A FIFO async mutex (no thread blocking): waiters suspend until the holder unlocks.
actor AsyncSerial {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
