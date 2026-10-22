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
            matchesContext(other)
                && frames.lowerBound <= other.frames.lowerBound && frames.upperBound >= other.frames.upperBound
        }

        func matchesContext(_ other: Key) -> Bool {
            witness == other.witness && interpretation == other.interpretation && map == other.map
                && revision == other.revision && channel == other.channel
                && recipe == other.recipe && rendererVersion == other.rendererVersion
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
            if let stitched = stitchedSamples(for: key) {
                hits += 1
                return stitched
            }
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

    private func stitchedSamples(for key: Key) -> [Float]? {
        let candidates = entries.indices.filter {
            entries[$0].key.matchesContext(key) && entries[$0].key.frames.overlaps(key.frames)
        }
        var cursor = key.frames.lowerBound
        var pieces: [(index: Int, frames: Range<Int64>)] = []
        while cursor < key.frames.upperBound {
            guard let index = candidates.filter({
                entries[$0].key.frames.contains(cursor)
            }).max(by: {
                entries[$0].key.frames.upperBound < entries[$1].key.frames.upperBound
            }) else { return nil }
            let end = min(key.frames.upperBound, entries[index].key.frames.upperBound)
            pieces.append((index, cursor..<end))
            cursor = end
        }
        guard !pieces.isEmpty else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int(key.frames.count))
        for piece in pieces {
            let entry = entries[piece.index]
            let lower = Int(piece.frames.lowerBound - entry.key.frames.lowerBound)
            let upper = Int(piece.frames.upperBound - entry.key.frames.lowerBound)
            samples.append(contentsOf: entry.samples[lower..<upper])
        }
        let used = Set(pieces.map(\.index))
        let retained = entries.indices.filter { !used.contains($0) }.map { entries[$0] }
        entries = retained + pieces.map { entries[$0.index] }
        return samples
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
