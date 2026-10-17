import Foundation
import WWAlignEstimate

struct AffineFit: Sendable {
    let center: Double
    let intercept: Double
    let slope: Double

    func offset(at time: Double) -> Double { intercept + slope * (time - center) }

    static func weighted(_ points: [DelayEvidence]) -> AffineFit? {
        guard points.count >= 2 else { return nil }
        let weight = points.reduce(0) { $0 + $1.weight }
        let center = points.reduce(0) { $0 + $1.weight * $1.targetCenter } / weight
        let mean = points.reduce(0) { $0 + $1.weight * ($1.offsetSeconds ?? 0) } / weight
        let xx = points.reduce(0) { $0 + $1.weight * pow($1.targetCenter - center, 2) }
        let xy = points.reduce(0) { $0 + $1.weight * ($1.targetCenter - center) * (($1.offsetSeconds ?? 0) - mean) }
        guard xx > 1e-12 else { return nil }
        return AffineFit(center: center, intercept: mean, slope: xy / xx)
    }
}

enum RobustFit {
    enum Outcome {
        case success(AffineFit)
        case failure(AbstentionReason)
    }

    /// Exhaustive two-point consensus (at most 120 hypotheses), followed by quality-weighted refinement.
    /// Only isolated outliers can be trimmed. Adjacent contradictory stations, two coherent regions or
    /// a substantial alternate solution always refuse; consensus is not permission to erase a restart.
    static func fit(
        _ points: [DelayEvidence], tolerance: Double = AutomaticAlignment.fitToleranceSeconds, minimumPoints: Int = 5
    ) -> Outcome {
        let sorted = points.sorted { $0.targetCenter < $1.targetCenter }
        guard sorted.count >= minimumPoints else { return .failure(.insufficientCoverage) }
        if let whole = AffineFit.weighted(sorted),
           sorted.allSatisfy({ abs(($0.offsetSeconds ?? .infinity) - whole.offset(at: $0.targetCenter)) <= tolerance }) {
            return .success(whole)
        }
        for split in sorted.indices where split >= 3 && sorted.count - split >= 3 {
            let left = Array(sorted[..<split]), right = Array(sorted[split...])
            guard let a = AffineFit.weighted(left), let b = AffineFit.weighted(right),
                  left.allSatisfy({ abs(($0.offsetSeconds ?? .infinity) - a.offset(at: $0.targetCenter)) <= tolerance }),
                  right.allSatisfy({ abs(($0.offsetSeconds ?? .infinity) - b.offset(at: $0.targetCenter)) <= tolerance })
            else { continue }
            let at = (left.last!.targetCenter + right.first!.targetCenter) / 2
            if abs(a.offset(at: at) - b.offset(at: at)) > 2 * tolerance { return .failure(.discontinuous) }
        }
        var best: [DelayEvidence] = []
        var bestWeight = 0.0
        for i in sorted.indices {
            for j in sorted.indices where j > i {
                guard let line = AffineFit.weighted([sorted[i], sorted[j]]) else { continue }
                let inside = sorted.filter { abs(($0.offsetSeconds ?? .infinity) - line.offset(at: $0.targetCenter)) <= tolerance }
                let weight = inside.reduce(0) { $0 + $1.weight }
                if inside.count > best.count || (inside.count == best.count && weight > bestWeight) {
                    best = inside
                    bestWeight = weight
                }
            }
        }
        guard best.count >= minimumPoints, Double(best.count) / Double(sorted.count) >= 0.8,
              let fit = AffineFit.weighted(best) else { return .failure(.inconsistent) }
        var rejectedRun = 0
        for point in sorted {
            if abs((point.offsetSeconds ?? .infinity) - fit.offset(at: point.targetCenter)) > tolerance {
                rejectedRun += 1
                if rejectedRun >= 2 { return .failure(.discontinuous) }
            } else { rejectedRun = 0 }
        }
        guard best.allSatisfy({ abs(($0.offsetSeconds ?? .infinity) - fit.offset(at: $0.targetCenter)) <= tolerance }) else {
            return .failure(.inconsistent)
        }
        return .success(fit)
    }
}
