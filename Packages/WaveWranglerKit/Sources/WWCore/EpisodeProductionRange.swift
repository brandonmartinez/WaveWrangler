import Foundation

/// Finished-episode boundaries are independent of aligned Speaker In/Out.
/// An omitted edge follows the arrangement automatically; explicit edges reuse clip anchor semantics.
public struct EpisodeProductionRange: Sendable, Equatable, Codable {
    public var start: AudioPlacementAnchor?
    public var end: AudioPlacementAnchor?
    public var restrictSpeech: Bool

    public init(start: AudioPlacementAnchor? = nil, end: AudioPlacementAnchor? = nil,
                restrictSpeech: Bool = false) {
        self.start = start
        self.end = end
        self.restrictSpeech = restrictSpeech
    }

    public func validationIssues(in episode: Episode) -> [ValidationIssue] {
        var issues: [ValidationIssue] = [start, end].compactMap { $0 }.filter { !$0.isValid(in: episode) }.map { _ in
            .init(.invalidAudio, "episode \(episode.id) has an invalid production boundary anchor")
        }
        let reversed: Bool
        switch (start, end) {
        case let (.absolute(first)?, .absolute(last)?), let (.programOrigin(first)?, .programOrigin(last)?):
            reversed = first >= last
        case let (.dialogue(first)?, .dialogue(last)?)
            where first.alignmentRevision == last.alignmentRevision && first.mapIdentity == last.mapIdentity:
            reversed = first.frame >= last.frame
        case let (.insertion(first, firstOffset)?, .insertion(last, lastOffset)?) where first == last:
            reversed = firstOffset >= lastOffset
        default: reversed = false
        }
        if reversed {
            issues.append(.init(.invalidAudio, "episode \(episode.id) has reversed or empty production boundaries"))
        }
        return issues
    }
}

extension AudioPlacementAnchor {
    /// Structural validation retains historical map bindings; current-map review belongs to projection.
    package func isValid(in episode: Episode, allowsInsertion: Bool = true,
                         insertionRegions: [AudioInsertionRegion]? = nil) -> Bool {
        switch self {
        case .absolute(let frame), .programOrigin(let frame):
            return (-AudioArrangement.frameLimit...AudioArrangement.frameLimit).contains(frame)
        case .dialogue(let anchor):
            return anchor.alignmentRevision > 0
                && episode.alignment?.map(revision: anchor.alignmentRevision) != nil
                && anchor.mapIdentity.utf8.count == 64
                && anchor.mapIdentity.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && (-AudioArrangement.frameLimit...AudioArrangement.frameLimit).contains(anchor.frame)
        case .insertion(let id, let offset):
            return allowsInsertion && offset >= 0
                && (insertionRegions ?? episode.audioArrangement?.insertionRegions ?? []).contains {
                    $0.id == id && offset < $0.durationFrames
                }
        }
    }
}

extension ShowDocumentModel {
    public func settingProductionRange(_ range: EpisodeProductionRange?,
                                       in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else {
            throw .episodeNotFound(episodeID)
        }
        var result = self
        result.episodes[index].productionRange = range == EpisodeProductionRange() ? nil : range
        if let issue = result.validationIssues().first { throw .invalidAudio(issue.description) }
        return result
    }
}
