import CryptoKit
import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

// M2-RENDER-001 calibration of the candidate sample-rate-correction renderer (WW-018 / WW-023 part 1).
//
// Recipe: one recorder group, one 6-channel occurrence on one affine epoch per case; strata cover
// 48k->48k, 44.1k->48k, 16k->48k, 48k->16k, 96k->48k, 12k->48k at a = 1 +- 1000 ppm and two large-ratio
// strata (a ~ 1.02, a ~ 0.98); fractional aligned offset b and group-clock offset e are seeded. A
// separate multi-span case covers segment kinks, gaps, unsupported epochs and two occurrences.
// Truth is the WWTimeMap itself (`sourceFrame` / `alignedTime`), never the render plan.
//
// Gates are `RenderGates` (frozen as m2-freeze-render). The holdout split runs only when
// WW_M2_RENDER_HOLDOUT=1 and has NOT been run: the renderer remains a calibrated candidate, not
// qualified. Listening evaluation is BLOCKED (no consented listeners) and is not measured here.

/// The objective render gates. Frozen at m2-freeze-render (docs/m2/fixtures/m2-freeze-render.json;
/// RenderFreezeTests fails on drift).
enum RenderGates {
    /// Landmark (impulse) position error, output frames.
    static let landmarkFrames = 1.0
    /// Passband deviation, dB, for tones up to `passbandFraction` of the lower Nyquist.
    static let passbandDB = 0.1
    static let passbandFraction = 0.8
    /// In-band residual (images, aliases, interpolation error) and stopband leakage, dBc.
    static let aliasDBc = -80.0
    /// Interchannel skew, output frames.
    static let skewFrames = 1.0
    /// Peak of channels with silent input next to an isolated -1 dBFS channel, dBFS.
    static let inactiveDBFS = -80.0
    /// Passband tone phase error against map truth, degrees. Calibrated in this PR: worst calibration
    /// value 2.76e-6 degrees; frozen as max(10 x worst, 0.001 floor) rounded up on a 1-2-5 series. The
    /// floor keeps Float32 output quantisation from failing the gate; 0.001 degrees at 0.4 cycles per
    /// output frame is 7e-6 output frames.
    static let phaseToleranceDegrees = 0.001
    /// Resident peak of a render family (WW_TIMING_TESTS pass), bytes.
    static let familyPeakBytes = 1 << 30
}

enum RenderFixture {
    static let fixtureID = "M2-RENDER-001"
    static let calibrationCases = 16
    static let holdoutCases = 48
    static let holdoutEnabled = ProcessInfo.processInfo.environment["WW_M2_RENDER_HOLDOUT"] == "1"
    /// The calibration split is CPU-bound for tens of seconds, so it runs in its own serialized pass
    /// (scripts/test.sh) instead of starving the time-limited suites of the parallel package run.
    static let calibrationEnabled = ProcessInfo.processInfo.environment["WW_RENDER_CALIBRATION"] == "1"
    static let recordsDirectory = ProcessInfo.processInfo.environment["WW_RENDER_RECORDS_DIR"]

    static func seed(split: String, index: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m2-fixture|v1|\(fixtureID)|\(split)|\(index)".utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

struct RenderRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// Stateless per-sample noise in [-1, 1).
func noise(_ seed: UInt64, _ frame: Int64) -> Double {
    var rng = RenderRNG(state: seed ^ UInt64(bitPattern: frame) &* 0xD6E8_FEB8_6659_FD93)
    return 2 * rng.unit() - 1
}

struct RenderStratum: Sendable {
    let name: String
    let inputRate: Int64
    let outputRate: Int64
    /// Nominal clock offset from 1, ppm; each case adds a seeded +-1000 ppm.
    let basePPM: Int64

    static let all = [
        RenderStratum(name: "48k->48k", inputRate: 48000, outputRate: 48000, basePPM: 0),
        RenderStratum(name: "44.1k->48k", inputRate: 44100, outputRate: 48000, basePPM: 0),
        RenderStratum(name: "16k->48k", inputRate: 16000, outputRate: 48000, basePPM: 0),
        RenderStratum(name: "48k->16k", inputRate: 48000, outputRate: 16000, basePPM: 0),
        RenderStratum(name: "96k->48k", inputRate: 96000, outputRate: 48000, basePPM: 0),
        RenderStratum(name: "12k->48k", inputRate: 12000, outputRate: 48000, basePPM: 0),
        RenderStratum(name: "48k->44.1k a~1.02", inputRate: 48000, outputRate: 44100, basePPM: 20000),
        RenderStratum(name: "44.1k->48k a~0.98", inputRate: 44100, outputRate: 48000, basePPM: -20000),
    ]
}

/// One flat calibration record (JSON Lines).
struct RenderMeasurement: Codable, Sendable, Equatable {
    var fixture = RenderFixture.fixtureID
    var split: String
    var caseIndex: Int
    var stratum: String
    var inputRate: Int64
    var outputRate: Int64
    var rateRatio: String
    var sourceFramesPerOutputFrame: Double
    /// passband | stopband | landmark-common | landmark-unique | skew-landmark | skew-phase | inactive | active
    var kind: String
    var channel: Int? = nil
    var frequencyFraction: Double? = nil
    var gainDB: Double? = nil
    var residualDBc: Double? = nil
    var phaseErrorDegrees: Double? = nil
    var landmarkErrorFrames: Double? = nil
    var polarityCorrect: Bool? = nil
    var swapDetected: Bool? = nil
    var skewFrames: Double? = nil
    var peakDBFS: Double? = nil
}

struct GateOutcome: Equatable, CustomStringConvertible {
    let gate: String
    let worst: Double
    let limit: Double
    let passed: Bool
    var description: String { "\(gate): worst \(worst) vs \(limit) -> \(passed ? "pass" : "FAIL")" }
}

enum RenderGateEvaluation {
    /// Evaluates every objective gate. A gate with no measurements fails (never passes vacuously).
    static func evaluate(_ records: [RenderMeasurement], phaseTolerance: Double = RenderGates.phaseToleranceDegrees) -> [GateOutcome] {
        func outcome(_ gate: String, _ values: [Double], limit: Double) -> GateOutcome {
            guard let worst = values.max(), !values.contains(where: \.isNaN) else { return GateOutcome(gate: gate, worst: .nan, limit: limit, passed: false) }
            return GateOutcome(gate: gate, worst: worst, limit: limit, passed: worst <= limit)
        }
        let passband = records.filter { $0.kind == "passband" }
        let landmarks = records.filter { $0.kind.hasPrefix("landmark-") }
        return [
            outcome("landmarks", landmarks.compactMap(\.landmarkErrorFrames).map(abs), limit: RenderGates.landmarkFrames),
            outcome("passband", passband.filter { ($0.frequencyFraction ?? .infinity) <= RenderGates.passbandFraction + 1e-12 }.compactMap(\.gainDB).map(abs), limit: RenderGates.passbandDB),
            outcome("alias", records.filter { $0.kind == "passband" || $0.kind == "stopband" }.compactMap(\.residualDBc), limit: RenderGates.aliasDBc),
            outcome("skew", records.filter { $0.kind.hasPrefix("skew-") }.compactMap(\.skewFrames), limit: RenderGates.skewFrames),
            outcome("inversions-swaps", landmarks.isEmpty ? [] : [Double(landmarks.filter { $0.polarityCorrect != true || $0.swapDetected != false }.count)], limit: 0),
            outcome("inactive", records.filter { $0.kind == "inactive" }.compactMap(\.peakDBFS), limit: RenderGates.inactiveDBFS),
            outcome("phase", passband.compactMap(\.phaseErrorDegrees).map(abs), limit: phaseTolerance),
        ]
    }
}

// MARK: - Analysis

enum RenderAnalysis {
    static func dB(_ x: Double) -> Double { 20 * log10(x) }

    /// Least-squares fit of `y` to `g A sin(theta + psi)` over `frames`; returns gain (dB), phase error
    /// psi (degrees) and the residual relative to the fitted carrier (dBc).
    static func fitTone(_ y: [Float], firstFrame: Int64, frames: [Int64], amplitude: Double, theta: (Int64) -> Double) -> (gainDB: Double, phaseDegrees: Double, residualDBc: Double) {
        var sss = 0.0, scc = 0.0, ssc = 0.0, sys = 0.0, syc = 0.0
        for k in frames {
            let t = theta(k)
            let s = amplitude * sin(t)
            let c = amplitude * cos(t)
            let v = Double(y[Int(k - firstFrame)])
            sss += s * s; scc += c * c; ssc += s * c; sys += v * s; syc += v * c
        }
        let det = sss * scc - ssc * ssc
        let alpha = (sys * scc - syc * ssc) / det
        let beta = (syc * sss - sys * ssc) / det
        var residual = 0.0
        for k in frames {
            let t = theta(k)
            let r = Double(y[Int(k - firstFrame)]) - amplitude * (alpha * sin(t) + beta * cos(t))
            residual += r * r
        }
        let gain = (alpha * alpha + beta * beta).squareRoot()
        let carrierRMS = gain * amplitude / 2.squareRoot()
        let residualRMS = (residual / Double(frames.count)).squareRoot()
        return (dB(gain), atan2(beta, alpha) * 180 / .pi, dB(max(residualRMS, 1e-300) / carrierRMS))
    }

    /// Peak near `expected` (output frames): sub-frame position by parabola through |y|, and its sign.
    static func peak(_ y: [Float], firstFrame: Int64, near expected: Double, radius: Int64 = 4) -> (position: Double, value: Float) {
        let center = Int64(expected.rounded())
        var best = center
        for k in center - radius ... center + radius where abs(y[Int(k - firstFrame)]) > abs(y[Int(best - firstFrame)]) { best = k }
        let ym = Double(abs(y[Int(best - 1 - firstFrame)]))
        let y0 = Double(abs(y[Int(best - firstFrame)]))
        let yp = Double(abs(y[Int(best + 1 - firstFrame)]))
        let denominator = ym - 2 * y0 + yp
        let offset = denominator == 0 ? 0 : 0.5 * (ym - yp) / denominator
        return (Double(best) + offset, y[Int(best - firstFrame)])
    }

    static func maxAbs(_ y: some Collection<Float>) -> Float { y.reduce(0) { max($0, abs($1)) } }
}

// MARK: - Cases

/// One seeded calibration case: a 6-channel occurrence on one affine epoch.
struct RenderCase: Sendable {
    static let channelCount = 6
    static let amplitude = 0.5
    static let passbandFractions = [0.02, 0.15, 0.3, 0.5, 0.7, 0.8]

    let split: String
    let index: Int
    let stratum: RenderStratum
    let id = SourceOccurrenceID()
    let map: GroupTimeMap
    let a: ExactRational
    let frames: Int64
    let seed: UInt64
    let toneFractions: [Double]
    let tonePhases: [Double]
    let commonSigns: [Float]
    let uniqueSigns: [Float]

    // Map truth (never the plan): x(k) = xFirst + (k - kFirst) * delta on the hull.
    let kFirst: Int64
    let kLast: Int64
    let xFirst: Double
    let delta: Double

    init(split: String, index: Int) throws {
        self.split = split
        self.index = index
        stratum = RenderStratum.all[index % RenderStratum.all.count]
        seed = RenderFixture.seed(split: split, index: index)
        var rng = RenderRNG(state: seed)
        let ppm = stratum.basePPM + Int64(rng.next() % 2001) - 1000
        a = q(1_000_000 + ppm, 1_000_000)
        let b = q(Int64(rng.next() % 20001), 999_983)
        let e = q(Int64(rng.next() % 10001) - 5000, 1_000_003)
        frames = max(stratum.inputRate / 4, 3000)
        toneFractions = Self.passbandFractions.map { $0 * (1 - 0.02 * rng.unit()) }
        tonePhases = (0 ..< Self.channelCount).map { _ in 2 * .pi * rng.unit() }
        commonSigns = (0 ..< Self.channelCount).map { _ in rng.next() & 1 == 0 ? 1 : -1 }
        uniqueSigns = (0 ..< Self.channelCount).map { _ in rng.next() & 1 == 0 ? 1 : -1 }
        let epoch = RecordingEpochID()
        map = try groupMap(
            epochs: [mapped(epoch, [seg(q(-1), q(10), a, b)])],
            placements: [OccurrencePlacement(occurrence: occurrence(id, frames: frames, rate: stratum.inputRate), spans: [span(0, frames, epoch, e: e)])]
        )
        let g = q(stratum.outputRate)
        guard case .aligned(let lo) = try map.alignedTime(ofFrame: 0, in: id),
              case .aligned(let hi) = try map.alignedTime(ofFrame: frames - 1, in: id)
        else { throw TimeMapError.exactArithmeticEnvelopeExceeded }
        kFirst = Int64(try lo.instant.multiplied(by: g).ceil())
        kLast = Int64(try hi.instant.multiplied(by: g).floor())
        guard case .source(let first) = try map.sourceFrame(at: q(kFirst, stratum.outputRate), in: id),
              case .source(let last) = try map.sourceFrame(at: q(kLast, stratum.outputRate), in: id)
        else { throw TimeMapError.exactArithmeticEnvelopeExceeded }
        let slope = try last.exactFrame.subtracting(first.exactFrame).divided(by: q(kLast - kFirst))
        xFirst = first.exactFrame.approximateDouble
        delta = slope.approximateDouble
    }

    var outputFrames: Range<Int64> { kFirst - 64 ..< kLast + 65 }

    func x(_ k: Int64) -> Double { xFirst + Double(k - kFirst) * delta }

    /// Output frames whose every tap lies inside the span (no edge truncation).
    var steadyFrames: [Int64] {
        let reach = 32 * max(1, delta) + 2
        return Array(kFirst ... kLast).filter { x($0) >= reach && x($0) <= Double(frames) - reach - 1 }
    }

    /// Aligned output frame of source frame `n`, from the forward map.
    func truthFrame(_ n: Int64) throws -> Double {
        guard case .aligned(let p) = try map.alignedTime(ofFrame: n, in: id) else { throw TimeMapError.exactArithmeticEnvelopeExceeded }
        return try p.instant.multiplied(by: q(stratum.outputRate)).approximateDouble
    }

    var commonLandmark: Int64 { frames / 8 }
    func uniqueLandmark(_ channel: Int) -> Int64 { frames / 4 + Int64(channel) * (frames / 12) }

    func request() -> RenderRequest {
        RenderRequest(groupMap: map, outputRate: rate(stratum.outputRate), outputFrames: outputFrames, channels: channels(id, Self.channelCount), inputAssets: assets([id]))
    }

    func record(_ kind: String) -> RenderMeasurement {
        RenderMeasurement(split: split, caseIndex: index, stratum: stratum.name, inputRate: stratum.inputRate, outputRate: stratum.outputRate, rateRatio: "\(a.numerator)/\(a.denominator)", sourceFramesPerOutputFrame: delta, kind: kind)
    }

    func render(_ generate: @escaping FunctionProvider.Generator) async throws -> [[Float]] {
        let result = try await renderToArrays(request(), provider: FunctionProvider(generate))
        // Everything outside the hull is explicit zero.
        for channel in result.product {
            #expect(channel[0 ..< 64].allSatisfy { $0 == 0 } && channel[(channel.count - 64)...].allSatisfy { $0 == 0 })
        }
        return result.product
    }

    func measure() async throws -> [RenderMeasurement] {
        var records: [RenderMeasurement] = []
        let first = outputFrames.lowerBound
        let steady = steadyFrames
        #expect(steady.count > 2000)
        let amplitude = Self.amplitude

        // Passband tones: channel c carries fraction r_c of the lower Nyquist; nu_s cycles per source frame.
        let sourceCycles = toneFractions.map { $0 * min(1, 1 / delta) / 2 }
        let phases = tonePhases
        let tones = try await render { _, c, n in
            Float(amplitude * sin(2 * .pi * (sourceCycles[c] * Double(n)).truncatingRemainder(dividingBy: 1) + phases[c]))
        }
        var timing: [Double] = []
        for c in 0 ..< Self.channelCount {
            let fit = RenderAnalysis.fitTone(tones[c], firstFrame: first, frames: steady, amplitude: amplitude) { k in
                2 * .pi * (sourceCycles[c] * x(k)).truncatingRemainder(dividingBy: 1) + phases[c]
            }
            var m = record("passband")
            m.channel = c
            m.frequencyFraction = toneFractions[c]
            m.gainDB = fit.gainDB
            m.residualDBc = fit.residualDBc
            m.phaseErrorDegrees = fit.phaseDegrees
            records.append(m)
            // Phase error as a time offset in output frames (output tone frequency nu_s * delta).
            timing.append(fit.phaseDegrees / 360 / (sourceCycles[c] * delta))
        }
        var skewPhase = record("skew-phase")
        skewPhase.skewFrames = timing.max()! - timing.min()!
        records.append(skewPhase)

        // Stopband: content above the output Nyquist must not alias in (only when the output is lower).
        let upper = 0.98 * delta
        if upper > 1.01 {
            let ratios = (0 ..< Self.channelCount).map { 1 + (upper - 1) * Double($0) / Double(Self.channelCount - 1) }
            let cycles = ratios.map { $0 / (2 * delta) }
            let stop = try await render { _, c, n in
                Float(amplitude * sin(2 * .pi * (cycles[c] * Double(n)).truncatingRemainder(dividingBy: 1) + phases[c]))
            }
            for c in 0 ..< Self.channelCount {
                let rms = (steady.reduce(0.0) { $0 + pow(Double(stop[c][Int($1 - first)]), 2) } / Double(steady.count)).squareRoot()
                var m = record("stopband")
                m.channel = c
                m.frequencyFraction = ratios[c]
                m.residualDBc = RenderAnalysis.dB(max(rms, 1e-300) / (amplitude / 2.squareRoot()))
                records.append(m)
            }
        }

        // Landmarks: a common impulse on every channel (skew) and one unique impulse per channel (swap),
        // with seeded polarities (inversion).
        let common = commonLandmark
        let commonSigns = commonSigns
        let uniqueSigns = uniqueSigns
        let unique = (0 ..< Self.channelCount).map(uniqueLandmark)
        let impulses = try await render { _, c, n in
            if n == common { return 0.9 * commonSigns[c] }
            if n == unique[c] { return 0.9 * uniqueSigns[c] }
            return 0
        }
        let commonTruth = try truthFrame(common)
        let uniqueTruth = try unique.map(truthFrame)
        var commonPositions: [Double] = []
        for c in 0 ..< Self.channelCount {
            let y = impulses[c]
            let cp = RenderAnalysis.peak(y, firstFrame: first, near: commonTruth)
            var m = record("landmark-common")
            m.channel = c
            m.landmarkErrorFrames = cp.position - commonTruth
            m.polarityCorrect = cp.value.sign == (commonSigns[c] < 0 ? .minus : .plus)
            m.swapDetected = false
            records.append(m)
            commonPositions.append(cp.position)

            let up = RenderAnalysis.peak(y, firstFrame: first, near: uniqueTruth[c])
            let ownPresent = abs(up.value) >= 0.5 * abs(cp.value)
            let foreign = (0 ..< Self.channelCount).filter { $0 != c }.contains { other in
                let k = Int64(uniqueTruth[other].rounded())
                return RenderAnalysis.maxAbs(y[Int(k - 2 - first) ... Int(k + 2 - first)]) > 1e-3 * abs(cp.value)
            }
            var u = record("landmark-unique")
            u.channel = c
            u.landmarkErrorFrames = up.position - uniqueTruth[c]
            u.polarityCorrect = up.value.sign == (uniqueSigns[c] < 0 ? .minus : .plus)
            u.swapDetected = !ownPresent || foreign
            records.append(u)
        }
        var skewLandmark = record("skew-landmark")
        skewLandmark.skewFrames = commonPositions.max()! - commonPositions.min()!
        records.append(skewLandmark)

        // Inactive output: an isolated -1 dBFS noise channel; every other channel's input is silent.
        let peak = pow(10, -1.0 / 20)
        let noiseSeed = seed
        let isolated = index % Self.channelCount
        let inactive = try await render { _, c, n in c == isolated ? Float(peak * noise(noiseSeed, n)) : 0 }
        for c in 0 ..< Self.channelCount {
            var m = record(c == isolated ? "active" : "inactive")
            m.channel = c
            m.peakDBFS = RenderAnalysis.dB(Double(RenderAnalysis.maxAbs(inactive[c])))
            records.append(m)
        }
        return records
    }
}

/// Landmarks through segment kinks, gap restarts and an unsupported epoch, across two occurrences of
/// different rates in one group (MixedGroup).
func measureMultiSpan(split: String) async throws -> [RenderMeasurement] {
    let fixture = try MixedGroup()
    // (occurrence, decoded channel, source frame, sign). A 882 / B 2480 and A 3087 / B 4880 share aligned
    // instants (u = 0.03 and u = 0.08 on epoch e1), so they also measure cross-occurrence skew.
    let marks: [(SourceOccurrenceID, Int, Int64, Float)] = [
        (fixture.a, 0, 882, 1), (fixture.a, 1, 882, -1), (fixture.b, 0, 2480, -1),
        (fixture.a, 0, 3087, -1), (fixture.a, 1, 3087, 1), (fixture.b, 0, 4880, 1),
        (fixture.a, 0, 1764, 1), (fixture.a, 1, 6500, -1), (fixture.a, 0, 7500, 1), (fixture.a, 1, 8500, -1),
        (fixture.b, 0, 7000, -1), (fixture.b, 0, 8800, 1),
    ]
    let request = fixture.request(channelsA: 2, channelsB: 1)
    let result = try await renderToArrays(request, provider: FunctionProvider { o, c, n in
        marks.first { $0.0 == o && $0.1 == c && $0.2 == n }.map { 0.9 * $0.3 } ?? 0
    })
    let first = request.outputFrames.lowerBound
    var records: [RenderMeasurement] = []
    var positions: [Int64: [Double]] = [:]
    for (occurrenceID, channel, n, sign) in marks {
        guard case .aligned(let p) = try fixture.map.alignedTime(ofFrame: n, in: occurrenceID) else { throw TimeMapError.exactArithmeticEnvelopeExceeded }
        let truth = try p.instant.multiplied(by: q(48000)).approximateDouble
        let output = request.channels.firstIndex { $0.occurrence == occurrenceID && $0.decodedChannel == channel }!
        let found = RenderAnalysis.peak(result.product[output], firstFrame: first, near: truth)
        var m = RenderMeasurement(split: split, caseIndex: -1, stratum: "multi-span (kink, gap, unsupported, 44.1k+48k)", inputRate: occurrenceID == fixture.a ? 44100 : 48000, outputRate: 48000, rateRatio: "piecewise", sourceFramesPerOutputFrame: .nan, kind: "landmark-unique")
        m.channel = output
        m.landmarkErrorFrames = found.position - truth
        m.polarityCorrect = found.value.sign == (sign < 0 ? .minus : .plus)
        m.swapDetected = abs(found.value) < 0.3
        records.append(m)
        positions[Int64((truth * 16).rounded()), default: []].append(found.position)
    }
    for (_, group) in positions where group.count > 1 {
        var m = RenderMeasurement(split: split, caseIndex: -1, stratum: "multi-span (kink, gap, unsupported, 44.1k+48k)", inputRate: 0, outputRate: 48000, rateRatio: "piecewise", sourceFramesPerOutputFrame: .nan, kind: "skew-landmark")
        m.skewFrames = group.max()! - group.min()!
        records.append(m)
    }
    #expect(records.filter { $0.kind == "skew-landmark" }.count == 2)
    return records
}

func runSplit(_ split: String, cases: Int) async throws -> [RenderMeasurement] {
    var records = try await withThrowingTaskGroup(of: [RenderMeasurement].self) { group in
        for index in 0 ..< cases {
            group.addTask { try await RenderCase(split: split, index: index).measure() }
        }
        return try await group.reduce(into: []) { $0 += $1 }
    }
    records += try await measureMultiSpan(split: split)
    records.sort { ($0.caseIndex, $0.kind, $0.channel ?? -1) < ($1.caseIndex, $1.kind, $1.channel ?? -1) }
    if let directory = RenderFixture.recordsDirectory {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: "\(directory)/ww-018-\(split).jsonl", atomically: true, encoding: .utf8)
    }
    return records
}

@Suite("Render calibration (M2-RENDER-001)")
struct RenderCalibrationTests {
    @Test(.enabled(if: RenderFixture.calibrationEnabled, "serialized calibration pass (WW_RENDER_CALIBRATION=1)"))
    func calibrationSplitMeetsEveryObjectiveGate() async throws {
        let records = try await runSplit("calibration", cases: RenderFixture.calibrationCases)
        #expect(Set(records.map(\.stratum)).count == RenderStratum.all.count + 1)
        #expect(records.contains { $0.kind == "stopband" })
        for outcome in RenderGateEvaluation.evaluate(records) {
            #expect(outcome.passed, "\(outcome)")
        }
    }

    /// Frozen holdout: runs once, only with WW_M2_RENDER_HOLDOUT=1, after m2-freeze-render.
    @Test(.enabled(if: RenderFixture.holdoutEnabled))
    func holdoutSplitMeetsEveryFrozenGate() async throws {
        let records = try await runSplit("holdout", cases: RenderFixture.holdoutCases)
        for outcome in RenderGateEvaluation.evaluate(records) {
            #expect(outcome.passed, "\(outcome)")
        }
    }

    /// Each gate check trips on a measurement just past its limit and on missing evidence.
    @Test func gateChecksTripOnFailures() {
        let base = RenderMeasurement(split: "t", caseIndex: 0, stratum: "s", inputRate: 1, outputRate: 1, rateRatio: "1/1", sourceFramesPerOutputFrame: 1, kind: "")
        func make(_ kind: String, _ edit: (inout RenderMeasurement) -> Void) -> RenderMeasurement {
            var m = base
            m.kind = kind
            edit(&m)
            return m
        }
        let good = [
            make("passband") { $0.frequencyFraction = 0.8; $0.gainDB = -0.09; $0.residualDBc = -81; $0.phaseErrorDegrees = 0.0009 },
            make("stopband") { $0.residualDBc = -80 },
            make("landmark-unique") { $0.landmarkErrorFrames = -1; $0.polarityCorrect = true; $0.swapDetected = false },
            make("skew-landmark") { $0.skewFrames = 1 },
            make("inactive") { $0.peakDBFS = -.infinity },
        ]
        #expect(RenderGateEvaluation.evaluate(good).allSatisfy { $0.passed })
        let breaks: [(String, RenderMeasurement)] = [
            ("passband", make("passband") { $0.frequencyFraction = 0.8; $0.gainDB = 0.1001 }),
            ("alias", make("passband") { $0.frequencyFraction = 0.5; $0.residualDBc = -79.9 }),
            ("alias", make("stopband") { $0.residualDBc = -79.99 }),
            ("phase", make("passband") { $0.frequencyFraction = 0.5; $0.phaseErrorDegrees = -0.00101 }),
            ("landmarks", make("landmark-common") { $0.landmarkErrorFrames = 1.01; $0.polarityCorrect = true; $0.swapDetected = false }),
            ("inversions-swaps", make("landmark-common") { $0.landmarkErrorFrames = 0; $0.polarityCorrect = false; $0.swapDetected = false }),
            ("inversions-swaps", make("landmark-unique") { $0.landmarkErrorFrames = 0; $0.polarityCorrect = true; $0.swapDetected = true }),
            ("inversions-swaps", make("landmark-unique") { $0.landmarkErrorFrames = 0; $0.polarityCorrect = nil; $0.swapDetected = false }),
            ("skew", make("skew-phase") { $0.skewFrames = 1.001 }),
            ("inactive", make("inactive") { $0.peakDBFS = -79.9 }),
            ("landmarks", make("landmark-unique") { $0.landmarkErrorFrames = .nan; $0.polarityCorrect = true; $0.swapDetected = false }),
        ]
        for (gate, bad) in breaks {
            let outcomes = RenderGateEvaluation.evaluate(good + [bad])
            #expect(outcomes.filter { !$0.passed }.map(\.gate) == [gate], "\(gate): \(outcomes)")
        }
        // A tone beyond the passband fraction does not count toward the passband gate.
        #expect(RenderGateEvaluation.evaluate(good + [make("passband") { $0.frequencyFraction = 0.81; $0.gainDB = -3 }]).allSatisfy { $0.passed })
        // No evidence never passes.
        #expect(RenderGateEvaluation.evaluate([]).allSatisfy { !$0.passed })
        for kind in ["passband", "landmark-unique", "skew-landmark", "inactive"] {
            let missing = RenderGateEvaluation.evaluate(good.filter { $0.kind != kind })
            #expect(missing.contains { !$0.passed }, "missing \(kind) passed")
        }
    }

    /// Seeds are derived, stable and split-separated.
    @Test func seedsAreStableAndSplitSeparated() throws {
        #expect(RenderFixture.seed(split: "calibration", index: 0) == RenderFixture.seed(split: "calibration", index: 0))
        let calibration = Set((0 ..< RenderFixture.calibrationCases).map { RenderFixture.seed(split: "calibration", index: $0) })
        let holdout = Set((0 ..< RenderFixture.holdoutCases).map { RenderFixture.seed(split: "holdout", index: $0) })
        #expect(calibration.count == RenderFixture.calibrationCases && holdout.count == RenderFixture.holdoutCases)
        #expect(calibration.isDisjoint(with: holdout))
        let c0 = try RenderCase(split: "calibration", index: 0)
        let h0 = try RenderCase(split: "holdout", index: 0)
        #expect(c0.a != h0.a || c0.toneFractions != h0.toneFractions)
    }
}
