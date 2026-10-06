import Foundation
import WWCore
import WWTimeMap

// MARK: - Manifest

/// Why a channel is explicit zero padding over a run of output frames. Mirrors the WWTimeMap inverse
/// region (never inverted, bridged or extrapolated).
public enum RenderPaddingReason: Hashable, Sendable, Codable {
    /// Between two adjacent mapped spans of the occurrence (a known discontinuity).
    case gap
    /// Where frames of an epoch with no supported map could lie.
    case unsupportedEpoch(UnsupportedReason)
    /// Before the first or after the last mapped frame of the occurrence.
    case outsideCoverage
}

/// One output run rendered from one affine segment of one span: source position
/// `x(k) = firstSourcePosition + (k - outputStart) * sourceFramesPerOutputFrame`, exactly.
public struct RenderSourceRun: Hashable, Sendable, Codable {
    public let epoch: RecordingEpochID
    /// The span the taps are confined to (no tap ever reads outside it).
    public let spanStartFrame: Int64
    public let spanEndFrame: Int64
    public let provenance: MapProvenance.Kind
    /// Index of the affine segment in the epoch's map.
    public let segmentIndex: Int
    /// a, aligned seconds per group-clock second.
    public let rateRatio: ExactRational
    /// 1/a: the pitch change of clock correction. It is not a time stretch; no stretch is ever applied.
    public let clockPitchFactor: ExactRational
    /// Fin / (a * Fout), exact.
    public let sourceFramesPerOutputFrame: ExactRational
    /// Exact source frame position of the run's first output frame.
    public let firstSourcePosition: ExactRational
}

public enum RenderRunContent: Hashable, Sendable, Codable {
    case source(RenderSourceRun)
    case padding(RenderPaddingReason)
}

/// A half-open range of output frames `[outputStart, outputEnd)` with one treatment.
public struct RenderRun: Hashable, Sendable, Codable {
    public let outputStart: Int64
    public let outputEnd: Int64
    public let content: RenderRunContent
}

/// What one occurrence contributes: its input asset and the runs that tile the whole output range.
public struct RenderOccurrenceRecord: Hashable, Sendable, Codable {
    public let occurrence: SourceOccurrenceID
    public let source: SourceID
    public let nominalRate: NominalRate
    public let assetVersion: String
    /// Distinct decoded channels requested from this occurrence, ascending.
    public let decodedChannels: [Int]
    /// Ascending, contiguous, covering `outputFrames` exactly.
    public let runs: [RenderRun]
}

/// The complete, versioned description of a render. Everything that can change a rendered sample is here.
public struct RenderManifest: Hashable, Sendable, Codable {
    public let rendererVersion: Int
    public let outputAssetFormatVersion: Int
    public let recipe: RenderRecipe
    public let group: RecorderGroupID
    public let reference: TimelineReference
    public let outputRate: NominalRate
    /// First output frame `k0` (aligned instant `k0 / outputRate`): the explicit delay of the render.
    public let outputStartFrame: Int64
    public let outputFrameCount: Int64
    /// Output channel `i` is `channels[i]`.
    public let channels: [RenderChannel]
    public let occurrences: [RenderOccurrenceRecord]
}

// MARK: - Plan

struct PlannedSourceRun: Sendable {
    let outputStart: Int64
    let outputEnd: Int64
    let spanStart: Int64
    let spanEnd: Int64
    /// `x(k) = (positionNumerator + (k - outputStart) * stepNumerator) / denominator`.
    let positionNumerator: Int128
    let stepNumerator: Int128
    let denominator: Int128
    /// Taps on each side of the source position.
    let halfTaps: Int
    /// min(1, output/input frame rate): the kernel's time scale in source samples.
    let kernelScale: Double
    /// Unit step at an integer position: copied exactly.
    let isIdentity: Bool
}

struct PlannedOccurrence: Sendable {
    let occurrence: SourceOccurrenceID
    let source: SourceID
    let decodedChannels: [Int]
    /// `(output channel index, index into decodedChannels)`.
    let routes: [(output: Int, input: Int)]
    let runs: [PlannedSourceRun]

    /// The widest one-sided tap count of any run of the occurrence.
    var tapReach: Int { runs.map(\.halfTaps).max() ?? 0 }
}

struct RenderPlan: Sendable {
    let manifest: RenderManifest
    let occurrences: [PlannedOccurrence]
}

extension RenderPlan {
    static func make(_ request: RenderRequest) throws(RenderFailure) -> RenderPlan {
        let map = request.groupMap
        let k0 = request.outputFrames.lowerBound
        let k1 = request.outputFrames.upperBound
        guard k0 < k1, k1 - k0 <= RenderRequest.maximumOutputFrames,
              k0 >= -RenderRequest.maximumOutputFrameMagnitude, k1 <= RenderRequest.maximumOutputFrameMagnitude
        else { throw .invalidOutputRange }
        guard !request.channels.isEmpty else { throw .emptyChannelList }

        let placements = Dictionary(map.placements.map { ($0.occurrence.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<ChannelKey> = []
        var occurrenceOrder: [SourceOccurrenceID] = []
        var channelsByOccurrence: [SourceOccurrenceID: [(output: Int, decoded: Int)]] = [:]
        for (index, channel) in request.channels.enumerated() {
            guard placements[channel.occurrence] != nil else { throw .unknownOccurrence(channel.occurrence) }
            guard channel.decodedChannel >= 0, channel.decodedChannel < RenderRequest.maximumDecodedChannels else { throw .invalidDecodedChannel(channel) }
            if case .known(let stated) = channel.statedChannel, stated != channel.decodedChannel { throw .statedChannelMismatch(channel) }
            guard seen.insert(ChannelKey(occurrence: channel.occurrence, decodedChannel: channel.decodedChannel)).inserted else { throw .duplicateChannel(channel) }
            if channelsByOccurrence[channel.occurrence] == nil { occurrenceOrder.append(channel.occurrence) }
            channelsByOccurrence[channel.occurrence, default: []].append((index, channel.decodedChannel))
        }

        var assets: [SourceOccurrenceID: String] = [:]
        for asset in request.inputAssets {
            guard assets[asset.occurrence] == nil else { throw .duplicateInputAsset(asset.occurrence) }
            guard channelsByOccurrence[asset.occurrence] != nil,
                  !asset.assetVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw .invalidInputAsset(asset.occurrence) }
            assets[asset.occurrence] = asset.assetVersion
        }
        for occurrence in occurrenceOrder where assets[occurrence] == nil { throw .missingInputAsset(occurrence) }

        let epochs = Dictionary(map.epochs.map { ($0.epoch, $0.mapping) }, uniquingKeysWith: { first, _ in first })
        let g = Int128(request.outputRate.framesPerSecond)
        var records: [RenderOccurrenceRecord] = []
        var planned: [PlannedOccurrence] = []
        for occurrenceID in occurrenceOrder {
            guard let placement = placements[occurrenceID], let routesIn = channelsByOccurrence[occurrenceID], let assetVersion = assets[occurrenceID] else {
                throw .unknownOccurrence(occurrenceID)
            }
            let planner = OccurrencePlanner(map: map, placement: placement, epochs: epochs, g: g, k0: k0, k1: k1, recipe: request.recipe)
            let (runs, sourceRuns) = try planner.plan()
            let decoded = Array(Set(routesIn.map(\.decoded))).sorted()
            let routes = routesIn.map { route in (output: route.output, input: decoded.firstIndex(of: route.decoded)!) }
            records.append(RenderOccurrenceRecord(
                occurrence: occurrenceID,
                source: placement.occurrence.source,
                nominalRate: placement.occurrence.nominalRate,
                assetVersion: assetVersion,
                decodedChannels: decoded,
                runs: runs
            ))
            planned.append(PlannedOccurrence(occurrence: occurrenceID, source: placement.occurrence.source, decodedChannels: decoded, routes: routes, runs: sourceRuns))
        }
        let manifest = RenderManifest(
            rendererVersion: RenderVersions.renderer,
            outputAssetFormatVersion: RenderVersions.outputAssetFormat,
            recipe: request.recipe,
            group: map.group,
            reference: map.reference,
            outputRate: request.outputRate,
            outputStartFrame: k0,
            outputFrameCount: k1 - k0,
            channels: request.channels,
            occurrences: records
        )
        return RenderPlan(manifest: manifest, occurrences: planned)
    }
}

extension RenderRequest {
    /// The largest |k| accepted: 2^31 seconds at 2^20 Hz, the WWTimeMap instant envelope.
    public static let maximumOutputFrameMagnitude: Int64 = 1 << 51
    /// Decoded channel indices must be below this.
    public static let maximumDecodedChannels = 1024
}

private struct ChannelKey: Hashable {
    let occurrence: SourceOccurrenceID
    let decodedChannel: Int
}

// MARK: - Occurrence planning

/// Plans one occurrence: a source run for every (span, segment) whose aligned image meets the output grid,
/// and explicit padding elsewhere. Every run is cross-checked against `GroupTimeMap.sourceFrame` at both
/// ends (the planner and the map must agree exactly, or the render is refused).
private struct OccurrencePlanner {
    let map: GroupTimeMap
    let placement: OccurrencePlacement
    let epochs: [RecordingEpochID: EpochClockMap.Mapping]
    let g: Int128
    let k0: Int64
    let k1: Int64
    let recipe: RenderRecipe

    var occurrenceID: SourceOccurrenceID { placement.occurrence.id }

    func plan() throws(RenderFailure) -> ([RenderRun], [PlannedSourceRun]) {
        let f = ExactRational(placement.occurrence.nominalRate.framesPerSecond)
        let gRational = try exact { () throws(TimeMapError) in try ExactRational(numerator: g, denominator: 1) }
        var sourceRuns: [(record: RenderRun, planned: PlannedSourceRun)] = []
        // Output frames where the inverse region can change: the grid ends of every mapped span's hull.
        var breakpoints: Set<Int64> = []

        for span in placement.spans {
            guard case .mapped(let segments, let provenance)? = epochs[span.epoch] else { continue }
            let hullLo = try alignedInstant(span.startFrame)
            let hullHi = try alignedInstant(span.endFrame - 1)
            let hullKLo = try exact { () throws(TimeMapError) in try hullLo.multiplied(by: gRational).ceil() }
            let hullKEnd = try exact { () throws(TimeMapError) in try hullHi.multiplied(by: gRational).floor() } + 1
            breakpoints.insert(clamp(hullKLo))
            breakpoints.insert(clamp(hullKEnd))

            let e = span.groupClockOffset
            let uFirst = try exact { () throws(TimeMapError) in try ExactRational(span.startFrame, placement.occurrence.nominalRate.framesPerSecond).adding(e) }
            let uLast = try exact { () throws(TimeMapError) in try ExactRational(span.endFrame - 1, placement.occurrence.nominalRate.framesPerSecond).adding(e) }
            for (index, segment) in segments.enumerated() where segment.groupClockStart <= uLast && segment.groupClockEnd > uFirst {
                let a = segment.rateRatio
                let b = segment.alignedOffset
                let imageLo = try exact { () throws(TimeMapError) in try a.multiplied(by: segment.groupClockStart).adding(b) }
                let imageHi = try exact { () throws(TimeMapError) in try a.multiplied(by: segment.groupClockEnd).adding(b) }
                let lower = Swift.max(imageLo, hullLo)
                var kStart = try exact { () throws(TimeMapError) in try lower.multiplied(by: gRational).ceil() }
                var kEnd = imageHi > hullHi ? hullKEnd : try exact { () throws(TimeMapError) in try imageHi.multiplied(by: gRational).ceil() }
                kStart = Swift.max(kStart, Int128(k0))
                kEnd = Swift.min(kEnd, Int128(k1))
                guard kStart < kEnd else { continue }

                // x(k) = F * ((k/G - b)/a - e); step = F / (a G).
                let step = try exact { () throws(TimeMapError) in try f.divided(by: a.multiplied(by: gRational)) }
                guard step <= ExactRational(Int64(recipe.maximumDecimation)) else {
                    throw .ratioOutsideEnvelope(occurrenceID, sourceFramesPerOutputFrame: step)
                }
                let x0 = try position(k: kStart, a: a, b: b, e: e, f: f, g: gRational)
                let start = Int64(kStart)
                let end = Int64(kEnd)
                try verifyAgainstMap(k: start, expected: x0, epoch: span.epoch)
                let (positionNumerator, stepNumerator, denominator) = try runNumerators(x0, step, count: end - start)
                let xLast = try exact { () throws(TimeMapError) in
                    try ExactRational(numerator: positionNumerator + Int128(end - start - 1) * stepNumerator, denominator: denominator)
                }
                try verifyAgainstMap(k: end - 1, expected: xLast, epoch: span.epoch)

                let kernelScale = step <= .one ? 1.0 : 1.0 / step.approximateDouble
                let halfTaps = Int((Double(recipe.kernel.halfWidth) / kernelScale).rounded(.up))
                let record = RenderRun(outputStart: start, outputEnd: end, content: .source(RenderSourceRun(
                    epoch: span.epoch,
                    spanStartFrame: span.startFrame,
                    spanEndFrame: span.endFrame,
                    provenance: provenance.kind,
                    segmentIndex: index,
                    rateRatio: a,
                    clockPitchFactor: segment.clockPitchFactor,
                    sourceFramesPerOutputFrame: step,
                    firstSourcePosition: x0
                )))
                sourceRuns.append((record, PlannedSourceRun(
                    outputStart: start,
                    outputEnd: end,
                    spanStart: span.startFrame,
                    spanEnd: span.endFrame,
                    positionNumerator: positionNumerator,
                    stepNumerator: stepNumerator,
                    denominator: denominator,
                    halfTaps: halfTaps,
                    kernelScale: kernelScale,
                    isIdentity: step == .one && x0.isInteger
                )))
            }
        }

        sourceRuns.sort { $0.record.outputStart < $1.record.outputStart }
        for (left, right) in zip(sourceRuns, sourceRuns.dropFirst()) where right.record.outputStart < left.record.outputEnd {
            throw .mapInverseMismatch(occurrenceID, outputFrame: right.record.outputStart)
        }

        // Padding tiles the complement, split wherever the inverse region can change.
        var runs: [RenderRun] = []
        var cursor = k0
        func pad(upTo end: Int64) throws(RenderFailure) {
            let cuts = breakpoints.filter { $0 > cursor && $0 < end }.sorted() + [end]
            for cut in cuts {
                runs.append(RenderRun(outputStart: cursor, outputEnd: cut, content: .padding(try paddingReason(cursor, cut))))
                cursor = cut
            }
        }
        for run in sourceRuns {
            if run.record.outputStart > cursor { try pad(upTo: run.record.outputStart) }
            runs.append(run.record)
            cursor = run.record.outputEnd
        }
        if cursor < k1 { try pad(upTo: k1) }
        return (runs, sourceRuns.map(\.planned))
    }

    private func clamp(_ k: Int128) -> Int64 { Int64(Swift.min(Swift.max(k, Int128(k0)), Int128(k1))) }

    private func alignedInstant(_ frame: Int64) throws(RenderFailure) -> ExactRational {
        let forward: ForwardMapping
        do { forward = try map.alignedTime(ofFrame: frame, in: occurrenceID) } catch { throw .arithmeticEnvelopeExceeded }
        guard case .aligned(let position) = forward else { throw .mapInverseMismatch(occurrenceID, outputFrame: 0) }
        return position.instant
    }

    private func position(k: Int128, a: ExactRational, b: ExactRational, e: ExactRational, f: ExactRational, g: ExactRational) throws(RenderFailure) -> ExactRational {
        try exact { () throws(TimeMapError) in
            try ExactRational(numerator: k, denominator: 1).divided(by: g).subtracting(b).divided(by: a).subtracting(e).multiplied(by: f)
        }
    }

    private func inverse(_ k: Int64) throws(RenderFailure) -> InverseMapping {
        do { return try map.sourceFrame(at: ExactRational(numerator: Int128(k), denominator: g), in: occurrenceID) } catch { throw .arithmeticEnvelopeExceeded }
    }

    private func verifyAgainstMap(k: Int64, expected: ExactRational, epoch: RecordingEpochID) throws(RenderFailure) {
        guard case .source(let position) = try inverse(k), position.epoch == epoch, position.exactFrame == expected else {
            throw .mapInverseMismatch(occurrenceID, outputFrame: k)
        }
    }

    private func paddingReason(_ start: Int64, _ end: Int64) throws(RenderFailure) -> RenderPaddingReason {
        let first = try inverse(start)
        guard try inverse(end - 1) == first else { throw .mapInverseMismatch(occurrenceID, outputFrame: end - 1) }
        switch first {
        case .source: throw .mapInverseMismatch(occurrenceID, outputFrame: start)
        case .gap: return .gap
        case .unsupported(let region): return .unsupportedEpoch(region.candidates[0].reason)
        case .outsideCoverage: return .outsideCoverage
        }
    }
}

/// `x0 = P/Q`, `step = S/Q` over one denominator, so every position of a `count`-frame run is the exact
/// integer ratio `(P + j*S)/Q`. Refuses if any of them would leave Int128. (Maps accepted by the
/// WWTimeMap envelope have not been found to reach this; it stays as a fail-closed guard.)
func runNumerators(_ x0: ExactRational, _ step: ExactRational, count: Int64) throws(RenderFailure) -> (Int128, Int128, Int128) {
    let dx = x0.denominator
    let ds = step.denominator
    let common = Int128(gcd(dx.magnitude, ds.magnitude))
    let (q, o1) = (dx / common).multipliedReportingOverflow(by: ds)
    let (p, o2) = x0.numerator.multipliedReportingOverflow(by: q / dx)
    let (s, o3) = step.numerator.multipliedReportingOverflow(by: q / ds)
    let (span, o4) = Int128(count - 1).multipliedReportingOverflow(by: s)
    let (_, o5) = p.addingReportingOverflow(span)
    guard !(o1 || o2 || o3 || o4 || o5) else { throw .arithmeticEnvelopeExceeded }
    return (p, s, q)
}

private func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
    var (x, y) = (a, b)
    while y != 0 { (x, y) = (y, x % y) }
    return x
}

/// Runs exact WWTimeMap arithmetic, refusing (never approximating) if it leaves the Int128 envelope.
func exact<T>(_ body: () throws(TimeMapError) -> T) throws(RenderFailure) -> T {
    do { return try body() } catch { throw .arithmeticEnvelopeExceeded }
}
