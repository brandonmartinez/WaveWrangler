import Foundation
import WWAlignPipeline
import WWCore
import WWSources
import WWTimeMap

enum AlignmentWaveformLayout: String, CaseIterable, Codable {
    case speaker = "By speaker"
    case speakersOnly = "Speakers only"
    case recorderGroup = "By recorder"
    case overlay = "Overlay"

    static let defaultValue: Self = .speaker
}

struct AlignmentWaveformTrack: Identifiable, Sendable {
    var id: SourceID { envelope.source }
    let group: RecorderGroupID
    let epoch: RecordingEpochID
    let name: String
    let groupName: String
    let envelope: WaveformEnvelope
    let sourceIdentity: RawSourceIdentity?

    init(
        group: RecorderGroupID, epoch: RecordingEpochID, name: String, groupName: String,
        envelope: WaveformEnvelope, sourceIdentity: RawSourceIdentity? = nil
    ) {
        self.group = group
        self.epoch = epoch
        self.name = name
        self.groupName = groupName
        self.envelope = envelope
        self.sourceIdentity = sourceIdentity
    }
}

struct AlignmentWaveformSpeakerGroup: Identifiable {
    let id: SpeakerID?
    let tracks: [AlignmentWaveformTrack]
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

struct AlignmentWaveformStroke: Equatable, Sendable {
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

enum AlignmentTransportSelection {
    static func enabledSources(
        tracks: [AlignmentWaveformTrack], disabledGroups: Set<RecorderGroupID>,
        disabledTracks: Set<SourceID>
    ) -> [SourceID] {
        tracks.filter { !disabledGroups.contains($0.group) && !disabledTracks.contains($0.id) }
            .map(\.id)
    }

    static func gains(prepared: Set<SourceID>, enabled: [SourceID]) -> [SourceID: Float] {
        let audible = prepared.intersection(enabled)
        let level = 1 / Float(max(audible.count, 1))
        return Dictionary(uniqueKeysWithValues: prepared.map { source in
            (source, audible.contains(source) ? level : 0)
        })
    }
}

enum AlignmentWaveformProjection {
    struct ProposalInput: Sendable, Equatable {
        let source: SourceID
        let tilesVersion: UUID
        let overviewVersion: UUID
        let modelGeneration: UInt64?
        let tracks: [AlignmentWaveformTrack]
        let map: AlignedTimelineMap?
        let adaptive: AdaptiveAnalysisRecord?
        let group: RecorderGroupID?
        let epoch: RecordingEpochID?
        let segment: AffineClockSegment?
        let cuts: ManualCutTimeline
        let includeEstimated: Bool

        // Publication IDs cover immutable track/map snapshots without per-frame envelope comparisons.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source == rhs.source && lhs.tilesVersion == rhs.tilesVersion
                && lhs.overviewVersion == rhs.overviewVersion && lhs.modelGeneration == rhs.modelGeneration
                && lhs.adaptive == rhs.adaptive && lhs.group == rhs.group && lhs.epoch == rhs.epoch
                && lhs.segment == rhs.segment && lhs.cuts == rhs.cuts && lhs.includeEstimated == rhs.includeEstimated
        }

        func strokes() -> [AlignmentWaveformStroke] {
            if let adaptive {
                return AlignmentWaveformProjection.applyingCuts(cuts, to: tracks.flatMap {
                    AlignmentWaveformProjection.adaptiveStrokes(
                        track: $0, record: adaptive, includeEstimated: includeEstimated)
                })
            }
            guard let group, let epoch, let segment else { return [] }
            return AlignmentWaveformProjection.applyingCuts(cuts, to: tracks.flatMap {
                AlignmentWaveformProjection.proposedStrokes(
                    track: $0, map: map, targetGroup: group, targetEpoch: epoch, segment: segment)
            })
        }

        @concurrent
        func prepare() async -> AlignmentWaveformStrokeIndex {
            AlignmentWaveformStrokeIndex(strokes: strokes())
        }
    }

    struct Prepared: Sendable {
        var strokes: [SourceID: [AlignmentWaveformStroke]] = [:]
        var indices: [SourceID: AlignmentWaveformStrokeIndex] = [:]
        var gains: [SourceID: Double] = [:]
        var errors: [SourceID: String] = [:]
    }

    @concurrent
    static func prepare(load: AlignmentWaveformLoad, episode: Episode?,
                        cuts: ManualCutTimeline, mappedOnly: Bool = false) async throws -> Prepared {
        var result = Prepared()
        for track in load.tracks {
            try Task.checkCancellation()
            do {
                var projected = try strokes(track: track, map: load.map,
                    correction: episode?.alignment?.acceptedMap?.sourceCorrections?.first { $0.source == track.id },
                    cuts: cuts)
                if mappedOnly { projected.removeAll { !$0.mapped } }
                result.strokes[track.id] = projected
                let index = AlignmentWaveformStrokeIndex(strokes: projected)
                result.indices[track.id] = index
                result.gains[track.id] = index.normalizedGain
            } catch {
                result.errors[track.id] = error.localizedDescription
            }
        }
        try Task.checkCancellation()
        return result
    }

    static let overviewNavigationRange = -86_400.0...86_400.0

    static func steppedZoomDuration(duration: Double, maximum: Double, zoomIn: Bool) -> Double? {
        guard duration.isFinite, maximum.isFinite, duration > 0, maximum >= 0.5 else { return nil }
        return min(maximum, max(0.5, duration * (zoomIn ? 0.8 : 1.25)))
    }

    static func canReuseSamples(from loaded: Episode?, to current: Episode?) -> Bool {
        guard let loaded, let current else { return false }
        var unchangedTiming = current
        unchangedTiming.alignment = loaded.alignment
        return EpisodeMediaInputs(loaded) == EpisodeMediaInputs(unchangedTiming)
    }

    static func proposedStrokes(
        track: AlignmentWaveformTrack, map: AlignedTimelineMap?,
        targetGroup: RecorderGroupID, targetEpoch: RecordingEpochID, segment: AffineClockSegment
    ) -> [AlignmentWaveformStroke] {
        guard track.group == targetGroup else { return [] }
        let placement = map?.groups.first { $0.group == track.group }?
            .placements.first { $0.occurrence.source == track.id }
        let rate = Double(track.envelope.sampleRate)
        return track.envelope.bins.compactMap { bin in
            let span = placement?.spans.first { $0.startFrame <= bin.firstFrame && bin.endFrame <= $0.endFrame }
            guard (span?.epoch ?? track.epoch) == targetEpoch,
                  placement == nil || span != nil else { return nil }
            let offset = span?.groupClockOffset.approximateDouble ?? 0
            let first = max(Double(bin.firstFrame) / rate + offset, segment.groupClockStart.approximateDouble)
            let last = min(Double(bin.endFrame - 1) / rate + offset, segment.groupClockEnd.approximateDouble)
            guard first <= last, first < segment.groupClockEnd.approximateDouble else { return nil }
            let a = segment.rateRatio.approximateDouble, b = segment.alignedOffset.approximateDouble
            return AlignmentWaveformStroke(
                sourceSeconds: (first + last) / 2 - offset, groupSeconds: (first + last) / 2,
                displaySeconds: a * (first + last) / 2 + b, low: bin.minimum, high: bin.maximum,
                mapped: true, epoch: targetEpoch, displayRange: (a * first + b)...(a * last + b),
                groupRange: first...last
            )
        }
    }

    static func speakerGroups(
        tracks: [AlignmentWaveformTrack], speakerForSource: (SourceID) -> SpeakerID?
    ) -> [AlignmentWaveformSpeakerGroup] {
        var groups: [AlignmentWaveformSpeakerGroup] = []
        for track in tracks {
            let speaker = speakerForSource(track.id)
            if let index = groups.firstIndex(where: { $0.id == speaker }) {
                groups[index] = AlignmentWaveformSpeakerGroup(
                    id: speaker, tracks: groups[index].tracks + [track]
                )
            } else {
                groups.append(AlignmentWaveformSpeakerGroup(id: speaker, tracks: [track]))
            }
        }
        return groups
    }

    static func timedSources(in map: AlignedTimelineMap) -> Set<SourceID> {
        Set(map.groups.flatMap { group in
            let mappedEpochs = Set(group.epochs.compactMap { epoch -> RecordingEpochID? in
                if case .mapped = epoch.mapping { return epoch.epoch }
                return nil
            })
            return group.placements.compactMap { placement in
                placement.spans.contains(where: { mappedEpochs.contains($0.epoch) })
                    ? placement.occurrence.source : nil
            }
        })
    }

    static func hasAcceptedTiming(
        source: SourceID, epoch: RecordingEpochID, group: RecorderGroupID, map: AlignedTimelineMap?
    ) -> Bool {
        guard let groupMap = map?.groups.first(where: { $0.group == group }),
              let mapping = groupMap.epochs.first(where: { $0.epoch == epoch })?.mapping,
              case .mapped = mapping
        else { return false }
        return groupMap.placements.contains {
            $0.occurrence.source == source && $0.spans.contains { $0.epoch == epoch }
        }
    }

    struct RulerTick: Identifiable {
        let id: Int
        let time: Double
        let major: Bool
    }

    static func rulerTicks(start: Double, duration: Double, width: Double) -> [RulerTick] {
        guard start.isFinite, duration.isFinite, duration >= 0.5,
              width.isFinite, width > 0 else { return [] }
        let target = duration * 120 / width
        guard target.isFinite, target > 0 else { return [] }
        let magnitude = pow(10, floor(log10(target)))
        let major = ([1.0, 2, 5, 10].first { $0 * magnitude >= target } ?? 10) * magnitude
        let minor = major / 5
        guard minor.isFinite, minor > 0, start / minor < Double(Int.max / 2),
              (start + duration) / minor < Double(Int.max / 2) else { return [] }
        let first = Int(ceil(start / minor - 0.000_001))
        let last = Int(floor((start + duration) / minor + 0.000_001))
        guard last >= first, last - first <= 500 else { return [] }
        return (first...last).map { RulerTick(id: $0, time: Double($0) * minor, major: $0.isMultiple(of: 5)) }
    }

    static func rulerTime(
        at x: Double, width: Double, start: Double, duration: Double, bounds: ClosedRange<Double>
    ) -> Double? {
        guard x.isFinite, width.isFinite, width > 0, start.isFinite,
              duration.isFinite, duration > 0,
              bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              bounds.lowerBound < bounds.upperBound else { return nil }
        return min(bounds.upperBound, max(bounds.lowerBound,
            start + min(width, max(0, x)) / width * duration))
    }

    static func rulerZoom(
        duration: Double, playhead: Double, magnification: Double,
        bounds: ClosedRange<Double>, maximumDuration: Double
    ) -> (start: Double, duration: Double)? {
        guard duration.isFinite, duration > 0, playhead.isFinite,
              magnification.isFinite, magnification > 0,
              bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              bounds.lowerBound < bounds.upperBound, bounds.contains(playhead),
              maximumDuration.isFinite, maximumDuration >= 0.5 else { return nil }
        let span = min(maximumDuration, max(0.5, duration / magnification))
        return (min(max(bounds.lowerBound, bounds.upperBound - span),
                    max(bounds.lowerBound, playhead - span / 2)), span)
    }

    static func rulerPanStart(
        from start: Double, translation: Double, width: Double, duration: Double,
        bounds: ClosedRange<Double>
    ) -> Double? {
        guard start.isFinite, translation.isFinite, width.isFinite, width > 0,
              duration.isFinite, duration > 0,
              bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              bounds.lowerBound < bounds.upperBound else { return nil }
        return min(max(start, bounds.upperBound - duration / 2),
                   max(bounds.lowerBound, start - translation / width * duration))
    }

    struct DisplayColumn: Equatable {
        let x: Double
        let low: Float
        let high: Float
        let mapped: Bool
    }

    enum ScrollAction: Equatable {
        case pan(Double)
        case zoom(Double)
        case resize(Double)
    }

    static func scrollAction(
        deltaX: Double, deltaY: Double, option: Bool, precise: Bool
    ) -> ScrollAction? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        let scale = precise ? 1.0 : 10.0
        if abs(deltaX) > abs(deltaY) {
            return option ? .zoom(exp(max(-2, min(2, deltaX * scale * 0.01))))
                : .pan(deltaX * scale)
        }
        if option, deltaY != 0 { return .resize(deltaY * scale) }
        return nil
    }

    static func displayColumns(
        strokes: [AlignmentWaveformStroke], start: Double, duration: Double,
        width: Double, pixelsPerPoint: Double,
        draftEpoch: RecordingEpochID? = nil, ratePPM: Double = 0, offsetMilliseconds: Double = 0
    ) -> [DisplayColumn] {
        guard start.isFinite, duration.isFinite, duration > 0,
              width.isFinite, width > 0, pixelsPerPoint.isFinite, pixelsPerPoint > 0 else { return [] }
        let pixelWidth = width * pixelsPerPoint
        guard pixelWidth.isFinite, pixelWidth > 0, pixelWidth < Double(Int.max / 4) else { return [] }
        let count = Int(ceil(pixelWidth))
        var columns = [(low: Float, high: Float)?](repeating: nil, count: count * 2)
        for stroke in strokes {
            let first: Double
            let last: Double
            if stroke.epoch == draftEpoch {
                let rate = 1 + ratePPM / 1_000_000
                first = stroke.groupRange.lowerBound * rate + offsetMilliseconds / 1_000
                last = stroke.groupRange.upperBound * rate + offsetMilliseconds / 1_000
            } else {
                first = stroke.displayRange.lowerBound
                last = stroke.displayRange.upperBound
            }
            let lower = (first - start) / duration * pixelWidth
            let upper = (last - start) / duration * pixelWidth
            guard lower.isFinite, upper.isFinite, upper >= lower,
                  upper >= 0, lower < pixelWidth,
                  stroke.low.isFinite, stroke.high.isFinite, stroke.low <= stroke.high else { continue }
            let firstColumn = Int(max(0, lower).rounded(.down))
            let lastColumn = min(count - 1,
                max(firstColumn, Int(min(pixelWidth, upper).rounded(.up)) - 1))
            // A measured bin covers its entire span, not just its midpoint. Merge extrema only
            // where spans share a pixel; never interpolate across an uncovered source/timing gap.
            for column in firstColumn...lastColumn {
                let key = column * 2 + (stroke.mapped ? 0 : 1)
                if let prior = columns[key] {
                    columns[key] = (min(prior.low, stroke.low), max(prior.high, stroke.high))
                } else {
                    columns[key] = (stroke.low, stroke.high)
                }
            }
        }
        return columns.enumerated().compactMap { key, bounds in
            guard let bounds else { return nil }
            return DisplayColumn(
                x: (Double(key / 2) + 0.5) / pixelsPerPoint,
                low: bounds.low, high: bounds.high, mapped: key.isMultiple(of: 2)
            )
        }
    }

    static func speakerColorIndex(for id: SpeakerID, speakers: [SpeakerID], paletteCount: Int) -> Int? {
        guard paletteCount > 0 else { return nil }
        let ordered = Set(speakers).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        return ordered.firstIndex(of: id).map { $0 % paletteCount }
    }

    static func zoomDuration(for level: Double, maximum: Double = 30) -> Double? {
        guard level.isFinite, (0...1).contains(level),
              maximum.isFinite, maximum >= 0.5 else { return nil }
        return maximum * pow(0.5 / maximum, level)
    }

    static func zoomLevel(for duration: Double, maximum: Double = 30) -> Double? {
        guard duration.isFinite, maximum.isFinite, maximum > 0.5,
              (0.5...maximum).contains(duration) else { return nil }
        return log(maximum / duration) / log(maximum / 0.5)
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
        let lower = max(overviewNavigationRange.lowerBound, start - margin)
        let upper = min(overviewNavigationRange.upperBound, start + duration + margin)
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
        return (max(overviewNavigationRange.lowerBound, start - (duration - visible) / 2), duration)
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

    static func viewportClip(
        range: ClosedRange<Double>, start: Double, duration: Double, width: Double, shift: Double
    ) -> (drawingStart: Double, origin: Double, width: Double)? {
        let drawingStart = start - shift
        guard drawingStart.isFinite, duration.isFinite, duration > 0,
              (drawingStart + duration).isFinite, width.isFinite, width > 0,
              range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
        let lower = max(range.lowerBound, drawingStart)
        let upper = min(range.upperBound, drawingStart + duration)
        guard upper > lower else { return nil }
        return (drawingStart, (lower - drawingStart) / duration * width, (upper - lower) / duration * width)
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

    static func overviewExtent(
        indices: some Sequence<AlignmentWaveformStrokeIndex>, mappedOnly: Bool = false
    ) -> ClosedRange<Double>? {
        let ranges = indices.compactMap { mappedOnly ? $0.mappedDisplayExtent : $0.displayExtent }
        guard let first = ranges.map(\.lowerBound).min(),
              let last = ranges.map(\.upperBound).max(), first < last else { return nil }
        return first...last
    }

    static func windowStart(centeredAt time: Double, duration: Double) -> Double? {
        guard time.isFinite, overviewNavigationRange.contains(time),
              duration.isFinite, duration > 0, duration <= 30
        else { return nil }
        return max(overviewNavigationRange.lowerBound, time - duration / 2)
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

    static func adaptiveStrokes(
        track: AlignmentWaveformTrack, record: AdaptiveAnalysisRecord, includeEstimated: Bool = false
    ) -> [AlignmentWaveformStroke] {
        guard track.id == record.target.source, track.epoch == record.target.epoch else { return [] }
        let rate = Double(track.envelope.sampleRate)
        let intervals = record.playbackIntervals(includeEstimated: includeEstimated)
        return track.envelope.bins.compactMap { bin in
            let first = Double(bin.firstFrame) / rate, last = Double(bin.endFrame - 1) / rate
            guard let interval = intervals.first(where: { first >= $0.sourceStart && last < $0.sourceEnd }) else { return nil }
            let start = interval.alignedStart + (first - interval.sourceStart) * interval.rateRatio
            let end = interval.alignedStart + (last - interval.sourceStart) * interval.rateRatio
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return AlignmentWaveformStroke(
                sourceSeconds: (first + last) / 2, groupSeconds: (first + last) / 2,
                displaySeconds: (start + end) / 2, low: bin.minimum, high: bin.maximum,
                mapped: true, epoch: track.epoch, displayRange: start...end, groupRange: first...last
            )
        }
    }

    struct AdaptiveMarker: Identifiable, Equatable {
        let sourceSeconds: Double
        let alignedSeconds: Double
        let adjustmentMilliseconds: Double
        let kind: SourceTimingSegment.Kind?
        var isQuiet: Bool { kind == .quietTransition }
        var id: Double { sourceSeconds }
    }

    static func adaptiveMarkers(
        track: AlignmentWaveformTrack, record: AdaptiveAnalysisRecord, includeEstimated: Bool = false
    ) -> [AdaptiveMarker] {
        guard track.id == record.target.source, track.epoch == record.target.epoch else { return [] }
        let intervals = record.playbackIntervals(includeEstimated: includeEstimated)
        return intervals.map { region in
            let source = region.sourceStart, aligned = region.alignedStart
            return AdaptiveMarker(sourceSeconds: source, alignedSeconds: aligned,
                                  adjustmentMilliseconds: (aligned - source) * 1000, kind: region.kind)
        }
    }

    static func strokes(track: AlignmentWaveformTrack, map: AlignedTimelineMap?,
                        correction: SourceTimingCorrection? = nil,
                        cuts: ManualCutTimeline = .unedited) throws -> [AlignmentWaveformStroke] {
        let original = try track.envelope.bins.compactMap { bin -> AlignmentWaveformStroke? in
            guard let first = try position(frame: bin.firstFrame, track: track, map: map, correction: correction),
                  let last = try position(frame: bin.endFrame - 1, track: track, map: map, correction: correction),
                  first.epoch == last.epoch, first.mapped == last.mapped
            else { return nil }
            if let correction, first.mapped,
               !correction.segments.contains(where: { first.sourceSeconds >= $0.sourceStart && last.sourceSeconds < $0.sourceEnd }) {
                return nil
            }
            return AlignmentWaveformStroke(
                sourceSeconds: (first.sourceSeconds + last.sourceSeconds) / 2,
                groupSeconds: (first.groupSeconds + last.groupSeconds) / 2,
                displaySeconds: (first.displaySeconds + last.displaySeconds) / 2,
                low: bin.minimum, high: bin.maximum, mapped: first.mapped, epoch: first.epoch,
                displayRange: first.displaySeconds...last.displaySeconds,
                groupRange: first.groupSeconds...last.groupSeconds
            )
        }
        return applyingCuts(cuts, to: original)
    }

    static func applyingCuts(_ cuts: ManualCutTimeline,
                             to strokes: [AlignmentWaveformStroke]) -> [AlignmentWaveformStroke] {
        guard !cuts.removals.isEmpty else { return strokes }
        return strokes.flatMap { stroke in
            guard stroke.mapped else { return [stroke] }
            return cuts.keptAlignedRanges(in: stroke.displayRange).map { span in
                let full = stroke.displayRange.upperBound - stroke.displayRange.lowerBound
                let groupScale = full > 0
                    ? (stroke.groupRange.upperBound - stroke.groupRange.lowerBound) / full : 0
                let groupStart = stroke.groupRange.lowerBound
                    + (span.lowerBound - stroke.displayRange.lowerBound) * groupScale
                let groupEnd = stroke.groupRange.lowerBound
                    + (span.upperBound - stroke.displayRange.lowerBound) * groupScale
                let source = stroke.sourceSeconds + (groupStart + groupEnd) / 2 - stroke.groupSeconds
                let lo = cuts.editedTime(forAlignedTime: span.lowerBound)
                let hi = cuts.editedTime(forAlignedTime: span.upperBound)
                return AlignmentWaveformStroke(sourceSeconds: source,
                    groupSeconds: (groupStart + groupEnd) / 2, displaySeconds: (lo + hi) / 2,
                    low: stroke.low, high: stroke.high, mapped: stroke.mapped, epoch: stroke.epoch,
                    displayRange: lo...hi, groupRange: groupStart...groupEnd)
            }
        }
    }

    static func position(
        frame: Int64, track: AlignmentWaveformTrack, map: AlignedTimelineMap?,
        correction: SourceTimingCorrection? = nil
    ) throws -> AlignmentWaveformPosition? {
        let source = Double(frame) / Double(track.envelope.sampleRate)
        if let correction {
            guard correction.source == track.id, correction.isValid,
                  correction.sourceRate == track.envelope.sampleRate,
                  correction.sourceFrames == track.envelope.totalFrames else { throw WaveformWindowError.mapDoesNotMatchSource }
            let aligned = correction.alignedTime(at: source)
            return AlignmentWaveformPosition(sourceSeconds: source, groupSeconds: source,
                displaySeconds: aligned ?? source, epoch: correction.epoch, mapped: aligned != nil)
        }
        guard let map else {
            return AlignmentWaveformPosition(
                sourceSeconds: source, groupSeconds: source,
                displaySeconds: source, epoch: track.epoch, mapped: false
            )
        }
        guard let group = map.groups.first(where: { $0.group == track.group }),
              let placement = group.placements.first(where: { $0.occurrence.source == track.id })
        else {
            return AlignmentWaveformPosition(
                sourceSeconds: source, groupSeconds: source,
                displaySeconds: source, epoch: track.epoch, mapped: false
            )
        }
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
        case .outsideCoverage:
            return AlignmentWaveformPosition(
                sourceSeconds: source, groupSeconds: groupSeconds,
                displaySeconds: source, epoch: track.epoch, mapped: false
            )
        case .gap:
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

    static func anchorSourceSeconds(at time: Double, stroke: AlignmentWaveformStroke) -> Double? {
        guard time.isFinite, stroke.displayRange.contains(time) else { return nil }
        let displaySpan = stroke.displayRange.upperBound - stroke.displayRange.lowerBound
        let sourceSpan = stroke.groupRange.upperBound - stroke.groupRange.lowerBound
        let source = displaySpan > 0
            ? stroke.sourceSeconds + (time - stroke.displaySeconds) * sourceSpan / displaySpan
            : stroke.sourceSeconds
        return source.isFinite && source >= 0 ? source : nil
    }

}
