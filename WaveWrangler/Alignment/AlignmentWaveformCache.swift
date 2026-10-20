import Foundation
import WWCore
import WWTimeMap

struct AlignmentWaveformCache {
    struct Tile {
        var modelGeneration: UInt64
        var episode: Episode?
        let start: Double
        let duration: Double
        let load: AlignmentWaveformLoad
        let strokes: [SourceID: [AlignmentWaveformStroke]]
        let gains: [SourceID: Double]
        let errors: [SourceID: String]
        var reprojected = false
        let id = UUID()
    }

    struct Slice: Identifiable {
        let snapshot: UUID
        let segment: Int
        let start: Double
        let duration: Double
        let range: ClosedRange<Double>
        let strokes: [SourceID: [AlignmentWaveformStroke]]
        let gains: [SourceID: Double]

        var id: String { "\(snapshot.uuidString):\(segment)" }
    }

    private(set) var tiles: [Tile] = []
    var tracks: [AlignmentWaveformTrack] { tiles.flatMap { $0.load.tracks } }

    mutating func insert(_ tile: Tile) {
        tiles.removeAll {
            $0.modelGeneration != tile.modelGeneration
                || ($0.start == tile.start && $0.duration == tile.duration)
        }
        tiles.append(tile)
        if tiles.count > 8 { tiles.removeFirst() }
    }

    mutating func removeAll() { tiles.removeAll() }

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
                range: slice.range, strokes: tile.strokes, gains: tile.gains
            )
        }
    }

    func retainedStrokes(for source: SourceID) -> [AlignmentWaveformStroke] {
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
        map: AlignedTimelineMap?, episode: Episode?, modelGeneration: UInt64
    ) throws {
        tiles = try tiles.map { tile in
            let projected = try Dictionary(uniqueKeysWithValues: tile.load.tracks.map { track in
                (track.id, try AlignmentWaveformProjection.strokes(
                    track: track, map: map,
                    correction: episode?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == track.id }
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
    }
}
