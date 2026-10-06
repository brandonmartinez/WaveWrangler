import Foundation
import WWAlignEstimate
import WWCore
import WWTimeMap

/// Calibration strata. `expectation` is what the estimator must do; scoring is always against clock truth.
enum Stratum: String, CaseIterable, Sendable {
    /// Clock offset/drift with a sub-millisecond constant acoustic path.
    case positive
    /// One target group with two declared epochs (restart), estimated independently.
    case positiveRestart
    /// Two target groups, so the cycle (reference, i, j) is measured.
    case positiveThreeGroup
    /// NEGATIVE: constant 35 ms acoustic delay (the failed research candidate's first false accept).
    case constantDelay
    /// NEGATIVE: acoustic delay ramping 20 -> 50 ms plus a 0.3 ms wobble (the second false accept).
    case variableDelay
    /// NEGATIVE: undeclared 40 ms clock step mid-recording.
    case discontinuity
    /// NEGATIVE: the target hears a different scene.
    case unrelated
    /// NEGATIVE: the target is silent (noise floor only).
    case silent
    /// NEGATIVE: both hear the same pattern repeated every 0.2 - 1.8 s.
    case periodic
    /// NEGATIVE: the target epoch starts 135 - 200 s into the group clock, beyond the reference plus the search
    /// (the reference ends at 126 s), and hears activity the reference never recorded.
    case disconnected
    /// MECHANISM: two sources; recorders i and j share a delayed second source the reference never hears,
    /// so the direct i-j measurement disagrees with the reference path by 20 ms. Proposals must abstain.
    case cycleConflict

    enum Expectation: Sendable { case clockTruthWithinGates, acousticOnly, noProposal }

    var expectation: Expectation {
        switch self {
        case .positive, .positiveRestart, .positiveThreeGroup: .clockTruthWithinGates
        case .constantDelay, .variableDelay: .acousticOnly
        case .discontinuity, .unrelated, .silent, .periodic, .disconnected, .cycleConflict: .noProposal
        }
    }

    var isNegative: Bool {
        switch self {
        case .constantDelay, .variableDelay, .discontinuity, .unrelated, .silent, .periodic, .disconnected: true
        default: false
        }
    }
}

struct TargetEpoch: Sendable {
    let groupIndex: Int
    let recipe: TrackRecipe
    /// Declared overlap in seconds after the track's sample 0.
    let overlapSeconds: ClosedRange<Double>
}

struct CalibrationCase: Sendable {
    let stratum: Stratum
    let index: Int
    let seed: UInt64
    let reference: TrackRecipe
    let targets: [TargetEpoch]
}

enum CalibrationPlan {
    /// Calibration master seed ("WW16CA11B" = WW-016 calibration).
    static let calibrationMasterSeed: UInt64 = 0x5757_1600_CA11_B000
    static let counts: [(Stratum, Int)] = [
        (.positive, 12), (.positiveRestart, 2), (.positiveThreeGroup, 2),
        (.constantDelay, 3), (.variableDelay, 3), (.discontinuity, 3), (.unrelated, 3), (.silent, 2), (.periodic, 3),
        (.disconnected, 2), (.cycleConflict, 2),
    ]
    /// FROZEN by m2-freeze-estimator (docs/m2/fixtures/m2-freeze-estimator.json): the holdout master seed
    /// ("WW16401D" = WW-016 holdout) and counts. Only `HoldoutTests` uses them, and only when explicitly
    /// enabled; no holdout case is rendered or estimated by calibration, unit or CI runs.
    static let holdoutMasterSeed: UInt64 = 0x5757_1600_401D_0000
    static let holdoutCounts: [(Stratum, Int)] = [
        (.positive, 40), (.positiveRestart, 10), (.positiveThreeGroup, 10),
        (.constantDelay, 10), (.variableDelay, 10), (.discontinuity, 10), (.unrelated, 10), (.silent, 10), (.periodic, 10),
        (.disconnected, 10), (.cycleConflict, 10),
    ]
    static let referenceDuration = 126.0
    static let targetDuration = 120.0
    static let sceneRange: ClosedRange<Double> = -5...135
    static let searchDeviation = 2.0

    static func cases(master: UInt64 = calibrationMasterSeed, counts: [(Stratum, Int)] = counts) -> [CalibrationCase] {
        counts.flatMap { stratum, count in (0..<count).map { make(stratum, index: $0, master: master) } }
    }

    /// Case seeds only (nothing rendered), to prove the calibration and holdout sets are disjoint.
    static func seeds(master: UInt64, counts: [(Stratum, Int)]) -> [UInt64] {
        counts.flatMap { stratum, count in (0..<count).map { SplitMix64.caseSeed(master: master, stratum: stratum.rawValue, index: $0) } }
    }

    static func make(_ stratum: Stratum, index: Int, master: UInt64) -> CalibrationCase {
        let seed = SplitMix64.caseSeed(master: master, stratum: stratum.rawValue, index: index)
        var rng = SplitMix64(seed: seed)
        let scene = stratum == .periodic
            ? Scene.periodic(&rng, range: sceneRange, period: rng.uniform(0.2...1.8))
            : Scene.random(&rng, range: sceneRange)
        let reference = TrackRecipe(sampleRate: 8000, duration: referenceDuration, groupClockStart: 0, truth: ClockTruth(ppm: 0, offset: 0),
                                    hearings: [Hearing(scene: scene, gain: 1, delay: .none)], noiseRMS: rng.uniform(0.003...0.008), noiseSeed: rng.next())

        func truth(_ rng: inout SplitMix64) -> ClockTruth { ClockTruth(ppm: rng.uniform(-100...100), offset: rng.uniform(-1.5...1.5)) }
        func rate(_ rng: inout SplitMix64) -> Int { rng.bool() ? 8000 : 16000 }
        func target(_ rng: inout SplitMix64, truth t: ClockTruth, hearings: [Hearing], start: Double = 0, duration: Double = targetDuration, noise: Double? = nil) -> TrackRecipe {
            TrackRecipe(sampleRate: rate(&rng), duration: duration, groupClockStart: start, truth: t, hearings: hearings,
                        noiseRMS: noise ?? rng.uniform(0.003...0.01), noiseSeed: rng.next())
        }
        func smallDelay(_ rng: inout SplitMix64) -> DelayModel { .constant(rng.uniform(0...0.001)) }
        let overlap: ClosedRange<Double> = 3...(targetDuration - 3)

        var targets: [TargetEpoch] = []
        switch stratum {
        case .positive:
            let t = truth(&rng)
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: smallDelay(&rng))]), overlapSeconds: overlap)]
        case .positiveRestart:
            for start in [0.0, 62.0] {
                let t = truth(&rng)
                let recipe = target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: smallDelay(&rng))], start: start, duration: 58)
                targets.append(TargetEpoch(groupIndex: 1, recipe: recipe, overlapSeconds: 2...56))
            }
        case .positiveThreeGroup:
            for group in 1...2 {
                let t = truth(&rng)
                targets.append(TargetEpoch(groupIndex: group, recipe: target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: smallDelay(&rng))]), overlapSeconds: overlap))
            }
        case .constantDelay:
            let t = truth(&rng)
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: .constant(0.035))]), overlapSeconds: overlap)]
        case .variableDelay:
            let t = truth(&rng)
            let ramp = DelayModel.ramp(from: 0.020, to: 0.050, u0: 0, u1: targetDuration, wobble: 0.0003, wobblePeriod: rng.uniform(25...45))
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: ramp)]), overlapSeconds: overlap)]
        case .discontinuity:
            var t = truth(&rng)
            t.step = (at: rng.uniform(40...80), amount: rng.bool() ? 0.040 : -0.040)
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: smallDelay(&rng))]), overlapSeconds: overlap)]
        case .unrelated:
            let other = Scene.random(&rng, range: sceneRange)
            let t = truth(&rng)
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: other, gain: rng.uniform(0.5...1.5), delay: .none)]), overlapSeconds: overlap)]
        case .silent:
            let t = truth(&rng)
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [], noise: 1e-6), overlapSeconds: overlap)]
        case .periodic:
            let t = truth(&rng)
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: scene, gain: rng.uniform(0.5...1.5), delay: .none)]), overlapSeconds: overlap)]
        case .disconnected:
            let t = truth(&rng)
            let start = rng.uniform(135...200).rounded(.down)
            // The target hears a later stretch of activity the reference never recorded.
            let later = Scene.random(&rng, range: (start - 5)...(start + targetDuration + 5))
            targets = [TargetEpoch(groupIndex: 1, recipe: target(&rng, truth: t, hearings: [Hearing(scene: later, gain: rng.uniform(0.5...1.5), delay: smallDelay(&rng))], start: start), overlapSeconds: overlap)]
        case .cycleConflict:
            let second = Scene.random(&rng, range: sceneRange)
            for (group, secondDelay) in [(1, 0.0), (2, 0.020)] {
                let t = truth(&rng)
                let hearings = [Hearing(scene: scene, gain: 1, delay: .none), Hearing(scene: second, gain: 1.6, delay: .constant(secondDelay))]
                targets.append(TargetEpoch(groupIndex: group, recipe: target(&rng, truth: t, hearings: hearings, noise: 0.003), overlapSeconds: overlap))
            }
        }
        return CalibrationCase(stratum: stratum, index: index, seed: seed, reference: reference, targets: targets)
    }
}

/// One rendered + estimated case, scored against clock truth.
struct ScoredEpoch: Sendable {
    let stratum: Stratum
    let caseIndex: Int
    let estimate: EpochEstimate
    let truth: ClockTruth
    /// Clock-truth residuals of the proposal on a 1 s grid over the declared overlap, ms. Empty if abstained.
    let clockResidualsMs: [Double]
}

enum CalibrationRunner {
    static func run(_ c: CalibrationCase, parameters: EstimatorParameters = EstimatorParameters()) throws -> [ScoredEpoch] {
        let groups = (0...3).map { _ in RecorderGroupID() }
        let reference = EstimatorTrack(group: groups[0], epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                                       buffer: try SampleBuffer(samples: c.reference.render(), sampleRate: c.reference.sampleRate))
        var truths: [RecordingEpochID: ClockTruth] = [:]
        var tracks: [EstimatorTrack] = []
        for target in c.targets {
            let recipe = target.recipe
            let rate = Double(recipe.sampleRate)
            let lo = Int((target.overlapSeconds.lowerBound * rate).rounded())
            let hi = Int((target.overlapSeconds.upperBound * rate).rounded())
            let epoch = RecordingEpochID()
            truths[epoch] = recipe.truth
            tracks.append(EstimatorTrack(group: groups[target.groupIndex], epoch: epoch, occurrence: SourceOccurrenceID(),
                                         groupClockStart: ExactRational(Int64(recipe.groupClockStart)),
                                         buffer: try SampleBuffer(samples: recipe.render(), sampleRate: recipe.sampleRate), declaredOverlap: lo..<hi))
        }
        let report = try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: tracks, search: try SearchRange(maximumDeviationSeconds: CalibrationPlan.searchDeviation)), parameters: parameters)
        return report.epochs.map { estimate in
            let truth = truths[estimate.epoch]!
            return ScoredEpoch(stratum: c.stratum, caseIndex: c.index, estimate: estimate, truth: truth, clockResidualsMs: clockResiduals(estimate, truth: truth))
        }
    }

    /// |proposal(u) - truth(u)| in ms at every whole second of the declared overlap plus both ends.
    static func clockResiduals(_ estimate: EpochEstimate, truth: ClockTruth) -> [Double] {
        guard case .acousticConsistentProposal(let proposal) = estimate.outcome else { return [] }
        let a = proposal.segment.rateRatio.approximateDouble, b = proposal.segment.alignedOffset.approximateDouble
        let u0 = proposal.segment.groupClockStart.approximateDouble, u1 = proposal.segment.groupClockEnd.approximateDouble
        var grid = [u0]
        var u = u0.rounded(.down) + 1
        while u < u1 { grid.append(u); u += 1 }
        grid.append(u1)
        return grid.map { abs(a * $0 + b - truth.aligned($0)) * 1000 }
    }
}

enum Percentile {
    /// Nearest-rank: the value at 1-based rank ceil(p * n) of the sorted values.
    static func nearestRank(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(1, Int((p * Double(sorted.count)).rounded(.up))) - 1]
    }
}
