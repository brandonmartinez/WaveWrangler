import Foundation
import Testing
import WWCore
import WWTimeMap
@testable import WWAlignEstimate

/// Short (40 s) seeded scenes for each abstention path and each safety guard. Fast enough to run on every
/// mutation check; the calibration suite covers the full strata.
struct Scene40 {
    static let duration = 40.0
    static let overlap: ClosedRange<Double> = 2...38

    var rng: SplitMix64
    let scene: Scene
    let reference: TrackRecipe

    init(seed: UInt64, periodic: Double? = nil) {
        var rng = SplitMix64(seed: seed)
        scene = periodic.map { Scene.periodic(&rng, range: -5...55, period: $0) } ?? Scene.random(&rng, range: -5...55)
        reference = TrackRecipe(sampleRate: 8000, duration: 46, groupClockStart: 0, truth: ClockTruth(ppm: 0, offset: 0),
                                hearings: [Hearing(scene: scene, gain: 1, delay: .none)], noiseRMS: 0.004, noiseSeed: rng.next())
        self.rng = rng
    }

    mutating func target(rate: Int = 16000, truth: ClockTruth = ClockTruth(ppm: 40, offset: 0.6), hearings: [Hearing]? = nil, noise: Double = 0.005, groupClockStart: Double = 0) -> TrackRecipe {
        TrackRecipe(sampleRate: rate, duration: Self.duration, groupClockStart: groupClockStart, truth: truth,
                    hearings: hearings ?? [Hearing(scene: scene, gain: 1, delay: .none)], noiseRMS: noise, noiseSeed: rng.next())
    }

    struct Result {
        let report: EstimationReport
        let truths: [ClockTruth]
        var epochs: [EpochEstimate] { report.epochs }
        func clockMaxMs(_ i: Int) -> Double { CalibrationRunner.clockResiduals(epochs[i], truth: truths[i]).max() ?? .infinity }
    }

    /// `edit` may post-process rendered target samples (e.g. to blank a span).
    func run(_ targets: [(group: RecorderGroupID, recipe: TrackRecipe)], search: SearchRange? = nil, parameters: EstimatorParameters = EstimatorParameters(), edit: (inout [Float], Int) -> Void = { _, _ in }) throws -> Result {
        let reference = EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                                       buffer: try SampleBuffer(samples: self.reference.render(), sampleRate: 8000))
        var tracks: [EstimatorTrack] = []
        for target in targets {
            var samples = target.recipe.render()
            edit(&samples, target.recipe.sampleRate)
            let rate = Double(target.recipe.sampleRate)
            tracks.append(EstimatorTrack(group: target.group, epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(),
                                         groupClockStart: ExactRational(Int64(target.recipe.groupClockStart)),
                                         buffer: try SampleBuffer(samples: samples, sampleRate: target.recipe.sampleRate),
                                         declaredOverlap: Int(Self.overlap.lowerBound * rate)..<Int(Self.overlap.upperBound * rate)))
        }
        let report = try AcousticEstimator.estimate(EstimationRequest(reference: reference, tracks: tracks, search: try search ?? SearchRange(maximumDeviationSeconds: 2)), parameters: parameters)
        return Result(report: report, truths: targets.map(\.recipe.truth))
    }
}

func abstention(_ estimate: EpochEstimate) -> AbstentionReason? {
    if case .abstained(let a) = estimate.outcome { return a.reason }
    return nil
}

func proposal(_ estimate: EpochEstimate) -> AcousticProposal? {
    if case .acousticConsistentProposal(let p) = estimate.outcome { return p }
    return nil
}

@Suite("Estimator scenarios", .enabled(if: EstimatorHeavyGate.enabled, EstimatorHeavyGate.reason))
struct ScenarioTests {
    @Test(arguments: [8000, 16000, 44100, 48000, 96000])
    func positiveAtAnyRateMeetsClockTruth(rate: Int) throws {
        var s = Scene40(seed: 0xA11CE + UInt64(rate))
        let result = try s.run([(RecorderGroupID(), s.target(rate: rate, truth: ClockTruth(ppm: -73.5, offset: -0.85)))])
        let estimate = result.epochs[0]
        let p = try #require(proposal(estimate))
        #expect(result.clockMaxMs(0) < 0.5)
        #expect(abs(p.ppm + 73.5) < 2)
        #expect(estimate.coverage.eligibleCount >= ProvisionalClockGates.minimumWindows)
        #expect(estimate.flags.isEmpty)
        #expect(estimate.epochClockMap.provenanceKind == .acousticConsistentProposal)
        // The segment spans exactly the declared overlap.
        #expect(p.segment.groupClockStart == ExactRational(2))
        #expect(p.segment.groupClockEnd == ExactRational(38))
    }

    @Test func acousticDelayIsProposedNeverApproved() throws {
        var s = Scene40(seed: 0xDE1A)
        let truth = ClockTruth(ppm: 20, offset: 0.3)
        let result = try s.run([(RecorderGroupID(), s.target(truth: truth, hearings: [Hearing(scene: s.scene, gain: 1, delay: .constant(0.035))]))])
        let estimate = result.epochs[0]
        // Acoustically the delayed map is perfectly consistent, so it is proposed ...
        #expect(proposal(estimate) != nil)
        #expect(estimate.epochClockMap.provenanceKind == .acousticConsistentProposal)
        // ... and it is 35 ms away from the clock: exactly why a proposal is never clock evidence.
        #expect(abs(result.clockMaxMs(0) - 35) < 0.5)
    }

    @Test func undeclaredStepAbstainsAsDiscontinuous() throws {
        var s = Scene40(seed: 0x57E9)
        var truth = ClockTruth(ppm: 10, offset: 0.2)
        truth.step = (at: 21, amount: 0.030)
        let result = try s.run([(RecorderGroupID(), s.target(truth: truth))])
        #expect(abstention(result.epochs[0]) == .discontinuous)
        #expect(result.epochs[0].flags.contains(.discontinuity))
        #expect(result.epochs[0].epochClockMap.mapping == .unsupported(.nonlinear))
    }

    @Test func silentTargetAbstains() throws {
        var s = Scene40(seed: 0x51E7)
        let result = try s.run([(RecorderGroupID(), s.target(hearings: [], noise: 1e-6))])
        #expect(abstention(result.epochs[0]) == .silent)
        #expect(result.epochs[0].epochClockMap.mapping == .unsupported(.estimatorAbstained))
    }

    @Test func unrelatedTargetAbstainsAsWeak() throws {
        var s = Scene40(seed: 0x0DD)
        var other = s.rng
        let otherScene = Scene.random(&other, range: -5...55)
        let result = try s.run([(RecorderGroupID(), s.target(hearings: [Hearing(scene: otherScene, gain: 1, delay: .none)]))])
        #expect(abstention(result.epochs[0]) == .weak)
    }

    @Test(arguments: [0.45, 0.9, 1.6])
    func periodicContentAbstains(period: Double) throws {
        var s = Scene40(seed: 0xBEA7, periodic: period)
        let result = try s.run([(RecorderGroupID(), s.target())])
        let reason = try #require(abstention(result.epochs[0]))
        #expect([.periodic, .ambiguous].contains(reason))
    }

    @Test func referenceOutOfReachIsDisconnected() throws {
        var s = Scene40(seed: 0xD15C)
        let result = try s.run([(RecorderGroupID(), s.target(truth: ClockTruth(ppm: 0, offset: 0), groupClockStart: 300))])
        #expect(abstention(result.epochs[0]) == .disconnected)
        #expect(result.epochs[0].epochClockMap.mapping == .unsupported(.disconnected))
    }

    @Test func shortGapIsFlaggedButProposed() throws {
        var s = Scene40(seed: 0x6A9)
        let result = try s.run([(RecorderGroupID(), s.target())]) { samples, rate in
            for n in (16 * rate)..<(22 * rate) { samples[n] = 0 }
        }
        let estimate = result.epochs[0]
        #expect(proposal(estimate) != nil)
        #expect(estimate.flags.contains(.coverageGap))
        #expect(estimate.windows.contains { $0.status == .silent })
        #expect(result.clockMaxMs(0) < 0.5)
    }

    @Test func eligibleWindowsMustSpanTheOverlap() throws {
        var s = Scene40(seed: 0xC0E5)
        let result = try s.run([(RecorderGroupID(), s.target())]) { samples, rate in
            for n in (27 * rate)..<samples.count { samples[n] = 0 }
        }
        let estimate = result.epochs[0]
        #expect(estimate.coverage.eligibleWindowFraction >= ProvisionalClockGates.minimumEligibleWindowFraction)
        #expect(estimate.coverage.eligibleSpanFraction < ProvisionalClockGates.minimumOverlapSpanFraction)
        #expect(abstention(estimate) == .insufficientCoverage)
        #expect(estimate.epochClockMap.mapping == .unsupported(.insufficientOverlap))
    }

    @Test func tooFewEligibleWindowsAbstain() throws {
        var s = Scene40(seed: 0xFE3)
        let result = try s.run([(RecorderGroupID(), s.target())]) { samples, rate in
            for n in (19 * rate)..<samples.count { samples[n] = 0 }
        }
        #expect(result.epochs[0].coverage.eligibleWindowFraction < ProvisionalClockGates.minimumEligibleWindowFraction)
        #expect(abstention(result.epochs[0]) == .silent)
    }

    @Test func fewerThanFiveEligibleWindowsAbstainEvenAtAHighFraction() throws {
        var s = Scene40(seed: 0xF1E)
        var parameters = EstimatorParameters()
        parameters.windowCount = ProvisionalClockGates.minimumWindows
        let result = try s.run([(RecorderGroupID(), s.target())], parameters: parameters) { samples, rate in
            for n in (35 * rate)..<samples.count { samples[n] = 0 }
        }
        let coverage = result.epochs[0].coverage
        #expect(coverage.eligibleCount == ProvisionalClockGates.minimumWindows - 1)
        #expect(coverage.eligibleWindowFraction >= ProvisionalClockGates.minimumEligibleWindowFraction)
        #expect(abstention(result.epochs[0]) == .silent)
    }

    @Test func implausibleDriftAbstains() throws {
        var s = Scene40(seed: 0xD21F)
        var parameters = EstimatorParameters()
        parameters.maximumAbsolutePPM = 50
        let result = try s.run([(RecorderGroupID(), s.target(truth: ClockTruth(ppm: 90, offset: 0.1)))], parameters: parameters)
        #expect(abstention(result.epochs[0]) == .implausibleDrift)
    }

    @Test func brokenCycleAbstainsBothEpochs() throws {
        var s = Scene40(seed: 0xC1C1E)
        var other = s.rng
        let second = Scene.random(&other, range: -5...55)
        let groups = [RecorderGroupID(), RecorderGroupID()]
        let targets = [(0.0, groups[0]), (0.020, groups[1])].map { delay, group in
            (group, s.target(truth: ClockTruth(ppm: 25, offset: -0.4), hearings: [Hearing(scene: s.scene, gain: 1, delay: .none), Hearing(scene: second, gain: 1.6, delay: .constant(delay))], noise: 0.003))
        }
        let result = try s.run(targets)
        for estimate in result.epochs {
            #expect(abstention(estimate) == .cycleInconsistent)
            #expect(estimate.flags.contains(.cycleInconsistent))
            guard case .measured(let triangles, let worst) = estimate.cycle else { Issue.record("cycle not measured"); continue }
            #expect(triangles == 1)
            #expect(worst > 15)
        }
    }

    @Test func closedCycleKeepsBothProposals() throws {
        var s = Scene40(seed: 0xC1C1F)
        let result = try s.run([(RecorderGroupID(), s.target(truth: ClockTruth(ppm: 25, offset: -0.4))), (RecorderGroupID(), s.target(truth: ClockTruth(ppm: -60, offset: 1.1)))])
        for (i, estimate) in result.epochs.enumerated() {
            #expect(proposal(estimate) != nil)
            #expect(result.clockMaxMs(i) < 0.5)
            guard case .measured(_, let worst) = estimate.cycle else { Issue.record("cycle not measured"); continue }
            #expect(worst < 0.5)
        }
    }

    @Test func restartedEpochsAreFlaggedAndEstimatedIndependently() throws {
        var s = Scene40(seed: 0x2E57)
        let group = RecorderGroupID()
        let first = s.target(truth: ClockTruth(ppm: 30, offset: 0.25))
        // A second epoch of the same group: its own clock (another offset), never bridged to the first.
        let second = s.target(truth: ClockTruth(ppm: -45, offset: -0.9))
        let result = try s.run([(group, first), (group, second)])
        for (i, estimate) in result.epochs.enumerated() {
            #expect(estimate.flags.contains(.restartedEpoch))
            #expect(proposal(estimate) != nil)
            #expect(result.clockMaxMs(i) < 0.5)
            #expect(estimate.cycle == .unavailable)
        }
    }

    @Test func estimationIsDeterministic() throws {
        var s = Scene40(seed: 0xD7E2)
        let target = s.target()
        let reference = EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(), buffer: try SampleBuffer(samples: s.reference.render(), sampleRate: 8000))
        let track = EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID(), buffer: try SampleBuffer(samples: target.render(), sampleRate: target.sampleRate))
        let request = EstimationRequest(reference: reference, tracks: [track], search: try SearchRange(maximumDeviationSeconds: 2))
        #expect(try AcousticEstimator.estimate(request) == AcousticEstimator.estimate(request))
    }

    @Test func proposalCompilesIntoAGroupTimeMap() throws {
        var s = Scene40(seed: 0x6A0)
        let recipe = s.target()
        let group = RecorderGroupID()
        let result = try s.run([(group, recipe)])
        let estimate = result.epochs[0]
        let occurrence = try SourceOccurrence(id: estimate.occurrence, source: SourceID(), nominalRate: NominalRate(Int64(recipe.sampleRate)), frameCount: Int64(recipe.frameCount))
        let referenceOccurrence = SourceOccurrenceID(), referenceEpoch = RecordingEpochID()
        let reference = TimelineReference(group: RecorderGroupID(), epoch: referenceEpoch, occurrence: referenceOccurrence)
        let map = try GroupTimeMap(group: group, reference: reference, epochs: [estimate.epochClockMap],
                                   placements: [OccurrencePlacement(occurrence: occurrence, spans: [EpochSpan(startFrame: Int64(2 * recipe.sampleRate), endFrame: Int64(38 * recipe.sampleRate), epoch: estimate.epoch, groupClockOffset: .zero)])])
        #expect(map.epochs == [estimate.epochClockMap])
    }
}
