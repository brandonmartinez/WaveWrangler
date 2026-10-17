import Foundation
import WWAlignEstimate

public struct TemporalCorroboration: Sendable, Equatable, Codable {
    public struct Energy: Sendable, Equatable, Codable {
        public let targetRMS: Double
        public let referenceRMS: Double
        public let targetPeak: Double
        public let referencePeak: Double

        var isValid: Bool {
            [targetRMS, referenceRMS, targetPeak, referencePeak].allSatisfy { $0.isFinite && $0 >= 0 }
                && targetRMS <= targetPeak && referenceRMS <= referencePeak
        }
    }

    public let targetCenter: Double
    public let offsetSeconds: Double
    public let score: Double
    public let competingScore: Double
    public let polarity: Int
    /// Nominal reference-rate length; earlier records contain half-second windows.
    public var windowSeconds: Double? = nil
    /// Centered speech-band energy at the full-window relationship, not at a noisy local winner.
    public var energy: Energy? = nil
}

public struct SpectralTimingWitness: Sendable, Equatable, Codable {
    public let status: String
    public let offsetSeconds: Double
    public let nccScore: Double
    public let nccSecond: Double
    public let phatOffsetSeconds: Double
    public let phatPeakRatio: Double
    public let polarity: Int
    public let corroborations: [TemporalCorroboration]
}

extension AdaptiveAlignment {
    public static let fineMethod = "speech-ncc+phat-lag+3-disjoint-ncc/4"
    public static let sequenceMethod = "speech-ncc+phat-lag+canonical-mid-ncc/1"
    public static let quietSequenceMethod = "speech-ncc+phat-lag+canonical-mid-ncc+shared-quiet/1"
    public static let spectralMethod = "speech600-ncc+phat-lag+3-disjoint-ncc+speech150-lag/1"
    public static let shortMethod = "speech-ncc+phat-lag-1s+3-disjoint-quarter+canonical-half/1"

    /// Only the three quarter-second windows count; the overlapping half-second is an output witness.
    static func shortCorroborations(_ point: DelayEvidence) -> [TemporalCorroboration]? {
        guard let checks = point.corroborations, checks.count == 4,
              let offset = point.offsetSeconds, offset.isFinite,
              (0.6...1).contains(point.nccScore), (0...1).contains(point.nccSecond),
              point.nccSecond < 0.8 * point.nccScore,
              let phat = point.phatOffsetSeconds, phat.isFinite,
              abs(phat - offset) <= AutomaticAlignment.fitToleranceSeconds,
              point.phatPeakRatio.map({ (0..<0.8).contains($0) }) == true,
              point.polarity == 1 || point.polarity == -1,
              zip(checks, [-0.375, 0, 0.375, 0]).allSatisfy({
                  $0.targetCenter.isFinite && abs($0.targetCenter - point.targetCenter - $1)
                      <= 1 / Signal.rate + abs($1) * AutomaticAlignment.maximumPPM / (1e6 - AutomaticAlignment.maximumPPM)
                      && $0.offsetSeconds.isFinite && (0.6...1).contains($0.score)
                      && (0...1).contains($0.competingScore) && $0.competingScore < 0.8 * $0.score
                      && $0.polarity == point.polarity
                      && abs($0.offsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds
                      && ($0.energy?.isValid ?? true)
              }),
              checks.prefix(3).allSatisfy({ $0.windowSeconds == 0.25 }),
              checks[3].windowSeconds == 0.5 else { return nil }
        let supports = Array(checks.prefix(3))
        guard zip(supports, supports.dropFirst()).allSatisfy({
            $1.targetCenter - $0.targetCenter >= 0.25 / (1 - AutomaticAlignment.maximumPPM / 1e6)
        }) else { return nil }
        return supports
    }

    static func hasStrongContradiction(_ checks: [TemporalCorroboration], to point: DelayEvidence) -> Bool {
        checks.contains {
            $0.score >= 0.55 && $0.competingScore < 0.8 * $0.score
                && ($0.polarity != point.polarity
                    || abs($0.offsetSeconds - (point.offsetSeconds ?? .infinity)) > AutomaticAlignment.fitToleranceSeconds)
        }
    }

    private static func checkedCorroborations(_ point: DelayEvidence) -> [TemporalCorroboration]? {
        guard let checks = point.corroborations, (3...9).contains(checks.count),
              point.polarity == 1 || point.polarity == -1,
              let offset = point.offsetSeconds, offset.isFinite,
              validCorroborations(checks, center: point.targetCenter),
              !hasStrongContradiction(checks, to: point) else { return nil }
        return checks
    }

    private static func validCorroborations(_ checks: [TemporalCorroboration], center: Double) -> Bool {
        checks.allSatisfy {
            $0.targetCenter.isFinite && abs($0.targetCenter - center) <= 0.751
                && $0.offsetSeconds.isFinite && $0.score.isFinite && $0.competingScore.isFinite
                && (0...1).contains($0.score) && (0...1).contains($0.competingScore)
                && ($0.polarity == 1 || $0.polarity == -1)
                && [0.5, 0.66].contains($0.windowSeconds ?? 0.5)
                && ($0.energy?.isValid ?? true)
        }
    }

    static func spectralCorroborations(_ point: DelayEvidence) -> [TemporalCorroboration]? {
        guard let checks = supportingCorroborations(point), let witness = point.spectralWitness,
              ["inconsistentSubwindows", "inconsistentMethods"].contains(witness.status),
              let offset = point.offsetSeconds, let phat = point.phatOffsetSeconds,
              (0.6...1).contains(point.nccScore), (0...1).contains(point.nccSecond),
              point.nccSecond < 0.8 * point.nccScore,
              point.phatPeakRatio.map({ (0..<0.8).contains($0) }) == true,
              abs(phat - offset) <= AutomaticAlignment.fitToleranceSeconds,
              [witness.offsetSeconds, witness.phatOffsetSeconds].allSatisfy(\.isFinite),
              (0.6...1).contains(witness.nccScore), (0...1).contains(witness.nccSecond),
              witness.nccSecond < 0.8 * witness.nccScore, (0..<0.8).contains(witness.phatPeakRatio),
              witness.polarity == 1 || witness.polarity == -1,
              (3...9).contains(witness.corroborations.count),
              validCorroborations(witness.corroborations, center: point.targetCenter),
              abs(witness.offsetSeconds - witness.phatOffsetSeconds) <= AutomaticAlignment.fitToleranceSeconds,
              abs(witness.offsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds,
              abs(witness.phatOffsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds,
              witness.corroborations[1].score >= 0.6,
              witness.corroborations[1].competingScore < 0.8 * witness.corroborations[1].score,
              (witness.corroborations[1].windowSeconds ?? 0.5) == 0.5,
              abs(witness.corroborations[1].targetCenter - point.targetCenter) <= 1 / Signal.rate,
              abs(witness.corroborations[1].offsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds,
              !witness.corroborations.contains(where: {
                  $0.score >= 0.55 && $0.competingScore < 0.8 * $0.score
                      && abs($0.offsetSeconds - offset) > AutomaticAlignment.fitToleranceSeconds
              }) else { return nil }
        return checks
    }

    /// Each complete grid must stand alone; overlapping attempts from different grids never pool.
    static func supportingCorroborations(_ point: DelayEvidence) -> [TemporalCorroboration]? {
        guard let checks = checkedCorroborations(point), [3, 6, 9].contains(checks.count),
              let offset = point.offsetSeconds else { return nil }
        for start in stride(from: 0, to: checks.count, by: 3) {
            let grid = Array(checks[start..<start + 3]).sorted { $0.targetCenter < $1.targetCenter }
            let seconds = grid[0].windowSeconds ?? 0.5
            guard grid.allSatisfy({
                $0.score >= 0.55 && $0.competingScore < 0.8 * $0.score
                    && $0.polarity == point.polarity
                    && abs($0.offsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds
                    && ($0.windowSeconds ?? 0.5) == seconds
            }),
            zip(grid, grid.dropFirst()).allSatisfy({
                $1.targetCenter - $0.targetCenter >= seconds / (1 - AutomaticAlignment.maximumPPM / 1e6)
            }) else { continue }
            return grid
        }
        return nil
    }

    /// One individually sufficient canonical window, never three supports from its overlapping context.
    static func sequenceCorroboration(
        _ point: DelayEvidence, allowingSharedQuiet: Bool = false
    ) -> TemporalCorroboration? {
        guard let checks = checkedCorroborations(point), let offset = point.offsetSeconds,
              (0.6...1).contains(point.nccScore), (0...1).contains(point.nccSecond),
              point.nccSecond < 0.8 * point.nccScore,
              let phatRatio = point.phatPeakRatio, (0..<0.8).contains(phatRatio),
              let phat = point.phatOffsetSeconds, phat.isFinite,
              abs(phat - offset) <= AutomaticAlignment.fitToleranceSeconds,
              zip(checks.prefix(3), [-0.75, 0, 0.75]).allSatisfy({
                  ($0.windowSeconds ?? 0.5) == 0.5
                      && abs($0.targetCenter - point.targetCenter - $1) <= 0.001
              }) else { return nil }
        let middle = checks[1]
        func sharedQuiet(_ check: TemporalCorroboration) -> Bool {
            guard allowingSharedQuiet, let energy = check.energy, let anchor = middle.energy,
                  anchor.targetRMS > 0, anchor.referenceRMS > 0 else { return false }
            return energy.targetRMS < 1e-4 && energy.referenceRMS < 1e-4
                && energy.targetRMS <= anchor.targetRMS * sqrt(0.001)
                && energy.referenceRMS <= anchor.referenceRMS * sqrt(0.001)
                && energy.targetPeak <= anchor.targetPeak * 0.1
                && energy.referencePeak <= anchor.referencePeak * 0.1
        }
        guard abs(middle.targetCenter - point.targetCenter) <= 1 / Signal.rate,
              middle.score >= 0.55, middle.competingScore < 0.8 * middle.score,
              middle.polarity == point.polarity,
              abs(middle.offsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds,
              checks.allSatisfy({
                  ($0.score >= 0.55 && $0.polarity == point.polarity
                      && abs($0.offsetSeconds - offset) <= AutomaticAlignment.fitToleranceSeconds)
                      || sharedQuiet($0)
              }) else { return nil }
        return middle
    }

    /// Fresh measurements only. A phase-whitened peak may select the opposite speech-band lobe after
    /// processing; three disjoint, unique signed correlations must independently corroborate its delay.
    public static func measure(
        reference: EstimatorTrack, target: EstimatorTrack, station: Int,
        predictedOffset: Double, deviation: Double, rateRatio: Double = 1
    ) throws -> [DelayEvidence] {
        let broad = try measureBand(reference: reference, target: target, station: station,
            predictedOffset: predictedOffset, deviation: deviation, rateRatio: rateRatio, upperSpeech: false)
        var measured = broad
        if broad.contains(where: {
            ["inconsistentSubwindows", "inconsistentMethods"].contains($0.status) && $0.nccScore >= 0.6
        }) {
            let upper = try measureBand(reference: reference, target: target, station: station,
                predictedOffset: predictedOffset, deviation: deviation, rateRatio: rateRatio, upperSpeech: true)
            guard upper.count == broad.count else {
                throw AlignEstimateError.invalidParameter("spectral measurements changed the source window grid")
            }
            measured = zip(broad, upper).map { original, candidate in
                guard ["inconsistentSubwindows", "inconsistentMethods"].contains(original.status),
                      candidate.status == "eligible", candidate.method == fineMethod,
                      let offset = original.offsetSeconds, let phat = original.phatOffsetSeconds,
                      let ratio = original.phatPeakRatio, let polarity = original.polarity else { return original }
                let measured = DelayEvidence(
                    station: candidate.station, attempt: candidate.attempt, targetCenter: candidate.targetCenter,
                    status: candidate.status, offsetSeconds: candidate.offsetSeconds, nccScore: candidate.nccScore,
                    nccSecond: candidate.nccSecond, phatOffsetSeconds: candidate.phatOffsetSeconds,
                    phatPeakRatio: candidate.phatPeakRatio, method: spectralMethod, polarity: candidate.polarity,
                    corroborations: candidate.corroborations, spectralWitness: SpectralTimingWitness(
                        status: original.status, offsetSeconds: offset, nccScore: original.nccScore,
                        nccSecond: original.nccSecond, phatOffsetSeconds: phat, phatPeakRatio: ratio,
                        polarity: polarity, corroborations: original.corroborations ?? [])
                )
                return spectralCorroborations(measured) != nil ? measured : original
            }
        }
        let refused = ["inconsistentSubwindows", "inconsistentMethods", "ambiguous", "weak"]
        func needsShorterWindow(_ point: DelayEvidence) -> Bool {
            refused.contains(point.status) || (point.status == "eligible" && point.nccScore < 0.6)
        }
        guard measured.contains(where: needsShorterWindow) else { return measured }
        let shorter = try measureBand(reference: reference, target: target, station: station,
            predictedOffset: predictedOffset, deviation: deviation, rateRatio: rateRatio,
            upperSpeech: false, windowSeconds: 1)
        guard shorter.count == measured.count else {
            throw AlignEstimateError.invalidParameter("short measurements changed the source window grid")
        }
        return try zip(measured, shorter).map { original, candidate in
            guard abs(original.targetCenter - candidate.targetCenter) <= 1 / Signal.rate else {
                throw AlignEstimateError.invalidParameter("short measurement changed the source window center")
            }
            return needsShorterWindow(original) && candidate.status == "eligible"
                && candidate.method == shortMethod && shortCorroborations(candidate) != nil ? candidate : original
        }
    }

    static func measureBand(
        reference: EstimatorTrack, target: EstimatorTrack, station: Int,
        predictedOffset: Double, deviation: Double, rateRatio: Double, upperSpeech: Bool,
        windowSeconds: Double = AutomaticAlignment.windowSeconds
    ) throws -> [DelayEvidence] {
        let full = try AutomaticAlignment.measure(
            reference: reference, target: target, station: station,
            predictedOffset: predictedOffset, deviation: deviation, rateRatio: rateRatio, upperSpeech: upperSpeech,
            windowSeconds: windowSeconds
        )
        let r = try upperSpeech
            ? Signal.upperSpeechBand(Signal(reference.buffer).samples) : Signal.speechBand(Signal(reference.buffer).samples)
        let t = try upperSpeech
            ? Signal.upperSpeechBand(Signal(target.buffer).samples) : Signal.speechBand(Signal(target.buffer).samples)
        return try full.map { observation in
            try Task.checkCancellation()
            var measured = observation
            guard ["eligible", "inconsistentMethods"].contains(observation.status),
                  observation.nccScore >= 0.6, let offset = observation.offsetSeconds,
                  let phat = observation.phatOffsetSeconds,
                  abs(offset - phat) <= AutomaticAlignment.fitToleranceSeconds else { return measured }
            measured = DelayEvidence(
                station: observation.station, attempt: observation.attempt,
                targetCenter: observation.targetCenter, status: "inconsistentSubwindows",
                offsetSeconds: observation.offsetSeconds, nccScore: observation.nccScore,
                nccSecond: observation.nccSecond, phatOffsetSeconds: observation.phatOffsetSeconds,
                phatPeakRatio: observation.phatPeakRatio,
                method: windowSeconds == 1 ? shortMethod : fineMethod, polarity: observation.polarity
            )
            let beginning = observation.targetCenter - windowSeconds / (2 * rateRatio)
            let start = Int(((beginning - target.groupClockStart.approximateDouble) * Signal.rate).rounded())
            func grid(_ positions: [Double], seconds: Double = 0.5) throws -> [TemporalCorroboration] {
                let n = Int(seconds * Signal.rate)
                var checks: [TemporalCorroboration] = []
                for position in positions {
                    try Task.checkCancellation()
                    let at = start + Int((position / rateRatio * Signal.rate).rounded())
                    guard at >= 0, Double(at) + Double(n - 1) / rateRatio < Double(t.count) else { break }
                    let time = target.groupClockStart.approximateDouble + Double(at) / Signal.rate
                    let expected = (time + predictedOffset - reference.groupClockStart.approximateDouble) * Signal.rate
                    let lo = max(0, Int(floor(expected - deviation * Signal.rate)))
                    let hi = min(r.count, Int(ceil(expected + deviation * Signal.rate)) + n + 1)
                    guard hi - lo > n + 2 else { break }
                    let x = Statistics.centered(try Signal.template(t, start: at, count: n, rateRatio: rateRatio))
                    let y = Array(r[lo..<hi])
                    let raw = Transform(atLeast: x.count + y.count).correlation(x, y)
                    let ex = x.reduce(0) { $0 + $1 * $1 }
                    var sum = y.prefix(n).reduce(0, +), energy = y.prefix(n).reduce(0) { $0 + $1 * $1 }
                    var scores = [Double](repeating: 0, count: y.count - n + 1)
                    for lag in scores.indices {
                        let ey = max(0, energy - sum * sum / Double(n))
                        if ex > 1e-12, ey > 1e-12 { scores[lag] = max(-1, min(1, raw[lag] / sqrt(ex * ey))) }
                        if lag + n < y.count {
                            sum += y[lag + n] - y[lag]
                            energy += y[lag + n] * y[lag + n] - y[lag] * y[lag]
                        }
                    }
                    let peak = Statistics.peak(scores.map(abs), exclusion: 20)
                    guard peak.index > 0, peak.index + 1 < scores.count else { break }
                    let center = time + seconds / (2 * rateRatio)
                    let referenceStart = Int(((time + offset
                        + (rateRatio - 1) * (time - observation.targetCenter)
                        - reference.groupClockStart.approximateDouble) * Signal.rate).rounded())
                    guard referenceStart >= 0, referenceStart <= r.count - n else {
                        throw AlignEstimateError.invalidParameter("adaptive context energy outside witnessed reference")
                    }
                    let context = Statistics.centered(Array(r[referenceStart..<referenceStart + n]))
                    checks.append(TemporalCorroboration(
                        targetCenter: center,
                        offsetSeconds: reference.groupClockStart.approximateDouble
                            + (Double(lo) + peak.refined) / Signal.rate + seconds / 2 - center,
                        score: peak.value, competingScore: peak.second, polarity: scores[peak.index] >= 0 ? 1 : -1,
                        windowSeconds: seconds,
                        energy: TemporalCorroboration.Energy(
                            targetRMS: Statistics.rms(x), referenceRMS: Statistics.rms(context),
                            targetPeak: x.reduce(0) { max($0, abs($1)) },
                            referencePeak: context.reduce(0) { max($0, abs($1)) })
                    ))
                }
                return checks
            }
            if windowSeconds == 1 {
                measured.corroborations = try grid([0, 0.375, 0.75], seconds: 0.25)
                    + grid([0.25], seconds: 0.5)
                if shortCorroborations(measured) != nil { measured.status = "eligible" }
                return measured
            }
            var checks = try grid([0, 0.75, 1.5])
            measured.corroborations = checks
            if supportingCorroborations(measured) == nil, !hasStrongContradiction(checks, to: measured) {
                checks += try grid([0.125, 0.75, 1.375])
                measured.corroborations = checks
            }
            if supportingCorroborations(measured) == nil, !hasStrongContradiction(checks, to: measured) {
                checks += try grid([0, 0.67, 1.34], seconds: 0.66)
                measured.corroborations = checks
            }
            if supportingCorroborations(measured) != nil { measured.status = "eligible"; return measured }
            let sequence: String?
            if sequenceCorroboration(measured) != nil {
                sequence = sequenceMethod
            } else if sequenceCorroboration(measured, allowingSharedQuiet: true) != nil {
                sequence = quietSequenceMethod
            } else {
                sequence = nil
            }
            if let sequence {
                return DelayEvidence(
                    station: measured.station, attempt: measured.attempt, targetCenter: measured.targetCenter,
                    status: "eligible", offsetSeconds: measured.offsetSeconds, nccScore: measured.nccScore,
                    nccSecond: measured.nccSecond, phatOffsetSeconds: measured.phatOffsetSeconds,
                    phatPeakRatio: measured.phatPeakRatio, method: sequence,
                    polarity: measured.polarity, corroborations: checks
                )
            }
            if observation.status == "eligible", !hasStrongContradiction(checks, to: measured) {
                var original = observation
                original.corroborations = checks
                return original
            }
            return measured
        }
    }
}
