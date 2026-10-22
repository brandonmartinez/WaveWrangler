import Foundation
import WWCore

struct AlignmentWaveformStrokeIndex: Sendable {
    private struct Span: Sendable {
        let index: Int
        let lower: Double
        let upper: Double
    }

    private struct Intervals: Sendable {
        let spans: [Span]
        let maximumEnds: [Double]

        init(_ spans: [Span]) {
            self.spans = spans.sorted {
                $0.lower == $1.lower ? $0.index < $1.index : $0.lower < $1.lower
            }
            var maximum = -Double.infinity
            maximumEnds = self.spans.map {
                maximum = max(maximum, $0.upper)
                return maximum
            }
        }

        func overlapping(start: Double, end: Double) -> [Int] {
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if maximumEnds[mid] < start { lo = mid + 1 } else { hi = mid }
            }
            let first = lo
            hi = spans.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if spans[mid].lower < end { lo = mid + 1 } else { hi = mid }
            }
            return spans[first..<lo].compactMap { $0.upper >= start ? $0.index : nil }
        }

        func contains(start: Double, end: Double) -> Bool {
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if maximumEnds[mid] < start { lo = mid + 1 } else { hi = mid }
            }
            return lo < spans.count && spans[lo].lower < end
        }
    }

    static let empty = Self(strokes: [])
    let id = UUID()
    let strokes: [AlignmentWaveformStroke]
    let normalizedGain: Double
    let displayExtent: ClosedRange<Double>?
    let mappedDisplayExtent: ClosedRange<Double>?
    private let display: Intervals
    private let groups: [RecordingEpochID: Intervals]

    var isEmpty: Bool { strokes.isEmpty }
    var count: Int { strokes.count }

    func hasVisible(start: Double, duration: Double) -> Bool {
        start.isFinite && duration.isFinite && duration > 0 && (start + duration).isFinite
            && display.contains(start: start, end: start + duration)
    }

    init(strokes: [AlignmentWaveformStroke]) {
        self.strokes = strokes
        normalizedGain = AlignmentWaveformProjection.displayGain(for: strokes, normalized: true)
        displayExtent = Self.extent(of: strokes)
        mappedDisplayExtent = Self.extent(of: strokes.lazy.filter(\.mapped))
        display = Intervals(strokes.enumerated().compactMap { index, stroke in
            let range = stroke.displayRange
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
            return Span(index: index, lower: range.lowerBound, upper: range.upperBound)
        })
        var grouped: [RecordingEpochID: [Span]] = [:]
        for (index, stroke) in strokes.enumerated() {
            let range = stroke.groupRange
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { continue }
            grouped[stroke.epoch, default: []].append(
                Span(index: index, lower: range.lowerBound, upper: range.upperBound))
        }
        groups = grouped.mapValues(Intervals.init)
    }

    private static func extent(of strokes: some Sequence<AlignmentWaveformStroke>) -> ClosedRange<Double>? {
        var lower = Double.infinity
        var upper = -Double.infinity
        for stroke in strokes {
            lower = min(lower, stroke.displayRange.lowerBound)
            upper = max(upper, stroke.displayRange.upperBound)
        }
        guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        return lower...upper
    }

    func visible(start: Double, duration: Double, draftEpoch: RecordingEpochID? = nil,
                 ratePPM: Double = 0, offsetMilliseconds: Double = 0) -> [AlignmentWaveformStroke] {
        guard start.isFinite, duration.isFinite, duration > 0, (start + duration).isFinite else { return [] }
        var matches = display.overlapping(start: start, end: start + duration)
        if let draftEpoch {
            matches.removeAll { strokes[$0].epoch == draftEpoch }
            let rate = 1 + ratePPM / 1_000_000
            let offset = offsetMilliseconds / 1_000
            if rate.isFinite, rate > 0, offset.isFinite {
                matches += groups[draftEpoch]?.overlapping(
                    start: (start - offset) / rate, end: (start + duration - offset) / rate) ?? []
            }
        }
        return matches.sorted().map { strokes[$0] }
    }

    @concurrent
    static func prepare(strokes: [AlignmentWaveformStroke]) async throws -> Self {
        try Task.checkCancellation()
        let index = Self(strokes: strokes)
        try Task.checkCancellation()
        return index
    }
}
