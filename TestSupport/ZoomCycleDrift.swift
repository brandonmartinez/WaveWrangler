import Foundation

struct ZoomCycleSample: Equatable, Sendable {
    let cycle: Int
    let offset: Double
    let tableWidth: Double
    let tier: String
}

struct ZoomCycleDriftCheck: Equatable, Sendable {
    let modeCount: Int
    let maximumAbsoluteSlope: Double
    let maximumAbsoluteMedianShift: Double
    let violations: [String]

    var passes: Bool { violations.isEmpty }
}

func checkZoomCycleDrift(
    _ samples: [ZoomCycleSample],
    maximumSlope: Double = 1.25,
    maximumMedianShift: Double = 10,
    modeGap: Double = 10
) -> ZoomCycleDriftCheck {
    struct WidthTier: Hashable {
        let widthBucket: Int
        let tier: String
    }

    var modes: [[ZoomCycleSample]] = []
    let widthTierGroups = Dictionary(grouping: samples) {
        WidthTier(widthBucket: Int(($0.tableWidth / 2).rounded()), tier: $0.tier)
    }
    for group in widthTierGroups.values {
        // The first two Window Zoom cycles are AppKit warm-up; drift is repeated movement after settling.
        let repeatedCycles = group.sorted { $0.cycle < $1.cycle }.dropFirst(2)
        let sortedOffsets = repeatedCycles.map(\.offset).sorted()
        let boundaries = zip(sortedOffsets, sortedOffsets.dropFirst()).compactMap { lower, upper in
            upper - lower > modeGap ? (lower + upper) / 2 : nil
        }
        let layoutModes = Dictionary(grouping: repeatedCycles) { sample in
            boundaries.firstIndex { sample.offset < $0 } ?? boundaries.count
        }
        modes.append(contentsOf: layoutModes.values)
    }

    var maximumAbsoluteSlope = 0.0
    var maximumAbsoluteMedianShift = 0.0
    var violations: [String] = []
    for mode in modes {
        let ordered = mode.sorted { $0.cycle < $1.cycle }
        guard ordered.count >= 4 else { continue }

        // Use the latest repeated cycles so one-time settling cannot masquerade as ongoing growth.
        let slopeWindow = Array(ordered.suffix(5))
        var slopes: [Double] = []
        for start in slopeWindow.indices {
            for end in slopeWindow.indices where end > start {
                slopes.append(
                    (slopeWindow[end].offset - slopeWindow[start].offset)
                        / Double(slopeWindow[end].cycle - slopeWindow[start].cycle)
                )
            }
        }
        let slope = median(slopes)
        maximumAbsoluteSlope = max(maximumAbsoluteSlope, abs(slope))
        if abs(slope) > maximumSlope {
            violations.append("layout mode slope \(slope) pt/cycle exceeds ±\(maximumSlope)")
        }

        let windowSize = max(2, ordered.count / 3)
        let earlyMedian = median(ordered.prefix(windowSize).map(\.offset))
        let lateMedian = median(ordered.suffix(windowSize).map(\.offset))
        let medianShift = lateMedian - earlyMedian
        maximumAbsoluteMedianShift = max(maximumAbsoluteMedianShift, abs(medianShift))
        if abs(medianShift) > maximumMedianShift {
            violations.append("layout mode median shift \(medianShift) pt exceeds ±\(maximumMedianShift)")
        }
    }

    return ZoomCycleDriftCheck(
        modeCount: modes.count,
        maximumAbsoluteSlope: maximumAbsoluteSlope,
        maximumAbsoluteMedianShift: maximumAbsoluteMedianShift,
        violations: violations
    )
}

private func median<C: Collection>(_ values: C) -> Double where C.Element == Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}
