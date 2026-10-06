import Foundation
import WWCore
import WWTimeMap

/// The one conversion between a persisted `EmbeddedJSON` map and the strict `WWTimeMap` type (WW-020).
///
/// Decoding is `WWTimeMap`'s strict decoder: unknown-newer `timeMapSchemaVersion` is refused before anything
/// else, then unknown keys, then every map invariant is re-checked. A map must also be in its single canonical
/// encoding (re-encoding the decoded map reproduces it exactly), so one map has one persisted representation.
public enum EmbeddedTimeMapCodec {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case undecodable(String)
        case notCanonical

        public var description: String {
            switch self {
            case let .undecodable(reason): "map is not a valid time map: \(reason)"
            case .notCanonical: "map is not in canonical form"
            }
        }
    }

    public static func decode(_ json: EmbeddedJSON) throws(Failure) -> AlignedTimelineMap {
        let map: AlignedTimelineMap
        do {
            map = try JSONDecoder().decode(AlignedTimelineMap.self, from: try encoder.encode(json))
        } catch {
            throw .undecodable(String(describing: error))
        }
        guard (try? encode(map)) == json else { throw .notCanonical }
        return map
    }

    public static func encode(_ map: AlignedTimelineMap) throws(Failure) -> EmbeddedJSON {
        do {
            return try JSONDecoder().decode(EmbeddedJSON.self, from: try encoder.encode(map))
        } catch {
            throw .undecodable(String(describing: error))
        }
    }

    /// Distinct sources placed in the map, in placement order.
    public static func placedSources(_ map: AlignedTimelineMap) -> [SourceID] {
        var seen = Set<SourceID>()
        return map.groups.flatMap(\.placements).map(\.occurrence.source).filter { seen.insert($0).inserted }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension ShowDocumentModel {
    /// Embedded-map checks that need `WWTimeMap` (WWCore checks the alignment structure). Run by the show
    /// coder on every open and every save, so an invalid map is never opened as valid nor published.
    public func embeddedMapIssues() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for episode in episodes {
            for version in episode.alignment?.maps ?? [] {
                let map: AlignedTimelineMap
                do {
                    map = try EmbeddedTimeMapCodec.decode(version.map)
                } catch {
                    issues.append(.init(.invalidAlignment, "episode \(episode.id) map \(version.revision): \(error)"))
                    continue
                }
                let placed = EmbeddedTimeMapCodec.placedSources(map)
                if Set(placed) != Set(version.inputs.sources.map(\.sourceID)) {
                    issues.append(.init(.invalidAlignment, "episode \(episode.id) map \(version.revision) inputs differ from placed sources"))
                }
            }
        }
        return issues
    }
}
