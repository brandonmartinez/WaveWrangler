import Foundation
import WWAlignEstimate
import WWCore
import WWTimeMap

/// Splits one recorder-group occurrence into epochs at discontinuities, using only the frozen WW-016
/// estimator's public API, and returns a validated `GroupTimeMap`.
///
/// Algorithm (all frames of every declared span end up in exactly one region):
/// 1. Dense pass: the span is cut into overlapping tiles (`tileSeconds`, stride chosen so window centres
///    continue at the estimator's own spacing) and every tile is measured by `AcousticEstimator`. Each
///    eligible window gives one point (group-clock centre u, offset y = aligned − u).
/// 2. Segmentation: the points are split recursively at the least-squares two-line split until every piece
///    fits one line within `splitToleranceMilliseconds` or is too small (an island of unresolved windows).
///    Island points are absorbed into a neighbour only if it still fits; neighbouring segments merge only if
///    their union still fits. A single line is therefore never fitted across a jump larger than the
///    tolerance.
/// 3. Boundaries: between consecutive segments the discontinuity is bracketed from the window evidence. A
///    window measures the offset of content inside it, so the change lies after the left segment's last
///    window start and before the right segment's first window end; the bracket is widened by the jump
///    size (inserted frames) and, for slope changes, by the interval where the two lines are within
///    `stepToleranceFactor` × tolerance of each other around their intersection.
/// 4. Supported candidates: each segment's frames from its first window centre + w/2 to its last window
///    centre − w/2 (a change closer to the edge evidence could not be seen), minus brackets, at least
///    `minimumSupportedSeconds` long. Everything else is unsupported with an explicit cause.
/// 5. Each candidate is re-estimated by the frozen estimator on exactly its frames. Abstention, or a
///    proposal disagreeing with the segment line, leaves it unsupported. Mapped images must be monotonic
///    in frame order; any overlapping pair is demoted.
/// 6. Each region is a WWTimeMap span with its own epoch; the map compiles or the call throws.
public enum DiscontinuitySegmenter {
    /// Identifier of the revised defaults (`m2-freeze-discontinuity-2`).
    public static let identifier = "ww-align-segment/2"
    /// Identifier stamped on any non-default (in-module test) parameter set.
    public static let customIdentifier = "ww-align-segment/2+custom"

    public static func segment(_ request: SegmentationRequest, parameters: SegmenterParameters = SegmenterParameters()) throws(SegmentError) -> SegmentationReport {
        try parameters.validate()
        try validate(request)
        var run = Run(request: request, parameters: parameters)
        return try run.perform()
    }

    static func validate(_ request: SegmentationRequest) throws(SegmentError) {
        let occurrence = request.occurrence
        guard request.group != request.reference.group else { throw .invalidRequest("target group is the reference group") }
        guard Int64(request.buffer.samples.count) == occurrence.frameCount else { throw .invalidRequest("buffer frame count differs from the occurrence") }
        guard Int64(request.buffer.sampleRate) == occurrence.nominalRate.framesPerSecond else { throw .invalidRequest("buffer rate differs from the occurrence nominal rate") }
        guard !request.declaredSpans.isEmpty else { throw .invalidRequest("no declared spans") }
        var epochs: Set<RecordingEpochID> = [request.reference.epoch]
        var previousEnd: Int64 = 0
        for span in request.declaredSpans {
            guard span.frames.lowerBound < span.frames.upperBound else { throw .invalidRequest("empty declared span") }
            guard span.frames.lowerBound >= previousEnd, span.frames.upperBound <= occurrence.frameCount else { throw .invalidRequest("declared spans must be ascending, disjoint and inside the occurrence") }
            guard epochs.insert(span.epoch).inserted else { throw .invalidRequest("declared epochs must be distinct and differ from the reference epoch") }
            previousEnd = span.frames.upperBound
        }
    }
}

// MARK: - Internals

struct Point {
    let u: Double
    let y: Double
    /// Index into the dense windows.
    let window: Int
}

/// y = intercept + slope · (u − pivot).
struct Line {
    let pivot: Double
    let intercept: Double
    let slope: Double

    func value(at u: Double) -> Double { intercept + slope * (u - pivot) }
}

struct LineFit {
    let line: Line
    let maxResidual: Double
}

enum Piece {
    case segment([Int])
    case island([Int])
}

/// Least-squares line through the indexed points and its worst absolute residual.
func fitLine(_ points: [Point], _ indices: [Int]) -> LineFit {
    let n = Double(indices.count)
    var su = 0.0, sy = 0.0
    for i in indices { su += points[i].u; sy += points[i].y }
    let mu = su / n, my = sy / n
    var suu = 0.0, suy = 0.0
    for i in indices {
        let du = points[i].u - mu
        suu += du * du
        suy += du * (points[i].y - my)
    }
    let slope = suu > 0 ? suy / suu : 0
    let line = Line(pivot: mu, intercept: my, slope: slope)
    var worst = 0.0
    for i in indices { worst = max(worst, abs(points[i].y - line.value(at: points[i].u))) }
    return LineFit(line: line, maxResidual: worst)
}

/// Prefix sums for O(1) least-squares residual sums over contiguous point ranges.
struct PrefixSums {
    private var u: [Double] = [0], y: [Double] = [0], uu: [Double] = [0], uy: [Double] = [0], yy: [Double] = [0]

    init(_ points: [Point]) {
        guard let first = points.first else { return }
        let u0 = first.u, y0 = first.y
        for p in points {
            let du = p.u - u0, dy = p.y - y0
            u.append(u.last! + du)
            y.append(y.last! + dy)
            uu.append(uu.last! + du * du)
            uy.append(uy.last! + du * dy)
            yy.append(yy.last! + dy * dy)
        }
    }

    /// Residual sum of squares of the least-squares line over points [i, j).
    func residualSum(_ i: Int, _ j: Int) -> Double {
        let n = Double(j - i)
        guard j - i >= 3 else { return 0 }
        let su = u[j] - u[i], sy = y[j] - y[i]
        let sxx = (uu[j] - uu[i]) - su * su / n
        let sxy = (uy[j] - uy[i]) - su * sy / n
        let syy = (yy[j] - yy[i]) - sy * sy / n
        guard sxx > 1e-12 else { return max(0, syy) }
        return max(0, syy - sxy * sxy / sxx)
    }
}

/// Splits sorted points into line segments (every point within `tolerance` of its segment's line) and
/// islands, absorbing and merging only while the tolerance still holds.
func segmentPoints(_ points: [Point], tolerance: Double, minimumPoints: Int) -> [Piece] {
    guard !points.isEmpty else { return [] }
    let sums = PrefixSums(points)
    var raw: [Piece] = []
    func split(_ r: Range<Int>) {
        let indices = Array(r)
        if r.count < minimumPoints { raw.append(.island(indices)); return }
        if fitLine(points, indices).maxResidual <= tolerance { raw.append(.segment(indices)); return }
        var best = r.lowerBound + 1
        var bestCost = Double.infinity
        for k in (r.lowerBound + 1)..<r.upperBound {
            let cost = sums.residualSum(r.lowerBound, k) + sums.residualSum(k, r.upperBound)
            if cost < bestCost { bestCost = cost; best = k }
        }
        split(r.lowerBound..<best)
        split(best..<r.upperBound)
    }
    split(0..<points.count)

    // Coalesce neighbouring islands.
    var pieces: [Piece] = []
    for piece in raw {
        if case .island(let b) = piece, case .island(let a)? = pieces.last {
            pieces[pieces.count - 1] = .island(a + b)
        } else {
            pieces.append(piece)
        }
    }

    // Absorb island points into a neighbouring segment while it still fits.
    for index in pieces.indices {
        guard case .island(var island) = pieces[index] else { continue }
        if index > 0, case .segment(var left) = pieces[index - 1] {
            while let next = island.first, fitLine(points, left + [next]).maxResidual <= tolerance {
                left.append(next)
                island.removeFirst()
            }
            pieces[index - 1] = .segment(left)
        }
        if index + 1 < pieces.count, case .segment(var right) = pieces[index + 1] {
            while let next = island.last, fitLine(points, [next] + right).maxResidual <= tolerance {
                right.insert(next, at: 0)
                island.removeLast()
            }
            pieces[index + 1] = .segment(right)
        }
        pieces[index] = .island(island)
    }
    pieces.removeAll { if case .island(let i) = $0 { return i.isEmpty } else { return false } }

    // Merge neighbouring segments whose union fits one line. A small island between them is treated as
    // outlying windows (excluded from the line), never as support for bridging a jump: the union must fit.
    var merged = true
    while merged {
        merged = false
        var index = 0
        while index < pieces.count {
            guard case .segment(let left) = pieces[index] else { index += 1; continue }
            var next = index + 1
            if next < pieces.count, case .island(let island) = pieces[next], island.count < minimumPoints {
                next += 1
            }
            if next < pieces.count, case .segment(let right) = pieces[next], fitLine(points, left + right).maxResidual <= tolerance {
                pieces.replaceSubrange(index...next, with: [.segment(left + right)])
                merged = true
                continue
            }
            index += 1
        }
    }
    return pieces
}

/// A fitted run must also persist over time; a burst of mutually consistent but short-lived outliers
/// is unresolved evidence, not a second clock. Long runs on either side remain separate.
func persistentPieces(_ pieces: [Piece], points: [Point], minimumSeconds: Double) -> [Piece] {
    var result: [Piece] = []
    for piece in pieces {
        let kept: Piece
        if case .segment(let indices) = piece,
           points[indices.last!].u - points[indices.first!].u < minimumSeconds {
            kept = .island(indices)
        } else {
            kept = piece
        }
        if case .island(let next) = kept, case .island(let prior)? = result.last {
            result[result.count - 1] = .island(prior + next)
        } else {
            result.append(kept)
        }
    }
    return result
}

private struct Candidate {
    let spanIndex: Int
    let frames: Range<Int64>
    let line: Line
}

private struct PendingRegion {
    let spanIndex: Int
    let frames: Range<Int64>
    var outcome: RegionOutcome
}

private struct Run {
    let request: SegmentationRequest
    let parameters: SegmenterParameters
    let estimatorParameters = EstimatorParameters()
    let rate: Int64
    let F: Double
    let halfWindow: Double
    let tolerance: Double
    let stepThreshold: Double

    var windows: [DenseWindow] = []
    var windowSpan: [Int] = []
    var detections: [Discontinuity] = []

    init(request: SegmentationRequest, parameters: SegmenterParameters) {
        self.request = request
        self.parameters = parameters
        self.rate = request.occurrence.nominalRate.framesPerSecond
        self.F = Double(rate)
        self.halfWindow = estimatorParameters.windowSeconds / 2
        self.tolerance = parameters.splitToleranceMilliseconds / 1000
        self.stepThreshold = parameters.stepToleranceFactor * parameters.splitToleranceMilliseconds / 1000
    }

    private var minimumSupportedFrames: Int64 { Int64((parameters.minimumSupportedSeconds * F).rounded(.up)) }

    private func u(_ frame: Double, _ span: DeclaredSpan) -> Double { span.groupClockOffset.approximateDouble + frame / F }
    private func frame(_ u: Double, _ span: DeclaredSpan) -> Double { (u - span.groupClockOffset.approximateDouble) * F }

    mutating func perform() throws(SegmentError) -> SegmentationReport {
        let spans = request.declaredSpans

        // 1. Dense pass.
        var tileTracks: [EstimatorTrack] = []
        var tileSpan: [Int] = []
        for (index, span) in spans.enumerated() where span.frames.upperBound - span.frames.lowerBound >= minimumSupportedFrames {
            for tile in tiles(span.frames) {
                tileTracks.append(try track(for: tile, in: span))
                tileSpan.append(index)
            }
        }
        var estimatorID = AcousticEstimator.identifier
        if !tileTracks.isEmpty {
            let dense = try estimate(tileTracks)
            estimatorID = dense.estimator
            for (estimate, spanIndex) in zip(dense.epochs, tileSpan) {
                for w in estimate.windows {
                    windows.append(DenseWindow(declaredEpoch: spans[spanIndex].epoch, groupClockCenter: w.groupClockCenter, status: w.status, peakScore: w.peakScore, secondPeakScore: w.secondPeakScore, offsetSeconds: w.offsetSeconds))
                    windowSpan.append(spanIndex)
                }
            }
        }

        // 2–4. Segment each span, bracket its boundaries, and collect supported candidates and the rest.
        var candidates: [Candidate] = []
        var regions: [PendingRegion] = []
        for (index, span) in spans.enumerated() {
            let (spanCandidates, spanRegions) = analyse(spanIndex: index, span: span)
            candidates += spanCandidates
            regions += spanRegions
        }

        // 5. Re-estimate every candidate on exactly its frames.
        if !candidates.isEmpty {
            var tracks: [EstimatorTrack] = []
            for c in candidates { tracks.append(try track(for: c.frames, in: spans[c.spanIndex])) }
            let report = try estimate(tracks)
            for (c, estimate) in zip(candidates, report.epochs) {
                let span = spans[c.spanIndex]
                let outcome: RegionOutcome
                switch estimate.outcome {
                case .abstained(let a):
                    outcome = .unsupported(a.reason.unsupportedReason, .estimatorAbstained(a.reason))
                case .acousticConsistentProposal(let p):
                    let a = p.segment.rateRatio.approximateDouble
                    let b = p.segment.alignedOffset.approximateDouble
                    var worst = 0.0
                    for f in [Double(c.frames.lowerBound), Double(c.frames.upperBound)] {
                        let uu = u(f, span)
                        worst = max(worst, abs(((a - 1) * uu + b) - c.line.value(at: uu)))
                    }
                    let disagreement = worst * 1000
                    outcome = disagreement <= parameters.proposalAgreementMilliseconds ? .supported(p) : .unsupported(.nonlinear, .lineDisagreement(disagreement))
                }
                regions.append(PendingRegion(spanIndex: c.spanIndex, frames: c.frames, outcome: outcome))
            }
        }
        regions.sort { $0.frames.lowerBound < $1.frames.lowerBound }

        // Monotonic images: demote any neighbouring mapped pair whose aligned images overlap.
        var changed = true
        while changed {
            changed = false
            let mapped = regions.indices.filter { regions[$0].isSupported }
            for (l, r) in zip(mapped, mapped.dropFirst()) {
                guard case .supported(let left) = regions[l].outcome, case .supported(let right) = regions[r].outcome else { continue }
                let leftHi = try image(left.segment, left.segment.groupClockEnd)
                let rightLo = try image(right.segment, right.segment.groupClockStart)
                if rightLo < leftHi {
                    regions[l].outcome = .unsupported(.nonlinear, .imageOverlap)
                    regions[r].outcome = .unsupported(.nonlinear, .imageOverlap)
                    changed = true
                    break
                }
            }
        }

        // 6. Epochs, the group map, the report.
        var final: [SegmentRegion] = []
        var epochMaps: [EpochClockMap] = []
        for (index, span) in spans.enumerated() {
            let mine = regions.filter { $0.spanIndex == index }
            let keeper = mine.firstIndex { $0.isSupported } ?? 0
            for (k, region) in mine.enumerated() {
                let epoch = k == keeper ? span.epoch : RecordingEpochID()
                final.append(SegmentRegion(frames: region.frames, epoch: epoch, declaredEpoch: span.epoch, groupClockOffset: span.groupClockOffset, outcome: region.outcome))
                switch region.outcome {
                case .supported(let p):
                    epochMaps.append(EpochClockMap(epoch: epoch, mapping: .mapped(segments: [p.segment], provenance: .acousticConsistentProposal(p.provenance))))
                case .unsupported(let reason, _):
                    epochMaps.append(EpochClockMap(epoch: epoch, mapping: .unsupported(reason)))
                }
            }
        }
        let placement = OccurrencePlacement(occurrence: request.occurrence, spans: final.map { EpochSpan(startFrame: $0.frames.lowerBound, endFrame: $0.frames.upperBound, epoch: $0.epoch, groupClockOffset: $0.groupClockOffset) })
        let reference = TimelineReference(group: request.reference.group, epoch: request.reference.epoch, occurrence: request.reference.occurrence)
        let map: GroupTimeMap
        do throws(TimeMapError) {
            map = try GroupTimeMap(group: request.group, reference: reference, epochs: epochMaps, placements: [placement])
        } catch {
            throw .timeMap(error)
        }
        let segmenter = parameters == SegmenterParameters() ? DiscontinuitySegmenter.identifier : DiscontinuitySegmenter.customIdentifier
        return SegmentationReport(segmenter: segmenter, estimator: estimatorID, regions: final, detections: detections, windows: windows, map: map)
    }

    // MARK: Per-span analysis

    private mutating func analyse(spanIndex: Int, span: DeclaredSpan) -> ([Candidate], [PendingRegion]) {
        let s0 = span.frames.lowerBound, s1 = span.frames.upperBound
        if s1 - s0 < minimumSupportedFrames {
            return ([], [PendingRegion(spanIndex: spanIndex, frames: span.frames, outcome: .unsupported(.insufficientOverlap, .tooShort))])
        }
        let mine = windows.indices.filter { windowSpan[$0] == spanIndex }
        let points = mine.compactMap { i -> Point? in
            guard windows[i].status == .eligible, let y = windows[i].offsetSeconds else { return nil }
            return Point(u: windows[i].groupClockCenter, y: y, window: i)
        }.sorted { $0.u < $1.u }
        let pieces = persistentPieces(
            segmentPoints(points, tolerance: tolerance, minimumPoints: parameters.minimumSegmentWindows),
            points: points, minimumSeconds: parameters.minimumSupportedSeconds)

        var segments: [(indices: [Int], fit: LineFit)] = []
        var islandBefore: [Int] = []   // island points between segment k-1 and k (index k)
        var islandPoints: [Int] = []
        var pendingIsland = 0
        for piece in pieces {
            switch piece {
            case .segment(let indices):
                segments.append((indices, fitLine(points, indices)))
                islandBefore.append(pendingIsland)
                pendingIsland = 0
            case .island(let indices):
                pendingIsland += indices.count
                islandPoints += indices
            }
        }

        // Boundaries.
        var brackets: [(frames: Range<Int64>, detection: Int)] = []
        let spanULo = u(Double(s0), span), spanUHi = u(Double(s1), span)
        for k in segments.indices.dropFirst() {
            let left = segments[k - 1], right = segments[k]
            let cL = left.indices.map { points[$0].u }.max()!
            let cR = right.indices.map { points[$0].u }.min()!
            let mid = (cL + cR) / 2
            let jump = right.fit.line.value(at: mid) - left.fit.line.value(at: mid)
            let dSlope = right.fit.line.slope - left.fit.line.slope
            let unresolved = islandBefore[k]
            let kind: DiscontinuityKind = unresolved > 0 ? .unresolved : (abs(jump) > stepThreshold ? .offsetStep : .slopeChange)
            var lo = cL - halfWindow - abs(jump)
            var hi = cR + halfWindow + abs(jump)
            var position = mid
            if kind == .slopeChange || (kind == .unresolved && abs(jump) <= stepThreshold) {
                // Where the lines are within the step threshold of each other the change cannot be located
                // more precisely than their intersection ± that interval.
                let intersection = dSlope != 0 ? mid - jump / dSlope : Double.nan
                if intersection.isFinite, dSlope != 0 {
                    let margin = stepThreshold / abs(dSlope) + halfWindow
                    lo = min(lo, intersection - margin)
                    hi = max(hi, intersection + margin)
                    if kind == .slopeChange { position = intersection }
                } else {
                    lo = spanULo
                    hi = spanUHi
                }
            }
            lo = max(lo, spanULo)
            hi = min(hi, spanUHi)
            position = min(max(position, lo), hi)
            let fLo = max(s0, Int64(frame(lo, span).rounded(.down)))
            let fHi = min(s1, Int64(frame(hi, span).rounded(.up)) + 1)
            var status: [WindowStatus: Int] = [:]
            for i in mine where windows[i].groupClockCenter >= lo && windows[i].groupClockCenter <= hi { status[windows[i].status, default: 0] += 1 }
            let detection = Discontinuity(
                kind: kind, declaredEpoch: span.epoch, bracket: lo...hi, frames: fLo..<fHi, position: position,
                stepMilliseconds: jump * 1000, slopeChangePPM: dSlope * 1e6,
                leftWindowCount: left.indices.count, rightWindowCount: right.indices.count, unresolvedWindowCount: unresolved,
                leftResidualMaxMilliseconds: left.fit.maxResidual * 1000, rightResidualMaxMilliseconds: right.fit.maxResidual * 1000,
                leftMedianPeakScore: median(left.indices.map { windows[points[$0].window].peakScore }),
                rightMedianPeakScore: median(right.indices.map { windows[points[$0].window].peakScore }),
                bracketWindowStatus: status)
            detections.append(detection)
            brackets.append((fLo..<fHi, detections.count - 1))
        }

        // Supported candidates.
        var candidates: [Candidate] = []
        var tooShort: [Range<Int64>] = []
        for segment in segments {
            let us = segment.indices.map { points[$0].u }
            let start = max(s0, Int64(frame(us.min()! + halfWindow, span).rounded(.up)))
            let end = min(s1, Int64(frame(us.max()! - halfWindow, span).rounded(.down)) + 1)
            guard start < end else { continue }
            var pieces: [Range<Int64>] = [start..<end]
            for bracket in brackets {
                pieces = pieces.flatMap { subtract(bracket.frames, from: $0) }
            }
            for piece in pieces {
                if piece.upperBound - piece.lowerBound >= minimumSupportedFrames {
                    candidates.append(Candidate(spanIndex: spanIndex, frames: piece, line: segment.fit.line))
                } else {
                    tooShort.append(piece)
                }
            }
        }

        // Everything else is unsupported, with its cause.
        var regions: [PendingRegion] = tooShort.map { PendingRegion(spanIndex: spanIndex, frames: $0, outcome: .unsupported(.insufficientOverlap, .tooShort)) }
        var covered = (candidates.map(\.frames) + tooShort).sorted { $0.lowerBound < $1.lowerBound }
        covered.append(s1..<s1)
        var cursor = s0
        for range in covered {
            if range.lowerBound > cursor {
                let gap = cursor..<range.lowerBound
                regions.append(PendingRegion(spanIndex: spanIndex, frames: gap, outcome: cause(of: gap, span: span, brackets: brackets, islandPoints: islandPoints, points: points, windowsInSpan: mine)))
            }
            cursor = max(cursor, range.upperBound)
        }
        return (candidates, regions)
    }

    private func cause(of gap: Range<Int64>, span: DeclaredSpan, brackets: [(frames: Range<Int64>, detection: Int)], islandPoints: [Int], points: [Point], windowsInSpan: [Int]) -> RegionOutcome {
        let hits = brackets.filter { $0.frames.overlaps(gap) }.map(\.detection)
        if !hits.isEmpty { return .unsupported(.nonlinear, .discontinuity(hits)) }
        func inside(_ c: Double) -> Bool {
            let f = frame(c, span)
            return f >= Double(gap.lowerBound) && f < Double(gap.upperBound)
        }
        let unresolved = islandPoints.filter { inside(points[$0].u) }.count
        if unresolved > 0 { return .unsupported(.nonlinear, .unresolvedWindows(unresolved)) }
        var counts: [WindowStatus: Int] = [:]
        for i in windowsInSpan where windows[i].status != .eligible && inside(windows[i].groupClockCenter) { counts[windows[i].status, default: 0] += 1 }
        if let dominant = WindowStatus.allCases.filter({ counts[$0] != nil }).max(by: { counts[$0]! < counts[$1]! }) {
            return .unsupported(dominant == .noReference ? .disconnected : .estimatorAbstained, .noEvidence(dominant: dominant))
        }
        return .unsupported(.insufficientOverlap, .edgeMargin)
    }

    // MARK: Estimator and exact helpers

    private func tiles(_ frames: Range<Int64>) -> [Range<Int64>] {
        let s0 = frames.lowerBound, s1 = frames.upperBound
        let tile = Int64((parameters.tileSeconds * F).rounded())
        let k = Double(estimatorParameters.windowCount)
        let stride = max(1, Int64(((parameters.tileSeconds - estimatorParameters.windowSeconds) * k / (k - 1) * F).rounded()))
        guard s1 - s0 > tile else { return [frames] }
        var result: [Range<Int64>] = []
        var start = s0
        while start + tile < s1 {
            result.append(start..<(start + tile))
            start += stride
        }
        result.append((s1 - tile)..<s1)
        return result
    }

    private func track(for frames: Range<Int64>, in span: DeclaredSpan) throws(SegmentError) -> EstimatorTrack {
        let pad = Int64((parameters.slicePaddingSeconds * F).rounded())
        let lo = max(span.frames.lowerBound, frames.lowerBound - pad)
        let hi = min(span.frames.upperBound, frames.upperBound + pad)
        let buffer: SampleBuffer
        do throws(AlignEstimateError) {
            buffer = try SampleBuffer(samples: Array(request.buffer.samples[Int(lo)..<Int(hi)]), sampleRate: request.buffer.sampleRate)
        } catch {
            throw .estimator(error)
        }
        let start: ExactRational
        do throws(TimeMapError) {
            start = try span.groupClockOffset.adding(ExactRational(lo, rate))
        } catch {
            throw .timeMap(error)
        }
        return EstimatorTrack(group: request.group, epoch: RecordingEpochID(), occurrence: request.occurrence.id, groupClockStart: start, buffer: buffer, declaredOverlap: Int(frames.lowerBound - lo)..<Int(frames.upperBound - lo))
    }

    private func estimate(_ tracks: [EstimatorTrack]) throws(SegmentError) -> EstimationReport {
        do throws(AlignEstimateError) {
            return try AcousticEstimator.estimate(EstimationRequest(reference: request.reference, tracks: tracks, search: request.search))
        } catch {
            throw .estimator(error)
        }
    }

    private func image(_ segment: AffineClockSegment, _ u: ExactRational) throws(SegmentError) -> ExactRational {
        do throws(TimeMapError) {
            return try segment.rateRatio.multiplied(by: u).adding(segment.alignedOffset)
        } catch {
            throw .timeMap(error)
        }
    }
}

private extension PendingRegion {
    var isSupported: Bool {
        if case .supported = outcome { return true }
        return false
    }
}

func subtract(_ cut: Range<Int64>, from range: Range<Int64>) -> [Range<Int64>] {
    guard cut.overlaps(range) else { return [range] }
    var result: [Range<Int64>] = []
    if cut.lowerBound > range.lowerBound { result.append(range.lowerBound..<cut.lowerBound) }
    if cut.upperBound < range.upperBound { result.append(cut.upperBound..<range.upperBound) }
    return result
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}
