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
            self.init(sortedSpans: spans.sorted {
                $0.lower == $1.lower ? $0.index < $1.index : $0.lower < $1.lower
            })
        }

        init(sortedSpans: [Span]) {
            spans = sortedSpans
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

    private struct Cached: Codable {
        let strokes: Data
        let epochs: [RecordingEpochID]
        let displayOrder: Data
        let groupOrders: [RecordingEpochID: Data]
    }

    enum CacheError: Error {
        case invalidIndex
    }

    func cachedPayload() throws -> Data {
        guard strokes.count <= Int(UInt32.max) else { throw CacheError.invalidIndex }
        var epochs: [RecordingEpochID] = []
        var epochIndices: [RecordingEpochID: UInt64] = [:]
        var words: [UInt64] = []
        words.reserveCapacity(strokes.count * 9)
        // Each stroke stores seven Float64 coordinates, packed Float32 extrema, and an epoch/mapped word.
        for stroke in strokes {
            let epoch = epochIndices[stroke.epoch] ?? UInt64(epochs.count)
            if epochIndices[stroke.epoch] == nil {
                epochIndices[stroke.epoch] = epoch
                epochs.append(stroke.epoch)
            }
            words.append(contentsOf: [
                stroke.sourceSeconds.bitPattern, stroke.groupSeconds.bitPattern, stroke.displaySeconds.bitPattern,
                stroke.displayRange.lowerBound.bitPattern, stroke.displayRange.upperBound.bitPattern,
                stroke.groupRange.lowerBound.bitPattern, stroke.groupRange.upperBound.bitPattern,
                UInt64(stroke.low.bitPattern) | UInt64(stroke.high.bitPattern) << 32,
                epoch << 1 | (stroke.mapped ? 1 : 0)
            ].map(\.littleEndian))
        }
        func order(_ intervals: Intervals) -> Data {
            intervals.spans.map { UInt32($0.index).littleEndian }.withUnsafeBytes { Data($0) }
        }
        let cached = Cached(strokes: words.withUnsafeBytes { Data($0) }, epochs: epochs,
            displayOrder: order(display), groupOrders: groups.mapValues(order))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(cached)
    }

    init(cachedPayload: Data) throws {
        let cached = try PropertyListDecoder().decode(Cached.self, from: cachedPayload)
        let stride = 9 * MemoryLayout<UInt64>.stride
        guard cached.strokes.count.isMultiple(of: stride),
              cached.strokes.count / stride <= Int(UInt32.max),
              Set(cached.epochs).count == cached.epochs.count,
              cached.groupOrders.values.reduce(0, { $0 + $1.count }) == cached.strokes.count / stride * 4
        else { throw CacheError.invalidIndex }
        let strokes: [AlignmentWaveformStroke] = try cached.strokes.withUnsafeBytes { bytes in
            try (0..<(bytes.count / stride)).map { index in
                func word(_ field: Int) -> UInt64 {
                    UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: index * stride + field * 8, as: UInt64.self))
                }
                let source = Double(bitPattern: word(0)), group = Double(bitPattern: word(1))
                let display = Double(bitPattern: word(2))
                let displayStart = Double(bitPattern: word(3)), displayEnd = Double(bitPattern: word(4))
                let groupStart = Double(bitPattern: word(5)), groupEnd = Double(bitPattern: word(6))
                let low = Float(bitPattern: UInt32(truncatingIfNeeded: word(7)))
                let high = Float(bitPattern: UInt32(truncatingIfNeeded: word(7) >> 32))
                let epoch = word(8) >> 1
                guard source.isFinite, group.isFinite, display.isFinite,
                      displayStart.isFinite, displayEnd.isFinite, displayStart <= displayEnd,
                      groupStart.isFinite, groupEnd.isFinite, groupStart <= groupEnd,
                      low.isFinite, high.isFinite, low <= high,
                      epoch < UInt64(cached.epochs.count) else { throw CacheError.invalidIndex }
                return AlignmentWaveformStroke(sourceSeconds: source, groupSeconds: group,
                    displaySeconds: display, low: low, high: high, mapped: word(8) & 1 == 1,
                    epoch: cached.epochs[Int(epoch)], displayRange: displayStart...displayEnd,
                    groupRange: groupStart...groupEnd)
            }
        }
        func restore(_ order: Data, epoch: RecordingEpochID? = nil) throws -> Intervals {
            guard order.count.isMultiple(of: MemoryLayout<UInt32>.stride),
                  epoch != nil || order.count / 4 == strokes.count,
                  epoch == nil || !order.isEmpty else { throw CacheError.invalidIndex }
            var previous: Span?
            let spans: [Span] = try order.withUnsafeBytes { bytes in
                try (0..<(bytes.count / 4)).map { offset in
                    let index = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset * 4, as: UInt32.self)))
                    guard strokes.indices.contains(index),
                          epoch == nil || strokes[index].epoch == epoch else { throw CacheError.invalidIndex }
                    let range = epoch == nil ? strokes[index].displayRange : strokes[index].groupRange
                    let span = Span(index: index, lower: range.lowerBound, upper: range.upperBound)
                    // Strict stored order proves uniqueness without re-sorting or a per-stroke hash set.
                    guard previous.map({ $0.lower < span.lower || ($0.lower == span.lower && $0.index < span.index) }) ?? true
                    else { throw CacheError.invalidIndex }
                    previous = span
                    return span
                }
            }
            return Intervals(sortedSpans: spans)
        }
        self.strokes = strokes
        normalizedGain = AlignmentWaveformProjection.displayGain(for: strokes, normalized: true)
        displayExtent = Self.extent(of: strokes)
        mappedDisplayExtent = Self.extent(of: strokes.lazy.filter(\.mapped))
        display = try restore(cached.displayOrder)
        var groups: [RecordingEpochID: Intervals] = [:]
        for (epoch, order) in cached.groupOrders {
            groups[epoch] = try restore(order, epoch: epoch)
        }
        self.groups = groups
    }

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
        groups = grouped.mapValues { Intervals($0) }
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
