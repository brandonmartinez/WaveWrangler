import Foundation
import WWAlignEstimate
import WWAlignSegment
import WWCore
import WWTimeMap

/// Per-plant result, scored against the planted truth (never against the segmenter's own fit).
struct PlantScore: Sendable {
    enum Status: String, Sendable { case flagged, unsupported, bridged }
    let plant: Plant
    let status: Status
    /// The detection whose bracket covers the plant, if any.
    let detection: Discontinuity?
    /// |detected position − planted position|, seconds (flagged only).
    let positionErrorSeconds: Double?
}

struct CaseScore: Sendable {
    let kase: SegmentCase
    let plants: [PlantScore]
    /// Mapped regions whose frames span more than one truth piece or include inserted frames.
    let bridgingRegions: Int
    /// Of those, the ones whose residual against truth is inside the WW-016 gate (silent smooth bridging).
    let silentBridges: Int
    /// Worst per-region p95 / max residual of mapped regions against clock truth, milliseconds.
    let residualP95Milliseconds: Double
    let residualMaxMilliseconds: Double
    let residualGateFailures: [String]
    let monotonicFailures: [String]
    let inverseFailures: [String]
    let retentionFailures: [String]
    let detections: Int
    /// Detections as "kind@position s [bracket]" and unsupported regions as "start-end s cause", for reports.
    let detectionSummary: [String]
    /// Detections whose bracket covers no planted discontinuity (on a negative, a false split; on a positive,
    /// a conservative extra split that costs coverage). Reported, not gated on positives.
    let spuriousDetections: Int
    let unsupportedSummary: [String]
    let mappedRegions: Int
    let supportedFraction: Double

    /// A false split on a negative: any detection, or more than one mapped region in the declared span.
    var falseSplit: Bool { detections > 0 || mappedRegions > 1 }

    var hardFailures: [String] {
        var f = residualGateFailures + monotonicFailures + inverseFailures + retentionFailures
        if bridgingRegions > 0 { f.append("\(bridgingRegions) mapped region(s) span a planted discontinuity") }
        for p in plants where p.status == .bridged { f.append("plant \(p.plant.kind.rawValue)@\(p.plant.frame) bridged") }
        return f
    }
}

enum Scoring {
    static let p95Gate = ProvisionalClockGates.maximumResidualP95Milliseconds
    static let maxGate = ProvisionalClockGates.maximumResidualMaxMilliseconds

    /// Nearest-rank 95th value.
    static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
    }

    static func exact(_ seconds: Double) throws -> ExactRational {
        try ExactRational(Int64((seconds * 1_000_000).rounded()), 1_000_000)
    }

    static func score(_ kase: SegmentCase, request: SegmentationRequest, report: SegmentationReport) throws -> CaseScore {
        let truth = kase.truth
        let f = Double(truth.rate)
        let map = report.map
        let occurrence = request.occurrence.id
        let mapped = report.regions.filter(\.isSupported)

        // Retention: one placement of the identical occurrence; regions tile the declared span exactly;
        // the declared epoch is present; epochs are distinct; nothing is clock-approved.
        var retention: [String] = []
        if map.placements.count != 1 || map.placements.first?.occurrence != request.occurrence { retention.append("occurrence not retained") }
        let span = request.declaredSpans[0]
        var cursor = span.frames.lowerBound
        for region in report.regions {
            if region.frames.lowerBound != cursor { retention.append("regions do not tile the declared span at \(cursor)") }
            if region.declaredEpoch != span.epoch { retention.append("region lost its declared epoch") }
            cursor = region.frames.upperBound
        }
        if cursor != span.frames.upperBound { retention.append("regions end at \(cursor), span at \(span.frames.upperBound)") }
        if !report.regions.contains(where: { $0.epoch == span.epoch }) { retention.append("declared epoch missing") }
        if Set(report.regions.map(\.epoch)).count != report.regions.count { retention.append("duplicate epochs") }
        if map.placements.first?.spans.map(\.epoch) != report.regions.map(\.epoch) { retention.append("placement spans differ from regions") }
        for epoch in map.epochs {
            if case .mapped(_, let provenance) = epoch.mapping, provenance.kind.isClockApproved { retention.append("clock approval emitted") }
        }
        if report.segmenter != DiscontinuitySegmenter.identifier { retention.append("segmenter identifier \(report.segmenter)") }

        // Residuals of every mapped region against clock truth on a 1 s grid (plus its last frame), and
        // whether the region spans more than one truth piece.
        var gateFailures: [String] = []
        var worstP95 = 0.0, worstMax = 0.0
        var bridging = 0, silent = 0
        var forward: [(frame: Int, time: Double)] = []
        var monotonic: [String] = []
        for region in mapped {
            let lo = Int(region.frames.lowerBound), hi = Int(region.frames.upperBound)
            let firstPiece = truth.pieceIndex(ofFrame: lo), lastPiece = truth.pieceIndex(ofFrame: hi - 1)
            var grid = Array(stride(from: lo, to: hi, by: truth.rate))
            grid.append(hi - 1)
            var residuals: [Double] = []
            for n in grid {
                guard case .aligned(let position) = try map.alignedTime(ofFrame: Int64(n), in: occurrence) else {
                    gateFailures.append("mapped frame \(n) has no aligned time")
                    continue
                }
                let t = position.instant.approximateDouble
                forward.append((n, t))
                if let truthTime = truth.time(ofFrame: n) { residuals.append(abs(t - truthTime) * 1000) }
            }
            let p95 = p95(residuals), worst = residuals.max() ?? 0
            worstP95 = max(worstP95, p95)
            worstMax = max(worstMax, worst)
            let spans = firstPiece != lastPiece || truth.pieces[firstPiece].content != truth.pieces[lastPiece].content
                || truth.pieces[firstPiece...lastPiece].contains { if case .inserted = $0.content { true } else { false } }
            if spans {
                bridging += 1
                if p95 <= p95Gate && worst <= maxGate { silent += 1 }
            } else if p95 > p95Gate || worst > maxGate {
                gateFailures.append(String(format: "region %d..<%d residual p95 %.3f ms max %.3f ms", lo, hi, p95, worst))
            }
            guard case .supported(let proposal) = region.outcome else { continue }
            if proposal.segment.rateRatio <= .zero { monotonic.append("non-positive rate ratio") }
        }
        forward.sort { $0.frame < $1.frame }
        for (l, r) in zip(forward, forward.dropFirst()) where r.frame > l.frame && !(r.time > l.time) {
            monotonic.append("aligned time not increasing at frames \(l.frame)->\(r.frame)")
        }

        // Inverse: probes inside skipped truth intervals never invert; every inverse lands within the gate
        // of truth and never in inserted frames.
        var inverse: [String] = []
        let mappedPieces = truth.pieces.enumerated().filter { if case .mapped = $0.element.content { true } else { false } }
        for (l, r) in zip(mappedPieces, mappedPieces.dropFirst()) {
            let prevEnd = truth.time(ofFrame: l.element.frames.upperBound - 1)! + 1 / f
            let nextStart = truth.time(ofFrame: r.element.frames.lowerBound)!
            let margin = 0.002 + 1 / f
            guard nextStart - prevEnd > 2 * margin else { continue }
            for k in 1...5 {
                let t = prevEnd + margin + (nextStart - prevEnd - 2 * margin) * Double(k) / 6
                if case .source(let s) = try map.sourceFrame(at: try exact(t), in: occurrence) {
                    inverse.append(String(format: "skipped instant %.4f inverted to frame %lld", t, s.frame))
                }
            }
        }
        let times = truth.pieces.compactMap { piece -> (Double, Double)? in
            guard case .mapped = piece.content, !piece.frames.isEmpty else { return nil }
            return (truth.time(ofFrame: piece.frames.lowerBound)!, truth.time(ofFrame: piece.frames.upperBound - 1)!)
        }
        let tLo = times.map(\.0).min()!, tHi = times.map(\.1).max()!
        for t in stride(from: tLo, through: tHi, by: 0.5) {
            guard case .source(let s) = try map.sourceFrame(at: try exact(t), in: occurrence) else { continue }
            guard let truthTime = truth.time(ofFrame: Int(s.frame)) else {
                inverse.append(String(format: "instant %.4f inverted into inserted frame %lld", t, s.frame))
                continue
            }
            if abs(truthTime - t) > maxGate / 1000 + 1 / f {
                inverse.append(String(format: "instant %.4f inverted to frame %lld, truth %.4f", t, s.frame, truthTime))
            }
        }

        // Plants.
        var plants: [PlantScore] = []
        for plant in kase.plants {
            let locus = (plant.frame - 1)..<((plant.inserted?.upperBound ?? plant.frame) + 1)
            let bridged = mapped.contains { region in
                let r = Int(region.frames.lowerBound)..<Int(region.frames.upperBound)
                if let ins = plant.inserted, r.overlaps(ins) { return true }
                return r.contains(plant.frame - 1) && r.contains(plant.inserted?.upperBound ?? plant.frame)
            }
            let detection = report.detections.first { d in
                let r = Int(d.frames.lowerBound)..<Int(d.frames.upperBound)
                return r.overlaps(locus)
            }
            let status: PlantScore.Status = bridged ? .bridged : (detection != nil ? .flagged : .unsupported)
            let error = detection.map { abs($0.position - Double(plant.frame) / f) }
            plants.append(PlantScore(plant: plant, status: status, detection: detection, positionErrorSeconds: error))
        }

        let spurious = report.detections.filter { d in
            let r = Int(d.frames.lowerBound)..<Int(d.frames.upperBound)
            return !kase.plants.contains { r.overlaps((($0.frame - 1)..<(($0.inserted?.upperBound ?? $0.frame) + 1))) }
        }.count
        let detectionSummary = report.detections.map {
            String(format: "%@@%.2fs[%.2f-%.2f]", $0.kind.rawValue, $0.position, $0.bracket.lowerBound, $0.bracket.upperBound)
        }
        let unsupportedSummary = report.regions.compactMap { region -> String? in
            guard case .unsupported(_, let cause) = region.outcome else { return nil }
            let label: String = switch cause {
            case .discontinuity: "discontinuity"
            case .unresolvedWindows(let n): "unresolved(\(n))"
            case .noEvidence(let dominant): "noEvidence(\(dominant))"
            case .edgeMargin: "edgeMargin"
            case .tooShort: "tooShort"
            case .estimatorAbstained(let reason): "abstained(\(reason))"
            case .lineDisagreement(let ms): String(format: "lineDisagreement(%.2fms)", ms)
            case .imageOverlap: "imageOverlap"
            }
            return String(format: "%.1f-%.1fs %@", Double(region.frames.lowerBound) / f, Double(region.frames.upperBound) / f, label)
        }

        let supportedFrames = mapped.map { Double($0.frames.upperBound - $0.frames.lowerBound) }.reduce(0, +)
        return CaseScore(
            kase: kase, plants: plants, bridgingRegions: bridging, silentBridges: silent,
            residualP95Milliseconds: worstP95, residualMaxMilliseconds: worstMax, residualGateFailures: gateFailures,
            monotonicFailures: monotonic, inverseFailures: inverse, retentionFailures: retention,
            detections: report.detections.count, detectionSummary: detectionSummary, spuriousDetections: spurious, unsupportedSummary: unsupportedSummary, mappedRegions: mapped.count,
            supportedFraction: supportedFrames / Double(truth.frameCount))
    }
}
