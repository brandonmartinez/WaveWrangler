import Foundation
import WWCore
@testable import WWTimeMap

// Deterministic synthetic truth for WWTimeMap. Everything here is generated in code from a seed; no
// recordings, files or clocks are involved. The oracle evaluates the generating parameters directly
// (`t = a*(n/F + e) + b`, `n = F*((t - b)/a - e)`) with plain ExactRational arithmetic and direct segment
// lookup, independently of the compiled `(p*n + c)/d` pieces used by the module under test.

/// SplitMix64 with explicit, toolchain-independent sampling helpers (the stdlib's `random(in:using:)`
/// algorithm is not guaranteed stable across toolchains).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-ish integer in `range` (modulo bias is irrelevant for test coverage; determinism is what matters).
    mutating func int(_ range: ClosedRange<Int64>) -> Int64 {
        let width = UInt64(bitPattern: range.upperBound &- range.lowerBound) &+ 1
        if width == 0 { return Int64(bitPattern: next()) }
        return range.lowerBound &+ Int64(bitPattern: next() % width)
    }

    mutating func index(_ count: Int) -> Int { Int(int(0...Int64(count - 1))) }

    mutating func chance(_ percent: Int64) -> Bool { int(0...99) < percent }

    mutating func pick<T>(_ values: [T]) -> T { values[index(values.count)] }

    /// Log-uniform integer in `1...max`.
    mutating func logUniform(_ max: Int64) -> Int64 {
        let bits = 64 - max.leadingZeroBitCount
        let b = int(0...Int64(bits - 1))
        let hi = Swift.min(max, (Int64(1) << (b + 1)) - 1)
        return int((Int64(1) << b)...Swift.max(Int64(1) << b, hi))
    }

    mutating func uuid() -> UUID {
        let a = next(), b = next()
        return withUnsafeBytes(of: (a, b)) { raw in
            UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
        }
    }
}

func q(_ n: Int64, _ d: Int64 = 1) -> ExactRational {
    try! ExactRational(n, d)
}

func q128(_ n: Int128, _ d: Int128) -> ExactRational {
    try! ExactRational(numerator: n, denominator: d)
}

// MARK: - Truth model

struct TruthSegment {
    let u0, u1, a, b: ExactRational

    func aligned(_ u: ExactRational) -> ExactRational { try! a.multiplied(by: u).adding(b) }
    var imageLo: ExactRational { aligned(u0) }
    var imageHi: ExactRational { aligned(u1) }

    var segment: AffineClockSegment {
        try! AffineClockSegment(groupClockStart: u0, groupClockEnd: u1, rateRatio: a, alignedOffset: b)
    }
}

enum TruthMapping {
    case mapped([TruthSegment], MapProvenance)
    case unsupported(UnsupportedReason)
}

struct TruthEpoch {
    let id: RecordingEpochID
    let mapping: TruthMapping

    var epochMap: EpochClockMap {
        switch mapping {
        case .mapped(let segments, let provenance): EpochClockMap(epoch: id, mapping: .mapped(segments: segments.map(\.segment), provenance: provenance))
        case .unsupported(let reason): EpochClockMap(epoch: id, mapping: .unsupported(reason))
        }
    }
}

struct TruthSpan {
    let start: Int64
    let end: Int64
    let epoch: RecordingEpochID
    let e: ExactRational

    var span: EpochSpan { EpochSpan(startFrame: start, endFrame: end, epoch: epoch, groupClockOffset: e) }
}

struct TruthOccurrence {
    let occurrence: SourceOccurrence
    let spans: [TruthSpan]

    var rate: Int64 { occurrence.nominalRate.framesPerSecond }
    var placement: OccurrencePlacement { OccurrencePlacement(occurrence: occurrence, spans: spans.map(\.span)) }
}

struct TruthGroup {
    let id: RecorderGroupID
    let epochs: [TruthEpoch]
    let occurrences: [TruthOccurrence]

    func epoch(_ id: RecordingEpochID) -> TruthEpoch { epochs.first { $0.id == id }! }
}

/// Expected results computed from the generating parameters.
enum OracleForward: Equatable {
    case aligned(ExactRational, RecordingEpochID)
    case gap
    case unsupported
    case outside
}

enum OracleInverse: Equatable {
    case source(ExactRational, RecordingEpochID)
    case gap
    /// Where unsupported spans could lie, with the unsupported spans between the neighbouring mapped spans.
    case unsupported([RecordingEpochID])
    case outside
}

struct SyntheticTimeline {
    let reference: TimelineReference
    let groups: [TruthGroup]

    func build() throws(TimeMapError) -> AlignedTimelineMap {
        var maps: [GroupTimeMap] = []
        for group in groups {
            maps.append(try GroupTimeMap(group: group.id, reference: reference, epochs: group.epochs.map(\.epochMap), placements: group.occurrences.map(\.placement)))
        }
        return try AlignedTimelineMap(reference: reference, groups: maps)
    }

    static func oracleForward(_ group: TruthGroup, _ occ: TruthOccurrence, frame n: Int64) -> OracleForward {
        guard n >= 0, n < occ.occurrence.frameCount else { return .outside }
        guard let span = occ.spans.first(where: { n >= $0.start && n < $0.end }) else {
            let before = occ.spans.contains { $0.end <= n }
            let after = occ.spans.contains { $0.start > n }
            return before && after ? .gap : .outside
        }
        guard case .mapped(let segments, _) = group.epoch(span.epoch).mapping else { return .unsupported }
        let u = try! q(n, occ.rate).adding(span.e)
        let segment = segments.first { u >= $0.u0 && u < $0.u1 }!
        return .aligned(segment.aligned(u), span.epoch)
    }

    /// Exact aligned hull `[t(first frame), t(last frame)]` of a mapped span.
    static func hull(_ group: TruthGroup, _ occ: TruthOccurrence, _ span: TruthSpan) -> (ExactRational, ExactRational)? {
        guard case .aligned(let lo, _) = oracleForward(group, occ, frame: span.start),
              case .aligned(let hi, _) = oracleForward(group, occ, frame: span.end - 1) else { return nil }
        return (lo, hi)
    }

    static func oracleInverse(_ group: TruthGroup, _ occ: TruthOccurrence, at t: ExactRational) -> OracleInverse {
        var sawEarlier = false
        var unsupported: [RecordingEpochID] = []
        for span in occ.spans {
            guard let (lo, hi) = hull(group, occ, span), case .mapped(let segments, _) = group.epoch(span.epoch).mapping else {
                unsupported.append(span.epoch)
                continue
            }
            if t < lo { return !unsupported.isEmpty ? .unsupported(unsupported) : sawEarlier ? .gap : .outside }
            if t <= hi {
                let segment = segments.first { t >= $0.imageLo && t < $0.imageHi }!
                let u = try! t.subtracting(segment.b).divided(by: segment.a)
                let n = try! u.subtracting(span.e).multiplied(by: q(occ.rate))
                return .source(n, span.epoch)
            }
            sawEarlier = true
            unsupported = []
        }
        return unsupported.isEmpty ? .outside : .unsupported(unsupported)
    }
}

// MARK: - Generator

enum SyntheticTimeMapGenerator {
    /// Nominal rates: common, odd and envelope-edge (1 Hz, 7 Hz, 2^20 Hz).
    static let rates: [Int64] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176_400, 192_000, 352_800, 384_000, 1, 7, 44099, 1 << 20]
    /// Rate-ratio offsets in milli-ppm (a = 1 + q/1e9): 0, +-0.001, +-1, +-100, +-1000, +-10,000,
    /// +-100,000 ppm, and the envelope edges -500,000 ppm (a = 1/2) and +1,000,000 ppm (a = 2).
    static let ppmMilli: [Int64] = [
        0, 1, -1, 1000, -1000, 100_000, -100_000, 1_000_000, -1_000_000, 10_000_000, -10_000_000,
        100_000_000, -100_000_000, -500_000_000, 1_000_000_000,
    ]

    static func rateRatio(_ rng: inout SplitMix64) -> ExactRational {
        let milli = rng.chance(50) ? rng.pick(ppmMilli) : rng.int(-1_000_000...1_000_000)
        return q(1_000_000_000 + milli, 1_000_000_000)
    }

    static func spanLength(_ rng: inout SplitMix64, rate: Int64) -> Int64 {
        let maxLong = Swift.min((Int64(1) << 26) * rate, Int64(1) << 37)
        let roll = rng.int(0...99)
        if roll < 20 { return rng.int(1...64) }
        if roll < 70 { return rng.int(1...Swift.max(1, Swift.min(maxLong, rate * 3600))) }
        return rng.logUniform(maxLong)
    }

    static func provenance(_ rng: inout SplitMix64) -> MapProvenance {
        switch rng.int(0...3) {
        case 0:
            .clockApproved(try! ClockApproval(
                evaluator: "synthetic-truth",
                reference: IndependentClockReference(description: "synthetic certified anchors"),
                measurements: ClockGateMeasurements(windowCount: 8, overlapSpanFraction: 0.9, eligibleWindowFraction: 0.75, residualP95Milliseconds: 1, residualMaxMilliseconds: 2)
            ))
        case 1:
            .acousticConsistentProposal(try! AcousticConsistencyProposal(estimator: "synthetic", evidenceScore: 3.5, seed: CaptureMetadataSeed(kind: .fileCreationDate, suggestedOffset: q(12))))
        case 2:
            .manual(ManualCorrection(basis: .anchors))
        default:
            .externalEvidence(try! ExternalClockEvidence(kind: .sharedTimecodeGenerator, description: "synthetic LTC"))
        }
    }

    static func ceilMilliseconds(_ x: ExactRational) -> Int64 {
        Int64(try! x.multiplied(by: q(1000)).ceil())
    }

    /// One timeline: 1-3 groups, 1-4 epochs per group, 1-3 occurrences per group, dropouts that restart
    /// epochs, unsupported epochs, continuous multi-segment epochs, and occurrences that skip epochs.
    static func timeline(_ rng: inout SplitMix64) -> SyntheticTimeline {
        let groupCount = Int(rng.int(1...3))
        var groups: [TruthGroup] = []
        var reference: TimelineReference?
        for g in 0..<groupCount {
            let isReference = g == 0
            let groupID = RecorderGroupID(rng.uuid())
            let epochCount = Int(rng.int(1...4))
            let epochIDs = (0..<epochCount).map { _ in RecordingEpochID(rng.uuid()) }
            let occurrenceCount = Int(rng.int(1...3))
            let rate = rng.pick(rates) // tracks of one recorder share a nominal rate in practice; vary below
            struct Plan { var occurrence: SourceOccurrenceID; var rate: Int64; var epochs: [Int]; var lengths: [Int64]; var pads: [Int64]; var starts: [Int64] = []; var frameCount: Int64 = 0 }
            var plans: [Plan] = []
            for o in 0..<occurrenceCount {
                let occRate = rng.chance(70) ? rate : rng.pick(rates)
                var participating = (0..<epochCount).filter { _ in rng.chance(70) }
                if isReference, o == 0, !participating.contains(0) { participating.insert(0, at: 0) }
                if participating.isEmpty { participating = [rng.index(epochCount)] }
                let lengths = participating.map { _ in spanLength(&rng, rate: occRate) }
                let pads = participating.map { _ in rng.int(0...occRate) }
                plans.append(Plan(occurrence: SourceOccurrenceID(rng.uuid()), rate: occRate, epochs: participating, lengths: lengths, pads: pads))
            }
            // Frame layout: leading frames, spans separated by dropout gaps (possibly zero frames), trailing frames.
            for i in plans.indices {
                let r = plans[i].rate
                var cursor = rng.chance(30) ? 0 : rng.int(0...(r * 10))
                if isReference, i == 0 { cursor = rng.chance(50) ? 0 : rng.int(0...r) }
                for (k, length) in plans[i].lengths.enumerated() {
                    if k > 0 { cursor += rng.chance(20) ? 0 : rng.int(1...(r * 5)) }
                    plans[i].starts.append(cursor)
                    cursor += length
                }
                plans[i].frameCount = cursor + (rng.chance(30) ? 0 : rng.int(0...(r * 10)))
            }
            if isReference {
                // The reference occurrence's reference-epoch span has e = 0: pad == start.
                plans[0].pads[0] = plans[0].starts[0]
            }

            var epochs: [TruthEpoch] = []
            var spansByOccurrence: [[TruthSpan]] = plans.map { _ in [] }
            var alignedCursorMs = rng.int(-100_000_000...100_000_000)
            for j in 0..<epochCount {
                let isReferenceEpoch = isReference && j == 0
                let u0Ms: Int64 = isReferenceEpoch ? 0 : rng.int(-1_000_000...1_000_000)
                let u0 = q(u0Ms, 1000)
                var requiredEndMs = u0Ms + 1
                for (i, plan) in plans.enumerated() {
                    guard let k = plan.epochs.firstIndex(of: j) else { continue }
                    let start = plan.starts[k], length = plan.lengths[k], pad = plan.pads[k]
                    let e = try! u0.adding(q(pad - start, plan.rate))
                    spansByOccurrence[i].append(TruthSpan(start: start, end: start + length, epoch: epochIDs[j], e: e))
                    requiredEndMs = Swift.max(requiredEndMs, ceilMilliseconds(try! u0.adding(q(pad + length, plan.rate))))
                }
                let u1Ms = requiredEndMs + rng.int(0...1000)
                if !isReferenceEpoch, rng.chance(15) {
                    epochs.append(TruthEpoch(id: epochIDs[j], mapping: .unsupported(rng.pick(UnsupportedReason.allCases))))
                    alignedCursorMs += (u1Ms - u0Ms) * 2 + rng.int(0...10_000_000)
                    continue
                }
                var segments: [TruthSegment] = []
                if isReferenceEpoch {
                    segments = [TruthSegment(u0: u0, u1: q(u1Ms, 1000), a: .one, b: .zero)]
                } else {
                    let wanted = Int(rng.int(1...4))
                    var knots = Set<Int64>()
                    if u1Ms - u0Ms > 1 { for _ in 1..<wanted { knots.insert(rng.int((u0Ms + 1)...(u1Ms - 1))) } }
                    let bounds = [u0Ms] + knots.sorted() + [u1Ms]
                    var a = rateRatio(&rng)
                    var b = try! q(alignedCursorMs, 1000).subtracting(a.multiplied(by: u0))
                    for (lo, hi) in zip(bounds, bounds.dropFirst()) {
                        if lo != u0Ms {
                            // Continuity at the knot: a_prev*u + b_prev == a*u + b.
                            let next = rateRatio(&rng)
                            b = try! b.adding(a.subtracting(next).multiplied(by: q(lo, 1000)))
                            a = next
                        }
                        segments.append(TruthSegment(u0: q(lo, 1000), u1: q(hi, 1000), a: a, b: b))
                    }
                }
                let provenance: MapProvenance = isReferenceEpoch ? .timelineReference : SyntheticTimeMapGenerator.provenance(&rng)
                epochs.append(TruthEpoch(id: epochIDs[j], mapping: .mapped(segments, provenance)))
                alignedCursorMs = ceilMilliseconds(segments.last!.imageHi) + (rng.chance(20) ? 0 : rng.int(1...10_000_000))
            }
            var occurrences: [TruthOccurrence] = []
            for (i, plan) in plans.enumerated() {
                let occurrence = try! SourceOccurrence(id: plan.occurrence, source: SourceID(rng.uuid()), nominalRate: NominalRate(plan.rate), frameCount: plan.frameCount)
                occurrences.append(TruthOccurrence(occurrence: occurrence, spans: spansByOccurrence[i]))
            }
            if isReference {
                reference = TimelineReference(group: groupID, epoch: epochIDs[0], occurrence: plans[0].occurrence)
            }
            groups.append(TruthGroup(id: groupID, epochs: epochs, occurrences: occurrences))
        }
        return SyntheticTimeline(reference: reference!, groups: groups)
    }
}

/// Nearest-rank percentile of `values` (p in 0...100).
func nearestRank(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = Swift.max(1, Int((p / 100 * Double(sorted.count)).rounded(.up)))
    return sorted[rank - 1]
}
