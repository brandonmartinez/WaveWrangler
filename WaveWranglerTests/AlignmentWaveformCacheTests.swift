import Foundation
import Testing
import WWAlignPipeline
import WWCore

@Suite("Alignment waveform cache ownership")
struct AlignmentWaveformCacheTests {
    @Test func cacheIsBoundedReplacesMatchingWindowsAndDiscardsOldGenerations() {
        var cache = AlignmentWaveformCache()
        for start in 0..<9 { cache.insert(tile(start: Double(start))) }
        #expect(cache.tiles.count == 8)
        #expect(cache.tiles.map(\.start) == (1..<9).map(Double.init))
        let replacement = tile(start: 4)
        cache.insert(replacement)
        #expect(cache.tiles.count == 8)
        #expect(cache.tiles.last?.id == replacement.id)
        cache.insert(tile(start: 0, generation: 2))
        #expect(cache.tiles.count == 1)
        #expect(cache.tiles.first?.modelGeneration == 2)
        cache.removeAll()
        #expect(cache.tiles.isEmpty)
        #expect(cache.retainedIndices.isEmpty)
    }

    @Test func staleSamplesNeedExplicitRetentionAndDoNotCountAsFreshCoverage() {
        var cache = AlignmentWaveformCache()
        cache.insert(tile(start: 0))
        let move = PendingWaveformMove(
            group: RecorderGroupID(), milliseconds: 100, priorGeneration: 1, expectedGeneration: 2
        )
        #expect(cache.visibleSlices(start: 0, duration: 1, generation: 2,
                                    pendingMove: nil, canReuseSamples: false).isEmpty)
        #expect(!cache.visibleSlices(start: 0, duration: 1, generation: 2,
                                     pendingMove: move, canReuseSamples: false).isEmpty)
        #expect(cache.visibleSlices(start: 0, duration: 1, generation: 3,
                                    pendingMove: move, canReuseSamples: false).isEmpty)
        #expect(!cache.visibleSlices(start: 0, duration: 1, generation: 3,
                                     pendingMove: nil, canReuseSamples: true).isEmpty)
        #expect(cache.firstUncoveredTime(start: 0, duration: 1, margin: 0, generation: 2, pendingWindow: nil) == 0)
        #expect(cache.firstUncoveredTime(start: 0, duration: 1, margin: 0, generation: 2,
                                         pendingWindow: (0, 1)) == nil)
        #expect(cache.currentTile(start: 0, duration: 1, generation: 2, snapshot: cache.tiles[0].id) == nil)
    }

    @Test func presentationChangesAdoptGenerationWithoutReprojectionOrNewSamples() {
        let episode = Episode(title: "Synthetic")
        var cache = AlignmentWaveformCache()
        var initial = tile(start: 0)
        initial.episode = episode
        cache.insert(initial)
        var renamed = episode
        renamed.title = "New title"
        cache.adoptPresentation(of: renamed, generation: 2)
        #expect(cache.tiles[0].id == initial.id)
        #expect(cache.tiles[0].modelGeneration == 2)
        #expect(!cache.tiles[0].reprojected)
        #expect(cache.firstUncoveredTime(start: 0, duration: 1, margin: 0, generation: 2, pendingWindow: nil) == nil)
        renamed.sources.append(SourceRecord(displayNameHint: "A real new input"))
        cache.adoptPresentation(of: renamed, generation: 3)
        #expect(cache.tiles[0].modelGeneration == 2)
        #expect(cache.firstUncoveredTime(start: 0, duration: 1, margin: 0, generation: 3, pendingWindow: nil) == 0)
    }

    @Test func reprojectionRetainsDecodedBinsAndFreshWindowsReplaceOnlyCoveredStrokes() throws {
        var cache = AlignmentWaveformCache()
        let source = SourceID(), epoch = RecordingEpochID(), group = RecorderGroupID()
        func track(_ frames: [Int64]) -> AlignmentWaveformTrack {
            AlignmentWaveformTrack(group: group, epoch: epoch, name: "Synthetic", groupName: "Recorder",
                envelope: WaveformEnvelope(source: source, sampleRate: 1000, channelCount: 1, totalFrames: 3000,
                    bins: frames.map {
                        WaveformBin(firstFrame: $0, endFrame: $0 + 1000, minimum: -0.5, maximum: 0.5)
                    }))
        }
        let original = track([0, 1000, 2000])
        let originalStrokes = try AlignmentWaveformProjection.strokes(track: original, map: nil)
        let address = original.envelope.bins.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        cache.insert(AlignmentWaveformCache.Tile(
            modelGeneration: 1, episode: nil, start: 0, duration: 3,
            load: AlignmentWaveformLoad(tracks: [original], refusals: [], map: nil, mapWarning: nil),
            strokes: [source: originalStrokes],
            gains: [source: 1], errors: [:]
        ))
        try cache.reproject(map: nil, episode: nil, modelGeneration: 2)
        #expect(cache.tiles[0].reprojected)
        #expect(cache.tracks[0].envelope.bins.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } == address)
        #expect(cache.retainedStrokes(for: source).count == 3)
        let retainedID = cache.retainedIndices[source]?.id
        #expect(cache.retainedIndices[source]?.visible(start: 0.25, duration: 0.5) == [originalStrokes[0]])
        #expect(cache.visibleSlices(start: 0, duration: 3, generation: 2,
                                    pendingMove: nil, canReuseSamples: true).isEmpty)
        let fresh = track([1000])
        cache.insert(AlignmentWaveformCache.Tile(
            modelGeneration: 2, episode: nil, start: 1, duration: 1,
            load: AlignmentWaveformLoad(tracks: [fresh], refusals: [], map: nil, mapWarning: nil),
            strokes: [source: try AlignmentWaveformProjection.strokes(track: fresh, map: nil)],
            gains: [source: 1], errors: [:]
        ))
        #expect(cache.retainedStrokes(for: source) == [originalStrokes[0], originalStrokes[2]])
        #expect(cache.retainedIndices[source]?.id != retainedID)
        #expect(cache.retainedIndices[source]?.strokes == cache.retainedStrokes(for: source))
        let slice = cache.visibleSlices(start: 1.1, duration: 0.5, generation: 2,
            pendingMove: nil, canReuseSamples: false).first
        #expect(slice?.indices[source]?.id == cache.tiles.last?.indices[source]?.id)
        try cache.reproject(map: nil, episode: nil, modelGeneration: 3)
        #expect(cache.retainedIndices[source]?.id != retainedID)
        #expect(cache.retainedIndices[source]?.strokes == cache.retainedStrokes(for: source))
        cache.removeAll()
        #expect(cache.retainedIndices.isEmpty)
    }

    private func tile(start: Double, generation: UInt64 = 1) -> AlignmentWaveformCache.Tile {
        AlignmentWaveformCache.Tile(
            modelGeneration: generation, episode: nil, start: start, duration: 1,
            load: AlignmentWaveformLoad(tracks: [], refusals: [], map: nil, mapWarning: nil),
            strokes: [:], gains: [:], errors: [:]
        )
    }
}
