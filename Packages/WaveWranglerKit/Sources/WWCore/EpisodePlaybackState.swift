import Foundation

public enum EpisodePlaybackScope: Sendable, Hashable {
    case source(SourceID)
    case speaker(SpeakerID)
    case recorder(RecorderGroupID)
}

/// Session listening state, never a source role, visibility setting or analysis input.
public struct EpisodePlaybackState: Sendable, Equatable {
    public var muted: Set<EpisodePlaybackScope>
    public var soloed: Set<EpisodePlaybackScope>

    public init(muted: Set<EpisodePlaybackScope> = [], soloed: Set<EpisodePlaybackScope> = []) {
        self.muted = muted
        self.soloed = soloed
    }

    public func isAudible(_ sourceID: SourceID, in episode: Episode) -> Bool {
        guard let source = episode.source(sourceID) else { return false }
        var memberships: Set<EpisodePlaybackScope> = [.source(sourceID)]
        if let group = source.placement.recorderGroupID { memberships.insert(.recorder(group)) }
        for reference in episode.references(to: sourceID) { memberships.insert(.speaker(reference.speakerID)) }
        return memberships.isDisjoint(with: muted)
            && (soloed.isEmpty || !memberships.isDisjoint(with: soloed))
    }

    public func audibleSources(in episode: Episode) -> [SourceID] {
        episode.sources.map(\.id).filter { isAudible($0, in: episode) }
    }

    public mutating func setMuted(_ value: Bool, scope: EpisodePlaybackScope) {
        if value { muted.insert(scope) } else { muted.remove(scope) }
    }

    public mutating func setSoloed(_ value: Bool, scope: EpisodePlaybackScope) {
        if value { soloed.insert(scope) } else { soloed.remove(scope) }
    }

    public func canApply(_ policy: EditingPlaybackPolicy, in episode: Episode) -> Bool {
        let primaries = Set(episode.speakerAssignments.compactMap { $0.primary?.sourceID })
            .intersection(episode.sources.map(\.id))
        switch policy {
        case .keepChoices: return true
        case .muteNonPrimaries, .soloPrimaries: return !primaries.isEmpty
        case .soloBackups: return episode.sources.contains { !primaries.contains($0.id) }
        }
    }

    public func applying(_ policy: EditingPlaybackPolicy, in episode: Episode) throws(DomainError) -> Self {
        guard canApply(policy, in: episode) else {
            throw .invalidWorkspace("No eligible tracks for '\(policy.title)'. Assign the relevant recordings first.")
        }
        var result = self
        let primaries = Set(episode.speakerAssignments.compactMap { $0.primary?.sourceID })
        let nonPrimaries = Set(episode.sources.map(\.id)).subtracting(primaries)
        switch policy {
        case .keepChoices: break
        case .muteNonPrimaries:
            result.muted.formUnion(nonPrimaries.map(EpisodePlaybackScope.source))
        case .soloPrimaries:
            result.soloed = Set(primaries.map(EpisodePlaybackScope.source))
        case .soloBackups:
            result.soloed = Set(nonPrimaries.map(EpisodePlaybackScope.source))
        }
        return result
    }

    public mutating func retainScopes(in episode: Episode) {
        let sources = Set(episode.sources.map { EpisodePlaybackScope.source($0.id) })
        let speakers = Set(episode.speakerAssignments.map { EpisodePlaybackScope.speaker($0.speakerID) })
        let recorders = Set(episode.recorderGroups.map { EpisodePlaybackScope.recorder($0.id) })
        let valid = sources.union(speakers).union(recorders)
        muted.formIntersection(valid)
        soloed.formIntersection(valid)
    }
}
