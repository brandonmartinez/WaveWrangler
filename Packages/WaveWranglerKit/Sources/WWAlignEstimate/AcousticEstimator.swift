import Foundation
import WWCore
import WWTimeMap

/// The WW-016 acoustic offset/drift estimator. See the module header in Inputs.swift: it emits
/// acoustically consistent PROPOSALS or ABSTENTIONS and never approves a clock.
public enum AcousticEstimator {
    /// The frozen estimator (`m2-freeze-estimator`): stamped only when every parameter equals the frozen default.
    public static let identifier = "ww-align-estimate/1"
    /// Stamped on reports and proposals produced with any non-frozen parameter.
    public static let customIdentifier = identifier + "+custom"

    static func identifier(for parameters: EstimatorParameters) -> String {
        parameters == EstimatorParameters() ? identifier : customIdentifier
    }
    /// Half-width of the pairwise search used by the cycle check around the predicted pairwise offset, seconds.
    static let cycleSearchSeconds = 0.25

    /// Synchronous and CPU-bound; run it off the main thread.
    public static func estimate(_ request: EstimationRequest, parameters: EstimatorParameters = EstimatorParameters()) throws(AlignEstimateError) -> EstimationReport {
        try parameters.validate()
        var seen: Set<RecordingEpochID> = []
        for track in request.tracks {
            guard track.epoch != request.reference.epoch else { throw .referenceEpochInTracks(track.epoch) }
            guard seen.insert(track.epoch).inserted else { throw .duplicateEpoch(track.epoch) }
            let overlap = track.overlapFrames
            guard overlap.lowerBound >= 0, overlap.upperBound <= track.buffer.samples.count, !overlap.isEmpty else {
                throw .invalidDeclaredOverlap(track.occurrence)
            }
        }
        var epochsPerGroup: [RecorderGroupID: Int] = [request.reference.group: 1]
        for track in request.tracks { epochsPerGroup[track.group, default: 0] += 1 }

        let windowLength = Int((parameters.windowSeconds * parameters.proxyRate).rounded())
        var correlator = WindowCorrelator(parameters: parameters, windowLength: windowLength)
        let reference = ProxySignal(buffer: request.reference.buffer, parameters: parameters)
        let referenceStart = request.reference.groupClockStart.approximateDouble

        var drafts: [Draft] = []
        for track in request.tracks {
            var draft = try analyse(track, reference: reference, referenceStart: referenceStart, search: request.search, parameters: parameters, windowLength: windowLength, correlator: &correlator)
            if (epochsPerGroup[track.group] ?? 0) > 1 { draft.flags.insert(.restartedEpoch) }
            drafts.append(draft)
        }
        checkCycles(&drafts, parameters: parameters, correlator: &correlator)
        return EstimationReport(estimator: identifier(for: parameters), epochs: drafts.map(\.estimate))
    }

    // MARK: - Per-epoch analysis

    struct Draft {
        let track: EstimatorTrack
        let proxy: ProxySignal
        let clockStart: Double
        let windowStarts: [Int]
        var outcome: EpochOutcome
        let windows: [WindowMeasurement]
        let coverage: WindowCoverage
        let scores: EvidenceScores
        var flags: Set<EstimateFlag>
        var cycleTriangles = 0
        var cycleMaximumMilliseconds = 0.0
        /// The proposal's exact map as doubles (t = a*u + b), for the cycle check.
        var map: (a: Double, b: Double)?

        var estimate: EpochEstimate {
            EpochEstimate(group: track.group, epoch: track.epoch, occurrence: track.occurrence, outcome: outcome, windows: windows, coverage: coverage, scores: scores, flags: flags,
                          cycle: cycleTriangles == 0 ? .unavailable : .measured(triangles: cycleTriangles, maximumMilliseconds: cycleMaximumMilliseconds))
        }
    }

    private static func analyse(_ track: EstimatorTrack, reference: ProxySignal, referenceStart: Double, search: SearchRange, parameters: EstimatorParameters, windowLength nw: Int, correlator: inout WindowCorrelator) throws(AlignEstimateError) -> Draft {
        let proxy = ProxySignal(buffer: track.buffer, parameters: parameters)
        let rate = Double(track.buffer.sampleRate)
        let fp = parameters.proxyRate
        let e = track.groupClockStart.approximateDouble
        let overlap = track.overlapFrames
        let declaredStart = e + Double(overlap.lowerBound) / rate
        let declaredEnd = e + Double(overlap.upperBound) / rate
        let p0 = Int((Double(overlap.lowerBound) * fp / rate).rounded(.up))
        let p1 = min(proxy.samples.count, Int((Double(overlap.upperBound) * fp / rate).rounded(.down)))

        let k = parameters.windowCount
        var starts: [Int] = []
        if p1 - p0 >= nw {
            let room = Double(p1 - p0 - nw)
            starts = (0..<k).map { p0 + Int((room * Double($0) / Double(k - 1)).rounded()) }
        }
        var windows: [WindowMeasurement] = []
        for (index, start) in starts.enumerated() {
            let o = correlator.observe(target: proxy, targetStart: start, targetClockStart: e, reference: reference, referenceClockStart: referenceStart, predictedOffset: search.centerOffsetSeconds, deviation: search.maximumDeviationSeconds)
            windows.append(WindowMeasurement(index: index, groupClockCenter: e + (Double(start) + Double(nw) / 2) / fp, status: o.status, peakScore: o.peakScore, secondPeakScore: o.secondPeakScore, periodicityScore: o.periodicityScore, offsetSeconds: o.offsetSeconds))
        }

        let eligible = windows.filter { $0.status == .eligible }
        let windowHalf = Double(nw) / 2 / fp
        let declaredLength = declaredEnd - declaredStart
        var span = 0.0
        if let first = eligible.first, let last = eligible.last, declaredLength > 0 {
            span = min(1, max(0, ((last.groupClockCenter + windowHalf) - (first.groupClockCenter - windowHalf)) / declaredLength))
        }
        let eligibleFraction = windows.isEmpty ? 0 : Double(eligible.count) / Double(windows.count)
        let coverage = WindowCoverage(declaredStart: declaredStart, declaredEnd: declaredEnd, windowCount: windows.count, eligibleCount: eligible.count, eligibleWindowFraction: eligibleFraction, eligibleSpanFraction: span)
        let scores = EvidenceScores(medianPeakScore: Stats.median(eligible.map(\.peakScore)),
                                    medianPeakMargin: Stats.median(eligible.map { $0.peakScore > 0 ? 1 - max(0, $0.secondPeakScore) / $0.peakScore : 0 }))
        var flags: Set<EstimateFlag> = []
        if let firstEligible = windows.firstIndex(where: { $0.status == .eligible }), let lastEligible = windows.lastIndex(where: { $0.status == .eligible }) {
            var run = 0
            for w in windows[firstEligible...lastEligible] {
                run = w.status == .eligible ? 0 : run + 1
                if run >= 2 { flags.insert(.coverageGap) }
            }
        }

        func abstain(_ reason: AbstentionReason, _ detail: String) -> Draft {
            Draft(track: track, proxy: proxy, clockStart: e, windowStarts: starts, outcome: .abstained(Abstention(reason: reason, detail: detail)), windows: windows, coverage: coverage, scores: scores, flags: flags)
        }

        guard !windows.isEmpty else {
            return abstain(.insufficientCoverage, "declared overlap is shorter than one \(parameters.windowSeconds) s analysis window")
        }
        if eligible.count < ProvisionalClockGates.minimumWindows || eligibleFraction < ProvisionalClockGates.minimumEligibleWindowFraction {
            let (reason, count) = dominantReason(windows)
            return abstain(reason, "\(eligible.count) of \(windows.count) windows eligible (need at least \(ProvisionalClockGates.minimumWindows) and a fraction of \(ProvisionalClockGates.minimumEligibleWindowFraction)); most frequent: \(reason.rawValue) in \(count)")
        }
        if span < ProvisionalClockGates.minimumOverlapSpanFraction {
            return abstain(.insufficientCoverage, "eligible windows span \(span) of the declared overlap (need \(ProvisionalClockGates.minimumOverlapSpanFraction))")
        }
        let tolerance = parameters.consistencyToleranceMilliseconds / 1000
        let points = eligible.compactMap { w in w.offsetSeconds.map { (u: w.groupClockCenter, o: $0) } }
        let line: LineFit
        switch ConsistencyFit.fit(points, tolerance: tolerance) {
        case .consistent(let fitted): line = fitted
        case .discontinuous(let step, let at):
            flags.insert(.discontinuity)
            return abstain(.discontinuous, "offset steps by \(step * 1000) ms near group-clock \(at) s; declare an epoch boundary or anchor manually")
        case .inconsistent(let residual):
            return abstain(.inconsistent, "eligible windows deviate up to \(residual * 1000) ms from any single offset/drift line (tolerance \(parameters.consistencyToleranceMilliseconds) ms)")
        }
        let ppm = line.slope * 1e6
        guard abs(ppm) <= parameters.maximumAbsolutePPM else {
            return abstain(.implausibleDrift, "fitted drift \(ppm) ppm exceeds \(parameters.maximumAbsolutePPM) ppm")
        }
        let residualsMs = points.map { abs($0.o - line.offset(at: $0.u)) * 1000 }
        let p95 = Stats.nearestRank(residualsMs, 0.95)
        let maxResidual = residualsMs.max() ?? 0
        guard p95 <= ProvisionalClockGates.maximumResidualP95Milliseconds, maxResidual <= ProvisionalClockGates.maximumResidualMaxMilliseconds else {
            return abstain(.inconsistent, "acoustic residual p95 \(p95) ms / max \(maxResidual) ms outside the provisional gates")
        }

        // Exact map: a to 1 ppb, b to 1 ns, over exactly the declared overlap.
        let ppb = (line.slope * 1e9).rounded()
        guard ppb.isFinite, abs(ppb) < 1e9 else { return abstain(.implausibleDrift, "fitted drift is not representable") }
        let aNumerator = Int64(1_000_000_000) + Int64(ppb)
        let aDouble = Double(aNumerator) / 1e9
        let bDouble = (line.centre + line.intercept) - aDouble * line.centre
        let bNanos = (bDouble * 1e9).rounded()
        guard bNanos.isFinite, abs(bNanos) < 9e18 else { throw .timeMap(.exactArithmeticEnvelopeExceeded) }
        let segment: AffineClockSegment
        let provenance: AcousticConsistencyProposal
        do throws(TimeMapError) {
            let start = try track.groupClockStart.adding(ExactRational(Int64(overlap.lowerBound), Int64(track.buffer.sampleRate)))
            let end = try track.groupClockStart.adding(ExactRational(Int64(overlap.upperBound), Int64(track.buffer.sampleRate)))
            segment = try AffineClockSegment(groupClockStart: start, groupClockEnd: end, rateRatio: ExactRational(aNumerator, 1_000_000_000), alignedOffset: ExactRational(Int64(bNanos), 1_000_000_000))
            let measurements = try AcousticConsistencyMeasurements(windowCount: eligible.count, overlapSpanFraction: span, eligibleWindowFraction: eligibleFraction, acousticResidualP95Milliseconds: p95, acousticResidualMaxMilliseconds: maxResidual)
            provenance = try AcousticConsistencyProposal(estimator: identifier(for: parameters), evidenceScore: scores.medianPeakScore, measurements: measurements, seed: search.seed)
        } catch {
            throw .timeMap(error)
        }
        let proposal = AcousticProposal(segment: segment, ppm: ppm, offsetAtCenterSeconds: line.intercept, acousticResidualP95Milliseconds: p95, acousticResidualMaxMilliseconds: maxResidual, provenance: provenance)
        var draft = Draft(track: track, proxy: proxy, clockStart: e, windowStarts: starts, outcome: .acousticConsistentProposal(proposal), windows: windows, coverage: coverage, scores: scores, flags: flags)
        draft.map = (aDouble, Double(Int64(bNanos)) / 1e9)
        return draft
    }

    /// The most frequent non-eligible window status, as an abstention reason. Ties resolve in the order
    /// disconnected, silent, periodic, ambiguous, weak (edge peaks count as weak).
    static func dominantReason(_ windows: [WindowMeasurement]) -> (AbstentionReason, Int) {
        let order: [AbstentionReason] = [.disconnected, .silent, .periodic, .ambiguous, .weak]
        var counts: [AbstentionReason: Int] = [:]
        for w in windows {
            switch w.status {
            case .eligible: break
            case .noReference: counts[.disconnected, default: 0] += 1
            case .silent: counts[.silent, default: 0] += 1
            case .periodic: counts[.periodic, default: 0] += 1
            case .ambiguous: counts[.ambiguous, default: 0] += 1
            case .weak, .edgePeak: counts[.weak, default: 0] += 1
            }
        }
        var best = (AbstentionReason.weak, 0)
        for reason in order where (counts[reason] ?? 0) > best.1 { best = (reason, counts[reason] ?? 0) }
        return best
    }

    // MARK: - Cycle consistency

    /// For every pair of proposals in different groups, re-measure one against the other directly and check
    /// that the triangle (reference, i, j) closes. A failure abstains both epochs. Honest limit: one sound
    /// source heard with a constant delay per recorder still closes every triangle, so cycles cannot detect
    /// acoustic delay; they catch inconsistent pairwise solutions.
    private static func checkCycles(_ drafts: inout [Draft], parameters: EstimatorParameters, correlator: inout WindowCorrelator) {
        let tolerance = parameters.cycleToleranceMilliseconds
        var failed: [Int: Double] = [:]
        for i in drafts.indices {
            for j in drafts.indices where j > i {
                guard drafts[i].track.group != drafts[j].track.group, let mi = drafts[i].map, let mj = drafts[j].map else { continue }
                var residuals: [Double] = []
                let nw = correlator.windowLength
                for start in drafts[j].windowStarts {
                    let u0 = drafts[j].clockStart + Double(start) / parameters.proxyRate
                    let predicted = (mj.a * u0 + mj.b - mi.b) / mi.a - u0
                    let o = correlator.observe(target: drafts[j].proxy, targetStart: start, targetClockStart: drafts[j].clockStart, reference: drafts[i].proxy, referenceClockStart: drafts[i].clockStart, predictedOffset: predicted, deviation: cycleSearchSeconds)
                    guard o.status == .eligible, let offset = o.offsetSeconds else { continue }
                    let uc = u0 + Double(nw) / 2 / parameters.proxyRate
                    residuals.append(abs(mi.a * (uc + offset) + mi.b - (mj.a * uc + mj.b)) * 1000)
                }
                guard residuals.count >= ProvisionalClockGates.minimumWindows, let worst = residuals.max() else { continue }
                for index in [i, j] {
                    drafts[index].cycleTriangles += 1
                    drafts[index].cycleMaximumMilliseconds = max(drafts[index].cycleMaximumMilliseconds, worst)
                    if worst > tolerance { failed[index] = max(failed[index] ?? 0, worst) }
                }
            }
        }
        for (index, worst) in failed {
            drafts[index].flags.insert(.cycleInconsistent)
            drafts[index].map = nil
            drafts[index].outcome = .abstained(Abstention(reason: .cycleInconsistent, detail: "a cycle through this epoch disagrees by \(worst) ms (tolerance \(tolerance) ms)"))
        }
    }
}
