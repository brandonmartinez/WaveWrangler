import Foundation

/// A least-squares line in centred coordinates: offset(u) = intercept + slope * (u - centre).
struct LineFit: Sendable, Equatable {
    let centre: Double
    let intercept: Double
    let slope: Double

    func offset(at u: Double) -> Double { intercept + slope * (u - centre) }

    /// nil when fewer than two distinct abscissae.
    static func leastSquares(_ points: [(u: Double, o: Double)]) -> LineFit? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let centre = points.reduce(0) { $0 + $1.u } / n
        let mean = points.reduce(0) { $0 + $1.o } / n
        var sxx = 0.0, sxy = 0.0
        for p in points {
            let du = p.u - centre
            sxx += du * du
            sxy += du * (p.o - mean)
        }
        guard sxx > 0 else { return nil }
        return LineFit(centre: centre, intercept: mean, slope: sxy / sxx)
    }

    func maximumResidual(_ points: [(u: Double, o: Double)]) -> Double {
        points.reduce(0) { max($0, abs($1.o - offset(at: $1.u))) }
    }
}

enum FitOutcome: Sendable, Equatable {
    case consistent(LineFit)
    /// The points split (in time order) into two consistent runs whose lines disagree at the split.
    case discontinuous(stepSeconds: Double, atGroupClock: Double)
    case inconsistent(maximumResidualSeconds: Double)
}

enum ConsistencyFit {
    /// Strict fit: EVERY point must lie within `tolerance` of one least-squares line. A single stray window is
    /// not trimmed away: it either reveals a step (discontinuous) or an inconsistency, and both abstain.
    static func fit(_ points: [(u: Double, o: Double)], tolerance: Double) -> FitOutcome {
        let sorted = points.sorted { $0.u < $1.u }
        guard let line = LineFit.leastSquares(sorted) else { return .inconsistent(maximumResidualSeconds: .infinity) }
        let residual = line.maximumResidual(sorted)
        if residual <= tolerance { return .consistent(line) }
        var bestStep: (step: Double, at: Double)?
        if sorted.count >= 4 {
            for split in 2...(sorted.count - 2) {
                let left = Array(sorted[..<split]), right = Array(sorted[split...])
                guard let l = LineFit.leastSquares(left), let r = LineFit.leastSquares(right),
                      l.maximumResidual(left) <= tolerance, r.maximumResidual(right) <= tolerance else { continue }
                let at = 0.5 * (sorted[split - 1].u + sorted[split].u)
                let step = abs(r.offset(at: at) - l.offset(at: at))
                if step > tolerance, step > (bestStep?.step ?? 0) { bestStep = (step, at) }
            }
        }
        if let bestStep { return .discontinuous(stepSeconds: bestStep.step, atGroupClock: bestStep.at) }
        return .inconsistent(maximumResidualSeconds: residual)
    }
}
