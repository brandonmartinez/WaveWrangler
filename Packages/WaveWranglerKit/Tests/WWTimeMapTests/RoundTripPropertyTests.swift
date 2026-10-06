import Foundation
import Testing
import WWCore
@testable import WWTimeMap

/// Property tests over many seeded synthetic timelines. Every probe is compared with the oracle evaluated
/// from the generating parameters; the aggregate line printed at the end feeds the WW-015 evidence note.
@Suite("Synthetic-truth round trips")
struct RoundTripPropertyTests {
    static let seed: UInt64 = 0x5757_3031_355F_544D // "WW015_TM"
    static let timelineCount = 1500

    struct Stats {
        var timelines = 0, groups = 0, mappedEpochs = 0, unsupportedEpochs = 0, segments = 0, occurrences = 0, spans = 0
        var frameRoundTrips = 0, forwardGap = 0, forwardUnsupported = 0, forwardOutside = 0
        var inverseSource = 0, inverseGap = 0, inverseUnsupported = 0, inverseOutside = 0
        var maxFrameCount: Int64 = 0
        var maxAbsPPM = 0.0
        /// |returned frame - exact inverse| in source frames, for every inverse that returned a source.
        var quantisation: [Double] = []
        var failures: [String] = []

        mutating func fail(_ message: @autoclosure () -> String) {
            if failures.count < 25 { failures.append(message()) }
        }
    }

    @Test func seededSyntheticTimelinesRoundTripWithinHalfAFrame() throws {
        var rng = SplitMix64(seed: Self.seed)
        var stats = Stats()
        for _ in 0..<Self.timelineCount {
            let truth = SyntheticTimeMapGenerator.timeline(&rng)
            let map: AlignedTimelineMap
            do { map = try truth.build() } catch {
                stats.fail("generated timeline refused: \(error)")
                continue
            }
            stats.timelines += 1
            for group in truth.groups {
                stats.groups += 1
                for epoch in group.epochs {
                    switch epoch.mapping {
                    case .mapped(let segments, _):
                        stats.mappedEpochs += 1
                        stats.segments += segments.count
                        for s in segments { stats.maxAbsPPM = max(stats.maxAbsPPM, abs((s.a.approximateDouble - 1) * 1e6)) }
                    case .unsupported: stats.unsupportedEpochs += 1
                    }
                }
                for occ in group.occurrences {
                    stats.occurrences += 1
                    stats.spans += occ.spans.count
                    stats.maxFrameCount = max(stats.maxFrameCount, occ.occurrence.frameCount)
                    Self.probe(map, group, occ, &rng, &stats)
                }
            }
        }

        let maxQ = stats.quantisation.max() ?? .nan
        let p95Q = nearestRank(stats.quantisation, 95)
        print("""
        WW-015 synthetic truth: seed=0x\(String(Self.seed, radix: 16)) timelines=\(stats.timelines) groups=\(stats.groups) \
        mappedEpochs=\(stats.mappedEpochs) unsupportedEpochs=\(stats.unsupportedEpochs) segments=\(stats.segments) \
        occurrences=\(stats.occurrences) spans=\(stats.spans) maxFrameCount=\(stats.maxFrameCount) maxAbsPPM=\(stats.maxAbsPPM)
        WW-015 probes: frameRoundTrips=\(stats.frameRoundTrips) (exact) forwardGap=\(stats.forwardGap) \
        forwardUnsupported=\(stats.forwardUnsupported) forwardOutside=\(stats.forwardOutside) \
        inverseSource=\(stats.inverseSource) inverseGap=\(stats.inverseGap) inverseUnsupported=\(stats.inverseUnsupported) inverseOutside=\(stats.inverseOutside)
        WW-015 inverse quantisation (source frames, N=\(stats.quantisation.count)): max=\(maxQ) p95(nearest-rank)=\(p95Q)
        """)
        #expect(stats.failures.isEmpty, "\(stats.failures.joined(separator: "\n"))")
        #expect(stats.timelines == Self.timelineCount)
        #expect(maxQ <= 0.5)
        // Coverage of the generator itself (guards against a degenerate generator silently passing).
        #expect(stats.unsupportedEpochs > 0 && stats.forwardGap > 0 && stats.inverseGap > 0 && stats.forwardUnsupported > 0 && stats.inverseUnsupported > 0)
        #expect(stats.inverseSource > 50_000 && stats.frameRoundTrips > 50_000)
        #expect(stats.maxAbsPPM >= 1_000_000 && stats.maxFrameCount >= 1 << 36)
    }

    // MARK: Probing

    static func epochKind(_ group: TruthGroup, _ id: RecordingEpochID) -> MapProvenance.Kind? {
        if case .mapped(_, let provenance) = group.epoch(id).mapping { return provenance.kind }
        return nil
    }

    static func probe(_ map: AlignedTimelineMap, _ group: TruthGroup, _ occ: TruthOccurrence, _ rng: inout SplitMix64, _ stats: inout Stats) {
        let id = occ.occurrence.id
        let rate = occ.rate

        // Forward probes: span edges, interior, frames on either side of every knot, gaps, outside.
        var frames: [Int64] = [-1, 0, occ.occurrence.frameCount - 1, occ.occurrence.frameCount, .min, .max]
        for (k, span) in occ.spans.enumerated() {
            frames += [span.start, span.end - 1, span.start + 1, span.end - 2, span.start - 1, span.end]
            for _ in 0..<3 { frames.append(rng.int(span.start...(span.end - 1))) }
            if case .mapped(let segments, _) = group.epoch(span.epoch).mapping {
                for s in segments.dropFirst() {
                    let n = Int64(try! s.u0.subtracting(span.e).multiplied(by: q(rate)).ceil())
                    frames += [n - 1, n, n + 1]
                }
            }
            if k + 1 < occ.spans.count, span.end < occ.spans[k + 1].start {
                frames.append(rng.int(span.end...(occ.spans[k + 1].start - 1)))
            }
        }
        var mappedTimes: [(Int64, ExactRational)] = []
        for n in frames {
            let expected = SyntheticTimeline.oracleForward(group, occ, frame: n)
            let actual: ForwardMapping
            do { actual = try map.alignedTime(ofFrame: n, in: id) } catch {
                stats.fail("forward threw \(error) for frame \(n)")
                continue
            }
            switch (expected, actual) {
            case (.aligned(let t, let epoch), .aligned(let position)):
                guard position.instant == t, position.epoch == epoch, position.provenance == epochKind(group, epoch) else {
                    stats.fail("forward mismatch frame \(n): \(position) vs \(t)")
                    continue
                }
                doubleSanity(group, occ, n, t, &stats)
                mappedTimes.append((n, t))
                // Frame -> aligned -> frame is exact.
                switch try? map.sourceFrame(at: t, in: id) {
                case .source(let back)? where back.frame == n && back.exactFrame == q(n) && back.epoch == epoch:
                    stats.frameRoundTrips += 1
                default:
                    stats.fail("frame round trip failed for frame \(n) at \(t)")
                }
            case (.gap, .gap(let boundary)):
                guard boundary.precedingLastFrame < n, boundary.followingFirstFrame > n else {
                    stats.fail("gap boundary \(boundary) does not bracket frame \(n)")
                    continue
                }
                stats.forwardGap += 1
            case (.unsupported, .unsupported):
                stats.forwardUnsupported += 1
            case (.outside, .outsideCoverage):
                stats.forwardOutside += 1
            default:
                stats.fail("forward frame \(n): expected \(expected), got \(actual)")
            }
        }
        // Strictly increasing over all mapped frames of the occurrence (positive map, across epochs too).
        let sorted = mappedTimes.sorted { $0.0 < $1.0 }
        for (left, right) in zip(sorted, sorted.dropFirst()) where left.0 != right.0 && !(left.1 < right.1) {
            stats.fail("non-monotonic: frame \(left.0) -> \(left.1), frame \(right.0) -> \(right.1)")
        }

        // Inverse probes: aligned grid instants, hull ends, knot images, arbitrary rationals, gaps, outside.
        var instants: [ExactRational] = []
        var hulls: [(ExactRational, ExactRational)] = []
        for span in occ.spans {
            guard let (lo, hi) = SyntheticTimeline.hull(group, occ, span) else { continue }
            hulls.append((lo, hi))
            instants += [lo, hi]
            let grid = rng.pick([Int64(8000), 44100, 48000, 96000, 192_000, rate])
            let kLo = try! lo.multiplied(by: q(grid)).ceil()
            let kHi = try! hi.multiplied(by: q(grid)).floor()
            if kLo <= kHi {
                var ks: [Int128] = [kLo, kHi]
                let width = kHi - kLo
                for _ in 0..<8 { ks.append(kLo + Int128(rng.int(0...Int64(min(width, Int128(Int64.max - 1)))))) }
                instants += ks.map { q128($0, Int128(grid)) }
            }
            if case .mapped(let segments, _) = group.epoch(span.epoch).mapping {
                for s in segments.dropFirst() { instants.append(s.imageLo) }
            }
            let width = try! hi.subtracting(lo)
            for _ in 0..<2 { instants.append(try! lo.adding(width.multiplied(by: q(rng.int(0...(1 << 20)), 1 << 20)))) }
        }
        if hulls.isEmpty { instants += [q(0), q(-1, 3), q(1 << 20)] }
        if let first = hulls.first, let last = hulls.last {
            instants += [try! first.0.subtracting(q(1, 1 << 30)), try! first.0.subtracting(q(1000)), try! last.1.adding(q(1, 1 << 30)), try! last.1.adding(q(1000))]
        }
        for (left, right) in zip(hulls, hulls.dropFirst()) {
            let gap = try! right.0.subtracting(left.1)
            instants += [try! left.1.adding(gap.divided(by: q(2))), try! left.1.adding(gap.divided(by: q(1 << 20))), try! right.0.subtracting(gap.divided(by: q(1 << 20)))]
        }
        for t in instants { checkInverse(map, group, occ, t, &stats) }
    }

    static func checkInverse(_ map: AlignedTimelineMap, _ group: TruthGroup, _ occ: TruthOccurrence, _ t: ExactRational, _ stats: inout Stats) {
        let expected = SyntheticTimeline.oracleInverse(group, occ, at: t)
        let actual: InverseMapping
        do { actual = try map.sourceFrame(at: t, in: occ.occurrence.id) } catch {
            stats.fail("inverse threw \(error) at \(t)")
            return
        }
        switch (expected, actual) {
        case (.source(let exact, let epoch), .source(let position)):
            let error = try! q128(Int128(position.frame), 1).subtracting(exact)
            let absError = error < .zero ? error.negated() : error
            guard position.exactFrame == exact, position.epoch == epoch, Int128(position.frame) == exact.roundedHalfUp(),
                  absError <= q(1, 2), position.provenance == epochKind(group, epoch)
            else {
                stats.fail("inverse mismatch at \(t): \(position) vs exact \(exact)")
                return
            }
            // aligned -> nearest frame -> aligned stays within half a frame of the steepest local slope.
            guard case .aligned(let back)? = try? map.alignedTime(ofFrame: position.frame, in: occ.occurrence.id),
                  case .mapped(let segments, _) = group.epoch(epoch).mapping
            else {
                stats.fail("nearest frame \(position.frame) of \(t) is not mapped")
                return
            }
            let aMax = segments.map(\.a).max()!
            let bound = try! aMax.divided(by: q(2 * occ.rate))
            let drift = try! back.instant.subtracting(t)
            if (drift < .zero ? drift.negated() : drift) > bound { stats.fail("aligned round trip \(drift) exceeds \(bound) at \(t)") }
            stats.inverseSource += 1
            stats.quantisation.append(absError.approximateDouble)
        case (.gap, .gap(let boundary)):
            // State agreement: a gap is between ADJACENT spans (nothing unsupported in between), and the
            // forward map of any frame strictly between them reports the same gap.
            guard let i = occ.spans.firstIndex(where: { $0.epoch == boundary.precedingEpoch }), i + 1 < occ.spans.count,
                  occ.spans[i + 1].epoch == boundary.followingEpoch
            else {
                stats.fail("inverse gap at \(t) skips a span: \(boundary)")
                return
            }
            if boundary.followingFirstFrame - boundary.precedingLastFrame > 1,
               (try? map.alignedTime(ofFrame: boundary.precedingLastFrame + 1, in: occ.occurrence.id)) != .gap(boundary) {
                stats.fail("forward state disagrees with inverse gap \(boundary)")
            }
            stats.inverseGap += 1
        case (.unsupported(let epochs), .unsupported(let region)):
            // State agreement: every candidate is an unsupported span whose frames map forward to
            // unsupported with the same epoch and reason.
            guard region.occurrence == occ.occurrence.id, region.candidates.map(\.epoch) == epochs else {
                stats.fail("inverse unsupported at \(t): expected \(epochs), got \(region)")
                return
            }
            for candidate in region.candidates {
                for frame in [candidate.startFrame, candidate.endFrame - 1] where
                    (try? map.alignedTime(ofFrame: frame, in: occ.occurrence.id)) != .unsupported(epoch: candidate.epoch, reason: candidate.reason) {
                    stats.fail("forward state of frame \(frame) disagrees with inverse \(region)")
                }
            }
            stats.inverseUnsupported += 1
        case (.outside, .outsideCoverage):
            stats.inverseOutside += 1
        default:
            stats.fail("inverse at \(t): expected \(expected), got \(actual)")
        }
    }

    /// Independent floating-point evaluation of `a*(n/F + e) + b` (sanity check of the exact arithmetic).
    static func doubleSanity(_ group: TruthGroup, _ occ: TruthOccurrence, _ n: Int64, _ t: ExactRational, _ stats: inout Stats) {
        guard let span = occ.spans.first(where: { n >= $0.start && n < $0.end }),
              case .mapped(let segments, _) = group.epoch(span.epoch).mapping else { return }
        // Segment selection uses the exact u (Double rounding at a knot would pick a neighbour); the
        // arithmetic below is pure Double and independent of ExactRational.
        let exactU = try! q(n, occ.rate).adding(span.e)
        guard let s = segments.first(where: { exactU >= $0.u0 && exactU < $0.u1 }) else {
            stats.fail("double sanity: no segment for frame \(n)")
            return
        }
        let u = Double(n) / Double(occ.rate) + span.e.approximateDouble
        let a = s.a.approximateDouble, b = s.b.approximateDouble
        let approx = a * u + b
        let tolerance = (abs(a * u) + abs(b) + 1) * 1e-12
        if abs(approx - t.approximateDouble) > tolerance { stats.fail("double sanity frame \(n): \(approx) vs \(t.approximateDouble)") }
    }
}

@Suite("Envelope extremes")
struct EnvelopeExtremeTests {
    /// Maximum frame count (2^40) at 48 kHz and 2^20 Hz, at the rate-ratio envelope edges and tiny drifts.
    @Test(arguments: SyntheticTimeMapGenerator.ppmMilli)
    func maximumFrameCountsRoundTripAtEveryRateRatio(ppmMilli: Int64) throws {
        let a = q(1_000_000_000 + ppmMilli, 1_000_000_000)
        for rate in [Int64(48000), 1 << 20, 44099] {
            let refEpoch = RecordingEpochID(), group = RecorderGroupID(), refOccurrence = SourceOccurrenceID()
            let frames = TimeMapEnvelope.maxFrameCount
            let refSource = try SourceOccurrence(id: refOccurrence, source: SourceID(), nominalRate: NominalRate(rate), frameCount: frames)
            let reference = TimelineReference(group: group, epoch: refEpoch, occurrence: refOccurrence)
            let duration = q(frames, rate)
            let refMap = try GroupTimeMap(
                group: group, reference: reference,
                epochs: [EpochClockMap(epoch: refEpoch, mapping: .mapped(segments: [AffineClockSegment(groupClockStart: .zero, groupClockEnd: duration, rateRatio: .one, alignedOffset: .zero)], provenance: .timelineReference))],
                placements: [OccurrencePlacement(occurrence: refSource, spans: [EpochSpan(startFrame: 0, endFrame: frames, epoch: refEpoch, groupClockOffset: .zero)])]
            )
            let otherGroup = RecorderGroupID(), otherEpoch = RecordingEpochID(), otherOccurrence = SourceOccurrenceID()
            let other = try SourceOccurrence(id: otherOccurrence, source: SourceID(), nominalRate: NominalRate(rate), frameCount: frames)
            let b = q(-12_345_678, 1000)
            let otherMap = try GroupTimeMap(
                group: otherGroup, reference: reference,
                epochs: [EpochClockMap(epoch: otherEpoch, mapping: .mapped(segments: [AffineClockSegment(groupClockStart: q(-1), groupClockEnd: duration, rateRatio: a, alignedOffset: b)], provenance: .manual(ManualCorrection(basis: .numericEntry))))],
                placements: [OccurrencePlacement(occurrence: other, spans: [EpochSpan(startFrame: 0, endFrame: frames, epoch: otherEpoch, groupClockOffset: q(-1, 2))])]
            )
            let map = try AlignedTimelineMap(reference: reference, groups: [refMap, otherMap])

            for n in [Int64(0), 1, frames / 2 + 1, frames - 2, frames - 1] {
                guard case .aligned(let position) = try map.alignedTime(ofFrame: n, in: otherOccurrence) else {
                    Issue.record("frame \(n) unmapped")
                    continue
                }
                let expected = try a.multiplied(by: q(n, rate).adding(q(-1, 2))).adding(b)
                #expect(position.instant == expected)
                guard case .source(let back) = try map.sourceFrame(at: position.instant, in: otherOccurrence) else {
                    Issue.record("frame \(n) did not invert")
                    continue
                }
                #expect(back.frame == n && back.exactFrame == q(n))
                guard case .aligned(let refPosition) = try map.alignedTime(ofFrame: n, in: refOccurrence) else { continue }
                #expect(refPosition.instant == q(n, rate), "reference frame n must be exactly n/F")
            }
            // An aligned 48 kHz grid instant near the far end inverts to within half a frame.
            guard case .aligned(let last) = try map.alignedTime(ofFrame: frames - 1, in: otherOccurrence) else { continue }
            let k = try last.instant.multiplied(by: q(48000)).floor()
            let t = q128(k, 48000)
            guard case .source(let position) = try map.sourceFrame(at: t, in: otherOccurrence) else {
                Issue.record("grid instant near the end did not invert")
                continue
            }
            let exact = try t.subtracting(b).divided(by: a).subtracting(q(-1, 2)).multiplied(by: q(rate))
            #expect(position.exactFrame == exact)
            let error = try q128(Int128(position.frame), 1).subtracting(exact)
            #expect(error <= q(1, 2) && error >= q(-1, 2))
        }
    }
}

/// Review finding (PR #173): parameter denominators near 2^40 that are coprime to the 44.1/48 kHz output
/// grids. Every such map is either refused at construction with `exactArithmeticEnvelopeExceeded`, or
/// inverts EVERY probed grid instant k/G (G <= 2^20) inside its hull without throwing, to the rounded
/// source frame.
struct HostileDenominatorInverseTests {
    static let seed: UInt64 = 0x57573031355f4744
    static let mapCount = 1000

    static func coprimeDenominator(near bits: Int, _ rng: inout SplitMix64) -> Int128 {
        while true {
            let d = Int128(rng.int((Int64(1) << (bits - 1))...(Int64(1) << bits) - 1)) | 1
            if d % 3 != 0, d % 5 != 0, d % 7 != 0 { return d }
        }
    }

    @Test func gridInstantsInvertOrTheMapIsRefused() throws {
        var rng = SplitMix64(seed: Self.seed)
        var accepted = 0, refused = 0, outsideEnvelope = 0, probes = 0, halfFrameVerified = 0
        var failures: [String] = []
        for index in 0..<Self.mapCount {
            let rate = rng.pick([Int64(44100), 48000, 1 << 20, rng.int(8000...192_000)])
            let frames = rng.pick([Int64(1) << 16, 1 << 20, 1 << 26, 1 << 32, TimeMapEnvelope.maxFrameCount, rng.int(2...(1 << 40))])
            let aDen = Self.coprimeDenominator(near: rng.pick([20, 30, 36, 40]), &rng)
            let ppm = rng.chance(50) ? rng.int(-1000...1000) : rng.int(-400_000...900_000)
            let a = q128(aDen + Int128(ppm) * aDen / 1_000_000 + Int128(rng.int(-7...7)), aDen)
            let eDen = Self.coprimeDenominator(near: rng.pick([20, 32, 40]), &rng)
            let e = q128(Int128(rng.int(-(1 << 40)...(1 << 40))) * eDen / (1 << 40), eDen)
            let bDen = Self.coprimeDenominator(near: rng.pick([20, 32, 40]), &rng)
            let b = q128(Int128(rng.int(-1_000_000...1_000_000)) * bDen + Int128(rng.int(0...(1 << 40))) % bDen, bDen)
            let fx = Fixture(), epoch = RecordingEpochID()
            let occurrence = fx.occurrence(frames: frames, rate: rate)
            guard let u1 = try? e.adding(q(frames, rate)),
                  let segment = try? AffineClockSegment(groupClockStart: q128(e.floor(), 1), groupClockEnd: q128(u1.ceil(), 1), rateRatio: a, alignedOffset: b)
            else {
                outsideEnvelope += 1
                continue
            }
            let map: GroupTimeMap
            do {
                map = try fx.otherGroup(epochs: [mapped(epoch, [segment])], placements: [OccurrencePlacement(occurrence: occurrence, spans: [span(0, frames, epoch, e: e)])])
            } catch TimeMapError.exactArithmeticEnvelopeExceeded {
                refused += 1
                continue
            } catch {
                outsideEnvelope += 1  // Outside the documented time envelope; not this test's subject.
                continue
            }
            accepted += 1
            guard case .aligned(let first) = try map.alignedTime(ofFrame: 0, in: occurrence.id),
                  case .aligned(let last) = try map.alignedTime(ofFrame: frames - 1, in: occurrence.id)
            else {
                failures.append("map \(index): hull ends unmapped")
                continue
            }
            for grid in [Int128(44100), 48000, Int128(rng.int(1...(1 << 20)))] {
                guard let kLo = try? first.instant.multiplied(by: q128(grid, 1)).ceil(),
                      let kHi = try? last.instant.multiplied(by: q128(grid, 1)).floor(), kLo <= kHi
                else { continue }
                let span = kHi - kLo
                var ks: [Int128] = [kLo, kHi, kLo + span / 2]
                for _ in 0..<6 { ks.append(kLo + Int128(rng.next() % UInt64(1 << 62)) % (span + 1)) }
                for k in ks {
                    let t = q128(k, grid)
                    probes += 1
                    let result: InverseMapping
                    do {
                        result = try map.sourceFrame(at: t, in: occurrence.id)
                    } catch {
                        failures.append("map \(index) a=\(a) e=\(e) b=\(b) F=\(rate) N=\(frames): inverse of \(t) threw \(error)")
                        continue
                    }
                    guard case .source(let position) = result, position.epoch == epoch else {
                        failures.append("map \(index): \(t) inside the hull did not invert: \(result)")
                        continue
                    }
                    // Independent bracket from the forward map (proven to fit): f-1 < exact < f+1.
                    let f = position.frame
                    if f > 0, case .aligned(let below) = try map.alignedTime(ofFrame: f - 1, in: occurrence.id), !(below.instant < t) {
                        failures.append("map \(index): frame \(f) - 1 maps at or after \(t)")
                    }
                    if f + 1 < frames, case .aligned(let above) = try map.alignedTime(ofFrame: f + 1, in: occurrence.id), !(t < above.instant) {
                        failures.append("map \(index): frame \(f) + 1 maps at or before \(t)")
                    }
                    // Half-up rounding bound, checked in aligned time when the half-frame instants are
                    // representable: a((f -/+ 1/2)/F + e) + b brackets t as [lo, hi).
                    let fq = q128(Int128(f), 1)
                    if let lo = try? a.multiplied(by: fq.subtracting(q(1, 2)).divided(by: q(rate)).adding(e)).adding(b),
                       let hi = try? a.multiplied(by: fq.adding(q(1, 2)).divided(by: q(rate)).adding(e)).adding(b) {
                        halfFrameVerified += 1
                        if !(lo <= t && t < hi) { failures.append("map \(index): \(t) not within half a frame of \(f)") }
                    }
                    if position.exactFrame.roundedHalfUp() != Int128(f) { failures.append("map \(index): frame is not exactFrame rounded half-up") }
                }
            }
        }
        print("WW015-HOSTILE-GRID seed=0x\(String(Self.seed, radix: 16)) maps=\(Self.mapCount) accepted=\(accepted) refused=\(refused) outsideEnvelope=\(outsideEnvelope) probes=\(probes) halfFrameVerified=\(halfFrameVerified) failures=\(failures.count)")
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(accepted > 0 && refused > 0 && probes > 0 && outsideEnvelope < Self.mapCount / 20)
    }
}
