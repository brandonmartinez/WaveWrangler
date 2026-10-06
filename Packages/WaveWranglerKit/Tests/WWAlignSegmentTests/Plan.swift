import Foundation

/// Calibration strata. Positives plant discontinuities with independent truth; negatives must not split.
enum SegmentStratum: String, CaseIterable, Sendable {
    /// NEGATIVE: one smooth clock, no discontinuity.
    case clean
    /// NEAR-MISS NEGATIVE: strong clicks and noise bursts only the target hears.
    case transient
    /// NEAR-MISS NEGATIVE: 3 - 8 s without shared sound (scene silent, or the target muted); no clock change.
    case silenceGap
    /// Dropped samples (5 - 500 ms, whole frames).
    case dropped
    /// Inserted samples (5 - 500 ms of noise or a repeat of the preceding frames).
    case inserted
    /// A clock step of ±5 - 500 ms (fractional frames).
    case clockStep
    /// A recorder restart: 0.3 - 1.2 s pause and a new rate (±100 ppm), within one declared span.
    case restart
    /// A mid-file rate change of 300 - 400 ppm.
    case rateChange
    /// Two of the above at least 15 s apart.
    case compound

    var isNegative: Bool { self == .clean || self == .transient || self == .silenceGap }

    var plantKind: PlantKind? {
        switch self {
        case .dropped: .dropped
        case .inserted: .inserted
        case .clockStep: .clockStep
        case .restart: .restart
        case .rateChange: .rateChange
        case .clean, .transient, .silenceGap, .compound: nil
        }
    }
}

/// Floor-sweep override: a fixed planted size instead of the stratum's random range (reported, not gated).
enum PlantOverride: Sendable {
    case clockStep(seconds: Double)
    case rateChange(ppm: Double)
}

enum SegmentPlan {
    /// Revision-2 calibration master seed, disjoint from the failed revision-1 holdout.
    static let calibrationMasterSeed: UInt64 = 0x5757_1700_CA12_B000
    static let counts: [(SegmentStratum, Int)] = [
        (.clean, 6), (.transient, 15), (.silenceGap, 15),
        (.dropped, 6), (.inserted, 6), (.clockStep, 6), (.restart, 6), (.rateChange, 6), (.compound, 4),
    ]
    /// FROZEN by m2-freeze-discontinuity-2 (docs/m2/fixtures/m2-freeze-discontinuity-2.json): the holdout master
    /// seed ("WW17401D" = WW-017 holdout) and counts. Only `HoldoutTests` uses them, and only when explicitly
    /// enabled; no holdout case is rendered or segmented by calibration, unit or CI runs.
    static let holdoutMasterSeed: UInt64 = 0x5757_1700_401D_2000
    static let holdoutCounts: [(SegmentStratum, Int)] = [
        (.clean, 20), (.transient, 15), (.silenceGap, 15),
        (.dropped, 20), (.inserted, 20), (.clockStep, 20), (.restart, 20), (.rateChange, 20), (.compound, 15),
    ]
    /// Revision-2 floor-sweep master seed; disjoint from calibration and both holdouts.
    static let floorMasterSeed: UInt64 = 0x5757_1700_F200_0000
    static let floorSteps: [Double] = [0.00025, 0.0005, 0.001, 0.002, 0.005]
    static let floorPPM: [Double] = [25, 50, 100, 200, 300]
    static let floorRepeats = 2

    /// Calibration gate on the negatives' false-split rate (see the evidence note).
    static let maximumFalseSplitRate = 0.0

    static let lengthRange: ClosedRange<Double> = 50...70
    static let plantMargin = 8.0
    static let compoundSeparation = 15.0
    static let searchDeviation = 2.5

    static func cases(master: UInt64 = calibrationMasterSeed, counts: [(SegmentStratum, Int)] = counts) -> [SegmentCase] {
        counts.flatMap { stratum, count in (0..<count).map { make(stratum, index: $0, master: master) } }
    }

    /// Case seeds only (nothing rendered), to prove the calibration, floor and holdout sets are disjoint.
    static func seeds(master: UInt64, counts: [(SegmentStratum, Int)]) -> [UInt64] {
        counts.flatMap { stratum, count in (0..<count).map { SplitMix64.caseSeed(master: master, stratum: stratum.rawValue, index: $0) } }
    }

    static func floorCases() -> [(label: String, kase: SegmentCase)] {
        var result: [(String, SegmentCase)] = []
        for step in floorSteps {
            for sign in [1.0, -1.0] {
                for r in 0..<floorRepeats {
                    let index = result.count
                    result.append(("step \(sign * step * 1000) ms #\(r)", make(.clockStep, index: index, master: floorMasterSeed, override: .clockStep(seconds: sign * step))))
                }
            }
        }
        for ppm in floorPPM {
            for r in 0..<floorRepeats {
                let index = result.count
                result.append(("rate \(ppm) ppm #\(r)", make(.rateChange, index: index, master: floorMasterSeed, override: .rateChange(ppm: ppm))))
            }
        }
        return result
    }

    static func make(_ stratum: SegmentStratum, index: Int, master: UInt64, override: PlantOverride? = nil, length fixedLength: Double? = nil) -> SegmentCase {
        let seed = SplitMix64.caseSeed(master: master, stratum: stratum.rawValue, index: index)
        var rng = SplitMix64(seed: seed)
        let drawnLength = rng.uniform(lengthRange)
        let length = fixedLength ?? drawnLength
        let rate = rng.bool() ? 8000 : 16000
        let f = Double(rate)
        let frameCount = Int((length * f).rounded())
        let ppm = rng.uniform(-100...100)
        let offset = rng.uniform(-0.3...0.3)
        var scene = Scene.random(&rng, range: -4...(length + 6))
        var hearings = [TrackRender(scene: scene, gain: rng.uniform(0.5...1.5), delay: rng.uniform(0...0.001))]
        var mute: Range<Int>?

        // Plants (frames), in order.
        var kinds: [PlantKind] = []
        var positions: [Double] = []
        switch stratum {
        case .clean:
            break
        case .transient:
            let extra = Scene.transients(&rng, range: 2...(length - 2), count: Int(rng.uniform(4...8.99)))
            hearings.append(TrackRender(scene: extra, gain: 1, delay: 0))
        case .silenceGap:
            let duration = rng.uniform(3...8)
            let start = rng.uniform(10...(length - 10 - duration))
            if rng.bool() {
                // Scene silent: the scene time window corresponding to [start, start + duration] of the target.
                let t0 = (1 + ppm * 1e-6) * start + offset
                scene = scene.removing(t0...(t0 + duration))
                hearings[0] = TrackRender(scene: scene, gain: hearings[0].gain, delay: hearings[0].delay)
            } else {
                mute = Int(start * f)..<Int((start + duration) * f)
            }
        case .compound:
            for _ in 0..<2 { kinds.append(PlantKind.allCases[Int(rng.next() % UInt64(PlantKind.allCases.count))]) }
            let p1 = rng.uniform(plantMargin...(length - plantMargin - compoundSeparation))
            let p2 = rng.uniform((p1 + compoundSeparation)...(length - plantMargin))
            positions = [p1, p2]
        default:
            kinds = [stratum.plantKind!]
            positions = [rng.uniform(plantMargin...(length - plantMargin))]
        }

        var plants: [Plant] = []
        var restartPPM: [Double] = []
        var currentPPM = ppm
        for (kind, position) in zip(kinds, positions) {
            let frame = Int((position * f).rounded())
            let a = 1 + currentPPM * 1e-6
            switch kind {
            case .dropped:
                let dropped = max(1, Int((rng.logUniform(0.005...0.5) * f).rounded()))
                plants.append(Plant(kind: .dropped, frame: frame, inserted: nil, stepSeconds: a * Double(dropped) / f, deltaPPM: 0, repeatsContent: false))
            case .inserted:
                let count = max(1, Int((rng.logUniform(0.005...0.5) * f).rounded()))
                let repeats = rng.bool()
                plants.append(Plant(kind: .inserted, frame: frame, inserted: frame..<(frame + count), stepSeconds: -a * Double(count) / f, deltaPPM: 0, repeatsContent: repeats))
            case .clockStep:
                var step = rng.logUniform(0.005...0.5) * (rng.bool() ? 1 : -1)
                if case .clockStep(let s)? = override { step = s }
                plants.append(Plant(kind: .clockStep, frame: frame, inserted: nil, stepSeconds: step, deltaPPM: 0, repeatsContent: false))
            case .restart:
                let pause = rng.uniform(0.3...1.2)
                let newPPM = rng.uniform(-100...100)
                restartPPM.append(newPPM)
                plants.append(Plant(kind: .restart, frame: frame, inserted: nil, stepSeconds: pause, deltaPPM: newPPM - currentPPM, repeatsContent: false))
                currentPPM = newPPM
            case .rateChange:
                var delta = rng.uniform(300...400) * (currentPPM > 0 ? -1 : (currentPPM < 0 ? 1 : (rng.bool() ? 1 : -1)))
                if case .rateChange(let d)? = override { delta = d * (currentPPM > 0 ? -1 : 1) }
                plants.append(Plant(kind: .rateChange, frame: frame, inserted: nil, stepSeconds: 0, deltaPPM: delta, repeatsContent: false))
                currentPPM += delta
            }
        }
        // Inserted frames lengthen the occurrence: the file keeps `length` seconds of recorded frames plus them.
        let insertedTotal = plants.compactMap(\.inserted).map(\.count).reduce(0, +)
        var shifted: [Plant] = []
        var shift = 0
        for plant in plants {
            let frame = plant.frame + shift
            let inserted = plant.inserted.map { (frame)..<(frame + $0.count) }
            shifted.append(Plant(kind: plant.kind, frame: frame, inserted: inserted, stepSeconds: plant.stepSeconds, deltaPPM: plant.deltaPPM, repeatsContent: plant.repeatsContent))
            shift += plant.inserted?.count ?? 0
        }
        let truth = OccurrenceTruth.build(rate: rate, frameCount: frameCount + insertedTotal, ppm: ppm, offset: offset, plants: shifted, restartPPM: restartPPM)
        return SegmentCase(
            stratum: stratum, index: index, seed: seed, lengthSeconds: length, truth: truth, plants: shifted, scene: scene,
            target: hearings, mute: mute, referenceNoise: rng.uniform(0.003...0.008), targetNoise: rng.uniform(0.003...0.01),
            referenceNoiseSeed: rng.next(), targetNoiseSeed: rng.next(), searchDeviation: searchDeviation)
    }
}
