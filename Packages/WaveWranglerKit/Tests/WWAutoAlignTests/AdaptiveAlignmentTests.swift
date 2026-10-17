import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWAutoAlign

@Suite("File-local adaptive timing support")
struct AdaptiveAlignmentTests {
    static func points(_ range: Range<Int>, offset: Double = -9.53, ppm: Double = 0) -> [DelayEvidence] {
        range.map { index in
            let time = Double(index)
            let delay = offset + ppm * 1e-6 * time
            return DelayEvidence(
                station: index % 16, attempt: 0, targetCenter: time, status: "eligible",
                offsetSeconds: delay, nccScore: 0.85, nccSecond: 0.1,
                phatOffsetSeconds: delay, phatPeakRatio: 0.1, method: AutomaticAlignment.fineMethod
            )
        }
    }

    static func sequencePoint(_ center: Double, score: Double = 0.9, competing: Double = 0.1) -> DelayEvidence {
        DelayEvidence(station: 0, attempt: 0, targetCenter: center, status: "eligible",
            offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1,
            phatOffsetSeconds: -0.2, phatPeakRatio: 0.1, method: AdaptiveAlignment.sequenceMethod, polarity: -1,
            corroborations: [-0.75, 0, 0.75].map {
                TemporalCorroboration(targetCenter: center + $0, offsetSeconds: -0.2,
                    score: $0 == 0 ? score : 0.9,
                    competingScore: $0 == 0 ? competing : 0.85, polarity: -1, windowSeconds: 0.5)
            })
    }

    @Test func networkTimingStepsRemainSeparateSupportedRunsWithExplicitUnknownTransitions() throws {
        let observations = Self.points(10..<30) + Self.points(30..<50, offset: -9.51)
            + Self.points(50..<70, offset: -9.52)
        let result = try AdaptiveAlignment.regions(observations: observations, start: 0, end: 75)
        #expect(result.regions.count == 3)
        #expect(abs(try #require(result.referenceTime(at: 20)) - 10.47) < 1e-9)
        #expect(abs(try #require(result.referenceTime(at: 40)) - 30.49) < 1e-9)
        #expect(abs(try #require(result.referenceTime(at: 60)) - 50.48) < 1e-9)
        #expect(result.referenceTime(at: 29.5) == nil)
        #expect(result.referenceTime(at: 49.5) == nil)
        #expect(result.referenceTime(at: 0) == nil)
        #expect(result.referenceTime(at: 74) == nil)
        #expect(result.regions.allSatisfy { $0.maximumResidualMilliseconds < 0.0001 })
    }

    @Test func localClockDriftIsBoundedAndNoUntestedEndsAreExtrapolated() throws {
        let result = try AdaptiveAlignment.regions(observations: Self.points(10..<80, ppm: 180), start: 0, end: 90)
        let region = try #require(result.regions.first)
        #expect(result.regions.count == 1)
        #expect(abs((region.rateRatio - 1) * 1e6 - 180) < 0.0001)
        #expect(result.referenceTime(at: 79) == nil)
        #expect(result.referenceTime(at: 9) == nil)
        let decoded = try JSONDecoder().decode(AdaptiveTimingResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }

    @Test func missingSilentOrContradictoryAudioNeverGetsABridgingCurve() throws {
        var observations = Self.points(10..<30) + Self.points(40..<60)
        observations += Self.points(30..<40).map { point in
            var point = point
            point.status = "inconsistentMethods"
            return point
        }
        let result = try AdaptiveAlignment.regions(observations: observations, start: 0, end: 65)
        #expect(result.regions.count == 2)
        for time in 30..<40 { #expect(result.referenceTime(at: Double(time)) == nil) }
        #expect(result.usableWindows == 40)
        #expect(result.attemptedWindows == 50)
    }

    @Test func shortClustersLowQualityAndExcessiveRatesSupplyNoSupportedRegion() throws {
        #expect(try AdaptiveAlignment.regions(observations: Self.points(10..<14), start: 0, end: 20).regions.isEmpty)
        #expect(try AdaptiveAlignment.regions(observations: Self.points(10..<30, ppm: 1000), start: 0, end: 40).regions.isEmpty)
        let weak = Self.points(10..<30).map { point in
            DelayEvidence(station: point.station, attempt: 0, targetCenter: point.targetCenter, status: "weak",
                offsetSeconds: point.offsetSeconds, nccScore: 0.4, nccSecond: 0.3,
                phatOffsetSeconds: point.phatOffsetSeconds, phatPeakRatio: 0.8, method: point.method)
        }

        #expect(try AdaptiveAlignment.regions(observations: weak, start: 0, end: 40).regions.isEmpty)
    }

    @Test func evenOneAmbiguousWindowSplitsSupportRatherThanGettingDiscardedAsAnOutlier() throws {
        var observations = Self.points(10..<50)
        observations[20].status = "ambiguous"
        let result = try AdaptiveAlignment.regions(observations: observations, start: 0, end: 55)
        #expect(result.regions.count == 2)
        #expect(result.referenceTime(at: 30) == nil)
        #expect(result.referenceTime(at: 29.5) == nil)
        #expect(result.referenceTime(at: 30.5) == nil)
    }

    @Test func duplicateNonfiniteAndTimeReversingEvidenceRefuse() throws {
        #expect(throws: AlignEstimateError.self) {
            try AdaptiveAlignment.regions(observations: Self.points(10..<20) + Self.points(10..<20), start: 0, end: 30)
        }
        #expect(throws: AlignEstimateError.self) {
            try AdaptiveAlignment.regions(observations: Self.points(10..<20, offset: .nan), start: 0, end: 30)
        }
        #expect(throws: AlignEstimateError.self) {
            try AdaptiveAlignment.regions(observations: Self.points(10..<30) + Self.points(30..<50, offset: -20), start: 0, end: 60)
        }
    }

    @Test func cancellationIsAuthoritative() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AdaptiveAlignment.regions(observations: Self.points(10..<100), start: 0, end: 110)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func freshTemporalCorroborationMeasuresProcessedSpeechAndKeepsNegativeControls() throws {
        let reference = try SyntheticSpeech.track(start: 100, duration: 5, noiseLevel: 0)
        let target = try SyntheticSpeech.track(start: 100.5, duration: 4, offset: -0.17, processed: true)
        let fresh = try AdaptiveAlignment.measure(
            reference: reference, target: target, station: 0, predictedOffset: -0.17, deviation: 0.35
        )
        let usable = fresh.filter { $0.status == "eligible" && $0.method == AdaptiveAlignment.fineMethod }
        #expect(usable.count >= 2)
        for point in usable {
            #expect(abs(try #require(point.offsetSeconds) + 0.17) < 0.001)
            #expect([3, 6, 9].contains(point.corroborations?.count ?? 0))
            #expect(AdaptiveAlignment.supportingCorroborations(point)?.count == 3)
        }
        let unrelated = try SyntheticSpeech.track(start: 100.5, duration: 4, seed: 711)
        #expect(try AdaptiveAlignment.measure(
            reference: reference, target: unrelated, station: 0, predictedOffset: -0.17, deviation: 0.35
        ).allSatisfy { $0.status != "eligible" })
        let step = try SyntheticSpeech.track(start: 100.5, duration: 4, offset: -0.17,
                                            stepAt: 102.5, step: 0.02)
        let crossing = try AdaptiveAlignment.measure(
            reference: reference, target: step, station: 0, predictedOffset: -0.17, deviation: 0.35
        )
        #expect(crossing.filter { abs($0.targetCenter - 102.5) < 0.01 }.allSatisfy { $0.status != "eligible" })
    }

    @Test func shortSpeechRequiresThreeActuallyDisjointMeasuredSubwindows() throws {
        func evidence(centers: [Double], badDelay: Bool = false) -> DelayEvidence {
            DelayEvidence(station: 0, attempt: 0, targetCenter: 10, status: "eligible",
                offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1,
                phatOffsetSeconds: -0.2, phatPeakRatio: 0.1, method: AdaptiveAlignment.fineMethod, polarity: -1,
                corroborations: centers.enumerated().map {
                    TemporalCorroboration(targetCenter: $0.element,
                        offsetSeconds: badDelay && $0.offset == 2 ? -0.19 : -0.2,
                        score: 0.85, competingScore: 0.1, polarity: -1)
                })
        }

        let result = try AdaptiveAlignment.regions(
            observations: [evidence(centers: [9.25, 10, 10.75])], start: 0, end: 20
        )
        #expect(result.regions.count == 1)
        #expect(result.supportedSeconds == 1.5)
        #expect(result.referenceTime(at: 9.2) == nil && result.referenceTime(at: 10.75) == nil)
        #expect(try AdaptiveAlignment.regions(observations: [evidence(centers: [10, 10, 10])],
                                             start: 0, end: 20).regions.isEmpty)
        #expect(try AdaptiveAlignment.regions(observations: [evidence(centers: [9.25, 10, 10.75], badDelay: true)],
                                             start: 0, end: 20).regions.isEmpty)
    }

    @Test func upperSpeechRemeasurementKeepsOffsetTruthAndNegativeControls() throws {
        let reference = try SyntheticSpeech.track(start: 100, duration: 5, noiseLevel: 0)
        let target = try SyntheticSpeech.track(start: 100.5, duration: 4, offset: -0.17, processed: true)
        let points = try AdaptiveAlignment.measureBand(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1, upperSpeech: true)
        let usable = points.filter { $0.status == "eligible" && $0.nccScore >= 0.6 }
        #expect(!usable.isEmpty)
        for point in usable {
            #expect(abs(try #require(point.offsetSeconds) + 0.17) < 0.001)
        }
        for target in [
            try SyntheticSpeech.track(start: 100.5, duration: 4, seed: 711),
            try SyntheticSpeech.track(start: 100.5, duration: 4, offset: -0.17, stepAt: 102.5, step: 0.02),
        ] {
            let measured = try AdaptiveAlignment.measureBand(reference: reference, target: target,
                station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1, upperSpeech: true)
            #expect(measured.filter { abs($0.targetCenter - 102.5) < 0.01 }.allSatisfy { $0.status != "eligible" })
        }
    }

    static func shortPoint(_ center: Double = 10) -> DelayEvidence {
        DelayEvidence(station: 0, attempt: 0, targetCenter: center, status: "eligible",
            offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1,
            phatOffsetSeconds: -0.2, phatPeakRatio: 0.1, method: AdaptiveAlignment.shortMethod, polarity: -1,
            corroborations: [-0.375, 0, 0.375, 0].enumerated().map {
                TemporalCorroboration(targetCenter: center + $0.element, offsetSeconds: -0.2,
                    score: 0.85, competingScore: 0.1, polarity: -1,
                    windowSeconds: $0.offset == 3 ? 0.5 : 0.25)
            })
    }

    @Test func shortProofCountsOnlyThreeDisjointQuartersAndNeverExtrapolates() throws {
        let point = Self.shortPoint()
        #expect(AdaptiveAlignment.shortCorroborations(point)?.count == 3)
        let result = try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20)
        let region = try #require(result.regions.first)
        #expect(result.regions.count == 1 && region.measurements == 3)
        #expect(region.sourceStart == 9.625 && region.sourceEnd == 10.375)
        #expect(result.referenceTime(at: 9.5) == nil && result.referenceTime(at: 10.4) == nil)
        #expect(abs(try #require(result.referenceTime(at: 10)) - 9.8) < 1e-9)
    }

    @Test func longEarlierContextsCannotHideACompleteIndependentShortProof() throws {
        let observations = Self.points(9..<10, offset: -0.2) + [Self.shortPoint()]
        let result = try AdaptiveAlignment.regions(observations: observations, start: 0, end: 20)
        #expect(result.regions.count == 1)
        #expect(result.regions.first?.measurements == 4, "every observation still participates in the fit")
        #expect(result.regions.first?.sourceStart == 9.625)
        #expect(result.regions.first?.sourceEnd == 10.375)
    }

    @Test func alreadyIndependentLongContextsKeepTheirBoundsAlongsideShortProof() throws {
        let observations = Self.points(3..<10, offset: -0.2) + [Self.shortPoint()]
        let result = try AdaptiveAlignment.regions(observations: observations, start: 0, end: 20)
        #expect(result.regions.count == 1)
        #expect(result.regions.first?.measurements == 10)
        #expect(result.regions.first?.sourceStart == 3 && result.regions.first?.sourceEnd == 10.375)
    }

    @Test func shortProofRefusesMissingAmbiguousContradictoryAndOverlappingEvidence() throws {
        let point = Self.shortPoint()
        let checks = try #require(point.corroborations)
        var invalid: [[TemporalCorroboration]?] = [nil, Array(checks.prefix(3)), checks + [checks[3]]]
        for index in checks.indices {
            let check = checks[index]
            for (center, offset, score, second, polarity, seconds) in [
                (check.targetCenter, check.offsetSeconds, 0.59999, 0.1, -1, check.windowSeconds),
                (check.targetCenter, check.offsetSeconds, 0.85, 0.8 * 0.85, -1, check.windowSeconds),
                (check.targetCenter, check.offsetSeconds + 0.0011, 0.85, 0.1, -1, check.windowSeconds),
                (check.targetCenter, check.offsetSeconds, 0.85, 0.1, 1, check.windowSeconds),
                (10.0, check.offsetSeconds, 0.85, 0.1, -1, 0.5),
                (Double.nan, check.offsetSeconds, 0.85, 0.1, -1, check.windowSeconds),
            ] {
                var replacement = checks
                replacement[index] = TemporalCorroboration(
                    targetCenter: center, offsetSeconds: offset, score: score, competingScore: second,
                    polarity: polarity, windowSeconds: seconds)
                // The canonical half is already centered and half a second long.
                if index == 3 && center == 10 && seconds == 0.5 && offset == check.offsetSeconds
                    && score == 0.85 && second == 0.1 && polarity == -1 { continue }
                invalid.append(replacement)
            }
        }
        for checks in invalid {
            var invalidPoint = point
            invalidPoint.corroborations = checks
            #expect(AdaptiveAlignment.shortCorroborations(invalidPoint) == nil)
            #expect(try AdaptiveAlignment.regions(observations: [invalidPoint], start: 0, end: 20).regions.isEmpty)
        }
        func full(
            score: Double = 0.9, second: Double = 0.1, phat: Double? = -0.2,
            ratio: Double? = 0.1, polarity: Int? = -1
        ) -> DelayEvidence {
            DelayEvidence(station: 0, attempt: 0, targetCenter: 10, status: "eligible",
                offsetSeconds: -0.2, nccScore: score, nccSecond: second,
                phatOffsetSeconds: phat, phatPeakRatio: ratio, method: AdaptiveAlignment.shortMethod,
                polarity: polarity, corroborations: checks)
        }
        for invalid in [
            full(score: 0.59999), full(second: 0.8 * 0.9),
            full(phat: nil), full(phat: .nan), full(phat: -0.1989),
            full(ratio: nil), full(ratio: 0.8), full(ratio: -0.1), full(polarity: nil),
        ] {
            #expect(AdaptiveAlignment.shortCorroborations(invalid) == nil)
            #expect(try AdaptiveAlignment.regions(observations: [invalid], start: 0, end: 20).regions.isEmpty)
        }
    }

    @Test func freshlyShortenedWindowsRecoverOnlyTheUnsteppedInterior() throws {
        let reference = try SyntheticSpeech.track(start: 100, duration: 5, noiseLevel: 0)
        let target = try SyntheticSpeech.track(start: 100.5, duration: 4, offset: -0.17,
            stepAt: 103.2, step: 0.02)
        let previous = try AdaptiveAlignment.measureBand(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1, upperSpeech: false)
        let fresh = try AdaptiveAlignment.measure(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35)
        let middle = try #require(fresh.first { abs($0.targetCenter - 102.5) < 0.001 })
        #expect(previous.first { abs($0.targetCenter - 102.5) < 0.001 }?.status != "eligible")
        #expect(middle.status == "eligible" && middle.method == AdaptiveAlignment.shortMethod)
        #expect(abs(try #require(middle.offsetSeconds) + 0.17) < 0.001)
        #expect(AdaptiveAlignment.shortCorroborations(middle)?.count == 3)
        let timing = try AdaptiveAlignment.regions(observations: fresh, start: 100, end: 105)
        #expect(timing.referenceTime(at: 102.7) != nil)
        #expect(timing.referenceTime(at: 103.2) == nil)
        for (original, replacement) in zip(previous, fresh) where original.status == "eligible" {
            #expect(replacement == original)
        }
        let unrelated = try SyntheticSpeech.track(start: 100.5, duration: 4, seed: 711)
        #expect(try AdaptiveAlignment.measureBand(reference: reference, target: unrelated,
            station: 0, predictedOffset: -0.17, deviation: 0.35,
            rateRatio: 1, upperSpeech: false, windowSeconds: 1).allSatisfy { $0.status != "eligible" })
    }

    @Test func shortWindowCoordinatesRespectSignedRateAndPolarity() throws {
        let reference = try SyntheticSpeech.track(start: 100, duration: 5, noiseLevel: 0)
        for ppm in [-500.0, 500.0] {
            for gain in [-0.4, 1] {
                let target = try SyntheticSpeech.track(start: 100.5, duration: 4, offset: -0.17,
                    ppm: ppm, noiseLevel: 0, gain: gain)
                let points = try AdaptiveAlignment.measureBand(reference: reference, target: target,
                    station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1 + ppm / 1e6,
                    upperSpeech: false, windowSeconds: 1)
                let good = points.filter { $0.status == "eligible" && $0.method == AdaptiveAlignment.shortMethod }
                #expect(good.count >= 2)
                for point in good {
                    #expect(point.polarity == (gain < 0 ? -1 : 1))
                    for check in try #require(AdaptiveAlignment.shortCorroborations(point)) {
                        let truth = -0.17 + ppm * check.targetCenter / 1e6
                        #expect(abs(check.offsetSeconds - truth) < 0.001)
                    }
                }
            }
        }
    }

    @Test func aLowScoreOrdinaryEligibleLabelCannotHideFreshSufficientShortEvidence() throws {
        let reference = try SyntheticSpeech.track(start: 100, duration: 5, noiseLevel: 0)
        let target = try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
            occurrence: SourceOccurrenceID(), groupClockStart: ExactRational(201, 2),
            buffer: SampleBuffer(samples: (0..<32000).map { index in
                let source = 100.5 + Double(index) / 8000
                return Float(SyntheticSpeech.value(source - 0.17, seed: (102..<103).contains(source) ? 42 : 886))
            }, sampleRate: 8000))
        let previous = try AdaptiveAlignment.measureBand(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1, upperSpeech: false)
        let original = try #require(previous.first { abs($0.targetCenter - 102.5) < 0.001 })
        #expect(original.status == "eligible" && original.nccScore < 0.6)
        let fresh = try AdaptiveAlignment.measure(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35)
        let middle = try #require(fresh.first { abs($0.targetCenter - 102.5) < 0.001 })
        #expect(middle.status == "eligible" && middle.method == AdaptiveAlignment.shortMethod)
        #expect(middle.nccScore >= 0.6)
        #expect(abs(try #require(middle.offsetSeconds) + 0.17) < 0.001)
        let timing = try AdaptiveAlignment.regions(observations: fresh, start: 100, end: 105)
        #expect(timing.referenceTime(at: 102.5) != nil)
        #expect(timing.referenceTime(at: 101.9) == nil && timing.referenceTime(at: 103.1) == nil)
    }

    @Test func shortWindowsDoNotResolvePeriodicEqualEchoOrUnrelatedMaterial() throws {
        let reference = try SyntheticSpeech.track(start: 100, duration: 5, noiseLevel: 0)
        let periodicReference = try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
            occurrence: SourceOccurrenceID(), groupClockStart: ExactRational(100, 1),
            buffer: SampleBuffer(samples: (0..<40000).map {
                Float(sin(2 * .pi * 220 * (100 + Double($0) / 8000)) * 0.2)
            }, sampleRate: 8000))
        for echo in [false, true] {
            let samples = (0..<32000).map { index -> Float in
                let time = 100.5 + Double(index) / 8000 - 0.17
                return Float(echo
                    ? SyntheticSpeech.value(time, seed: 42) + SyntheticSpeech.value(time - 0.06, seed: 42)
                    : sin(2 * .pi * 220 * time) * 0.2)
            }
            let target = try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
                occurrence: SourceOccurrenceID(), groupClockStart: ExactRational(201, 2),
                buffer: SampleBuffer(samples: samples, sampleRate: 8000))
            let points = try AdaptiveAlignment.measureBand(reference: echo ? reference : periodicReference, target: target,
                station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1,
                upperSpeech: false, windowSeconds: 1)
            #expect(points.allSatisfy { $0.status != "eligible" || $0.method != AdaptiveAlignment.shortMethod })
        }
        for seed in UInt64(11)..<19 {
            let target = try SyntheticSpeech.track(start: 100.5, duration: 4, seed: seed)
            let points = try AdaptiveAlignment.measureBand(reference: reference, target: target,
                station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1,
                upperSpeech: false, windowSeconds: 1)
            #expect(points.allSatisfy { $0.status != "eligible" || $0.method != AdaptiveAlignment.shortMethod })
        }
    }

    @Test func freshSpectralFallbackRetainsIndependentTruthThroughFrequencyDependentProcessing() throws {
        func track(start: Double, duration: Int, offset: Double, processed: Bool, seed: UInt64 = 42) throws -> EstimatorTrack {
            let samples = (0..<duration * 8000).map { index -> Float in
                let time = start + Double(index) / 8000 + offset
                let value = SyntheticSpeech.value(time, seed: seed)
                // A differentiator changes frequency-dependent phase without a source-clock step.
                return Float(processed ? value - SyntheticSpeech.value(time - 0.00025, seed: seed) : value)
            }
            return try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
                occurrence: SourceOccurrenceID(),
                groupClockStart: ExactRational(Int64((start * 1e6).rounded()), 1_000_000),
                buffer: SampleBuffer(samples: samples, sampleRate: 8000))
        }
        let reference = try track(start: 100, duration: 5, offset: 0, processed: false)
        let target = try track(start: 100.5, duration: 4, offset: -0.17, processed: true)
        let broad = try AdaptiveAlignment.measureBand(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35, rateRatio: 1, upperSpeech: false)
        let measured = try AdaptiveAlignment.measure(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35)
        let spectral = measured.filter { $0.method == AdaptiveAlignment.spectralMethod }
        #expect(spectral.count == 1)
        for (original, current) in zip(broad, measured) where current.method != AdaptiveAlignment.spectralMethod {
            #expect(current == original, "the fallback never replaces already sufficient broad-band evidence")
        }
        let timing = try AdaptiveAlignment.regions(observations: measured, start: 100.5, end: 104.5)
        for point in spectral {
            #expect(broad.first { $0.targetCenter == point.targetCenter }?.status != "eligible")
            #expect(abs(try #require(point.offsetSeconds) + 0.17) < 0.001)
            #expect(AdaptiveAlignment.spectralCorroborations(point) != nil)
            #expect(abs(try #require(timing.referenceTime(at: point.targetCenter)) - point.targetCenter + 0.17) < 0.001)
        }
        let unrelated = try track(start: 100.5, duration: 4, offset: -0.17, processed: true, seed: 881)
        #expect(try AdaptiveAlignment.measure(reference: reference, target: unrelated,
            station: 0, predictedOffset: -0.17, deviation: 0.35).allSatisfy { $0.status != "eligible" })
    }

    @Test func spectralSupportRequiresCompleteUpperGridAndIndependentlyAgreeingBroadLags() throws {
        func witness(
            status: String = "inconsistentSubwindows", delta: Double = 0.0006,
            score: Double = 0.9, second: Double = 0.1, phatDelta: Double = 0.0001,
            phatRatio: Double = 0.1, checkDelta: Double = 0.0006,
            middleScore: Double = 0.9, middleSecond: Double = 0.1
        ) -> SpectralTimingWitness {
            SpectralTimingWitness(status: status, offsetSeconds: -0.2 + delta, nccScore: score,
                nccSecond: second, phatOffsetSeconds: -0.2 + phatDelta, phatPeakRatio: phatRatio,
                polarity: 1, corroborations: [9.25, 10, 10.75].map {
                    TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2 + checkDelta,
                        score: $0 == 10 ? middleScore : 0.85,
                        competingScore: $0 == 10 ? middleSecond : 0.1, polarity: 1)
                })
        }
        var point = DelayEvidence(station: 0, attempt: 0, targetCenter: 10, status: "eligible",
            offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1, phatOffsetSeconds: -0.2,
            phatPeakRatio: 0.1, method: AdaptiveAlignment.spectralMethod, polarity: -1,
            corroborations: [9.25, 10, 10.75].map {
                TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2,
                    score: 0.9, competingScore: 0.1, polarity: -1)
            }, spectralWitness: witness())
        let result = try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20)
        #expect(result.regions.count == 1 && result.supportedSeconds == 1.5)
        #expect(result.regions.first?.measurements == 3)
        #expect(abs(try #require(result.referenceTime(at: 10)) - 9.8) < 1e-9)
        #expect(try JSONDecoder().decode(SpectralTimingWitness.self,
            from: JSONEncoder().encode(try #require(point.spectralWitness))) == point.spectralWitness)
        point.spectralWitness = witness(middleScore: 0.6)
        #expect(AdaptiveAlignment.spectralCorroborations(point) != nil)
        for invalid in [
            witness(status: "silent"), witness(status: "eligible"),
            witness(delta: 0.0011), witness(delta: .nan),
            witness(score: 0.59), witness(second: 0.8 * 0.9),
            witness(phatDelta: 0.0011), witness(phatRatio: 0.8),
            witness(checkDelta: 0.0011), witness(checkDelta: .infinity),
            witness(middleScore: 0.599), witness(middleSecond: 0.8 * 0.9),
        ] {
            point.spectralWitness = invalid
            #expect(AdaptiveAlignment.spectralCorroborations(point) == nil)
            #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty)
        }
        point.spectralWitness = nil
        #expect(AdaptiveAlignment.spectralCorroborations(point) == nil)
        point.spectralWitness = witness()
        point.corroborations?[0] = TemporalCorroboration(targetCenter: 9.25,
            offsetSeconds: -0.2, score: 0.9, competingScore: 0.1, polarity: 1)
        #expect(AdaptiveAlignment.spectralCorroborations(point) == nil,
                "opposite signs remain a contradiction within the same filtered band")
        point.corroborations = [9.9, 10, 10.1].map {
            TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2,
                score: 0.9, competingScore: 0.1, polarity: -1)
        }
        #expect(AdaptiveAlignment.spectralCorroborations(point) == nil,
                "cross-band agreement never supplies additional independent windows")
    }

    @Test func alternateGridsStandAloneAndNeverDiscardStrongContradictions() throws {
        func check(_ center: Double, ambiguous: Bool = false, offset: Double = -0.2, polarity: Int = -1) -> TemporalCorroboration {
            TemporalCorroboration(targetCenter: center, offsetSeconds: offset, score: 0.85,
                                  competingScore: ambiguous ? 0.8 : 0.1, polarity: polarity)
        }
        let original = [check(9.25, ambiguous: true), check(10), check(10.75)]
        let alternate = [check(9.375), check(10), check(10.625)]
        var point = DelayEvidence(station: 0, attempt: 0, targetCenter: 10, status: "eligible",
            offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1,
            phatOffsetSeconds: -0.2, phatPeakRatio: 0.1, method: AdaptiveAlignment.fineMethod, polarity: -1,
            corroborations: original + alternate)
        let result = try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20)
        #expect(result.regions.count == 1 && result.supportedSeconds == 1.25)
        #expect(result.regions.first?.measurements == 3)
        #expect(AdaptiveAlignment.supportingCorroborations(point) == alternate)
        #expect(point.corroborations?.count == 6, "all attempts remain recorded")
        point.corroborations = original + [check(9.375), check(10), check(10.625, ambiguous: true)]
        #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty,
                "two insufficient grids may not pool their individually sufficient subwindows")
        for contradictory in [check(10.75, offset: -0.19), check(10.75, polarity: 1)] {
            point.corroborations = [original[0], original[1], contradictory] + alternate
            #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty)
        }
        point.corroborations = original + [check(9.9), check(10), check(10.1)]
        #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty,
                "a winning alternative still needs three genuinely non-overlapping supports")
    }

    @Test func longerCorroborationsRetainTheirActualDurationAndCannotPretendToBeDisjoint() throws {
        func grid(_ centers: [Double], seconds: Double, ambiguous: Bool) -> [TemporalCorroboration] {
            centers.map {
                TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2, score: 0.9,
                    competingScore: ambiguous ? 0.85 : 0.1, polarity: -1, windowSeconds: seconds)
            }
        }
        let original = grid([9.25, 10, 10.75], seconds: 0.5, ambiguous: true)
            + grid([9.375, 10, 10.625], seconds: 0.5, ambiguous: true)
        let longer = grid([9.33, 10, 10.67], seconds: 0.66, ambiguous: false)
        var point = DelayEvidence(station: 0, attempt: 0, targetCenter: 10, status: "eligible",
            offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1,
            phatOffsetSeconds: -0.2, phatPeakRatio: 0.1, method: AdaptiveAlignment.fineMethod, polarity: -1,
            corroborations: original + longer)
        let result = try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20)
        #expect(result.regions.count == 1 && abs(result.supportedSeconds - 1.34) < 1e-9)
        #expect(result.regions.first?.measurements == 3)
        #expect(AdaptiveAlignment.supportingCorroborations(point) == longer)
        #expect(try JSONDecoder().decode([TemporalCorroboration].self, from: JSONEncoder().encode(longer)) == longer)
        let legacy = try JSONDecoder().decode(TemporalCorroboration.self, from: Data(
            #"{"targetCenter":10,"offsetSeconds":-0.2,"score":0.9,"competingScore":0.1,"polarity":-1}"#.utf8))
        #expect(legacy.windowSeconds == nil)
        #expect(legacy.energy == nil)
        point.corroborations = original + grid([9.45, 10, 10.55], seconds: 0.66, ambiguous: false)
        #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty,
                "longer windows overlap even where half-second windows would not")
        var malformed = longer
        malformed[0].windowSeconds = 0.01
        point.corroborations = original + malformed
        #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty)
        point.corroborations = [TemporalCorroboration(targetCenter: 9.25, offsetSeconds: -0.19,
            score: 0.9, competingScore: 0.1, polarity: -1)] + Array(original.dropFirst()) + longer
        #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).regions.isEmpty)
    }

    @Test func canonicalSequenceNeedsThreeDisjointWindowsFromSeparateObservations() throws {
        let points = [10.0, 11, 12].map { Self.sequencePoint($0) }
        #expect(try AdaptiveAlignment.regions(observations: [points[0]], start: 0, end: 20).regions.isEmpty,
                "the three recorded context checks supply only one canonical support")
        #expect(try AdaptiveAlignment.regions(observations: Array(points.prefix(2)), start: 0, end: 20).regions.isEmpty)
        let result = try AdaptiveAlignment.regions(observations: points, start: 0, end: 20)
        #expect(result.regions.count == 1 && result.supportedSeconds == 2)
        #expect(result.regions.first?.measurements == 3)
        #expect(result.referenceTime(at: 9.9) == nil && result.referenceTime(at: 12) == nil)
        #expect(abs(try #require(result.referenceTime(at: 11)) - 10.8) < 1e-9)
        let overlapping = [10.0, 10.5, 11].map { Self.sequencePoint($0) }
        #expect(try AdaptiveAlignment.regions(observations: overlapping, start: 0, end: 20).regions.isEmpty)
    }

    @Test func canonicalSequenceCannotPoolAmbiguousChecksOrChooseAnotherGrid() throws {
        #expect(AdaptiveAlignment.sequenceCorroboration(Self.sequencePoint(10, score: 0.55)) != nil)
        #expect(AdaptiveAlignment.sequenceCorroboration(Self.sequencePoint(10, score: 0.549)) == nil)
        var point = Self.sequencePoint(10, competing: 0.8 * 0.9)
        #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil)
        point.corroborations? += [9.375, 10, 10.625].map {
            TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2, score: 0.9,
                competingScore: 0.1, polarity: -1, windowSeconds: 0.5)
        }
        #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil,
                "another grid cannot rescue an insufficient canonical middle")
        point = Self.sequencePoint(10)
        point.corroborations?[1] = TemporalCorroboration(targetCenter: 10.01, offsetSeconds: -0.2,
            score: 0.9, competingScore: 0.1, polarity: -1, windowSeconds: 0.5)
        #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil)
        point = Self.sequencePoint(10)
        point.corroborations?.removeLast()
        #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil)
    }

    @Test func canonicalSequenceRetainsContextContradictionsAndExplicitGaps() throws {
        for polarity in [-1, 1] {
            var points = (10..<20).map { Self.sequencePoint(Double($0)) }
            points[5].corroborations?[0] = TemporalCorroboration(targetCenter: 14.25,
                offsetSeconds: polarity == -1 ? -0.19 : -0.2,
                score: 0.9, competingScore: 0.1, polarity: polarity, windowSeconds: 0.5)
            let result = try AdaptiveAlignment.regions(observations: points, start: 0, end: 25)
            #expect(result.regions.count == 2)
            #expect(result.referenceTime(at: 14.5) == nil && result.referenceTime(at: 15.5) == nil)
            #expect(AdaptiveAlignment.sequenceCorroboration(points[5]) == nil)
        }
        var point = Self.sequencePoint(10)
        point.corroborations? += [9.375, 10, 10.625].map {
            TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2, score: 0.9,
                competingScore: 0.85, polarity: -1, windowSeconds: 0.5)
        }
        point.corroborations?.append(TemporalCorroboration(targetCenter: 9.33, offsetSeconds: -0.19,
            score: 0.9, competingScore: 0.1, polarity: -1, windowSeconds: 0.66))
        #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil,
                "even a partially measured later grid retains its strong contradiction")
    }

    @Test func canonicalSequenceAlsoVetoesWeakOrAmbiguousButDisagreeingContext() throws {
        for check in [
            TemporalCorroboration(targetCenter: 9.25, offsetSeconds: -0.19,
                score: 0.9, competingScore: 0.85, polarity: -1),
            TemporalCorroboration(targetCenter: 9.25, offsetSeconds: -0.2,
                score: 0.9, competingScore: 0.85, polarity: 1),
            TemporalCorroboration(targetCenter: 9.25, offsetSeconds: -0.2,
                score: 0.54, competingScore: 0.1, polarity: -1),
        ] {
            var point = Self.sequencePoint(10)
            point.corroborations?[0] = check
            #expect(!AdaptiveAlignment.hasStrongContradiction(try #require(point.corroborations), to: point),
                    "these checks would escape the ordinary strong-unique contradiction veto")
            #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil)
        }
    }

    @Test func freshCanonicalMeasurementRefusesAmbiguousContextDespiteUniqueMiddle() throws {
        func noise(_ time: Double, rate: Double, seed: UInt64) -> Double {
            let position = time * rate, index = Int64(floor(position)), fraction = position - floor(position)
            return SyntheticSpeech.noise(seed, index) * (1 - fraction)
                + SyntheticSpeech.noise(seed, index + 1) * fraction
        }
        func signal(_ time: Double, highPolarity: Double) -> Float {
            let local = time - 101.33
            let weight = min(1, max(0, (0.3 - abs(local)) / 0.03))
            let carrier = 0.2 * sin(2 * .pi * 220 * time)
            let chirp = 0.2 * sin(2 * .pi * (400 * local + 400 * local * local))
            let shared = 0.005 * noise(time, rate: 600, seed: 791)
            let high = 0.04 * (noise(time, rate: 4000, seed: 182)
                - noise(time - 0.00025, rate: 4000, seed: 182))
            return Float(carrier * (1 - weight) + chirp * weight + shared + highPolarity * high)
        }
        func track(start: Double, duration: Int, offset: Double, highPolarity: Double) throws -> EstimatorTrack {
            let samples = (0..<duration * 8000).map {
                signal(start + Double($0) / 8000 + offset, highPolarity: highPolarity)
            }
            return try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
                occurrence: SourceOccurrenceID(),
                groupClockStart: ExactRational(Int64((start * 1e6).rounded()), 1_000_000),
                buffer: SampleBuffer(samples: samples, sampleRate: 8000))
        }
        let reference = try track(start: 100, duration: 5, offset: 0, highPolarity: 1)
        let target = try track(start: 100.5, duration: 4, offset: -0.17, highPolarity: -1)
        let measured = try AdaptiveAlignment.measure(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35)
        let point = try #require(measured.first { ($0.corroborations?.count ?? 0) >= 3 })
        let checks = try #require(point.corroborations)
        let middle = checks[1]
        #expect(point.status == "eligible" && point.method == AutomaticAlignment.fineMethod,
                "insufficient canonical context must retain a valid ordinary fallback")
        #expect(middle.score >= 0.55 && middle.competingScore < 0.8 * middle.score)
        #expect(abs(middle.offsetSeconds + 0.17) < 0.001)
        #expect(!AdaptiveAlignment.hasStrongContradiction(checks, to: point))
        #expect(checks.contains {
            $0.score >= 0.55 && $0.competingScore >= 0.8 * $0.score
                && ($0.polarity != point.polarity || abs($0.offsetSeconds + 0.17) > 0.001)
        })
        #expect(AdaptiveAlignment.sequenceCorroboration(point) == nil)
        #expect(measured.allSatisfy { $0.method != AdaptiveAlignment.sequenceMethod })
        #expect(AdaptiveAlignment.sequenceCorroboration(point, allowingSharedQuiet: true) == nil)
        #expect(measured.allSatisfy { $0.method != AdaptiveAlignment.quietSequenceMethod })
    }

    static func quietSequencePoint(_ center: Double) -> DelayEvidence {
        let anchor = TemporalCorroboration.Energy(targetRMS: 0.1, referenceRMS: 0.1,
            targetPeak: 0.4, referencePeak: 0.4)
        let quiet = TemporalCorroboration.Energy(targetRMS: 1e-5, referenceRMS: 1e-5,
            targetPeak: 1e-4, referencePeak: 1e-4)
        return DelayEvidence(station: 0, attempt: 0, targetCenter: center, status: "eligible",
            offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1, phatOffsetSeconds: -0.2,
            phatPeakRatio: 0.1, method: AdaptiveAlignment.quietSequenceMethod, polarity: -1,
            corroborations: [-0.75, 0, 0.75].map {
                TemporalCorroboration(targetCenter: center + $0, offsetSeconds: $0 == 0 ? -0.2 : -0.19,
                    score: $0 == 0 ? 0.9 : 0.1, competingScore: 0.09,
                    polarity: $0 == 0 ? -1 : 1, windowSeconds: 0.5, energy: $0 == 0 ? anchor : quiet)
            })
    }

    @Test func measuredSharedQuietContextSuppliesNoTimingOrExtraIndependence() throws {
        let points = [10.0, 11, 12].map(Self.quietSequencePoint)
        #expect(AdaptiveAlignment.sequenceCorroboration(points[0]) == nil)
        #expect(AdaptiveAlignment.sequenceCorroboration(points[0], allowingSharedQuiet: true) != nil)
        for count in 1...2 {
            #expect(try AdaptiveAlignment.regions(observations: Array(points.prefix(count)),
                start: 0, end: 20).regions.isEmpty)
        }
        let result = try AdaptiveAlignment.regions(observations: points, start: 0, end: 20)
        #expect(result.regions.count == 1 && result.regions.first?.measurements == 3)
        #expect(result.supportedSeconds == 2)
        #expect(abs(try #require(result.referenceTime(at: 11)) - 10.8) < 1e-9)
        #expect(result.referenceTime(at: 9.9) == nil && result.referenceTime(at: 12) == nil)
        let checks = try #require(points[0].corroborations)
        #expect(try JSONDecoder().decode([TemporalCorroboration].self,
            from: JSONEncoder().encode(checks)) == checks)
    }

    @Test func quietContextRequiresBothSourcesAndBothAbsoluteAndRelativeEnergyGuards() throws {
        typealias Energy = TemporalCorroboration.Energy
        let refused = [
            Energy(targetRMS: 1e-5, referenceRMS: 0.04, targetPeak: 1e-4, referencePeak: 0.1),
            Energy(targetRMS: 0.04, referenceRMS: 1e-5, targetPeak: 0.1, referencePeak: 1e-4),
            Energy(targetRMS: 1e-4, referenceRMS: 1e-5, targetPeak: 1e-3, referencePeak: 1e-4),
            Energy(targetRMS: 1e-5, referenceRMS: 1e-4, targetPeak: 1e-4, referencePeak: 1e-3),
            Energy(targetRMS: 1e-5, referenceRMS: 1e-5, targetPeak: 0.041, referencePeak: 1e-4),
            Energy(targetRMS: 1e-5, referenceRMS: 1e-5, targetPeak: 1e-4, referencePeak: 0.041),
            Energy(targetRMS: -.ulpOfOne, referenceRMS: 0, targetPeak: 0, referencePeak: 0),
            Energy(targetRMS: 0, referenceRMS: .nan, targetPeak: 0, referencePeak: 0),
            Energy(targetRMS: 0, referenceRMS: 0, targetPeak: .infinity, referencePeak: 0),
            Energy(targetRMS: 1e-5, referenceRMS: 0, targetPeak: 0, referencePeak: 0),
        ]
        for energy in refused {
            var point = Self.quietSequencePoint(10)
            point.corroborations?[0].energy = energy
            #expect(AdaptiveAlignment.sequenceCorroboration(point, allowingSharedQuiet: true) == nil)
            #expect(try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20).usableWindows == 0)
        }
        for target in [true, false] {
            var point = Self.quietSequencePoint(10)
            point.corroborations?[1].energy = Energy(
                targetRMS: target ? 1e-4 : 0.1, referenceRMS: target ? 0.1 : 1e-4,
                targetPeak: 0.4, referencePeak: 0.4)
            #expect(AdaptiveAlignment.sequenceCorroboration(point, allowingSharedQuiet: true) == nil,
                    "absolute quiet alone cannot replace the relative RMS guard")
        }
        for index in [0, 1] {
            var point = Self.quietSequencePoint(10)
            point.corroborations?[index].energy = nil
            #expect(AdaptiveAlignment.sequenceCorroboration(point, allowingSharedQuiet: true) == nil,
                    "legacy or missing energy is never proof of quiet context")
        }
    }

    @Test func sharedQuietCannotEraseStrongContradictionsOrAnInsufficientCanonicalMiddle() throws {
        var points = (10..<20).map { Self.quietSequencePoint(Double($0)) }
        let quiet = try #require(points[5].corroborations?[0].energy)
        points[5].corroborations?[0] = TemporalCorroboration(targetCenter: 14.25,
            offsetSeconds: -0.19, score: 0.9, competingScore: 0.1, polarity: -1, energy: quiet)
        #expect(AdaptiveAlignment.sequenceCorroboration(points[5], allowingSharedQuiet: true) == nil)
        let result = try AdaptiveAlignment.regions(observations: points, start: 0, end: 25)
        #expect(result.regions.count == 2)
        #expect(result.referenceTime(at: 14.5) == nil && result.referenceTime(at: 15.5) == nil)
        var point = Self.quietSequencePoint(10)
        point.corroborations?[1] = TemporalCorroboration(targetCenter: 10, offsetSeconds: -0.2,
            score: 0.54, competingScore: 0.1, polarity: -1, energy: quiet)
        #expect(AdaptiveAlignment.sequenceCorroboration(point, allowingSharedQuiet: true) == nil)
    }

    @Test func freshLocalizedQuietSpeechIsNotHiddenByOverlappingOrdinaryWindows() throws {
        func track(start: Double, duration: Int, offset: Double, seed: UInt64) throws -> EstimatorTrack {
            let samples = (0..<duration * 8000).map { index -> Float in
                let time = start + Double(index) / 8000 + offset
                var value = 1e-6 * SyntheticSpeech.noise(seed, Int64(floor(time * 8000)))
                for utterance in 0..<3 {
                    let local = time - (101.33 + Double(utterance))
                    let weight = min(1, max(0, (0.22 - abs(local)) / 0.02))
                    value += 0.2 * weight * sin(2 * .pi
                        * ((400 + 80 * Double(utterance)) * local + 650 * local * local))
                }
                return Float(value)
            }
            return try EstimatorTrack(group: RecorderGroupID(), epoch: RecordingEpochID(),
                occurrence: SourceOccurrenceID(),
                groupClockStart: ExactRational(Int64((start * 1e6).rounded()), 1_000_000),
                buffer: SampleBuffer(samples: samples, sampleRate: 8000))
        }
        let reference = try track(start: 100, duration: 5, offset: 0, seed: 193)
        let target = try track(start: 100.5, duration: 4, offset: -0.17, seed: 337)
        let ordinary = try AutomaticAlignment.measure(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35)
        #expect(ordinary.first?.status == "eligible")
        let measured = try AdaptiveAlignment.measure(reference: reference, target: target,
            station: 0, predictedOffset: -0.17, deviation: 0.35)
        #expect(measured.first?.method == AdaptiveAlignment.quietSequenceMethod,
                "a valid full-window match must not hide independently measured shorter support")
        let result = try AdaptiveAlignment.regions(observations: measured, start: 100.5, end: 104.5)
        #expect(result.regions.count == 1 && abs(result.supportedSeconds - 2) < 0.001)
        for time in [101.5, 102, 103] {
            #expect(abs(try #require(result.referenceTime(at: time)) - time + 0.17) < 0.001)
        }
    }

    @Test func individuallySufficientGridsRetainAnAdmissibleLineWhenUnconstrainedLeastSquaresFails() throws {
        for deltas in [[0.0009, 0, -0.0009], [0.0009, -0.0009, 0.0009]] {
            let checks = zip([9.25, 10, 10.75], deltas).map {
                TemporalCorroboration(targetCenter: $0, offsetSeconds: -0.2 + $1,
                    score: 0.9, competingScore: 0.1, polarity: -1)
            }
            let point = DelayEvidence(station: 0, attempt: 0, targetCenter: 10, status: "eligible",
                offsetSeconds: -0.2, nccScore: 0.9, nccSecond: 0.1,
                phatOffsetSeconds: -0.2, phatPeakRatio: 0.1,
                method: AdaptiveAlignment.fineMethod, polarity: -1, corroborations: checks)
            #expect(AdaptiveAlignment.supportingCorroborations(point) == checks)
            let result = try AdaptiveAlignment.regions(observations: [point], start: 0, end: 20)
            let region = try #require(result.regions.first,
                "a zero-slope line already satisfies every measured check within 0.9 ms")
            #expect(result.regions.count == 1 && region.measurements == 3)
            #expect(abs((region.rateRatio - 1) * 1e6) <= 500)
            #expect(region.maximumResidualMilliseconds <= 1)
            for check in checks {
                #expect(abs(region.rateRatio * check.targetCenter + region.offsetSeconds
                    - check.targetCenter - check.offsetSeconds) <= 0.001)
            }
        }
    }
}
