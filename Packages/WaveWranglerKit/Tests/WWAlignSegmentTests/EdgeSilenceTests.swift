import Foundation
import Testing

/// Planted steps whose target goes silent for 1.2 s on one side of the jump. A 2 s window straddling the jump
/// then hears only the other side and reads that side's offset, so the outermost windows of a segment can lie
/// past the jump: only the half-window edge trim and the bracket margins keep the supported region off it.
/// The calibration strata never produce this (straddling windows follow the content majority), so without
/// this suite those margins would be unexercised. Heavy: serialized segment pass.
@Suite("Segment edge silence", .enabled(if: SegmentHeavyGate.enabled, SegmentHeavyGate.reason))
struct EdgeSilenceTests {
    static let muteSeconds = 1.2

    static func cases() -> [SegmentCase] {
        let all = SegmentPlan.cases()
        var out: [SegmentCase] = []
        for stratum in [SegmentStratum.dropped, .clockStep, .restart] {
            let kase = all.first { $0.stratum == stratum }!
            let plant = kase.plants[0].frame
            let width = Int(muteSeconds * Double(kase.truth.rate))
            for mute in [plant..<(plant + width), (plant - width)..<plant] {
                out.append(SegmentCase(
                    stratum: kase.stratum, index: kase.index, seed: kase.seed, lengthSeconds: kase.lengthSeconds, truth: kase.truth,
                    plants: kase.plants, scene: kase.scene, target: kase.target, mute: mute, referenceNoise: kase.referenceNoise,
                    targetNoise: kase.targetNoise, referenceNoiseSeed: kase.referenceNoiseSeed, targetNoiseSeed: kase.targetNoiseSeed,
                    searchDeviation: kase.searchDeviation))
            }
        }
        return out
    }

    @Test func silenceBesideAJumpNeverBridgesIt() async throws {
        let scores = try await SegmentRunner.runAll(Self.cases())
        for score in scores { print("WW-017 edge-silence " + SegmentRunner.line(score)) }
        let failures = SegmentRunner.gateFailures(scores, maximumFalseSplitRate: 0)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(scores.count == 6)
        #expect(scores.flatMap(\.plants).allSatisfy { $0.status != .bridged })
    }
}
