import Foundation
import WWDecode
import WWDerived
import WWSources

/// Decoded canonical tiles, not authorization. Every hit still requires a current map and source witness.
actor AdaptiveAudioPCMCache {
    struct Key: Sendable, Equatable {
        let asset: DerivedAssetKey
        let witness: RawSourceIdentity
    }

    struct Statistics: Sendable {
        let hits: Int
        let misses: Int
        let entries: Int
        let sampleBytes: Int
    }

    private struct Entry {
        let key: Key
        let tile: AdaptivePCM
        let bytes: Int
    }

    private let maximumSampleBytes: Int
    private let maximumEntries: Int
    private var entries: [Entry] = []
    private var sampleBytes = 0
    private var hits = 0
    private var misses = 0

    init(maximumSampleBytes: Int = 64 << 20, maximumEntries: Int = 16) {
        self.maximumSampleBytes = max(0, maximumSampleBytes)
        self.maximumEntries = max(0, maximumEntries)
    }

    var statistics: Statistics {
        Statistics(hits: hits, misses: misses, entries: entries.count, sampleBytes: sampleBytes)
    }

    func tile(for key: Key) -> AdaptivePCM? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            misses += 1
            return nil
        }
        let entry = entries.remove(at: index)
        entries.append(entry)
        hits += 1
        return entry.tile
    }

    func insert(_ tile: AdaptivePCM, for key: Key) {
        let bytes = tile.channels.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
        guard maximumEntries > 0, bytes <= maximumSampleBytes else { return }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            sampleBytes -= entries.remove(at: index).bytes
        }
        while !entries.isEmpty, entries.count >= maximumEntries || sampleBytes + bytes > maximumSampleBytes {
            sampleBytes -= entries.removeFirst().bytes
        }
        entries.append(Entry(key: key, tile: tile, bytes: bytes))
        sampleBytes += bytes
    }

    func removeAll() {
        entries.removeAll()
        sampleBytes = 0
    }
}
