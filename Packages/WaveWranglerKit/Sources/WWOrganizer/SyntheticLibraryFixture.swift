import Foundation
import WWCore

/// Synthetic, in-memory library fixtures (F-EMPTY, F-LIB100). No files, no user media, no paths.
public enum SyntheticLibraryFixture {
    public struct Output: Sendable {
        public var library: LibraryModel
        public var details: [ShowID: LibraryEntryDetails]
        public var sourceReferenceCount: Int
    }

    /// F-LIB100: `shows` shows carrying `sourceReferences` source references in total, `collections`
    /// collections and three unavailable entries (not found, needs permission, newer format; the newer-format
    /// entry's episode count is unknown).
    public static func make(
        shows: Int = 100,
        sourceReferences: Int = 1_000,
        episodesPerShow: Int = 5,
        collections: Int = 5,
        seed: UInt64 = 0x5EED
    ) -> Output {
        var generator = SplitMix64(seed: seed)
        var entries: [LibraryShowEntry] = []
        var details: [ShowID: LibraryEntryDetails] = [:]
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let unavailableStates: [LibraryEntryState] = [.notFound(folderDisplayName: "Synthetic Folder"), .needsPermission, .newerFormat]
        let locations = ["iCloud Drive › Podcasts", "OneDrive › Shows", "Dropbox › Audio", "This Mac › Documents"]
        var remainingRefs = sourceReferences
        for index in 0..<shows {
            let showID = ShowID(UUID(uuid: uuidBytes(&generator)))
            let title = String(format: "Synthetic Show %03d", index + 1)
            entries.append(LibraryShowEntry(showID: showID, lastKnownTitle: title))
            let showsLeft = shows - index
            let refs = remainingRefs / showsLeft
            remainingRefs -= refs
            let episodes = (0..<episodesPerShow).map { number in
                EpisodeSummary(id: EpisodeID(UUID(uuid: uuidBytes(&generator))), number: number + 1, title: "Synthetic Episode \(number + 1)")
            }
            let state: LibraryEntryState = index < unavailableStates.count ? unavailableStates[index] : .available
            details[showID] = LibraryEntryDetails(
                state: state,
                locationDisplayName: locations[index % locations.count],
                lastOpened: base.addingTimeInterval(Double(index) * 3_600),
                // A show saved by a newer WaveWrangler can't be read, so its episode count is unknown ("—").
                // The episode IDs are still generated so every other fixture ID stays the same.
                episodes: state == .newerFormat ? nil : episodes,
                sourceReferenceCount: refs
            )
        }
        let collectionModels = (0..<collections).map { number in
            let members = stride(from: number, to: entries.count, by: max(collections, 1)).prefix(20).map { entries[$0].showID }
            return LibraryCollection(id: CollectionID(UUID(uuid: uuidBytes(&generator))), name: "Synthetic Collection \(number + 1)", showIDs: Array(members))
        }
        let recents = entries.suffix(10).reversed().map(\.showID)
        let library = LibraryModel(entries: entries, collections: collectionModels, recentShowIDs: Array(recents))
        return Output(library: library, details: details, sourceReferenceCount: sourceReferences)
    }

    private static func uuidBytes(_ generator: inout SplitMix64) -> uuid_t {
        let a = generator.next()
        let b = generator.next()
        func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: value >> shift) }
        return (
            byte(a, 0), byte(a, 8), byte(a, 16), byte(a, 24), byte(a, 32), byte(a, 40), (byte(a, 48) & 0x0F) | 0x40, byte(a, 56),
            (byte(b, 0) & 0x3F) | 0x80, byte(b, 8), byte(b, 16), byte(b, 24), byte(b, 32), byte(b, 40), byte(b, 48), byte(b, 56)
        )
    }
}

/// Deterministic generator so fixtures are stable across runs.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
