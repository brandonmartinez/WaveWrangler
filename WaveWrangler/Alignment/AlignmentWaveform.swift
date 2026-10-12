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

enum AlignmentWaveformProjection {
    static let overviewNavigationRange = 0.0...86_400.0

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
