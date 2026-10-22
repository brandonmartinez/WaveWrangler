import Foundation
import WWCore
import WWTimeMap

struct AlignmentWaveformCache: Sendable {
    struct Tile: Sendable {
        var modelGeneration: UInt64
        var episode: Episode?
        let start: Double
        let duration: Double
        let load: AlignmentWaveformLoad
        let strokes: [SourceID: [AlignmentWaveformStroke]]
        let indices: [SourceID: AlignmentWaveformStrokeIndex]
        let gains: [SourceID: Double]
        let errors: [SourceID: String]
        var reprojected = false
        let id = UUID()

        init(modelGeneration: UInt64, episode: Episode?, start: Double, duration: Double,
             load: AlignmentWaveformLoad, strokes: [SourceID: [AlignmentWaveformStroke]],
             gains: [SourceID: Double], errors: [SourceID: String],
             indices: [SourceID: AlignmentWaveformStrokeIndex]? = nil, reprojected: Bool = false) {
            self.modelGeneration = modelGeneration
            self.episode = episode
            self.start = start
            self.duration = duration
            self.load = load
            self.strokes = strokes
            self.indices = indices ?? strokes.mapValues { AlignmentWaveformStrokeIndex(strokes: $0) }
            self.gains = gains
            self.errors = errors
            self.reprojected = reprojected
        }
    }

    struct Slice: Identifiable {
        let snapshot: UUID
        let segment: Int
        let start: Double
        let duration: Double
        let range: ClosedRange<Double>
        let strokes: [SourceID: [AlignmentWaveformStroke]]
        let indices: [SourceID: AlignmentWaveformStrokeIndex]
        let gains: [SourceID: Double]

        var id: String { "\(snapshot.uuidString):\(segment)" }
    }

    private(set) var tiles: [Tile] = []
    private(set) var retainedIndices: [SourceID: AlignmentWaveformStrokeIndex] = [:]
    var tracks: [AlignmentWaveformTrack] { tiles.flatMap { $0.load.tracks } }

    mutating func insert(_ tile: Tile) {
        tiles.removeAll {
            $0.modelGeneration != tile.modelGeneration
                || ($0.start == tile.start && $0.duration == tile.duration)
        }
        tiles.append(tile)
        if tiles.count > 8 { tiles.removeFirst() }
        rebuildRetainedIndices()
    }

    mutating func removeAll() {
        tiles.removeAll()
        retainedIndices.removeAll()
    }

    @concurrent
    func inserting(_ tile: Tile) async throws -> Self {
        try Task.checkCancellation()
        var copy = self
        copy.insert(tile)
        try Task.checkCancellation()
        return copy
    }

    mutating func adoptPresentation(of episode: Episode, generation: UInt64) {
        for index in tiles.indices {
            guard let prior = tiles[index].episode,
                  EpisodeMediaInputs(prior) == EpisodeMediaInputs(episode) else { continue }
            tiles[index].episode = episode
            tiles[index].modelGeneration = generation
        }
    }

    func visibleSlices(
        start: Double, duration: Double, generation: UInt64?,
        pendingMove: PendingWaveformMove?, canReuseSamples: Bool
    ) -> [Slice] {
        let slices = AlignmentWaveformProjection.visibleTileSlices(
            start: start, duration: duration,
            tiles: tiles.filter { tile in
                !tile.reprojected && (tile.modelGeneration == generation
                    || generation.map { live in
                        pendingMove?.retainsTile(generation: tile.modelGeneration, liveGeneration: live) == true
                    } == true || canReuseSamples)
            }.map { (id: $0.id, start: $0.start, duration: $0.duration) }
        )
        var segmentCounts: [UUID: Int] = [:]
        return slices.compactMap { slice in
            guard let tile = tiles.first(where: { $0.id == slice.id }) else { return nil }
            let segment = segmentCounts[slice.id, default: 0]
            segmentCounts[slice.id] = segment + 1
            return Slice(
                snapshot: tile.id, segment: segment, start: tile.start, duration: tile.duration,
                range: slice.range, strokes: tile.strokes, indices: tile.indices, gains: tile.gains
            )
        }
    }

    func retainedStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        retainedIndices[source]?.strokes ?? []
    }

    private func makeRetainedStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
        guard tiles.contains(where: \.reprojected) else { return [] }
        let fresh = tiles.filter { !$0.reprojected }.flatMap { tile in
            (tile.strokes[source] ?? []).reduce(into: [RecordingEpochID: ClosedRange<Double>]()) { ranges, stroke in
                let prior = ranges[stroke.epoch] ?? stroke.groupRange
                let lower = min(prior.lowerBound, stroke.groupRange.lowerBound)
                let upper = max(prior.upperBound, stroke.groupRange.upperBound)
                ranges[stroke.epoch] = lower...upper
            }.map { (epoch: $0.key, range: $0.value) }
        }
        return tiles.filter(\.reprojected).flatMap { $0.strokes[source] ?? [] }.filter { stroke in
            !fresh.contains { $0.epoch == stroke.epoch && $0.range.contains(stroke.groupSeconds) }
        }
    }

    private mutating func rebuildRetainedIndices() {
        let sources = Set(tiles.filter(\.reprojected).flatMap { $0.strokes.keys })
        retainedIndices = Dictionary(uniqueKeysWithValues: sources.map { source in
            (source, AlignmentWaveformStrokeIndex(strokes: makeRetainedStrokes(for: source)))
        })
    }

    func firstUncoveredTime(
        start: Double, duration: Double, margin: Double, generation: UInt64?,
        pendingWindow: (start: Double, duration: Double)?
    ) -> Double? {
        var ranges = tiles.filter {
            !$0.reprojected && $0.modelGeneration == generation
        }.map { (id: $0.id, start: $0.start, duration: $0.duration) }
        if let pendingWindow {
            ranges.append((id: UUID(), start: pendingWindow.start, duration: pendingWindow.duration))
        }
        return AlignmentWaveformProjection.firstUncoveredTime(
            start: start, duration: duration, margin: margin, tiles: ranges
        )
    }

    func currentTile(start: Double, duration: Double, generation: UInt64?, snapshot: UUID) -> Tile? {
        let center = start + duration / 2
        return tiles.reversed().first {
            $0.modelGeneration == generation && $0.start <= center && center < $0.start + $0.duration
        } ?? tiles.first(where: {
            $0.modelGeneration == generation && $0.id == snapshot
        }) ?? tiles.last(where: { $0.modelGeneration == generation })
    }

    mutating func reproject(
        map: AlignedTimelineMap?, episode: Episode?, modelGeneration: UInt64,
        revealingCut: UUID? = nil
    ) throws {
        let cuts = try episode?.manualCutTimeline(revealing: revealingCut) ?? .unedited
        tiles = try tiles.map { tile in
            try Task.checkCancellation()
            let projected = try Dictionary(uniqueKeysWithValues: tile.load.tracks.map { track in
                (track.id, try AlignmentWaveformProjection.strokes(
                    track: track, map: map,
                    correction: episode?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == track.id },
                    cuts: cuts
                ))
            })
            return Tile(
                modelGeneration: modelGeneration, episode: episode, start: tile.start, duration: tile.duration,
                load: AlignmentWaveformLoad(
                    tracks: tile.load.tracks, refusals: tile.load.refusals, map: map, mapWarning: nil
                ),
                strokes: projected, gains: tile.gains, errors: [:], reprojected: true
            )
        }
        rebuildRetainedIndices()
    }

    @concurrent
    func reprojected(map: AlignedTimelineMap?, episode: Episode?, modelGeneration: UInt64,
                     revealingCut: UUID?) async throws -> Self {
        var copy = self
        try copy.reproject(map: map, episode: episode, modelGeneration: modelGeneration,
                           revealingCut: revealingCut)
        try Task.checkCancellation()
        return copy
    }
}
