import Foundation
import WWCore

// MARK: - Epoch maps and placements

/// The group-clock -> aligned map of one clock epoch (a continuous-clock span of the recorder group).
public struct EpochClockMap: Hashable, Sendable {
    public enum Mapping: Hashable, Sendable {
        /// Contiguous, continuous, positive affine segments in ascending group-clock order.
        case mapped(segments: [AffineClockSegment], provenance: MapProvenance)
        /// No supported map for this epoch. Its frames have no aligned position and nothing inverts into it.
        case unsupported(UnsupportedReason)
    }

    public let epoch: RecordingEpochID
    public let mapping: Mapping

    public init(epoch: RecordingEpochID, mapping: Mapping) {
        self.epoch = epoch
        self.mapping = mapping
    }
}

/// A half-open range of an occurrence's frames recorded within one epoch.
public struct EpochSpan: Hashable, Sendable {
    /// First frame of the span.
    public let startFrame: Int64
    /// One past the last frame of the span.
    public let endFrame: Int64
    public let epoch: RecordingEpochID
    /// e in `u = n/F + e`: the epoch's group-clock time of (the extension of this span to) frame 0, seconds.
    public let groupClockOffset: ExactRational

    public init(startFrame: Int64, endFrame: Int64, epoch: RecordingEpochID, groupClockOffset: ExactRational) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.epoch = epoch
        self.groupClockOffset = groupClockOffset
    }
}

/// Where an occurrence's frames sit on its group's epochs. Frames between two spans are a known gap (a
/// discontinuity); consecutive spans must therefore be in different epochs (a gap restarts the epoch).
public struct OccurrencePlacement: Hashable, Sendable {
    public let occurrence: SourceOccurrence
    /// Ascending, non-overlapping spans.
    public let spans: [EpochSpan]

    public init(occurrence: SourceOccurrence, spans: [EpochSpan]) {
        self.occurrence = occurrence
        self.spans = spans
    }
}

// MARK: - Query results

public struct AlignedPosition: Hashable, Sendable {
    /// Exact aligned time, seconds.
    public let instant: ExactRational
    public let epoch: RecordingEpochID
    public let provenance: MapProvenance.Kind
}

public struct SourcePosition: Hashable, Sendable {
    public let occurrence: SourceOccurrenceID
    public let epoch: RecordingEpochID
    /// Nearest frame, HALF-UP: always within 1/2 frame of `exactFrame`.
    public let frame: Int64
    /// Exact (fractional) source frame position of the queried aligned instant.
    public let exactFrame: ExactRational
    public let provenance: MapProvenance.Kind
}

/// The two spans on either side of a known gap.
public struct GapBoundary: Hashable, Sendable {
    public let occurrence: SourceOccurrenceID
    public let precedingEpoch: RecordingEpochID
    public let precedingLastFrame: Int64
    public let followingEpoch: RecordingEpochID
    public let followingFirstFrame: Int64
}

public enum ForwardMapping: Hashable, Sendable {
    case aligned(AlignedPosition)
    /// The frame lies between two spans of the occurrence (a known discontinuity).
    case gap(GapBoundary)
    case unsupported(epoch: RecordingEpochID, reason: UnsupportedReason)
    case outsideCoverage

    public var regionState: TimeMapRegionState {
        switch self {
        case .aligned(let p): .mapped(p.provenance)
        case .gap: .gap
        case .unsupported(_, let reason): .unsupported(reason)
        case .outsideCoverage: .outsideCoverage
        }
    }
}

public enum InverseMapping: Hashable, Sendable {
    case source(SourcePosition)
    /// The instant lies strictly between two mapped spans of the occurrence. Gaps have no inverse.
    case gap(GapBoundary)
    /// Before the first or after the last mapped frame instant of the occurrence. Never extrapolated.
    case outsideCoverage

    public var regionState: TimeMapRegionState {
        switch self {
        case .source(let p): .mapped(p.provenance)
        case .gap: .gap
        case .outsideCoverage: .outsideCoverage
        }
    }
}

// MARK: - Group map

/// The validated, positive, piecewise map `source(n/F, epoch) -> group clock -> aligned` of one recorder
/// group, relative to an explicit ``TimelineReference``.
///
/// Construction validates every invariant (see ``TimeMapError``) and proves that every exact intermediate
/// needed to map any placed frame forward fits `Int128`, so forward queries for placed frames cannot fail.
/// Inverse queries are exact and refuse (throw) rather than approximate if an arbitrary query instant's
/// exact arithmetic would leave the envelope.
public struct GroupTimeMap: Sendable {
    public let group: RecorderGroupID
    public let reference: TimelineReference
    public let epochs: [EpochClockMap]
    public let placements: [OccurrencePlacement]

    private let compiled: [SourceOccurrenceID: CompiledOccurrence]

    public init(group: RecorderGroupID, reference: TimelineReference, epochs: [EpochClockMap], placements: [OccurrencePlacement]) throws(TimeMapError) {
        self.group = group
        self.reference = reference
        self.epochs = epochs
        self.placements = placements
        self.compiled = try Self.compile(group: group, reference: reference, epochs: epochs, placements: placements)
    }

    public var occurrenceIDs: [SourceOccurrenceID] { placements.map(\.occurrence.id) }

    /// Maps source frame `frame` of `occurrence` to the aligned timeline.
    public func alignedTime(ofFrame frame: Int64, in occurrence: SourceOccurrenceID) throws(TimeMapError) -> ForwardMapping {
        guard let compiled = compiled[occurrence] else { throw .unknownOccurrence(occurrence) }
        guard frame >= 0, frame < compiled.frameCount else { return .outsideCoverage }
        let spans = compiled.spans
        guard let index = spans.firstIndex(where: { frame < $0.span.endFrame }), frame >= spans[index].span.startFrame else {
            if let next = spans.firstIndex(where: { frame < $0.span.startFrame }), next > 0 {
                return .gap(Self.boundary(occurrence, spans[next - 1].span, spans[next].span))
            }
            return .outsideCoverage
        }
        let span = spans[index]
        switch span.state {
        case .unsupported(let reason):
            return .unsupported(epoch: span.span.epoch, reason: reason)
        case .mapped(let kind, let pieces, _, _):
            let n = Int128(frame)
            guard let piece = pieces.first(where: { n >= $0.frameLo && n <= $0.frameHi }) else { return .outsideCoverage }
            return .aligned(AlignedPosition(instant: try piece.forward(n), epoch: span.span.epoch, provenance: kind))
        }
    }

    /// Maps an exact aligned instant back to `occurrence`'s source frames. Known gaps and uncovered instants
    /// are reported, never inverted, bridged or extrapolated.
    public func sourceFrame(at instant: ExactRational, in occurrence: SourceOccurrenceID) throws(TimeMapError) -> InverseMapping {
        guard let compiled = compiled[occurrence] else { throw .unknownOccurrence(occurrence) }
        var previous: CompiledSpan?
        for span in compiled.spans {
            guard case .mapped(let kind, let pieces, let hullLo, let hullHi) = span.state else { continue }
            if instant < hullLo {
                guard let previous else { return .outsideCoverage }
                return .gap(Self.boundary(occurrence, previous.span, span.span))
            }
            if instant <= hullHi {
                guard let piece = pieces.first(where: { instant >= $0.imageLo && instant < $0.imageHi }) else { return .outsideCoverage }
                let exact = try piece.inverse(instant)
                return .source(SourcePosition(occurrence: occurrence, epoch: span.span.epoch, frame: Int64(exact.roundedHalfUp()), exactFrame: exact, provenance: kind))
            }
            previous = span
        }
        return .outsideCoverage
    }

    private static func boundary(_ occurrence: SourceOccurrenceID, _ before: EpochSpan, _ after: EpochSpan) -> GapBoundary {
        GapBoundary(occurrence: occurrence, precedingEpoch: before.epoch, precedingLastFrame: before.endFrame - 1, followingEpoch: after.epoch, followingFirstFrame: after.startFrame)
    }
}

extension GroupTimeMap: Equatable {
    public static func == (lhs: GroupTimeMap, rhs: GroupTimeMap) -> Bool {
        lhs.group == rhs.group && lhs.reference == rhs.reference && lhs.epochs == rhs.epochs && lhs.placements == rhs.placements
    }
}

// MARK: - Compilation and validation

/// `t = (p*n + c) / d` for frames `frameLo...frameHi` of one span inside one segment; `n = (d*t - c) / p`.
struct CompiledPiece: Sendable {
    let frameLo: Int128
    let frameHi: Int128
    /// The segment's aligned image `[imageLo, imageHi)`.
    let imageLo: ExactRational
    let imageHi: ExactRational
    let p: Int128
    let c: Int128
    let d: Int128

    func forward(_ n: Int128) throws(TimeMapError) -> ExactRational {
        try ExactRational(numerator: ExactRational.add(ExactRational.mul(p, n), c), denominator: d)
    }

    func inverse(_ t: ExactRational) throws(TimeMapError) -> ExactRational {
        try t.multiplied(by: ExactRational(numerator: d, denominator: 1))
            .subtracting(ExactRational(numerator: c, denominator: 1))
            .divided(by: ExactRational(numerator: p, denominator: 1))
    }
}

struct CompiledSpan: Sendable {
    enum State: Sendable {
        case mapped(MapProvenance.Kind, [CompiledPiece], hullLo: ExactRational, hullHi: ExactRational)
        case unsupported(UnsupportedReason)
    }

    let span: EpochSpan
    let state: State
}

struct CompiledOccurrence: Sendable {
    let frameCount: Int64
    let spans: [CompiledSpan]
}

extension GroupTimeMap {
    private struct MappedEpoch {
        let segments: [AffineClockSegment]
        let provenance: MapProvenance
        let imageLo: ExactRational
        let imageHi: ExactRational
    }

    static func compile(group: RecorderGroupID, reference: TimelineReference, epochs: [EpochClockMap], placements: [OccurrencePlacement]) throws(TimeMapError) -> [SourceOccurrenceID: CompiledOccurrence] {
        let isReferenceGroup = reference.group == group

        // Epochs: segments positive, ordered, contiguous and continuous; images non-overlapping.
        var mapped: [RecordingEpochID: MappedEpoch] = [:]
        var unsupported: [RecordingEpochID: UnsupportedReason] = [:]
        for epochMap in epochs {
            let id = epochMap.epoch
            guard mapped[id] == nil, unsupported[id] == nil else { throw .duplicateEpoch(id) }
            switch epochMap.mapping {
            case .unsupported(let reason):
                unsupported[id] = reason
            case .mapped(let segments, let provenance):
                guard let first = segments.first, let last = segments.last else { throw .emptyEpochMap(id) }
                for (left, right) in zip(segments, segments.dropFirst()) {
                    if right.groupClockStart < left.groupClockStart { throw .segmentsOutOfOrder(id) }
                    if right.groupClockStart < left.groupClockEnd { throw .overlappingSegments(id) }
                    if right.groupClockStart > left.groupClockEnd { throw .segmentsNotContiguous(id) }
                    let boundary = right.groupClockStart
                    guard try left.aligned(boundary) == right.aligned(boundary) else { throw .discontinuityWithinEpoch(id) }
                }
                if provenance == .timelineReference {
                    guard isReferenceGroup, id == reference.epoch else { throw .misplacedTimelineReference(id) }
                }
                if isReferenceGroup, id == reference.epoch {
                    guard provenance == .timelineReference, segments.allSatisfy(\.isIdentity) else { throw .referenceEpochNotIdentity(id) }
                }
                mapped[id] = MappedEpoch(
                    segments: segments,
                    provenance: provenance,
                    imageLo: try first.aligned(first.groupClockStart),
                    imageHi: try last.aligned(last.groupClockEnd)
                )
            }
        }
        if isReferenceGroup, mapped[reference.epoch] == nil { throw .referenceEpochMissing(reference.epoch) }
        let ordered = epochs.compactMap { e in mapped[e.epoch].map { (e.epoch, $0) } }.sorted { $0.1.imageLo < $1.1.imageLo }
        for (left, right) in zip(ordered, ordered.dropFirst()) where right.1.imageLo < left.1.imageHi {
            throw .overlappingEpochs(left.0, right.0)
        }

        // Placements.
        var result: [SourceOccurrenceID: CompiledOccurrence] = [:]
        var referenceAnchored = false
        for placement in placements {
            let occurrence = placement.occurrence
            let occurrenceID = occurrence.id
            guard result[occurrenceID] == nil else { throw .duplicateOccurrence(occurrenceID) }
            guard !placement.spans.isEmpty else { throw .emptyPlacement(occurrenceID) }
            let rate = Int128(occurrence.nominalRate.framesPerSecond)
            var seenEpochs: Set<RecordingEpochID> = []
            var compiledSpans: [CompiledSpan] = []
            var lastMappedHull: ExactRational?
            for (index, span) in placement.spans.enumerated() {
                guard span.endFrame > span.startFrame else { throw .nonPositiveSpanLength(occurrenceID) }
                guard span.startFrame >= 0, span.endFrame <= occurrence.frameCount else { throw .spanOutsideSource(occurrenceID) }
                if index > 0 {
                    let previous = placement.spans[index - 1]
                    if span.startFrame < previous.startFrame { throw .spansOutOfOrder(occurrenceID) }
                    if span.startFrame < previous.endFrame { throw .overlappingSpans(occurrenceID) }
                    if span.epoch == previous.epoch { throw .gapMustRestartEpoch(occurrenceID, span.epoch) }
                }
                guard seenEpochs.insert(span.epoch).inserted else { throw .epochReusedWithinOccurrence(occurrenceID, span.epoch) }
                try TimeMapEnvelope.checkTime(span.groupClockOffset, "groupClockOffset")

                if let reason = unsupported[span.epoch] {
                    compiledSpans.append(CompiledSpan(span: span, state: .unsupported(reason)))
                    continue
                }
                guard let epoch = mapped[span.epoch] else { throw .unknownEpoch(span.epoch) }
                if occurrenceID == reference.occurrence, isReferenceGroup, span.epoch == reference.epoch {
                    guard span.groupClockOffset == .zero else { throw .referenceOccurrenceNotAnchored(occurrenceID) }
                    referenceAnchored = true
                }
                let compiledSpan = try compileSpan(span, rate: rate, epoch: epoch, occurrenceID: occurrenceID)
                if case .mapped(_, _, let hullLo, let hullHi) = compiledSpan.state {
                    if let lastMappedHull, hullLo <= lastMappedHull { throw .nonMonotonicPlacement(occurrenceID) }
                    lastMappedHull = hullHi
                }
                compiledSpans.append(compiledSpan)
            }
            result[occurrenceID] = CompiledOccurrence(frameCount: occurrence.frameCount, spans: compiledSpans)
        }
        if isReferenceGroup, !referenceAnchored { throw .referenceOccurrenceNotAnchored(reference.occurrence) }
        return result
    }

    private static func compileSpan(_ span: EpochSpan, rate: Int128, epoch: MappedEpoch, occurrenceID: SourceOccurrenceID) throws(TimeMapError) -> CompiledSpan {
        let e = span.groupClockOffset
        let f = ExactRational(canonicalNumerator: rate, denominator: 1)
        let firstFrame = Int128(span.startFrame)
        let lastFrame = Int128(span.endFrame) - 1
        let uFirst = try ExactRational(numerator: firstFrame, denominator: rate).adding(e)
        let uLast = try ExactRational(numerator: lastFrame, denominator: rate).adding(e)
        guard let first = epoch.segments.first, let last = epoch.segments.last,
              uFirst >= first.groupClockStart, uLast < last.groupClockEnd
        else { throw .placementNotCoveredByEpochMap(occurrenceID, span.epoch) }

        var pieces: [CompiledPiece] = []
        for segment in epoch.segments where segment.groupClockStart <= uLast && segment.groupClockEnd > uFirst {
            let a = segment.rateRatio
            // Frames n with u(n) in [u0, u1): n in [F(u0 - e), F(u1 - e)).
            let segmentFirstFrame = try segment.groupClockStart.subtracting(e).multiplied(by: f).ceil()
            let segmentEndFrame = try segment.groupClockEnd.subtracting(e).multiplied(by: f).ceil()
            let lo = max(firstFrame, segmentFirstFrame)
            let hi = min(lastFrame, segmentEndFrame - 1)
            // t = (a/F) n + (a e + b)
            let slope = try a.divided(by: f)
            let intercept = try a.multiplied(by: e).adding(segment.alignedOffset)
            let g = Int128(ExactRational.gcd(slope.denominator.magnitude, intercept.denominator.magnitude))
            let d = try ExactRational.mul(slope.denominator / g, intercept.denominator)
            let piece = CompiledPiece(
                frameLo: lo,
                frameHi: hi,
                imageLo: try segment.aligned(segment.groupClockStart),
                imageHi: try segment.aligned(segment.groupClockEnd),
                p: try ExactRational.mul(slope.numerator, d / slope.denominator),
                c: try ExactRational.mul(intercept.numerator, d / intercept.denominator),
                d: d
            )
            // p*n + c is linear in n, so proving both ends fit proves every frame of the piece fits.
            if lo <= hi {
                _ = try piece.forward(lo)
                _ = try piece.forward(hi)
            }
            pieces.append(piece)
        }
        func forward(_ n: Int128) throws(TimeMapError) -> ExactRational {
            guard let piece = pieces.first(where: { n >= $0.frameLo && n <= $0.frameHi }) else { throw .placementNotCoveredByEpochMap(occurrenceID, span.epoch) }
            return try piece.forward(n)
        }
        let hullLo = try forward(firstFrame)
        let hullHi = try forward(lastFrame)
        // Inverting the hull ends must also be representable (round trips of placed frames never fail).
        for piece in pieces {
            for t in [hullLo, hullHi] where t >= piece.imageLo && t < piece.imageHi { _ = try piece.inverse(t) }
        }
        return CompiledSpan(span: span, state: .mapped(epoch.provenance.kind, pieces, hullLo: hullLo, hullHi: hullHi))
    }
}

// MARK: - Codable

extension EpochClockMap: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case epoch, state, segments, provenance, unsupportedReason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "EpochClockMap")
        let epoch = try c.decode(RecordingEpochID.self, forKey: .epoch)
        let state = try c.decode(String.self, forKey: .state)
        switch state {
        case "mapped":
            guard !c.contains(.unsupportedReason) else { throw TimeMapDecodingError.unknownKeys(type: "EpochClockMap.mapped", keys: ["unsupportedReason"]) }
            self.init(epoch: epoch, mapping: .mapped(
                segments: try c.decode([AffineClockSegment].self, forKey: .segments),
                provenance: try c.decode(MapProvenance.self, forKey: .provenance)
            ))
        case "unsupported":
            let extra = [CodingKeys.segments, .provenance].filter { c.contains($0) }.map(\.stringValue)
            guard extra.isEmpty else { throw TimeMapDecodingError.unknownKeys(type: "EpochClockMap.unsupported", keys: extra) }
            self.init(epoch: epoch, mapping: .unsupported(try c.decode(UnsupportedReason.self, forKey: .unsupportedReason)))
        default:
            throw TimeMapDecodingError.unknownKind(type: "EpochClockMap", kind: state)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(epoch, forKey: .epoch)
        switch mapping {
        case .mapped(let segments, let provenance):
            try c.encode("mapped", forKey: .state)
            try c.encode(segments, forKey: .segments)
            try c.encode(provenance, forKey: .provenance)
        case .unsupported(let reason):
            try c.encode("unsupported", forKey: .state)
            try c.encode(reason, forKey: .unsupportedReason)
        }
    }
}

extension EpochSpan: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case startFrame, endFrame, epoch, groupClockOffset }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "EpochSpan")
        self.init(
            startFrame: try c.decode(Int64.self, forKey: .startFrame),
            endFrame: try c.decode(Int64.self, forKey: .endFrame),
            epoch: try c.decode(RecordingEpochID.self, forKey: .epoch),
            groupClockOffset: try c.decode(ExactRational.self, forKey: .groupClockOffset)
        )
    }
}

extension OccurrencePlacement: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case occurrence, spans }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "OccurrencePlacement")
        self.init(occurrence: try c.decode(SourceOccurrence.self, forKey: .occurrence), spans: try c.decode([EpochSpan].self, forKey: .spans))
    }
}

extension GroupTimeMap: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case timeMapSchemaVersion, group, reference, epochs, placements }

    /// Strict: refuses unknown-newer versions first, then unknown keys, then re-validates the whole map
    /// through the throwing initializer (an invalid map can never be decoded).
    public init(from decoder: any Decoder) throws {
        try decoder.checkTimeMapSchemaVersion()
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self, typeName: "GroupTimeMap")
        try self.init(
            group: c.decode(RecorderGroupID.self, forKey: .group),
            reference: c.decode(TimelineReference.self, forKey: .reference),
            epochs: c.decode([EpochClockMap].self, forKey: .epochs),
            placements: c.decode([OccurrencePlacement].self, forKey: .placements)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(TimeMapSchema.currentVersion, forKey: .timeMapSchemaVersion)
        try c.encode(group, forKey: .group)
        try c.encode(reference, forKey: .reference)
        try c.encode(epochs, forKey: .epochs)
        try c.encode(placements, forKey: .placements)
    }
}
