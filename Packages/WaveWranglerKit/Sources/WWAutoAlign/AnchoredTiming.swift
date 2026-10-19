import Foundation
import WWAlignEstimate
import WWCore

public struct AnchoredTimingObservation: Sendable, Equatable, Codable {
    public let leftRegion: Int
    public let center: Double
    public let status: String
    public let offset: Double?
    public let score: Double
    public let second: Double
    public let phatOffset: Double?
    public let phatRatio: Double
    public let polarity: Int
    public let canonical: TemporalCorroboration?
    public var canonicalPhatOffset: Double? = nil
    public var canonicalPhatRatio: Double? = nil

    var isEligible: Bool {
        guard status == "eligible", let offset, let phatOffset, let canonical,
              let canonicalPhatOffset, let canonicalPhatRatio,
              [offset, phatOffset, score, second, phatRatio].allSatisfy(\.isFinite) else { return false }
        return score >= 0.65 && score <= 1 && second >= 0 && second < 0.8 * score
            && (0..<0.8).contains(phatRatio) && abs(phatOffset - offset) <= 0.001
            && (polarity == 1 || polarity == -1)
            && canonical.windowSeconds == 0.25 && abs(canonical.targetCenter - center) <= 1 / Signal.rate
            && canonical.score >= 0.75 && canonical.score <= 1
            && canonical.competingScore >= 0 && canonical.competingScore < 0.8 * canonical.score
            && canonical.polarity == polarity && abs(canonical.offsetSeconds - offset) <= 0.001
            && abs(canonicalPhatOffset - canonical.offsetSeconds) <= 0.001
            && (0..<0.8).contains(canonicalPhatRatio)
    }
}

public struct AnchoredTimingRegion: Sendable, Equatable, Codable {
    public let sourceStart: Double
    public let sourceEnd: Double
    public let rateRatio: Double
    public let offsetSeconds: Double
    public let observations: [Int]
}

public struct AnchoredTimingRecovery: Sendable, Equatable, Codable {
    public let observations: [AnchoredTimingObservation]
    public let regions: [AnchoredTimingRegion]
    public var supportedSeconds: Double { regions.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart } }
}

public struct AnchoredTimingSearch: Sendable {
    public let leftRegion: Int
    public let sourceStart: Double
    public let sourceEnd: Double
    public let leftOffset: Double
    public let rightOffset: Double

    func prediction(at time: Double) -> Double {
        leftOffset + (rightOffset - leftOffset) * (time - sourceStart) / (sourceEnd - sourceStart)
    }
}

/// Existing independent anchors bound the search; short matches confirm passages, not a new clock.
public enum AnchoredTiming {
    public static let identifier = "ww-anchor-guided-timing/1"

    public static func searches(in timing: AdaptiveTimingResult) -> [AnchoredTimingSearch] {
        zip(timing.regions.indices, timing.regions.dropFirst()).compactMap { index, right in
            let left = timing.regions[index]
            let seconds = right.sourceStart - left.sourceEnd
            let a = (left.rateRatio - 1) * left.sourceEnd + left.offsetSeconds
            let b = (right.rateRatio - 1) * right.sourceStart + right.offsetSeconds
            guard seconds >= 0.3, seconds <= 300, abs(b - a) <= 0.05 else { return nil }
            return AnchoredTimingSearch(leftRegion: index, sourceStart: left.sourceEnd, sourceEnd: right.sourceStart,
                                        leftOffset: a, rightOffset: b)
        }
    }

    /// A bounded log-band path guides fresh waveform searches. Feature frames are never timing votes.
    public static func featureHints(
        search: AnchoredTimingSearch, centers: [Double], reference: SpectralFingerprint, target: SpectralFingerprint
    ) throws -> [Double] {
        guard centers.count <= 40, centers.allSatisfy({ $0.isFinite && $0 > search.sourceStart && $0 < search.sourceEnd }) else {
            throw AlignEstimateError.invalidParameter("anchor feature path exceeds bounded search")
        }
        guard !centers.isEmpty else { return [] }
        let shifts = [-0.04, -0.02, 0, 0.02, 0.04]
        var costs = [[Double]](), parents = [[Int]]()
        func score(center: Double, offset: Double) -> Double {
            let t = Int(((center - 0.25) * 50).rounded())
            let r = Int(((center + offset - 0.25) * 50).rounded())
            guard t >= 0, r >= 0, t + 25 <= target.frameCount, r + 25 <= reference.frameCount else { return 0 }
            var score = 0.0
            for band in 0..<6 {
                let a = Statistics.centered(target.bands[band][t..<t + 25].map(Double.init))
                let b = Statistics.centered(reference.bands[band][r..<r + 25].map(Double.init))
                let energy = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
                if energy > 1e-8 { score += zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / (6 * energy) }
            }
            return min(1, max(-1, score))
        }
        for (row, center) in centers.enumerated() {
            try Task.checkCancellation()
            let predicted = search.prediction(at: center)
            var values = [Double](repeating: .infinity, count: shifts.count)
            var back = [Int](repeating: 0, count: shifts.count)
            for state in shifts.indices {
                let local = 1 - score(center: center, offset: predicted + shifts[state])
                if row == 0 {
                    values[state] = local + abs(shifts[state]) * 5
                } else {
                    for previous in shifts.indices where abs(shifts[state] - shifts[previous]) <= 0.020001 {
                        let candidate = costs[row - 1][previous] + local + abs(shifts[state] - shifts[previous]) * 5
                        if candidate < values[state] { values[state] = candidate; back[state] = previous }
                    }
                }
            }
            costs.append(values)
            parents.append(back)
        }
        var state = shifts.indices.min { costs[centers.count - 1][$0] + abs(shifts[$0]) * 5
            < costs[centers.count - 1][$1] + abs(shifts[$1]) * 5 } ?? 2
        var hints = [Double](repeating: 0, count: centers.count)
        for row in centers.indices.reversed() {
            hints[row] = search.prediction(at: centers[row]) + shifts[state]
            state = parents[row][state]
        }
        return hints
    }

    public static func measure(
        search: AnchoredTimingSearch, centers: [Double], hints: [Double],
        reference: EstimatorTrack, target: EstimatorTrack
    ) throws -> [AnchoredTimingObservation] {
        guard centers.count == hints.count, centers.count <= 40,
              search.sourceStart.isFinite, search.sourceEnd.isFinite,
              search.sourceStart >= 0, search.sourceEnd <= 7200,
              search.sourceEnd - search.sourceStart <= 300, search.sourceEnd > search.sourceStart,
              abs(search.leftOffset) <= 7200, abs(search.rightOffset) <= 7200,
              target.buffer.durationSeconds <= 14.1, reference.buffer.durationSeconds <= 15,
              hints.allSatisfy({ $0.isFinite && $0 >= min(search.leftOffset, search.rightOffset) - 0.085
                  && $0 <= max(search.leftOffset, search.rightOffset) + 0.085 }),
              centers.allSatisfy({ $0.isFinite && $0 > search.sourceStart && $0 < search.sourceEnd }) else {
            throw AlignEstimateError.invalidParameter("anchor waveform search exceeds bounded buffers")
        }
        let r = try Signal.speechBand(Signal(reference.buffer).samples)
        let t = try Signal.speechBand(Signal(target.buffer).samples)
        let targetStart = target.groupClockStart.approximateDouble
        let referenceStart = reference.groupClockStart.approximateDouble
        func correlate(center: Double, seconds: Double, hint: Double) throws
            -> (center: Double, offset: Double, score: Double, second: Double, phat: Double, ratio: Double, polarity: Int, edge: Bool, rms: Double)? {
            let n = Int(seconds * Signal.rate)
            let at = Int(((center - seconds / 2 - targetStart) * Signal.rate).rounded())
            guard at >= 0, at + n <= t.count else { return nil }
            let time = targetStart + Double(at) / Signal.rate
            let lowerOffset = max(min(search.leftOffset, search.rightOffset) - 0.05, hint - 0.035)
            let upperOffset = min(max(search.leftOffset, search.rightOffset) + 0.05, hint + 0.035)
            let lo = max(0, Int(floor((time + lowerOffset - referenceStart) * Signal.rate)))
            let hi = min(r.count, Int(ceil((time + upperOffset - referenceStart) * Signal.rate)) + n + 1)
            guard hi - lo >= n + 3 else { return nil }
            let x = Statistics.centered(Array(t[at..<at + n]))
            let y = Array(r[lo..<hi])
            let fft = Transform(atLeast: x.count + y.count)
            let (raw, white) = fft.correlations(x, y)
            let energy = x.reduce(0) { $0 + $1 * $1 }
            var sum = y.prefix(n).reduce(0, +), power = y.prefix(n).reduce(0) { $0 + $1 * $1 }
            var scores = [Double](repeating: 0, count: y.count - n + 1)
            for lag in scores.indices {
                let other = max(0, power - sum * sum / Double(n))
                if energy > 1e-12, other > 1e-12 { scores[lag] = min(1, max(-1, raw[lag] / sqrt(energy * other))) }
                if lag + n < y.count {
                    sum += y[lag + n] - y[lag]
                    power += y[lag + n] * y[lag + n] - y[lag] * y[lag]
                }
            }
            let peak = Statistics.peak(scores.map(abs), exclusion: 20)
            let phat = Statistics.peak(white.prefix(scores.count).map(abs), exclusion: 20)
            let polarity = scores[peak.index] >= 0 ? 1 : -1
            return (time + seconds / 2, referenceStart + (Double(lo) + peak.refined) / Signal.rate - time,
                    peak.value, peak.second, referenceStart + (Double(lo) + phat.refined) / Signal.rate - time,
                    phat.value > 0 ? phat.second / phat.value : 1, polarity,
                    peak.index == 0 || peak.index + 1 == scores.count || phat.index == 0 || phat.index + 1 == scores.count
                        || (white[phat.index] >= 0 ? 1 : -1) != polarity,
                    sqrt(energy / Double(n)))
        }
        return try zip(centers, hints).map { center, hint in
            try Task.checkCancellation()
            guard let full = try correlate(center: center, seconds: 0.5, hint: hint),
                  let middle = try correlate(center: center, seconds: 0.25, hint: hint) else {
                return AnchoredTimingObservation(leftRegion: search.leftRegion, center: center, status: "noReference",
                    offset: nil, score: 0, second: 0, phatOffset: nil, phatRatio: 1, polarity: 0, canonical: nil)
            }
            let status = full.rms < 1e-4 || middle.rms < 1e-4 ? "silent"
                : full.score < 0.65 || middle.score < 0.75 ? "weak"
                : full.second >= 0.8 * full.score || middle.second >= 0.8 * middle.score
                    || full.ratio >= 0.8 || middle.ratio >= 0.8 ? "ambiguous"
                : full.edge || middle.edge ? "edgePeak"
                : abs(full.phat - full.offset) > 0.001 || abs(middle.phat - middle.offset) > 0.001
                    ? "inconsistentMethods"
                : full.polarity != middle.polarity || abs(full.offset - middle.offset) > 0.001
                    ? "inconsistentSubwindows" : "eligible"
            let point = AnchoredTimingObservation(leftRegion: search.leftRegion, center: middle.center, status: status,
                offset: full.offset, score: full.score, second: full.second, phatOffset: full.phat,
                phatRatio: full.ratio, polarity: full.polarity,
                canonical: TemporalCorroboration(targetCenter: middle.center, offsetSeconds: middle.offset,
                    score: middle.score, competingScore: middle.second, polarity: middle.polarity, windowSeconds: 0.25),
                canonicalPhatOffset: middle.phat, canonicalPhatRatio: middle.ratio)
            return point
        }
    }

    public static func recovering(
        _ timing: AdaptiveTimingResult, observations: [AnchoredTimingObservation]
    ) throws -> AdaptiveTimingResult {
        guard observations.count <= 28800 else { throw AlignEstimateError.invalidParameter("excessive anchor observations") }
        var original = timing
        original.anchoredRecovery = nil
        let searches = Dictionary(uniqueKeysWithValues: searches(in: original).map { ($0.leftRegion, $0) })
        let base = original.referenceIntervals
        var regions: [AnchoredTimingRegion] = []
        var run: [Int] = []
        func fit(_ indices: [Int]) -> (rate: Double, offset: Double)? {
            let points = indices.map { observations[$0] }
            let xs = points.map(\.center), ys = points.compactMap(\.offset)
            guard ys.count == xs.count else { return nil }
            let x = xs.reduce(0, +) / Double(xs.count), y = ys.reduce(0, +) / Double(ys.count)
            let variance = xs.reduce(0) { $0 + ($1 - x) * ($1 - x) }
            let slope = variance > 0 ? zip(xs, ys).reduce(0) { $0 + ($1.0 - x) * ($1.1 - y) } / variance : 0
            guard abs(slope) <= 0.01,
                  zip(xs, ys).allSatisfy({ abs($0.1 - (y + slope * ($0.0 - x))) <= 0.001 }) else { return nil }
            return (1 + slope, y - slope * x)
        }
        func flush() {
            defer { run = [] }
            guard let first = run.first, let last = run.last, let line = fit(run) else { return }
            let start = observations[first].center - 0.125, end = observations[last].center + 0.125
            let alignedStart = line.rate * start + line.offset, alignedEnd = line.rate * end + line.offset
            let parent = observations[first].leftRegion
            let left = timing.regions[parent], right = timing.regions[parent + 1]
            guard alignedStart >= left.rateRatio * left.sourceEnd + left.offsetSeconds,
                  alignedEnd <= right.rateRatio * right.sourceStart + right.offsetSeconds,
                  !base.contains(where: {
                ($0.sourceStart < end && $0.sourceEnd > start) || ($0.alignedStart < alignedEnd && $0.alignedEnd > alignedStart)
            }), regions.last.map({ $0.sourceEnd <= start && $0.rateRatio * $0.sourceEnd + $0.offsetSeconds <= alignedStart }) ?? true
            else { return }
            regions.append(AnchoredTimingRegion(sourceStart: start, sourceEnd: end, rateRatio: line.rate,
                                                offsetSeconds: line.offset, observations: run))
        }
        var previous: AnchoredTimingObservation?
        for (index, point) in observations.enumerated() {
            try Task.checkCancellation()
            guard point.center.isFinite, point.score.isFinite, point.second.isFinite,
                  let search = searches[point.leftRegion], point.center - 0.125 > search.sourceStart,
                  point.center + 0.125 < search.sourceEnd,
                  point.offset.map({ $0.isFinite && $0 >= min(search.leftOffset, search.rightOffset) - 0.085
                      && $0 <= max(search.leftOffset, search.rightOffset) + 0.085 }) ?? (point.status == "noReference"),
                  previous.map({ point.center > $0.center }) ?? true else {
                throw AlignEstimateError.invalidParameter("invalid or unordered anchor observation")
            }
            let continueRun = previous.map {
                $0.leftRegion == point.leftRegion && point.center - $0.center <= 0.301
                    && point.center - $0.center >= 0.25 / (1 - 500e-6)
                    && point.polarity == $0.polarity
            } ?? false
            if !continueRun || !point.isEligible { flush() }
            previous = point
            guard point.isEligible else { continue }
            if base.contains(where: { $0.sourceStart < point.center + 0.125 && $0.sourceEnd > point.center - 0.125 }) {
                flush()
                continue
            }
            let candidate = run + [index]
            if fit(candidate) == nil { flush() }
            run.append(index)
        }
        flush()
        var result = original
        result.anchoredRecovery = observations.isEmpty ? nil : AnchoredTimingRecovery(observations: observations, regions: regions)
        guard result.referenceIntervals.count <= 21600 else {
            throw AlignEstimateError.invalidParameter("excessive recovered source intervals")
        }
        return result
    }

    /// Explicitly unverified interpolation, never included unless the user opts in at acceptance.
    public static func estimatedIntervals(between segments: [SourceTimingSegment]) -> [SourceTimingSegment] {
        zip(segments, segments.dropFirst()).compactMap { left, right in
            let duration = right.sourceStart - left.sourceEnd
            let delta = (right.alignedStart - right.sourceStart) - (left.alignedEnd - left.sourceEnd)
            guard duration >= 0.01, duration <= 300, abs(delta) <= 0.05 else { return nil }
            var rate = (right.alignedStart - left.alignedEnd) / duration
            guard (0.99...1.01).contains(rate) else { return nil }
            if left.alignedEnd + duration * rate > right.alignedStart { rate = rate.nextDown }
            return SourceTimingSegment(sourceStart: left.sourceEnd, sourceEnd: right.sourceStart,
                alignedStart: left.alignedEnd, rateRatio: rate, kind: .estimated)
        }
    }
}
