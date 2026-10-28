import WWCore
import WWDerived
import WWTimeMap

/// One immutable calculation, never a source grant or a cached coordinator admission.
actor AcceptedMapContextCache {
    struct Key: Sendable, Equatable {
        let media: EpisodeMediaInputs
        let sources: [SourceID: String]
        let format: FormatRevision
        private let versions: [TimeMapVersion]

        init(episode: Episode, inputs: DerivedInputs) {
            media = EpisodeMediaInputs(episode)
            sources = inputs.sources
            format = inputs.format
            versions = episode.alignment?.maps ?? []
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.media == rhs.media, lhs.sources == rhs.sources, lhs.format == rhs.format else { return false }
            // Value equality merges signed zero and canonically equivalent strings, but the persisted
            // identity does not. Reuse only the same retained immutable snapshot; recreated values miss.
            return lhs.versions.withUnsafeBufferPointer { left in
                rhs.versions.withUnsafeBufferPointer { right in
                    left.count == right.count && left.baseAddress == right.baseAddress
                }
            }
        }
    }

    struct Context: Sendable {
        let map: AlignedTimelineMap
        let revision: MapRevisionReference
        let identity: AcceptedMapIdentity
    }

    private var prepared: (key: Key, context: Context)?
    #if DEBUG
    private(set) var preparationCount = 0
    #endif

    func context(for key: Key) -> Context? {
        guard let prepared, prepared.key == key else { return nil }
        return prepared.context
    }

    func retain(_ context: Context, for key: Key) {
        prepared = (key, context)
        #if DEBUG
        preparationCount += 1
        #endif
    }

    func clear() { prepared = nil }
}
