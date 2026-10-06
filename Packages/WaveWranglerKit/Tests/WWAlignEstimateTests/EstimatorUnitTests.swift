import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWAlignEstimate

@Suite("Estimator inputs and primitives")
struct EstimatorUnitTests {
    static func track(_ samples: [Float] = [Float](repeating: 0.1, count: 80_000), rate: Int = 8000, group: RecorderGroupID = RecorderGroupID(), epoch: RecordingEpochID = RecordingEpochID(), overlap: Range<Int>? = nil) throws -> EstimatorTrack {
        EstimatorTrack(group: group, epoch: epoch, occurrence: SourceOccurrenceID(), buffer: try SampleBuffer(samples: samples, sampleRate: rate), declaredOverlap: overlap)
    }

    // MARK: Inputs

    @Test func sampleBufferRejectsInvalidInput() {
        #expect(throws: AlignEstimateError.invalidSampleRate(7999)) { try SampleBuffer(samples: [0], sampleRate: 7999) }
        #expect(throws: AlignEstimateError.invalidSampleRate(0)) { try SampleBuffer(samples: [0], sampleRate: 0) }
        #expect(throws: AlignEstimateError.emptyBuffer) { try SampleBuffer(samples: [], sampleRate: 8000) }
        #expect(throws: AlignEstimateError.nonFiniteSample(index: 2)) { try SampleBuffer(samples: [0, 1, .nan, 0], sampleRate: 8000) }
        #expect(throws: AlignEstimateError.nonFiniteSample(index: 0)) { try SampleBuffer(samples: [.infinity], sampleRate: 48000) }
    }

    @Test func searchRangeRejectsInvalidInput() {
        #expect(throws: AlignEstimateError.invalidParameter("maximumDeviationSeconds")) { try SearchRange(maximumDeviationSeconds: 0) }
        #expect(throws: AlignEstimateError.invalidParameter("maximumDeviationSeconds")) { try SearchRange(maximumDeviationSeconds: .nan) }
        #expect(throws: AlignEstimateError.invalidParameter("maximumDeviationSeconds")) { try SearchRange(maximumDeviationSeconds: 601) }
        #expect(throws: AlignEstimateError.invalidParameter("centerOffsetSeconds")) { try SearchRange(centerOffsetSeconds: .infinity, maximumDeviationSeconds: 1) }
    }

    @Test func defaultParametersAreValidAndOutOfRangeOnesAreRejected() throws {
        try EstimatorParameters().validate()
        let mutations: [(String, (inout EstimatorParameters) -> Void)] = [
            ("proxyRate", { $0.proxyRate = 500 }),
            ("proxyCutoffFraction", { $0.proxyCutoffFraction = 0.5 }),
            ("windowSeconds", { $0.windowSeconds = 0.1 }),
            ("windowCount", { $0.windowCount = ProvisionalClockGates.minimumWindows - 1 }),
            ("minimumPeakScore", { $0.minimumPeakScore = 0 }),
            ("ambiguityRatio", { $0.ambiguityRatio = 1 }),
            ("periodicityThreshold", { $0.periodicityThreshold = 1 }),
            ("lobeExclusionMilliseconds", { $0.lobeExclusionMilliseconds = 0 }),
            ("silenceRMS", { $0.silenceRMS = 0 }),
            // The consistency tolerance can never be looser than the provisional residual gate.
            ("consistencyToleranceMilliseconds", { $0.consistencyToleranceMilliseconds = ProvisionalClockGates.maximumResidualP95Milliseconds + 0.001 }),
            ("maximumAbsolutePPM", { $0.maximumAbsolutePPM = 0 }),
            ("cycleToleranceMilliseconds", { $0.cycleToleranceMilliseconds = .infinity }),
        ]
        for (name, mutate) in mutations {
            var parameters = EstimatorParameters()
            mutate(&parameters)
            #expect(throws: AlignEstimateError.invalidParameter(name)) { try parameters.validate() }
        }
    }

    /// Only the frozen defaults carry the frozen identifier; any other parameter set (reachable in-module
    /// only, since the setters are internal) stamps the report and every proposal as custom.
    @Test func onlyFrozenParametersCarryTheFrozenIdentifier() throws {
        #expect(AcousticEstimator.identifier == "ww-align-estimate/1")
        #expect(AcousticEstimator.customIdentifier == "ww-align-estimate/1+custom")
        #expect(AcousticEstimator.identifier(for: EstimatorParameters()) == AcousticEstimator.identifier)
        let variants: [(inout EstimatorParameters) -> Void] = [
            { $0.proxyRate = 8000 }, { $0.proxyCutoffFraction = 0.4 }, { $0.windowSeconds = 3 }, { $0.windowCount = 17 },
            { $0.minimumPeakScore = 0.36 }, { $0.ambiguityRatio = 0.79 }, { $0.periodicityThreshold = 0.51 },
            { $0.lobeExclusionMilliseconds = 6 }, { $0.silenceRMS = 2e-4 }, { $0.consistencyToleranceMilliseconds = 0.9 },
            { $0.maximumAbsolutePPM = 400 }, { $0.cycleToleranceMilliseconds = 3 },
        ]
        for vary in variants {
            var parameters = EstimatorParameters()
            vary(&parameters)
            try parameters.validate()
            #expect(AcousticEstimator.identifier(for: parameters) == AcousticEstimator.customIdentifier)
        }

        var s = Scene40(seed: 0x1D_57A4)
        let target = s.target(rate: 8000)
        let frozen = try s.run([(RecorderGroupID(), target)])
        #expect(frozen.report.estimator == AcousticEstimator.identifier)
        #expect(try #require(proposal(frozen.epochs[0])).provenance.estimator == AcousticEstimator.identifier)
        var custom = EstimatorParameters()
        custom.windowCount = 17
        let varied = try s.run([(RecorderGroupID(), target)], parameters: custom)
        #expect(varied.report.estimator == AcousticEstimator.customIdentifier)
        #expect(try #require(proposal(varied.epochs[0])).provenance.estimator == AcousticEstimator.customIdentifier)
    }

    @Test func requestValidation() throws {
        let reference = try Self.track()
        let search = try SearchRange(maximumDeviationSeconds: 1)
        #expect(throws: AlignEstimateError.referenceEpochInTracks(reference.epoch)) {
            try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: [try Self.track(epoch: reference.epoch)], search: search))
        }
        let epoch = RecordingEpochID()
        #expect(throws: AlignEstimateError.duplicateEpoch(epoch)) {
            try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: [try Self.track(epoch: epoch), try Self.track(epoch: epoch)], search: search))
        }
        for overlap in [-1..<10, 0..<80_001, 5..<5] {
            let bad = try Self.track(overlap: overlap)
            #expect(throws: AlignEstimateError.invalidDeclaredOverlap(bad.occurrence)) {
                try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: [bad], search: search))
            }
        }
        var parameters = EstimatorParameters()
        parameters.windowCount = 1
        #expect(throws: AlignEstimateError.invalidParameter("windowCount")) {
            try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: [], search: search), parameters: parameters)
        }
    }

    @Test func overlapShorterThanOneWindowAbstains() throws {
        let reference = try Self.track()
        let short = try Self.track(overlap: 0..<8000) // 1 s < 2 s window
        let report = try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: [short], search: try SearchRange(maximumDeviationSeconds: 1)))
        #expect(report.estimator == AcousticEstimator.identifier)
        let estimate = try #require(report.epochs.first)
        #expect(abstention(estimate) == .insufficientCoverage)
        #expect(estimate.windows.isEmpty)
        #expect(estimate.epochClockMap == EpochClockMap(epoch: estimate.epoch, mapping: .unsupported(.insufficientOverlap)))
    }

    @Test func constantInputIsSilentNotPeriodic() throws {
        // A pure DC bias has no signal: every window is silent (centred statistics), never "periodic".
        let reference = try Self.track([Float](repeating: 0.3, count: 160_000))
        let target = try Self.track([Float](repeating: -0.2, count: 160_000))
        let report = try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: [target], search: try SearchRange(maximumDeviationSeconds: 1)))
        let estimate = try #require(report.epochs.first)
        #expect(abstention(estimate) == .silent)
        #expect(estimate.windows.allSatisfy { $0.status == .silent })
    }

    // MARK: Results

    @Test func abstentionReasonsMapToUnsupportedReasons() {
        let expected: [AbstentionReason: UnsupportedReason] = [
            .disconnected: .disconnected, .insufficientCoverage: .insufficientOverlap,
            .discontinuous: .nonlinear, .inconsistent: .nonlinear,
            .weak: .estimatorAbstained, .ambiguous: .estimatorAbstained, .periodic: .estimatorAbstained,
            .silent: .estimatorAbstained, .implausibleDrift: .estimatorAbstained, .cycleInconsistent: .estimatorAbstained,
        ]
        #expect(Set(expected.keys) == Set(AbstentionReason.allCases))
        for (reason, unsupported) in expected { #expect(reason.unsupportedReason == unsupported) }
    }

    @Test func dominantReasonCountsAndBreaksTies() {
        func windows(_ statuses: [WindowStatus]) -> [WindowMeasurement] {
            statuses.enumerated().map { WindowMeasurement(index: $0.offset, groupClockCenter: Double($0.offset), status: $0.element, peakScore: 0, secondPeakScore: 0, periodicityScore: 0, offsetSeconds: nil) }
        }
        #expect(AcousticEstimator.dominantReason(windows([.eligible, .weak, .edgePeak, .silent])) == (.weak, 2))
        #expect(AcousticEstimator.dominantReason(windows([.noReference, .silent])) == (.disconnected, 1))
        #expect(AcousticEstimator.dominantReason(windows([.ambiguous, .periodic])) == (.periodic, 1))
        #expect(AcousticEstimator.dominantReason(windows([.ambiguous, .ambiguous, .periodic])) == (.ambiguous, 2))
        #expect(AcousticEstimator.dominantReason(windows([.eligible])) == (.weak, 0))
    }

    // MARK: Signal primitives

    @Test(arguments: [2, 8, 64, 256])
    func fftMatchesNaiveDFT(size: Int) {
        var rng = SplitMix64(seed: UInt64(size))
        let xr = (0..<size).map { _ in rng.gaussian() }, xi = (0..<size).map { _ in rng.gaussian() }
        var re = xr, im = xi
        let fft = FFT(size: size)
        fft.transform(&re, &im, inverse: false)
        var worst = 0.0
        for k in 0..<size {
            var sr = 0.0, si = 0.0
            for n in 0..<size {
                let angle = -2 * Double.pi * Double(k * n % size) / Double(size)
                sr += xr[n] * cos(angle) - xi[n] * sin(angle)
                si += xr[n] * sin(angle) + xi[n] * cos(angle)
            }
            worst = max(worst, abs(sr - re[k]), abs(si - im[k]))
        }
        #expect(worst < 1e-9 * Double(size))
        fft.transform(&re, &im, inverse: true)
        #expect(zip(re, xr).allSatisfy { abs($0 - $1) < 1e-12 })
        #expect(zip(im, xi).allSatisfy { abs($0 - $1) < 1e-12 })
    }

    @Test func fftSizeIsTheNextPowerOfTwo() {
        #expect(FFT.size(atLeast: 0) == 2)
        #expect(FFT.size(atLeast: 2) == 2)
        #expect(FFT.size(atLeast: 3) == 4)
        #expect(FFT.size(atLeast: 1025) == 2048)
    }

    @Test func centredStatisticsIgnoreTheMean() throws {
        var parameters = EstimatorParameters()
        parameters.proxyRate = 4000
        let samples = (0..<16000).map { Float(0.5 + 0.1 * sin(2 * Double.pi * 300 * Double($0) / 8000)) }
        let proxy = ProxySignal(buffer: try SampleBuffer(samples: samples, sampleRate: 8000), parameters: parameters)
        let interior = 1000..<7000
        #expect(abs(proxy.centredRMS(interior) - 0.1 / 2.0.squareRoot()) < 0.002)
        // Constant input stays constant up to the buffer edges (edge extension, no invented step).
        let flat = ProxySignal(buffer: try SampleBuffer(samples: [Float](repeating: 0.7, count: 16000), sampleRate: 8000), parameters: parameters)
        #expect(flat.centredRMS(interior) < 1e-6)
        #expect(flat.centredRMS(0..<flat.samples.count) < 1e-6)
    }

    @Test func nearestRankPercentile() {
        #expect(Stats.nearestRank([], 0.95) == 0)
        #expect(Stats.nearestRank([3], 0.95) == 3)
        let values = (1...20).map(Double.init).reversed().map { $0 }
        #expect(Stats.nearestRank(values, 0.95) == 19) // ceil(0.95 * 20) = 19
        #expect(Stats.nearestRank(values, 1) == 20)
        #expect(Stats.median([4, 1, 3]) == 3)
        #expect(Stats.median([4, 1, 3, 2]) == 2.5)
    }

    // MARK: Window correlator

    static func proxy(_ events: [SceneEvent], seed: UInt64, duration: Double = 20) throws -> ProxySignal {
        let recipe = TrackRecipe(sampleRate: 8000, duration: duration, groupClockStart: 0, truth: ClockTruth(ppm: 0, offset: 0),
                                 hearings: [Hearing(scene: Scene(events: events), gain: 1, delay: .none)], noiseRMS: 0.002, noiseSeed: seed)
        return ProxySignal(buffer: try SampleBuffer(samples: recipe.render(), sampleRate: 8000), parameters: EstimatorParameters())
    }

    static func observe(target: ProxySignal, reference: ProxySignal, at seconds: Double = 9) -> WindowObservation {
        var correlator = WindowCorrelator(parameters: EstimatorParameters(), windowLength: 8000)
        return correlator.observe(target: target, targetStart: Int(seconds * 4000), targetClockStart: 0, reference: reference, referenceClockStart: 0, predictedOffset: 0, deviation: 2)
    }

    @Test func distinctEventIsEligibleAtItsOffset() throws {
        var rng = SplitMix64(seed: 0xE1)
        let events = (0..<6).map { Scene.randomEvent(&rng, at: 8.7 + 0.45 * Double($0) + rng.uniform(0...0.1)) }
        let reference = try Self.proxy(events, seed: 1)
        let shifted = events.map { SceneEvent(time: $0.time - 0.6125, amplitude: $0.amplitude, shape: $0.shape) }
        let o = Self.observe(target: try Self.proxy(shifted, seed: 2), reference: reference)
        #expect(o.status == .eligible)
        #expect(abs((o.offsetSeconds ?? .infinity) - 0.6125) < 0.0002)
    }

    @Test func aRepeatedReferenceEventIsAmbiguous() throws {
        var rng = SplitMix64(seed: 0xA3)
        let event = Scene.randomEvent(&rng, at: 10, forceChirp: true)
        let copy = SceneEvent(time: 11.8, amplitude: event.amplitude, shape: event.shape)
        let o = Self.observe(target: try Self.proxy([event], seed: 3), reference: try Self.proxy([event, copy], seed: 4))
        #expect(o.periodicityScore < EstimatorParameters().periodicityThreshold)
        #expect(o.peakScore >= EstimatorParameters().minimumPeakScore)
        #expect(o.status == .ambiguous)
    }

    @Test func aRepeatingPatternIsPeriodic() throws {
        var rng = SplitMix64(seed: 0xB4)
        let scene = Scene.periodic(&rng, range: 0...20, period: 0.4)
        let o = Self.observe(target: try Self.proxy(scene.events, seed: 5), reference: try Self.proxy(scene.events, seed: 6))
        #expect(o.status == .periodic)
    }

    // MARK: Consistency fit

    static func line(_ slope: Double, _ intercept: Double, at us: [Double]) -> [(u: Double, o: Double)] {
        us.map { (u: $0, o: intercept + slope * $0) }
    }

    @Test func consistentPointsFitTheirLine() throws {
        let us = stride(from: 0.0, through: 100, by: 6.5).map { $0 }
        var points = Self.line(-80e-6, 0.42, at: us)
        points[3].o += 0.0004 // within 1 ms
        guard case .consistent(let fit) = ConsistencyFit.fit(points, tolerance: 0.001) else { Issue.record("not consistent"); return }
        #expect(abs(fit.slope + 80e-6) < 1e-5)
        #expect(abs(fit.offset(at: 0) - 0.42) < 0.0005)
    }

    @Test func aSingleStrayWindowIsNeverTrimmed() {
        let us = stride(from: 0.0, through: 100, by: 6.5).map { $0 }
        var points = Self.line(10e-6, 0.1, at: us)
        points[7].o += 0.02
        guard case .inconsistent(let residual) = ConsistencyFit.fit(points, tolerance: 0.001) else { Issue.record("expected inconsistent"); return }
        #expect(residual > 0.001)
    }

    @Test func aStepIsDiscontinuous() {
        let us = stride(from: 0.0, through: 100, by: 6.5).map { $0 }
        let points = Self.line(10e-6, 0.1, at: us).map { $0.u > 50 ? (u: $0.u, o: $0.o + 0.03) : $0 }
        guard case .discontinuous(let step, let at) = ConsistencyFit.fit(points, tolerance: 0.001) else { Issue.record("expected discontinuous"); return }
        #expect(abs(step - 0.03) < 0.001)
        #expect(at > 45 && at < 55)
    }

    @Test func degenerateFitsAreInconsistent() {
        #expect(ConsistencyFit.fit([], tolerance: 0.001) == .inconsistent(maximumResidualSeconds: .infinity))
        #expect(ConsistencyFit.fit([(u: 1, o: 0.1)], tolerance: 0.001) == .inconsistent(maximumResidualSeconds: .infinity))
        #expect(ConsistencyFit.fit([(u: 1, o: 0.1), (u: 1, o: 0.2)], tolerance: 0.001) == .inconsistent(maximumResidualSeconds: .infinity))
    }
}
