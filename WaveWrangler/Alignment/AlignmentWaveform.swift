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

enum AlignmentWaveformProjection {
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
