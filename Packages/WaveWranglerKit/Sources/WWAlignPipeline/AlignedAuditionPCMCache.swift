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
    private let coordinator: DerivedJobCoordinator?
    private let preparations = SharedAudioWork<Key, [Float]>()
    private var entries: [Entry] = []
    private var sampleBytes = 0
    private var hits = 0
    private var misses = 0

    public init(maximumSampleBytes: Int = 16 << 20, maximumEntries: Int = 64,
                coordinator: DerivedJobCoordinator? = nil) {
        self.maximumSampleBytes = max(0, maximumSampleBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.coordinator = coordinator
    }

    var persistsTiles: Bool { coordinator != nil }

    private struct Context: Encodable {
        let sourceRate: Int
        let sourceFrames: Int64
        let channelCount: Int
        let map: GroupTimeMap
        let recipe: RenderRecipe
    }

    func flattenedSamples(
        sourceURL: URL, source: SourceID, witness: RawSourceIdentity, interpretation: FormatInterpretation,
        decoder: SourceDecoder, map: GroupTimeMap, channel: Int, frames: Range<Int64>,
        revision: MapRevisionReference?
    ) async throws -> [Float] {
        guard let coordinator, await coordinator.isShutdown == false else {
            throw AlignmentAcceptanceError.coordinatorShutDown
        }
        let inputs = await coordinator.inputs
        guard let token = inputs.sources[source], inputs.format == .current else {
            throw DecodeFailure.sourceIdentityMismatch
        }
        if let revision, inputs.acceptedMaps[revision.episode] != revision.revision {
            throw AlignmentWorkFailure.acceptedMapChanged
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let context = Context(sourceRate: interpretation.sourceSampleRate,
            sourceFrames: interpretation.frames.validFrames, channelCount: interpretation.channelCount,
            map: map, recipe: .m2Candidate)
        // The coordinator owns canonical key hashing; this is timing/format metadata, never media bytes.
        let contextKey = try encoder.encode(context).base64EncodedString()
        let tileLength: Int64 = 5 * Int64(AlignedAuditionWindowReader.outputRate)
        let asset = AssetSpec(kind: "ww.aligned-listening-pcm", revision: 1)
        await coordinator.setAssetRevision(asset)
        var output: [Float] = []
        output.reserveCapacity(frames.count)
        for index in GroupRenderJob.floorDiv(frames.lowerBound, tileLength)...GroupRenderJob.floorDiv(frames.upperBound - 1, tileLength) {
            try Task.checkCancellation()
            let tileFrames = (index * tileLength)..<((index + 1) * tileLength)
            let memoryKey = Key(witness: witness, interpretation: interpretation, map: map,
                revision: revision, channel: channel, frames: tileFrames)
            let samples: [Float]
            if let cached = self.samples(for: memoryKey) {
                samples = cached
            } else {
                let recipe = RecipeReference(name: "ww.aligned-listening-pcm;\(contextKey);tile=\(index)",
                    revision: RenderVersions.renderer)
                let key = DerivedAssetKey(asset: asset, sources: [SourceRevision(source: source, token: token)],
                    format: .current, channel: channel, map: revision, recipe: recipe)
                let slot = DerivedSlot("aligned-listening/\(source)/\(channel)/\(index)")
                await coordinator.setRecipe(recipe)
                samples = try await preparations.value(for: memoryKey) {
                    let result = await coordinator.run(slot, key: key) { () throws(AlignmentWorkFailure) -> Data in
                        do {
                            let samples = try await AlignedAuditionWindowReader.readWindow(
                                sourceURL: sourceURL, source: source, matching: witness, decoder: decoder,
                                groupMap: map, decodedChannel: channel, outputFrames: tileFrames)
                            return try ListeningPCM(firstFrame: tileFrames.lowerBound,
                                sampleRate: AlignedAuditionWindowReader.outputRate, channels: [samples]).encode()
                        } catch { throw workFailure(error) }
                    }
                    try Task.checkCancellation()
                    guard result.isAvailable, await coordinator.staleReasons(for: key).isEmpty,
                          let bytes = await coordinator.readyPayload(for: slot, matching: key) else {
                        throw result.typedFailure ?? AlignmentWorkFailure.encoding("Aligned listening PCM became stale or unavailable.")
                    }
                    let pcm = try ListeningPCM.decode(bytes)
                    guard pcm.firstFrame == tileFrames.lowerBound,
                          pcm.sampleRate == AlignedAuditionWindowReader.outputRate,
                          pcm.channels.count == 1, pcm.channels[0].count == tileFrames.count else {
                        throw ListeningPCM.Failure.invalidPayload
                    }
                    return pcm.channels[0]
                }
                insert(samples, for: memoryKey)
            }
            let lower = max(frames.lowerBound, tileFrames.lowerBound)
            let upper = min(frames.upperBound, tileFrames.upperBound)
            output.append(contentsOf: samples[Int(lower - tileFrames.lowerBound)..<Int(upper - tileFrames.lowerBound)])
        }
        try Task.checkCancellation()
        return output
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
