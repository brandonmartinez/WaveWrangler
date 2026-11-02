import Foundation
import SwiftUI
import WWCommonEdit
import WWCore

enum AudioAutomationTarget: Hashable, Sendable {
    case point(Int)
    case level(first: Int, last: Int)
}

struct AudioEnvelopeGeometryKey: Equatable {
    let envelope: AudioClipEnvelope
    let durationFrames: Int64
    let programStart: Double
    let viewportStart: Double
    let viewportDuration: Double
    let viewportWidth: Double
    let left: Double
    let width: Double
    let height: Double
    let projection: AudioTimelineProjection
}

struct AudioEnvelopeGeometry {
    struct Point {
        let index: Int
        let local: AudioEnvelopeCoordinate
        let position: CGPoint
    }
    struct Segment {
        let first: Int
        let last: Int
        let frame: CGRect
    }
    let lines: [[CGPoint]]
    let points: [Point]
    let segments: [Segment]
    static let maximumColumns = 8_192

    static func make(_ key: AudioEnvelopeGeometryKey) throws -> Self {
        guard key.programStart.isFinite, key.viewportStart.isFinite,
              key.viewportDuration.isFinite, key.viewportDuration > 0,
              key.viewportWidth.isFinite, key.viewportWidth > 0,
              key.left.isFinite, key.width.isFinite, key.width > 0,
              key.height.isFinite, key.height >= 12 else {
            throw AudioFadeInput.Refusal("Envelope display needs a finite, positive viewport.")
        }
        let editing = try AudioEnvelopeEditing(envelope: key.envelope, durationFrames: key.durationFrames)
        guard !key.envelope.points.isEmpty else { return .init(lines: [], points: [], segments: []) }
        let columns = max(1, Int(ceil(min(Double(maximumColumns), key.width))))
        var xs = (0...(columns * 2)).map { Double($0) / Double(columns * 2) * key.width }
        var pointsByColumn: [Int: Point] = [:]
        for (index, point) in key.envelope.points.enumerated() {
            let local = try editing.localCoordinate(of: point)
            let localValue = Double(local.numerator) / Double(local.denominator)
            guard localValue >= 0, localValue <= Double(key.durationFrames) else { continue }
            let display = key.projection.displayTime(forProgramTime: key.programStart + localValue / 48_000)
            let x = (display - key.viewportStart) / key.viewportDuration * key.viewportWidth - key.left
            guard x >= 0, x <= key.width else { continue }
            let column = min(columns - 1, Int(x / key.width * Double(columns)))
            pointsByColumn[column] = .init(index: index, local: local, position: .init(x: x, y: y(point.amplitude, key: key)))
        }
        let points = pointsByColumn.values.sorted { $0.position.x < $1.position.x }
        let knots = Dictionary(points.map { (Double($0.position.x), $0.position) }, uniquingKeysWith: { _, latest in latest })
        xs += points.map { Double($0.position.x) }
        var visibleGaps = 0
        for gap in key.projection.reviewOnlyDisplayRanges {
            let first = (gap.lowerBound - key.viewportStart) / key.viewportDuration * key.viewportWidth - key.left
            let last = (gap.upperBound - key.viewportStart) / key.viewportDuration * key.viewportWidth - key.left
            guard last >= 0, first <= key.width else { continue }
            if visibleGaps == columns { break }
            visibleGaps += 1
            for time in [gap.lowerBound, gap.upperBound] {
                let x = (time - key.viewportStart) / key.viewportDuration * key.viewportWidth - key.left
                if x >= 0, x <= key.width { xs.append(x) }
            }
        }
        var lines: [[CGPoint]] = [], line: [CGPoint] = []
        for x in Set(xs).sorted() {
            let display = key.viewportStart + (key.left + x) / key.viewportWidth * key.viewportDuration
            guard let program = key.projection.programTime(forDisplayTime: display) else {
                if !line.isEmpty { lines.append(line); line = [] }
                continue
            }
            let local = (program - key.programStart) * 48_000
            guard local >= -0.000_1, local <= Double(key.durationFrames) + 0.000_1 else {
                if !line.isEmpty { lines.append(line); line = [] }
                continue
            }
            if let knot = knots[x] {
                line.append(knot)
                continue
            }
            // Pixel sampling is display-only. Exact knot positions below remain visibly inspectable;
            // production and offline rendering continue to evaluate the canonical rational curve.
            let frame = min(key.durationFrames, max(0, Int64(local.rounded(.toNearestOrEven))))
            let amplitude = try editing.evaluator.amplitude(atLocalFrame: frame)
            line.append(.init(x: x, y: y(amplitude, key: key)))
        }
        if !line.isEmpty { lines.append(line) }
        return .init(lines: lines, points: points, segments: try flatSegments(key, editing: editing))
    }

    func target(at position: CGPoint) -> AudioAutomationTarget? {
        if let point = points.filter({ hypot($0.position.x - position.x, $0.position.y - position.y) <= 8 })
            .min(by: { hypot($0.position.x - position.x, $0.position.y - position.y)
                < hypot($1.position.x - position.x, $1.position.y - position.y) }) {
            return .point(point.index)
        }
        return segments.first(where: { $0.frame.contains(position) }).map { .level(first: $0.first, last: $0.last) }
    }

    private static func flatSegments(_ key: AudioEnvelopeGeometryKey, editing: AudioEnvelopeEditing) throws -> [Segment] {
        let knots = key.envelope.points
        let locals = try knots.map { try editing.localCoordinate(of: $0) }
        let end = try AudioEnvelopeCoordinate(numerator: key.durationFrames)
        var result: [Segment] = []
        func add(_ first: Int, _ last: Int, from lo: Double, to hi: Double) {
            guard hi > lo, result.count < maximumColumns else { return }
            func x(_ local: Double) -> Double {
                (key.projection.displayTime(forProgramTime: key.programStart + local / 48_000) - key.viewportStart)
                    / key.viewportDuration * key.viewportWidth - key.left
            }
            let left = max(0, x(lo)), right = min(key.width, x(hi))
            guard right > left else { return }
            var ranges = [left..<right]
            for gap in key.projection.reviewOnlyDisplayRanges {
                let a = (gap.lowerBound - key.viewportStart) / key.viewportDuration * key.viewportWidth - key.left
                let b = (gap.upperBound - key.viewportStart) / key.viewportDuration * key.viewportWidth - key.left
                ranges = ranges.flatMap { range -> [Range<Double>] in
                    guard a < range.upperBound, b > range.lowerBound else { return [range] }
                    var kept: [Range<Double>] = []
                    if a > range.lowerBound { kept.append(range.lowerBound..<a) }
                    if b < range.upperBound { kept.append(b..<range.upperBound) }
                    return kept
                }
            }
            for range in ranges where range.upperBound - range.lowerBound >= 8 && result.count < maximumColumns {
                result.append(.init(first: first, last: last,
                    frame: .init(x: range.lowerBound, y: y(knots[first].amplitude, key: key) - 6,
                                 width: range.upperBound - range.lowerBound, height: 12)))
            }
        }
        func value(_ coordinate: AudioEnvelopeCoordinate) -> Double {
            Double(coordinate.numerator) / Double(coordinate.denominator)
        }
        if let first = locals.first, first > .zero, first <= end { add(0, 0, from: 0, to: value(first)) }
        for index in knots.indices.dropFirst()
        where knots[index - 1].amplitude == knots[index].amplitude
            && locals[index - 1] >= .zero && locals[index] <= end {
            add(index - 1, index, from: value(locals[index - 1]), to: value(locals[index]))
        }
        if let last = locals.last, last >= .zero, last < end {
            add(knots.count - 1, knots.count - 1, from: value(last), to: Double(key.durationFrames))
        }
        return result
    }

    private static func y(_ amplitude: Double, key: AudioEnvelopeGeometryKey) -> Double {
        (1 - amplitude) * (key.height - 12) + 6
    }
}

@MainActor
final class AudioEnvelopeGeometryCache {
    static let maximumEntries = 8
    struct Entry {
        let id = UUID()
        let geometry: AudioEnvelopeGeometry?
        let failure: String?
    }
    private var entries: [AudioClipID: (key: AudioEnvelopeGeometryKey, entry: Entry)] = [:]
    private var recency: [AudioClipID] = []
    private(set) var buildCount = 0
    var entryCount: Int { entries.count }

    func geometry(for clip: AudioClipID, key: AudioEnvelopeGeometryKey) -> Entry {
        if let prior = entries[clip], prior.key == key {
            touch(clip)
            return prior.entry
        }
        let entry: Entry
        do { entry = .init(geometry: try AudioEnvelopeGeometry.make(key), failure: nil) }
        catch { entry = .init(geometry: nil, failure: AudioFadeInput.describe(error)) }
        buildCount += 1
        entries[clip] = (key, entry)
        touch(clip)
        while recency.count > Self.maximumEntries { entries[recency.removeFirst()] = nil }
        return entry
    }

    func retain(_ clips: Set<AudioClipID>) {
        entries = entries.filter { clips.contains($0.key) }
        recency.removeAll { !clips.contains($0) }
    }

    private func touch(_ clip: AudioClipID) {
        recency.removeAll { $0 == clip }
        recency.append(clip)
    }
}

struct AudioEnvelopeDrawing: View, Equatable {
    let cache: AudioEnvelopeGeometryCache
    let clip: AudioClipID
    let key: AudioEnvelopeGeometryKey

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cache === rhs.cache && lhs.clip == rhs.clip && lhs.key == rhs.key
    }

    var body: some View {
        let entry = cache.geometry(for: clip, key: key)
        ZStack {
            Canvas(rendersAsynchronously: true) { context, _ in
                guard let geometry = entry.geometry else { return }
                for line in geometry.lines {
                    var path = Path()
                    path.addLines(line)
                    context.stroke(path, with: .color(.orange), lineWidth: 1.5)
                }
                for point in geometry.points {
                    let rect = CGRect(x: point.position.x - 2.5, y: point.position.y - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: rect), with: .color(.orange))
                }
            }
            if let failure = entry.failure {
                Text(failure).font(.caption2).foregroundStyle(.red)
            }
        }
        .clipped()
        .accessibilityHidden(entry.failure == nil)
        .allowsHitTesting(false)
    }
}
