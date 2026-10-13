import Foundation
import WWAlignPipeline
import WWCore
import WWTimeMap

struct AlignmentWaveformTrack: Identifiable, Sendable {
    var id: SourceID { envelope.source }
    let group: RecorderGroupID
    let epoch: RecordingEpochID
    let name: String
    let groupName: String
    let envelope: WaveformEnvelope
}

struct AlignmentWaveformRefusal: Identifiable, Sendable {
    let id: SourceID
    let name: String
    let reason: String
}

struct AlignmentWaveformLoad: Sendable {
    let tracks: [AlignmentWaveformTrack]
    let refusals: [AlignmentWaveformRefusal]
    let map: AlignedTimelineMap?
    let mapWarning: String?
}

struct AlignmentWaveformPosition: Equatable {
    let sourceSeconds: Double
    let groupSeconds: Double
    let displaySeconds: Double
    let epoch: RecordingEpochID
    let mapped: Bool
}

struct AlignmentWaveformStroke: Equatable {
    let sourceSeconds: Double
    let groupSeconds: Double
    let displaySeconds: Double
    let low: Float
    let high: Float
    let mapped: Bool
    let epoch: RecordingEpochID
    let displayRange: ClosedRange<Double>
    let groupRange: ClosedRange<Double>
}

struct AlignmentWaveformDrag {
    let startX: Double
    let width: Double
    let durationSeconds: Double
    let initialMilliseconds: Double
    let group: RecorderGroupID
    let snapshot: UUID

    func previewMilliseconds(at x: Double) -> Double? {
        guard startX.isFinite, x.isFinite, width.isFinite, width > 0,
              durationSeconds.isFinite, durationSeconds > 0,
              initialMilliseconds.isFinite
        else { return nil }
        let preview = initialMilliseconds + (x - startX) / width * durationSeconds * 1_000
        return preview.isFinite ? preview : nil
    }
}

struct PendingWaveformMove {
    let group: RecorderGroupID
    let milliseconds: Double
    let priorGeneration: UInt64
    let expectedGeneration: UInt64

    func retainsTile(generation: UInt64, liveGeneration: UInt64) -> Bool {
        generation == priorGeneration && liveGeneration == expectedGeneration
    }

    func displayShift(for group: RecorderGroupID) -> Double {
        self.group == group ? milliseconds : 0
    }
}

enum AlignmentWaveformProjection {
    static let overviewNavigationRange = 0.0...86_400.0

    static func zoomDuration(for level: Double) -> Double? {
        guard level.isFinite, (0...1).contains(level) else { return nil }
        return 30 * pow(1.0 / 60, level)
    }

    static func zoomLevel(for duration: Double) -> Double? {
        guard duration.isFinite, (0.5...30).contains(duration) else { return nil }
        return log(30 / duration) / log(60)
    }

    struct TileSlice: Equatable {
        let id: UUID
        let range: ClosedRange<Double>
    }

    static func visibleTileSlices(
        start: Double, duration: Double, tiles: [(id: UUID, start: Double, duration: Double)]
    ) -> [TileSlice] {
        guard start.isFinite, duration.isFinite, duration > 0 else { return [] }
        let end = start + duration
        guard end.isFinite else { return [] }
        let valid = tiles.filter { $0.start.isFinite && $0.duration.isFinite && $0.duration > 0 }
        let boundaries = ([start, end] + valid.flatMap { tile in
            [max(start, min(end, tile.start)), max(start, min(end, tile.start + tile.duration))]
        }).sorted()
        var result: [TileSlice] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) {
            guard upper > lower + 0.000_001 else { continue }
            let midpoint = (lower + upper) / 2
            guard let tile = valid.last(where: {
                $0.start <= midpoint && midpoint < $0.start + $0.duration
            }) else { continue }
            if let last = result.last, last.id == tile.id, last.range.upperBound == lower {
                result[result.count - 1] = TileSlice(id: tile.id, range: last.range.lowerBound...upper)
            } else {
                result.append(TileSlice(id: tile.id, range: lower...upper))
            }
        }
        return result
    }

    static func firstUncoveredTime(
        start: Double, duration: Double, margin: Double = 0,
        tiles: [(id: UUID, start: Double, duration: Double)]
    ) -> Double? {
        guard margin.isFinite, margin >= 0 else { return nil }
        let lower = max(0, start - margin)
        let upper = start + duration + margin
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        let slices = visibleTileSlices(start: lower, duration: upper - lower, tiles: tiles)
        var coveredUntil = lower
        for slice in slices {
            if slice.range.lowerBound > coveredUntil + 0.000_001 { break }
            coveredUntil = max(coveredUntil, slice.range.upperBound)
        }
        return coveredUntil < upper - 0.000_001 ? coveredUntil : nil
    }

    static func tileWindow(start: Double, visible: Double) -> (start: Double, duration: Double)? {
        guard start.isFinite, overviewNavigationRange.contains(start),
              visible.isFinite, visible > 0, visible <= 30 else { return nil }
        let duration = min(30, visible * 3)
        return (max(0, start - (duration - visible) / 2), duration)
    }

    static func tileTranslation(tileStart: Double, windowStart: Double, visible: Double, width: Double) -> Double? {
        guard tileStart.isFinite, windowStart.isFinite, visible.isFinite, visible > 0,
              width.isFinite, width > 0 else { return nil }
        let translation = (tileStart - windowStart) / visible * width
        return translation.isFinite ? translation : nil
    }

    static func tileClip(
        range: ClosedRange<Double>, tileStart: Double, tileDuration: Double, tileWidth: Double
    ) -> (origin: Double, width: Double)? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              tileStart.isFinite, tileDuration.isFinite, tileDuration > 0,
              tileWidth.isFinite, tileWidth > 0,
              range.lowerBound >= tileStart, range.upperBound <= tileStart + tileDuration,
              range.upperBound > range.lowerBound
        else { return nil }
        return ((range.lowerBound - tileStart) / tileDuration * tileWidth,
                (range.upperBound - range.lowerBound) / tileDuration * tileWidth)
    }

    static func moveMicroseconds(fromMilliseconds value: Double) -> Int64? {
        guard value.isFinite, abs(value) < Double(Int64.max) / 1_000 else { return nil }
        return Int64((value * 1_000).rounded())
    }

    static func timelineEnd(map: AlignedTimelineMap) -> Double {
        map.groups.flatMap { group in
            let placed = Set(group.placements.flatMap { $0.spans.map(\.epoch) })
            return group.epochs.filter { placed.contains($0.epoch) }.flatMap { epoch -> [Double] in
                guard case let .mapped(segments, _) = epoch.mapping else { return [] }
                return segments.compactMap {
                    try? $0.rateRatio.multiplied(by: $0.groupClockEnd)
                        .adding($0.alignedOffset).approximateDouble
                }
            }
        }.filter(\.isFinite).max() ?? 0
    }

    static func sourceTimelineEnd(durations: [(frames: Int64, rate: Int)]) -> Double {
        durations.compactMap { source in
            guard source.frames >= 0, source.rate > 0 else { return nil }
            return Double(source.frames) / Double(source.rate)
        }.filter(\.isFinite).max() ?? 0
    }

    static func displayGain(for strokes: [AlignmentWaveformStroke], normalized: Bool) -> Double {
        guard normalized else { return 1 }
        let peak = strokes.reduce(0.0) { max($0, abs(Double($1.low)), abs(Double($1.high))) }
        return peak.isFinite && peak > 0 && peak < 1 ? 1 / peak : 1
    }

    static func overviewExtent(_ strokes: [AlignmentWaveformStroke]) -> ClosedRange<Double>? {
        guard let first = strokes.map(\.displayRange.lowerBound).min(),
              let last = strokes.map(\.displayRange.upperBound).max(),
              first.isFinite, last.isFinite, first < last
        else { return nil }
        return first...last
    }

    static func windowStart(centeredAt time: Double, duration: Double) -> Double? {
        guard time.isFinite, overviewNavigationRange.contains(time),
              duration.isFinite, duration > 0, duration <= 30
        else { return nil }
        return max(0, time - duration / 2)
    }

    static func unavailableOverviewRanges(in extent: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        if extent.lowerBound < overviewNavigationRange.lowerBound {
            ranges.append(extent.lowerBound...min(extent.upperBound, overviewNavigationRange.lowerBound))
        }
        if extent.upperBound > overviewNavigationRange.upperBound {
            ranges.append(max(extent.lowerBound, overviewNavigationRange.upperBound)...extent.upperBound)
        }
        return ranges
    }

    static func overviewWindowStart(
        at time: Double, duration: Double, strokes: [AlignmentWaveformStroke]
    ) -> Double? {
        guard let start = windowStart(centeredAt: time, duration: duration),
              selectedStroke(
                at: time, strokes: strokes, draftEpoch: nil, ratePPM: 0, offsetMilliseconds: 0
              ) != nil
        else { return nil }
        return start
    }

    static func containsSelectedEpoch(
        source: SourceID, group: RecorderGroupID, initialEpoch: RecordingEpochID,
        selectedEpoch: RecordingEpochID, map: AlignedTimelineMap?
    ) -> Bool {
        guard let map else { return initialEpoch == selectedEpoch }
        return map.groups.first(where: { $0.group == group })?
            .placements.first(where: { $0.occurrence.source == source })?
            .spans.contains(where: { $0.epoch == selectedEpoch }) == true
    }

    static func strokes(track: AlignmentWaveformTrack, map: AlignedTimelineMap?) throws -> [AlignmentWaveformStroke] {
        try track.envelope.bins.compactMap { bin in
            guard let first = try position(frame: bin.firstFrame, track: track, map: map),
                  let last = try position(frame: bin.endFrame - 1, track: track, map: map),
                  first.epoch == last.epoch, first.mapped == last.mapped
            else { return nil }
            return AlignmentWaveformStroke(
                sourceSeconds: (first.sourceSeconds + last.sourceSeconds) / 2,
                groupSeconds: (first.groupSeconds + last.groupSeconds) / 2,
                displaySeconds: (first.displaySeconds + last.displaySeconds) / 2,
                low: bin.minimum, high: bin.maximum, mapped: first.mapped, epoch: first.epoch,
                displayRange: first.displaySeconds...last.displaySeconds,
                groupRange: first.groupSeconds...last.groupSeconds
            )
        }
    }

    static func position(
        frame: Int64, track: AlignmentWaveformTrack, map: AlignedTimelineMap?
    ) throws -> AlignmentWaveformPosition? {
        let source = Double(frame) / Double(track.envelope.sampleRate)
        guard let map else {
            return AlignmentWaveformPosition(
                sourceSeconds: source, groupSeconds: source,
                displaySeconds: source, epoch: track.epoch, mapped: false
            )
        }
        guard let group = map.groups.first(where: { $0.group == track.group }),
              let placement = group.placements.first(where: { $0.occurrence.source == track.id })
        else { return nil }
        let groupSeconds = source + (placement.spans.first(where: {
            $0.startFrame <= frame && frame < $0.endFrame
        })?.groupClockOffset.approximateDouble ?? 0)
        switch try map.alignedTime(ofFrame: frame, in: placement.occurrence.id) {
        case let .aligned(position):
            return AlignmentWaveformPosition(
                sourceSeconds: source, groupSeconds: groupSeconds,
                displaySeconds: position.instant.approximateDouble,
                epoch: position.epoch, mapped: true
            )
        case let .unsupported(epoch, _):
            return AlignmentWaveformPosition(
                sourceSeconds: source, groupSeconds: groupSeconds,
                displaySeconds: source, epoch: epoch, mapped: false
            )
        case .gap, .outsideCoverage:
            return nil
        }
    }

    static func selectedStroke(
        at time: Double, strokes: [AlignmentWaveformStroke],
        draftEpoch: RecordingEpochID?, ratePPM: Double, offsetMilliseconds: Double
    ) -> AlignmentWaveformStroke? {
        guard time.isFinite else { return nil }
        let candidates = strokes.filter { stroke in
            guard stroke.epoch == draftEpoch else { return stroke.displayRange.contains(time) }
            let ratio = 1 + ratePPM / 1_000_000
            let offset = offsetMilliseconds / 1_000
            guard ratio.isFinite, ratio > 0, offset.isFinite else { return false }
            return time >= stroke.groupRange.lowerBound * ratio + offset
                && time <= stroke.groupRange.upperBound * ratio + offset
        }
        guard Set(candidates.map(\.epoch)).count == 1 else { return nil }
        return candidates.first
    }

}
