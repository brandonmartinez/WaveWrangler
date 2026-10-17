import Foundation
import WWAlignEstimate
import WWTimeMap

public struct CoarseAlignment: Sendable {
    public let offsetSeconds: Double?
    public let measurements: [DelayEvidence]
    public let detail: String
    public let abstentionReason: AbstentionReason?
}

/// A newly measured delay, not an inherited eligibility classification or a probability.
public struct DelayEvidence: Sendable, Equatable {
    public let station: Int
    public let attempt: Int
    public let targetCenter: Double
    public var status: String
    public let offsetSeconds: Double?
    public let nccScore: Double
    public let nccSecond: Double
    public let phatOffsetSeconds: Double?
    public let phatPeakRatio: Double?
    public let method: String
    public var polarity: Int? = nil
    public var corroborations: [TemporalCorroboration]? = nil
    public var spectralWitness: SpectralTimingWitness? = nil

    var weight: Double { max(0.001, nccScore * nccScore * max(0, 1 - nccSecond / max(nccScore, 1e-10))) }
}

public struct AutomaticAlignmentResult: Sendable {
    public let proposal: AutomaticProposal?
    public let abstention: AutomaticAbstention?
    public let windows: [DelayEvidence]
    public let attempts: [DelayEvidence]
    public let startSeconds: Double
    public let endSeconds: Double
    public let spanFraction: Double
    public let expectedStations: Int
    public let flags: [String]
}

public struct AutomaticProposal: Sendable {
    public let segment: AffineClockSegment
    public let ppm: Double
    public let offsetAtCenterSeconds: Double
    public let acousticResidualP95Milliseconds: Double
    public let acousticResidualMaxMilliseconds: Double
    public let provenance: AcousticConsistencyProposal
}

public struct AutomaticAbstention: Sendable {
    public let reason: AbstentionReason
    public let detail: String
}

/// Native, bounded acoustic proposals. The v1 frozen estimator remains unchanged and independently callable.
public enum AutomaticAlignment {
    public static let identifier = "ww-auto-align/4"
    public static let fineMethod = "speech-ncc+phat-rate-polarity"
    public static let stationCount = 16
    public static let stationSeconds = 8.0
    public static let windowSeconds = 2.0
    public static let fitToleranceSeconds = 0.001
    public static let maximumPPM = 500.0

    /// A 60-second target and bounded reference buffer are sufficient for discovery. Six independent
    /// spectral-feature searches must support one offset; a seed is not a proposal and cannot be accepted.
    public static func coarse(reference: EstimatorTrack, target: EstimatorTrack, search: SearchRange) throws -> CoarseAlignment {
        guard target.buffer.durationSeconds <= 61, reference.buffer.durationSeconds <= 1270 else {
            throw AlignEstimateError.invalidParameter("coarse buffer exceeds bounded discovery duration")
        }
        let referenceSignal = try Signal(reference.buffer), targetSignal = try Signal(target.buffer)
        if Statistics.rms(referenceSignal.samples) < 1e-4 || Statistics.rms(targetSignal.samples) < 1e-4 {
            return CoarseAlignment(offsetSeconds: nil, measurements: [], detail: "The selected speaker channel is silent in this probe. Check its assignment or place anchors.", abstentionReason: .silent)
        }
        let r = try referenceSignal.features(), t = try targetSignal.features()
        let length = 200 // 4 seconds at 50 Hz
        guard let count = t.first?.count, count >= length, let referenceCount = r.first?.count else {
            return CoarseAlignment(offsetSeconds: nil, measurements: [], detail: "Too little audio for coarse offset discovery.", abstentionReason: .insufficientCoverage)
        }
        var evidence: [DelayEvidence] = []
        for station in 0..<6 {
            try Task.checkCancellation()
            let start = Int((Double(count - length) * Double(station) / 5).rounded())
            let time = target.groupClockStart.approximateDouble + Double(start) / 50
            let expected = (time + search.centerOffsetSeconds - reference.groupClockStart.approximateDouble) * 50
            guard expected.isFinite, abs(expected) < 1e12 else {
                throw AlignEstimateError.invalidParameter("coarse search coordinate")
            }
            let lo = max(0, Int(floor(expected - search.maximumDeviationSeconds * 50)))
            let hi = min(referenceCount, Int(ceil(expected + search.maximumDeviationSeconds * 50)) + length)
            guard hi - lo > length + 2 else { continue }
            let transform = Transform(atLeast: hi - lo + length)
            var scores = [Double](repeating: 0, count: hi - lo - length + 1)
            for band in 0..<6 {
                let x = Statistics.centered(Array(t[band][start..<start + length]))
                let y = Array(r[band][lo..<hi])
                let correlation = transform.correlation(x, y)
                let ex = x.reduce(0) { $0 + $1 * $1 }
                var sum = 0.0, energy = 0.0
                for k in 0..<length { sum += y[k]; energy += y[k] * y[k] }
                for lag in scores.indices {
                    let ey = max(0, energy - sum * sum / Double(length))
                    if ex > 1e-6, ey > 1e-6 { scores[lag] += max(-1, min(1, correlation[lag] / sqrt(ex * ey))) / 6 }
                    if lag + length < y.count {
                        sum += y[lag + length] - y[lag]
                        energy += y[lag + length] * y[lag + length] - y[lag] * y[lag]
                    }
                }
            }
            let peak = Statistics.peak(scores, exclusion: 12)
            let eligible = peak.value >= 0.25 && peak.second < 0.8 * peak.value
                && peak.index > 0 && peak.index + 1 < scores.count
            let offset = reference.groupClockStart.approximateDouble + (Double(lo) + peak.refined) / 50 - time
            evidence.append(DelayEvidence(
                station: station, attempt: 0, targetCenter: time + 2, status: eligible ? "eligible" : peak.value < 0.25 ? "weak" : "ambiguous",
                offsetSeconds: offset, nccScore: peak.value, nccSecond: peak.second,
                phatOffsetSeconds: nil, phatPeakRatio: nil, method: "log-band-coarse"
            ))
        }
        let eligible = evidence.filter { $0.status == "eligible" }
        let median = Statistics.median(eligible.compactMap(\.offsetSeconds))
        let tolerance = 0.04 + target.buffer.durationSeconds * maximumPPM / 1e6
        let agreeing = eligible.filter { abs(($0.offsetSeconds ?? .infinity) - median) <= tolerance }
        guard agreeing.count >= 3, agreeing.count == eligible.count else {
            let reason: AbstentionReason
            if evidence.isEmpty { reason = .insufficientCoverage }
            else if evidence.allSatisfy({ $0.status == "weak" }) { reason = .weak }
            else if eligible.count >= 3 { reason = .inconsistent }
            else if evidence.contains(where: { $0.status == "ambiguous" }) { reason = .ambiguous }
            else { reason = .insufficientCoverage }
            return CoarseAlignment(offsetSeconds: nil, measurements: evidence, detail: "Coarse searches did not find one unique shared offset (\(reason.rawValue)). Try a closer initial placement or place anchors; no timing was applied.", abstentionReason: reason)
        }
        return CoarseAlignment(offsetSeconds: median, measurements: evidence, detail: "Spectral-feature offset seed; precise distributed validation is still required.", abstentionReason: nil)
    }

    /// Measures three fresh local windows; low-quality old windows are never promoted into the fit.
    public static func measure(
        reference: EstimatorTrack, target: EstimatorTrack, station: Int,
        predictedOffset: Double, deviation: Double, rateRatio: Double = 1
    ) throws -> [DelayEvidence] {
        try measure(reference: reference, target: target, station: station, predictedOffset: predictedOffset,
                    deviation: deviation, rateRatio: rateRatio, upperSpeech: false)
    }

    static func measure(
        reference: EstimatorTrack, target: EstimatorTrack, station: Int,
        predictedOffset: Double, deviation: Double, rateRatio: Double, upperSpeech: Bool,
        windowSeconds: Double = AutomaticAlignment.windowSeconds
    ) throws -> [DelayEvidence] {
        guard target.buffer.durationSeconds <= stationSeconds + 0.01,
              reference.buffer.durationSeconds <= 60, predictedOffset.isFinite,
              deviation.isFinite, deviation > 0, deviation <= 10,
              [1, Self.windowSeconds].contains(windowSeconds),
              rateRatio.isFinite, abs(rateRatio - 1) <= maximumPPM / 1e6 + 1e-12,
              (0..<stationCount).contains(station) else {
            throw AlignEstimateError.invalidParameter("fine search exceeds bounded station envelope")
        }
        let r = try Signal(reference.buffer), t = try Signal(target.buffer)
        let referenceSamples = try upperSpeech ? Signal.upperSpeechBand(r.samples) : Signal.speechBand(r.samples)
        let targetSamples = try upperSpeech ? Signal.upperSpeechBand(t.samples) : Signal.speechBand(t.samples)
        let n = Int(windowSeconds * Signal.rate)
        let anchorCount = Int(Self.windowSeconds * Signal.rate)
        let available = Double(t.samples.count - 1) - Double(anchorCount - 1) / rateRatio
        guard available >= 0 else { return [] }
        var evidence: [DelayEvidence] = []
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let start = Int((floor(available) * Double(attempt) / 2).rounded())
                + Int(((Self.windowSeconds - windowSeconds) * Signal.rate / (2 * rateRatio)).rounded())
            let time = target.groupClockStart.approximateDouble + Double(start) / Signal.rate
            let targetCenter = time + windowSeconds / (2 * rateRatio)
            let expected = (time + predictedOffset - reference.groupClockStart.approximateDouble) * Signal.rate
            guard expected.isFinite, abs(expected) < 1e12 else {
                throw AlignEstimateError.invalidParameter("fine search coordinate")
            }
            let lo = max(0, Int(floor(expected - deviation * Signal.rate)))
            let hi = min(r.samples.count, Int(ceil(expected + deviation * Signal.rate)) + n + 1)
            guard hi - lo >= n + 3 else {
                evidence.append(DelayEvidence(station: station, attempt: attempt, targetCenter: targetCenter, status: "noReference", offsetSeconds: nil, nccScore: 0, nccSecond: 0, phatOffsetSeconds: nil, phatPeakRatio: nil, method: fineMethod))
                continue
            }
            let x = Statistics.centered(try Signal.template(targetSamples, start: start, count: n, rateRatio: rateRatio))
            let y = Statistics.centered(Array(referenceSamples[lo..<hi]))
            let transform = Transform(atLeast: x.count + y.count)
            let raw = transform.correlation(x, y)
            let whitened = transform.correlation(x, y, phat: true)
            let ex = x.reduce(0) { $0 + $1 * $1 }
            var scores = [Double](repeating: 0, count: y.count - n + 1)
            var sum = 0.0, energy = 0.0
            for k in 0..<n { sum += y[k]; energy += y[k] * y[k] }
            for lag in scores.indices {
                let ey = max(0, energy - sum * sum / Double(n))
                if ex > 1e-12, ey > 1e-12 { scores[lag] = max(-1, min(1, raw[lag] / sqrt(ex * ey))) }
                if lag + n < y.count {
                    sum += y[lag + n] - y[lag]
                    energy += y[lag + n] * y[lag + n] - y[lag] * y[lag]
                }
            }
            let peak = Statistics.peak(scores.map(abs), exclusion: 20)
            let phat = Statistics.peak(whitened.prefix(scores.count).map(abs), exclusion: 20)
            let polarity = scores[peak.index] >= 0 ? 1 : -1
            let offset = reference.groupClockStart.approximateDouble + (Double(lo) + peak.refined) / Signal.rate
                + windowSeconds / 2 - targetCenter
            let phatOffset = reference.groupClockStart.approximateDouble + (Double(lo) + phat.refined) / Signal.rate
                + windowSeconds / 2 - targetCenter
            let phatRatio = phat.value > 0 ? phat.second / phat.value : 1
            var status = "eligible"
            if Statistics.rms(Array(t.samples[start..<min(t.samples.count, start + n)])) < 1e-4 {
                let predicted = Int(expected.rounded()) - lo
                let shared = predicted >= 0 && lo + predicted + n <= r.samples.count
                    && Statistics.rms(Array(r.samples[lo + predicted..<lo + predicted + n])) < 1e-4
                status = shared ? "sharedSilence" : "silent"
            }
            else if peak.value < 0.35 { status = "weak" }
            else if peak.second >= 0.8 * peak.value || phatRatio >= 0.8 { status = "ambiguous" }
            else if peak.index == 0 || peak.index + 1 == scores.count
                || phat.index == 0 || phat.index + 1 == scores.count { status = "edgePeak" }
            else if abs(offset - phatOffset) > fitToleranceSeconds
                || (whitened[phat.index] >= 0 ? 1 : -1) != polarity { status = "inconsistentMethods" }
            evidence.append(DelayEvidence(
                station: station, attempt: attempt, targetCenter: targetCenter, status: status,
                offsetSeconds: offset, nccScore: peak.value, nccSecond: peak.second,
                phatOffsetSeconds: phatOffset, phatPeakRatio: phatRatio, method: fineMethod, polarity: polarity
            ))
        }
        return evidence
    }

    public static func finish(
        startSeconds: Double, endSeconds: Double,
        attempts: [DelayEvidence], expectedStations: Int = stationCount, sharedSilentStations: [Int] = []
    ) throws -> AutomaticAlignmentResult {
        guard (5...stationCount).contains(expectedStations), attempts.count <= stationCount * 9,
              sharedSilentStations.allSatisfy({ (0..<expectedStations).contains($0) }),
              startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds,
              attempts.allSatisfy({ $0.targetCenter.isFinite && $0.nccScore.isFinite
                  && $0.nccSecond.isFinite && ($0.offsetSeconds?.isFinite ?? true) }) else {
            throw AlignEstimateError.invalidParameter("automatic alignment evidence")
        }
        var selected: [DelayEvidence] = []
        for station in 0..<expectedStations {
            let candidates = attempts.filter { $0.station == station }
            let boundary = station == 0 ? candidates.first : station == expectedStations - 1 ? candidates.last : nil
            if let boundary, boundary.status == "eligible" {
                selected.append(boundary)
            } else if let best = candidates.max(by: {
                ($0.status == "eligible" ? 10 : 0) + $0.weight < ($1.status == "eligible" ? 10 : 0) + $1.weight
            }) { selected.append(best) }
            if sharedSilentStations.contains(station), !candidates.contains(where: { $0.status == "eligible" }) {
                selected.removeAll { $0.station == station }
                selected.append(DelayEvidence(station: station, attempt: 0,
                                              targetCenter: startSeconds + (endSeconds - startSeconds) * (Double(station) + 0.5) / Double(expectedStations),
                                              status: "sharedSilence", offsetSeconds: nil, nccScore: 0, nccSecond: 0,
                                              phatOffsetSeconds: nil, phatPeakRatio: nil, method: "whole-track-silence"))
            }
        }
        func result(_ reason: AbstentionReason, _ detail: String, flags: [String] = []) -> AutomaticAlignmentResult {
            AutomaticAlignmentResult(proposal: nil, abstention: AutomaticAbstention(reason: reason, detail: detail), windows: selected, attempts: attempts, startSeconds: startSeconds, endSeconds: endSeconds, spanFraction: 0, expectedStations: expectedStations, flags: flags)
        }
        let eligible = selected.filter { $0.status == "eligible" }
        var missingRun = 0
        for station in 0..<expectedStations {
            let status = selected.first { $0.station == station }?.status
            missingRun = status == "eligible" || status == "sharedSilence" ? 0 : missingRun + 1
            if missingRun >= 2 {
                return result(.insufficientCoverage, "Consecutive distributed regions have no reliable shared timing. This is insufficient coverage, not a measured restart. Choose another speaker or place anchors across the unmeasured region.")
            }
        }
        guard eligible.count >= ProvisionalClockGates.minimumWindows else {
            return result(.insufficientCoverage, "Only \(eligible.count) of \(expectedStations) distributed regions supplied precise, unambiguous delays. Weak, silent and competing matches are inconclusive, not evidence of a restart. Try a different shared speaker or place anchors.")
        }
        switch RobustFit.fit(eligible) {
        case .failure(let reason):
            return result(reason, reason == .discontinuous
                ? "Reliable delays change together in a sustained region. Declare a recorder restart or place anchors; a single affine map cannot bridge it."
                : "Distributed delay evidence supports competing or inconsistent timing. Place anchors; no region was silently discarded.",
                          flags: reason == .discontinuous ? ["discontinuity"] : [])
        case .success(let fit):
            let contradictory = Set(attempts.filter {
                $0.status == "eligible" && abs(($0.offsetSeconds ?? .infinity) - fit.offset(at: $0.targetCenter)) > fitToleranceSeconds
            }.map(\.station))
            if (0..<expectedStations - 1).contains(where: { contradictory.contains($0) && contradictory.contains($0 + 1) }) {
                return result(.discontinuous, "Fresh precise matches contradict the fitted timing in consecutive regions. A single affine map cannot safely bridge these measurements.", flags: ["discontinuity"])
            }
            let inliers = eligible.filter { abs(($0.offsetSeconds ?? .infinity) - fit.offset(at: $0.targetCenter)) <= fitToleranceSeconds }
            let fraction = Double(inliers.count) / Double(expectedStations)
            let first = inliers.map(\.targetCenter).min() ?? endSeconds
            let last = inliers.map(\.targetCenter).max() ?? startSeconds
            let span = min(1, max(0, (last - first + windowSeconds) / (endSeconds - startSeconds)))
            guard fraction >= ProvisionalClockGates.minimumEligibleWindowFraction, span >= ProvisionalClockGates.minimumOverlapSpanFraction else {
                return result(.insufficientCoverage, "\(inliers.count)/\(expectedStations) regions agree, spanning \(Int(span * 100))% of the overlap; at least 60% of regions and 80% span are required. Add anchors near the ends or select more shared audio.")
            }
            guard abs(fit.slope * 1e6) <= maximumPPM else { return result(.implausibleDrift, "The measured rate difference exceeds 500 ppm. Check recorder epochs and place anchors.") }
            let residuals = inliers.map { abs(($0.offsetSeconds ?? 0) - fit.offset(at: $0.targetCenter)) * 1000 }.sorted()
            let p95 = residuals[max(0, Int(ceil(0.95 * Double(residuals.count))) - 1)]
            let maximum = residuals.last ?? 0
            let a = Int64(1_000_000_000) + Int64((fit.slope * 1e9).rounded())
            let b = fit.offset(at: 0)
            guard b.isFinite, abs(b) < 9e9, startSeconds.isFinite, endSeconds.isFinite,
                  startSeconds >= 0, endSeconds > startSeconds, endSeconds < 9e9 else {
                throw AlignEstimateError.invalidParameter("automatic alignment domain")
            }
            let segment = try AffineClockSegment(
                groupClockStart: ExactRational(Int64((startSeconds * 1e9).rounded()), 1_000_000_000),
                groupClockEnd: ExactRational(Int64((endSeconds * 1e9).rounded()), 1_000_000_000),
                rateRatio: ExactRational(a, 1_000_000_000), alignedOffset: ExactRational(Int64((b * 1e9).rounded()), 1_000_000_000)
            )
            let measurements = try AcousticConsistencyMeasurements(
                windowCount: inliers.count, overlapSpanFraction: span, eligibleWindowFraction: fraction,
                acousticResidualP95Milliseconds: p95, acousticResidualMaxMilliseconds: maximum
            )
            let provenance = try AcousticConsistencyProposal(estimator: identifier, evidenceScore: Statistics.median(inliers.map(\.nccScore)), measurements: measurements)
            let proposal = AutomaticProposal(
                segment: segment, ppm: fit.slope * 1e6, offsetAtCenterSeconds: fit.offset(at: (startSeconds + endSeconds) / 2),
                acousticResidualP95Milliseconds: p95, acousticResidualMaxMilliseconds: maximum, provenance: provenance
            )
            for index in selected.indices where selected[index].status == "eligible"
                && !inliers.contains(selected[index]) { selected[index].status = "outlier" }
            return AutomaticAlignmentResult(proposal: proposal, abstention: nil, windows: selected, attempts: attempts, startSeconds: startSeconds, endSeconds: endSeconds, spanFraction: span, expectedStations: expectedStations, flags: [])
        }
    }
}
