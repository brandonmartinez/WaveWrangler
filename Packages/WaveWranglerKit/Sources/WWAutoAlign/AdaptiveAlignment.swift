import Foundation
import WWAlignEstimate
import WWCore

/// A locally supported source-to-reference relationship, not a recorder-clock map.
public struct AdaptiveTimingRegion: Sendable, Equatable, Codable {
    public let sourceStart: Double
    public let sourceEnd: Double
    public let rateRatio: Double
    public let offsetSeconds: Double
    public let measurements: Int
    public let maximumResidualMilliseconds: Double

    public func referenceTime(at sourceSeconds: Double) -> Double? {
        guard sourceSeconds.isFinite, sourceSeconds >= sourceStart, sourceSeconds < sourceEnd else { return nil }
        return rateRatio * sourceSeconds + offsetSeconds
    }
}

public struct AdaptiveTimingResult: Sendable, Equatable, Codable {
    public let regions: [AdaptiveTimingRegion]
    public let attemptedWindows: Int
    public let usableWindows: Int
    public let measuredStart: Double
    public let measuredEnd: Double
    public var quietTransitions: [AdaptiveQuietTransition]? = nil
    public var anchoredRecovery: AnchoredTimingRecovery? = nil

    public var supportedSeconds: Double { regions.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart } }
    public var quietSeconds: Double { (quietTransitions ?? []).reduce(0) { $0 + $1.sourceEnd - $1.sourceStart } }

    /// Geometry in reference-source seconds; quiet transitions never become measured speech regions.
    public var referenceIntervals: [SourceTimingSegment] {
        (regions.map {
            SourceTimingSegment(sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd,
                alignedStart: $0.rateRatio * $0.sourceStart + $0.offsetSeconds, rateRatio: $0.rateRatio)
        } + (quietTransitions ?? []).map {
            SourceTimingSegment(sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd,
                alignedStart: $0.rateRatio * $0.sourceStart + $0.offsetSeconds, rateRatio: $0.rateRatio,
                kind: .quietTransition)
        } + (anchoredRecovery?.regions ?? []).map {
            SourceTimingSegment(sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd,
                alignedStart: $0.rateRatio * $0.sourceStart + $0.offsetSeconds, rateRatio: $0.rateRatio,
                kind: .anchorGuided)
        }).sorted { $0.sourceStart < $1.sourceStart }
    }

    public var estimatedIntervals: [SourceTimingSegment] { AnchoredTiming.estimatedIntervals(between: referenceIntervals) }

    public func containsPlayableInterval(from start: Double, to end: Double, includeEstimated: Bool = false) -> Bool {
        regions.contains { start >= $0.sourceStart && end < $0.sourceEnd }
            || (quietTransitions ?? []).contains { start >= $0.sourceStart && end < $0.sourceEnd }
            || (anchoredRecovery?.regions ?? []).contains { start >= $0.sourceStart && end < $0.sourceEnd }
            || (includeEstimated && estimatedIntervals.contains { start >= $0.sourceStart && end < $0.sourceEnd })
    }

    /// Only measured regions and separately verified quiet interiors have a position.
    public func referenceTime(at sourceSeconds: Double, includeEstimated: Bool = false) -> Double? {
        if let measured = regions.first(where: { $0.sourceStart <= sourceSeconds && sourceSeconds < $0.sourceEnd }) {
            return measured.referenceTime(at: sourceSeconds)
        }
        if let quiet = quietTransitions?.first(where: { $0.sourceStart <= sourceSeconds && sourceSeconds < $0.sourceEnd }) {
            return quiet.rateRatio * sourceSeconds + quiet.offsetSeconds
        }
        if let guided = anchoredRecovery?.regions.first(where: { $0.sourceStart <= sourceSeconds && sourceSeconds < $0.sourceEnd }) {
            return guided.rateRatio * sourceSeconds + guided.offsetSeconds
        }
        guard includeEstimated, let estimated = estimatedIntervals.first(where: {
            $0.sourceStart <= sourceSeconds && sourceSeconds < $0.sourceEnd
        }) else { return nil }
        return estimated.alignedStart + (sourceSeconds - estimated.sourceStart) * estimated.rateRatio
    }
}

/// Candidate source-local timing support. Unsupported transitions stay absent rather than being
/// mislabeled as clock restarts, stretched across, or silently trimmed to one winning global line.
public enum AdaptiveAlignment {
    public static let version = 14
    public static let identifier = "ww-adaptive-align/14"
    public static let maximumSeconds = 7200.0
    public static let minimumIndependentWindows = 3

    public static func regions(
        observations: [DelayEvidence], start: Double, end: Double
    ) throws -> AdaptiveTimingResult {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= maximumSeconds,
              observations.count <= 3 * Int(maximumSeconds),
              observations.allSatisfy({
                  $0.targetCenter.isFinite && $0.targetCenter >= start && $0.targetCenter <= end
                      && $0.nccScore.isFinite && $0.nccSecond.isFinite
                      && ($0.offsetSeconds?.isFinite ?? true)
              })
        else { throw AlignEstimateError.invalidParameter("adaptive timing evidence outside bounded source interval") }
        let sorted = observations.sorted { $0.targetCenter < $1.targetCenter }
        for pair in zip(sorted, sorted.dropFirst()) where pair.1.targetCenter - pair.0.targetCenter < 0.5 {
            throw AlignEstimateError.invalidParameter("duplicate or insufficiently separated adaptive observations")
        }
        func isUsable(_ point: DelayEvidence) -> Bool {
            point.status == "eligible" && point.nccScore >= 0.6 && point.offsetSeconds != nil
                && (point.method == AutomaticAlignment.fineMethod || (
                    point.method == fineMethod && supportingCorroborations(point)?.allSatisfy {
                        $0.targetCenter >= start && $0.targetCenter <= end
                    } == true
                ) || (
                    point.method == spectralMethod && spectralCorroborations(point)?.allSatisfy {
                        $0.targetCenter >= start && $0.targetCenter <= end
                    } == true
                ) || (
                    point.method == shortMethod && shortCorroborations(point)?.allSatisfy {
                        $0.targetCenter >= start && $0.targetCenter <= end
                    } == true
                ) || (
                    [sequenceMethod, quietSequenceMethod].contains(point.method)
                        && sequenceCorroboration(point, allowingSharedQuiet: point.method == quietSequenceMethod).map {
                        $0.targetCenter >= start && $0.targetCenter <= end
                    } == true
                ))
                && point.phatOffsetSeconds?.isFinite == true
                && abs((point.phatOffsetSeconds ?? .infinity) - (point.offsetSeconds ?? 0))
                    <= AutomaticAlignment.fitToleranceSeconds
        }
        let usable = sorted.filter(isUsable)
        struct Support {
            let point: DelayEvidence
            let windowSeconds: Double
        }
        var regions: [AdaptiveTimingRegion] = []
        var run: [Support] = []
        let maximumSlope = AutomaticAlignment.maximumPPM / 1e6
        let tolerance = AutomaticAlignment.fitToleranceSeconds
        var lowerSlope = -maximumSlope, upperSlope = maximumSlope
        var currentFit: AffineFit?
        func resetRun() {
            run = []
            lowerSlope = -maximumSlope
            upperSlope = maximumSlope
            currentFit = nil
        }
        func extendRun(_ support: Support) -> Bool {
            guard let offset = support.point.offsetSeconds else { return false }
            var lower = lowerSlope, upper = upperSlope
            // Every pair bounds the slopes that can keep both residuals within the existing gate.
            for previous in run {
                guard let oldOffset = previous.point.offsetSeconds else { return false }
                let elapsed = support.point.targetCenter - previous.point.targetCenter
                let difference = offset - oldOffset
                if elapsed > 0 {
                    lower = max(lower, (difference - 2 * tolerance) / elapsed)
                    upper = min(upper, (difference + 2 * tolerance) / elapsed)
                } else if elapsed < 0 || abs(difference) > 2 * tolerance {
                    return false
                }
            }
            guard lower <= upper else { return false }
            let points = run.map(\.point) + [support.point]
            let preferred = AffineFit.weighted(points)
            guard preferred != nil || points.allSatisfy({ $0.targetCenter == support.point.targetCenter }) else {
                return false
            }
            if let preferred,
               ![preferred.center, preferred.intercept, preferred.slope].allSatisfy(\.isFinite) {
                return false
            }
            // A single/duplicate time only seeds a run, never sufficient independent support.
            let center = preferred?.center ?? support.point.targetCenter
            let slope = min(upper, max(lower, preferred?.slope ?? 0))
            let offsets = points.map { ($0.offsetSeconds ?? .infinity) - slope * ($0.targetCenter - center) }
            guard let minimum = offsets.min(), let maximum = offsets.max(),
                  maximum - tolerance <= minimum + tolerance else { return false }
            let intercept: Double
            if let preferred, preferred.slope == slope,
               preferred.intercept >= maximum - tolerance, preferred.intercept <= minimum + tolerance {
                intercept = preferred.intercept
            } else {
                intercept = minimum + (maximum - minimum) / 2
            }
            let fit = AffineFit(center: center, intercept: intercept, slope: slope)
            guard abs(fit.slope * 1e6) <= AutomaticAlignment.maximumPPM,
                  points.allSatisfy({
                      abs(($0.offsetSeconds ?? .infinity) - fit.offset(at: $0.targetCenter)) <= tolerance
                  }) else { return false }
            run.append(support)
            lowerSlope = lower
            upperSlope = upper
            currentFit = fit
            return true
        }
        func appendRun() {
            let points = run.map(\.point)
            guard let fit = currentFit else { return }
            // Earliest finish, not earliest center, maximizes truly disjoint mixed-length supports.
            let byEnd = run.sorted {
                $0.point.targetCenter + $0.windowSeconds / (2 * (1 - maximumSlope))
                    < $1.point.targetCenter + $1.windowSeconds / (2 * (1 - maximumSlope))
            }
            func independentCount(includeQuarters: Bool) -> Int {
                var count = 0, previousEnd = -Double.infinity
                for support in byEnd where includeQuarters || support.windowSeconds != 0.25 {
                    let half = support.windowSeconds / (2 * (1 - maximumSlope))
                    guard support.point.targetCenter - half >= previousEnd else { continue }
                    count += 1
                    previousEnd = support.point.targetCenter + half
                }
                return count
            }
            guard independentCount(includeQuarters: true) >= minimumIndependentWindows else { return }
            // A new short proof cannot lend its independence to otherwise insufficient long contexts
            // and claim their unverified centers. They still constrain the fit, never get trimmed.
            let localBounds = run.contains { $0.windowSeconds == 0.25 }
                && independentCount(includeQuarters: false) < minimumIndependentWindows
            guard let first = localBounds ? run.first(where: { $0.windowSeconds < 2 })?.point : points.first,
                  let last = localBounds ? run.last(where: { $0.windowSeconds < 2 })?.point : points.last else { return }
            regions.append(AdaptiveTimingRegion(
                sourceStart: first.targetCenter, sourceEnd: last.targetCenter,
                rateRatio: 1 + fit.slope, offsetSeconds: fit.offset(at: 0), measurements: points.count,
                maximumResidualMilliseconds: points.map {
                    abs(($0.offsetSeconds ?? 0) - fit.offset(at: $0.targetCenter)) * 1000
                }.max() ?? 0
            ))
        }
        var block: [Support] = []
        func flushBlock() throws {
            for support in block.sorted(by: { $0.point.targetCenter < $1.point.targetCenter }) {
                try Task.checkCancellation()
                if let last = run.last, support.point.targetCenter - last.point.targetCenter > 1.01 {
                    appendRun()
                    resetRun()
                }
                if !extendRun(support) {
                    appendRun()
                    resetRun()
                    guard extendRun(support) else {
                        throw AlignEstimateError.invalidParameter("adaptive support cannot seed a finite bounded line")
                    }
                }
            }
            appendRun()
            resetRun()
            block = []
        }
        var previousCenter: Double?
        for point in sorted {
            try Task.checkCancellation()
            guard isUsable(point) else {
                try flushBlock()
                previousCenter = nil
                continue
            }
            if let previousCenter, point.targetCenter - previousCenter > 1.01 { try flushBlock() }
            previousCenter = point.targetCenter
            let checks: [TemporalCorroboration]?
            if point.method == shortMethod {
                checks = shortCorroborations(point)
            } else if point.method == spectralMethod {
                checks = spectralCorroborations(point)
            } else if point.method == fineMethod {
                checks = supportingCorroborations(point)
            } else if [sequenceMethod, quietSequenceMethod].contains(point.method) {
                checks = sequenceCorroboration(point, allowingSharedQuiet: point.method == quietSequenceMethod).map { [$0] }
            } else {
                checks = nil
            }
            if let checks {
                block += checks.map { check in
                    Support(point: DelayEvidence(
                        station: point.station, attempt: point.attempt, targetCenter: check.targetCenter,
                        status: "eligible", offsetSeconds: check.offsetSeconds, nccScore: check.score,
                        nccSecond: check.competingScore, phatOffsetSeconds: nil, phatPeakRatio: nil, method: fineMethod
                    ), windowSeconds: check.windowSeconds ?? 0.5)
                }
            } else {
                block.append(Support(point: point, windowSeconds: AutomaticAlignment.windowSeconds))
            }
        }
        try flushBlock()
        for (left, right) in zip(regions, regions.dropFirst()) {
            guard left.sourceEnd <= right.sourceStart,
                  left.rateRatio * left.sourceEnd + left.offsetSeconds
                    <= right.rateRatio * right.sourceStart + right.offsetSeconds
            else { throw AlignEstimateError.invalidParameter("adaptive timing would repeat or reverse reference audio") }
        }
        return AdaptiveTimingResult(
            regions: regions, attemptedWindows: observations.count, usableWindows: usable.count,
            measuredStart: start, measuredEnd: end
        )
    }
}
