import Foundation
import WWCore
import WWDecode
import WWDerived
import WWRender
import WWSources
import WWTimeMap

/// Ephemeral listening PCM only; a hit is never source-access or accepted-map authorization.
public actor AlignedAuditionPCMCache {
    struct Key: Sendable, Equatable {
        let witness: RawSourceIdentity
        let interpretation: FormatInterpretation
        let map: GroupTimeMap
        let revision: MapRevisionReference?
        let channel: Int
        let frames: Range<Int64>
        let recipe = RenderRecipe.m2Candidate
        let rendererVersion = RenderVersions.renderer

        func contains(_ other: Key) -> Bool {
            witness == other.witness && interpretation == other.interpretation && map == other.map
                && revision == other.revision && channel == other.channel
                && recipe == other.recipe && rendererVersion == other.rendererVersion
                && frames.lowerBound <= other.frames.lowerBound && frames.upperBound >= other.frames.upperBound
        }
    }

    public struct Statistics: Sendable {
        public let hits: Int
        public let misses: Int
        public let entries: Int
        public let sampleBytes: Int
    }

    private struct Entry {
        let key: Key
        let samples: [Float]
    }

    private let maximumSampleBytes: Int
    private let maximumEntries: Int
    private var entries: [Entry] = []
    private var sampleBytes = 0
    private var hits = 0
    private var misses = 0

    public init(maximumSampleBytes: Int = 16 << 20, maximumEntries: Int = 64) {
        self.maximumSampleBytes = max(0, maximumSampleBytes)
        self.maximumEntries = max(0, maximumEntries)
    }

    public var statistics: Statistics {
        Statistics(hits: hits, misses: misses, entries: entries.count, sampleBytes: sampleBytes)
    }

    func samples(for key: Key) -> [Float]? {
        guard let index = entries.firstIndex(where: { $0.key.contains(key) }) else {
            misses += 1
            return nil
        }
        let entry = entries[index]
        entries.removeSubrange(index...index)
        entries.append(entry)
        hits += 1
        if entry.key.frames == key.frames { return entry.samples }
        let lower = Int(key.frames.lowerBound - entry.key.frames.lowerBound)
        let upper = Int(key.frames.upperBound - entry.key.frames.lowerBound)
        return Array(entry.samples[lower..<upper])
    }

    func insert(_ samples: [Float], for key: Key) {
        let bytes = samples.count * MemoryLayout<Float>.stride
        guard maximumEntries > 0, bytes <= maximumSampleBytes else { return }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            sampleBytes -= entries[index].samples.count * MemoryLayout<Float>.stride
            entries.removeSubrange(index...index)
        }
        while !entries.isEmpty,
              entries.count >= maximumEntries || sampleBytes + bytes > maximumSampleBytes {
            sampleBytes -= entries.removeFirst().samples.count * MemoryLayout<Float>.stride
        }
        entries.append(Entry(key: key, samples: samples))
        sampleBytes += bytes
    }
}
