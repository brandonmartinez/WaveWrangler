import Foundation
import WWAlignEstimate
import WWAutoAlign
import WWCore
import WWDecode
import WWDerived
import WWRender
import WWSources
import WWTimeMap

/// Asset kinds, revisions and version identities this module stores through `DerivedJobCoordinator`.
public enum AlignmentAssetKinds {
    /// Header-only facts of a source (rate, exact frame count, channels). Opening a source's format is
    /// content access, so probes are consent-gated like any decode.
    public static let sourceFacts = AssetSpec(kind: "ww.source-facts", revision: 1)
    /// One epoch's analysis: a proposal or an abstention, with its full evidence (`EpochAnalysisRecord`).
    public static let analysis = AssetSpec(kind: "ww.alignment-analysis", revision: 4)
    public static let fingerprint = AssetSpec(kind: "ww.alignment-fingerprint", revision: 1)
    /// One output channel of one aligned segment (`AlignedAudioSegment`). The revision is WWRender's output
    /// asset format version, so a format bump stales every aligned asset.
    public static let alignedAudio = AssetSpec(kind: "ww.aligned-audio-segment", revision: RenderVersions.outputAssetFormat)
    public static let adaptiveAlignedAudio = AssetSpec(kind: "ww.adaptive-aligned-audio-segment", revision: PitchPreservingAudio.renderRecipeVersion)

    public static let estimatorIdentifier = AcousticEstimator.identifier
    public static let rendererVersion = RenderVersions.renderer
    public static let renderRecipeVersion = RenderRecipe.currentVersion
    /// The content identity of the active accepted map revision of an episode (its canonical version
    /// encoding, verified against the document). Every aligned segment is keyed on it as an upstream.
    public static let acceptedMapIdentity = AssetSpec(kind: "ww.accepted-map-identity", revision: 1)

    /// Prefix of the recipe recorded on every map revision this module creates; the rest of the name is the
    /// digest of the revisions and placements the map was accepted against (`MapDependencies`).
    public static let acceptanceRecipePrefix = "ww.alignment-acceptance;deps="
    public static let acceptanceRecipeRevision = 2

    static let all = [sourceFacts, analysis, fingerprint, alignedAudio, adaptiveAlignedAudio, acceptedMapIdentity]
}

/// A source as the caller (the app) currently knows it: where it is and its Setup availability. The
/// pipeline reads content only for sources that are ON and carry an explicit `ContentWorkAuthorization`.
public struct AlignmentSource: Sendable, Equatable {
    public let id: SourceID
    public let url: URL
    public let availability: SourceAvailabilitySetting
    public let recordedFingerprint: FileSystemFingerprint?

    public init(
        id: SourceID, url: URL, availability: SourceAvailabilitySetting,
        recordedFingerprint: FileSystemFingerprint? = nil
    ) {
        self.id = id
        self.url = url
        self.availability = availability
        self.recordedFingerprint = recordedFingerprint
    }
}

/// The occurrence identity the pipeline uses for a source (one occurrence per source, deterministic so map
/// revisions, analysis records and aligned assets agree across runs).
public func alignmentOccurrenceID(for source: SourceID) -> SourceOccurrenceID {
    SourceOccurrenceID(source.rawValue)
}

// MARK: - Source facts

/// What a header-only probe established about a source (no sample was read): the decoder's whole format
/// interpretation (the output-settings policy decides from it) and the revision it was verified against.
public struct SourceFacts: Sendable, Codable, Equatable {
    public var interpretation: FormatInterpretation
    /// The metadata revision token the probe verified against (the coordinator's current token).
    public var revisionToken: String

    public init(interpretation: FormatInterpretation, revisionToken: String) {
        self.interpretation = interpretation
        self.revisionToken = revisionToken
    }

    public var source: SourceID { interpretation.source }
    public var sampleRate: Int { interpretation.sourceSampleRate }
    public var frameCount: Int64 { interpretation.frames.validFrames }
    public var channelCount: Int { interpretation.channelCount }
    public var formatInterpretationVersion: Int { interpretation.formatInterpretationVersion }
    public var envelopeVersion: Int { interpretation.envelopeVersion }
}

// MARK: - Analysis records (persisted payload of an analysis job)

/// One side of an analyzed pair.
public struct AnalysisParticipant: Sendable, Codable, Equatable {
    public var group: RecorderGroupID
    public var epoch: RecordingEpochID
    public var source: SourceID
    public var occurrence: SourceOccurrenceID
    public var revisionToken: String
    public var sourceRate: Int
    public var sourceFrames: Int64
    public var channelCount: Int
    /// Source frames analyzed (half-open).
    public var excerptStartFrame: Int64
    public var excerptEndFrame: Int64
    /// Decimated analysis rate (an exact divisor of `sourceRate`).
    public var analysisRate: Int
}

public struct WindowRecord: Sendable, Codable, Equatable {
    public var index: Int
    public var groupClockCenter: Double
    /// A v1 `WindowStatus` raw value, or a separately versioned automatic observation status.
    public var status: String
    public var peakScore: Double
    public var secondPeakScore: Double
    public var periodicityScore: Double
    public var offsetSeconds: Double?
    public var method: String? = nil
    public var phatOffsetSeconds: Double? = nil
    public var phatPeakRatio: Double? = nil
    public var polarity: Int? = nil
    public var corroborations: [TemporalCorroboration]? = nil
    public var spectralWitness: SpectralTimingWitness? = nil
}

public struct CoverageRecord: Sendable, Codable, Equatable {
    public var declaredStart: Double
    public var declaredEnd: Double
    public var windowCount: Int
    public var eligibleCount: Int
    public var eligibleWindowFraction: Double
    public var eligibleSpanFraction: Double
}

/// An acoustic-consistent proposal exactly as the estimator returned it. It is evidence for a person to
/// review, never clock approval. It deliberately has no `MapProvenance` field, so a record cannot express
/// (or smuggle) any approved provenance.
public struct ProposalRecord: Sendable, Codable, Equatable {
    public var segment: AffineClockSegment
    public var ppm: Double
    public var offsetAtCenterSeconds: Double
    public var acousticResidualP95Milliseconds: Double
    public var acousticResidualMaxMilliseconds: Double
    public var provenance: AcousticConsistencyProposal

    public init(
        segment: AffineClockSegment,
        ppm: Double,
        offsetAtCenterSeconds: Double,
        acousticResidualP95Milliseconds: Double,
        acousticResidualMaxMilliseconds: Double,
        provenance: AcousticConsistencyProposal
    ) {
        self.segment = segment
        self.ppm = ppm
        self.offsetAtCenterSeconds = offsetAtCenterSeconds
        self.acousticResidualP95Milliseconds = acousticResidualP95Milliseconds
        self.acousticResidualMaxMilliseconds = acousticResidualMaxMilliseconds
        self.provenance = provenance
    }
}

public struct AbstentionRecord: Sendable, Codable, Equatable {
    /// `AbstentionReason` raw value.
    public var reason: String
    public var detail: String

    public var abstentionReason: AbstentionReason? { AbstentionReason(rawValue: reason) }
}

/// The full, versioned result of analyzing one epoch against the timeline reference.
public struct EpochAnalysisRecord: Sendable, Codable, Equatable {
    public static let currentVersion = 4

    public var recordVersion: Int
    public var estimator: String
    public var recipe: String
    public var reference: AnalysisParticipant
    public var target: AnalysisParticipant
    public var searchCenterSeconds: Double
    public var searchDeviationSeconds: Double
    public var proposal: ProposalRecord?
    public var abstention: AbstentionRecord?
    public var windows: [WindowRecord]
    public var coverage: CoverageRecord
    public var medianPeakScore: Double
    public var medianPeakMargin: Double
    /// `EstimateFlag` raw values, sorted.
    public var flags: [String]
    /// Measured triangles through this epoch; zero means cycle evidence was unavailable.
    public var cycleTriangles: Int
    /// Worst measured disagreement, in milliseconds; nil when no triangle was measured.
    public var cycleMaximumMilliseconds: Double?
    /// Present only for the separately versioned automatic path. Every fresh attempt, including rejected
    /// candidates, is retained; `windows` contains at most one independent observation per temporal station.
    public var automaticAttempts: [WindowRecord]? = nil
    public var coarseWindows: [WindowRecord]? = nil
    public var fingerprintSeconds: [Double]? = nil
    public var refinementRatePPM: Double? = nil

    init(
        recipe: String,
        reference: AnalysisParticipant,
        target: AnalysisParticipant,
        search: SearchRange,
        estimate: EpochEstimate
    ) {
        recordVersion = Self.currentVersion
        estimator = AlignmentAssetKinds.estimatorIdentifier
        self.recipe = recipe
        self.reference = reference
        self.target = target
        searchCenterSeconds = search.centerOffsetSeconds
        searchDeviationSeconds = search.maximumDeviationSeconds
        switch estimate.outcome {
        case .acousticConsistentProposal(let p):
            proposal = ProposalRecord(
                segment: p.segment, ppm: p.ppm, offsetAtCenterSeconds: p.offsetAtCenterSeconds,
                acousticResidualP95Milliseconds: p.acousticResidualP95Milliseconds,
                acousticResidualMaxMilliseconds: p.acousticResidualMaxMilliseconds, provenance: p.provenance
            )
            abstention = nil
        case .abstained(let a):
            proposal = nil
            abstention = AbstentionRecord(reason: a.reason.rawValue, detail: a.detail)
        }
        windows = estimate.windows.map {
            WindowRecord(index: $0.index, groupClockCenter: $0.groupClockCenter, status: $0.status.rawValue, peakScore: $0.peakScore,
                         secondPeakScore: $0.secondPeakScore, periodicityScore: $0.periodicityScore, offsetSeconds: $0.offsetSeconds)
        }
        let c = estimate.coverage
        coverage = CoverageRecord(declaredStart: c.declaredStart, declaredEnd: c.declaredEnd, windowCount: c.windowCount, eligibleCount: c.eligibleCount,
                                  eligibleWindowFraction: c.eligibleWindowFraction, eligibleSpanFraction: c.eligibleSpanFraction)
        medianPeakScore = estimate.scores.medianPeakScore
        medianPeakMargin = estimate.scores.medianPeakMargin
        flags = estimate.flags.map(\.rawValue).sorted()
        switch estimate.cycle {
        case .unavailable:
            cycleTriangles = 0
            cycleMaximumMilliseconds = nil
        case let .measured(triangles, maximumMilliseconds):
            cycleTriangles = triangles
            cycleMaximumMilliseconds = maximumMilliseconds
        }
    }

    init(
        recipe: String, reference: AnalysisParticipant, target: AnalysisParticipant,
        search: SearchRange, automatic: AutomaticAlignmentResult, coarse: [DelayEvidence]
    ) {
        self.init(recipe: recipe, reference: reference, target: target, search: search,
                  abstention: .insufficientCoverage, detail: "Automatic matching did not produce a proposal.")
        estimator = AutomaticAlignment.identifier
        if let p = automatic.proposal {
            proposal = ProposalRecord(
                segment: p.segment, ppm: p.ppm, offsetAtCenterSeconds: p.offsetAtCenterSeconds,
                acousticResidualP95Milliseconds: p.acousticResidualP95Milliseconds,
                acousticResidualMaxMilliseconds: p.acousticResidualMaxMilliseconds, provenance: p.provenance
            )
            abstention = nil
        } else if let a = automatic.abstention {
            abstention = AbstentionRecord(reason: a.reason.rawValue, detail: a.detail)
        }
        windows = automatic.windows.map(Self.window)
        automaticAttempts = automatic.attempts.map(Self.window)
        coarseWindows = coarse.map(Self.window)
        let inliers = windows.filter { $0.status == "eligible" }
        coverage = CoverageRecord(
            declaredStart: automatic.startSeconds, declaredEnd: automatic.endSeconds,
            windowCount: automatic.expectedStations, eligibleCount: inliers.count,
            eligibleWindowFraction: Double(inliers.count) / Double(automatic.expectedStations),
            eligibleSpanFraction: automatic.spanFraction
        )
        medianPeakScore = proposal?.provenance.evidenceScore ?? 0
        let margins = inliers.map { 1 - $0.secondPeakScore / max($0.peakScore, 1e-10) }.sorted()
        let mid = margins.count / 2
        medianPeakMargin = margins.isEmpty ? 0 : margins.count.isMultiple(of: 2)
            ? (margins[mid - 1] + margins[mid]) / 2 : margins[mid]
        flags = automatic.flags
    }

    private static func window(_ evidence: DelayEvidence) -> WindowRecord {
        WindowRecord(
            index: evidence.station, groupClockCenter: evidence.targetCenter, status: evidence.status,
            peakScore: evidence.nccScore, secondPeakScore: evidence.nccSecond, periodicityScore: 0,
            offsetSeconds: evidence.offsetSeconds, method: evidence.method,
            phatOffsetSeconds: evidence.phatOffsetSeconds, phatPeakRatio: evidence.phatPeakRatio, polarity: evidence.polarity
        )
    }

    /// A record for an epoch the pipeline could not analyze for a structural reason it decided itself (no
    /// estimator run), e.g. no possible overlap with the reference.
    init(recipe: String, reference: AnalysisParticipant, target: AnalysisParticipant, search: SearchRange, abstention: AbstentionReason, detail: String) {
        recordVersion = Self.currentVersion
        estimator = AlignmentAssetKinds.estimatorIdentifier
        self.recipe = recipe
        self.reference = reference
        self.target = target
        searchCenterSeconds = search.centerOffsetSeconds
        searchDeviationSeconds = search.maximumDeviationSeconds
        proposal = nil
        self.abstention = AbstentionRecord(reason: abstention.rawValue, detail: detail)
        windows = []
        coverage = CoverageRecord(declaredStart: 0, declaredEnd: 0, windowCount: 0, eligibleCount: 0, eligibleWindowFraction: 0, eligibleSpanFraction: 0)
        medianPeakScore = 0
        medianPeakMargin = 0
        flags = []
        cycleTriangles = 0
        cycleMaximumMilliseconds = nil
    }

    static func encode(_ record: EpochAnalysisRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> EpochAnalysisRecord {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        let record = try decoder.decode(EpochAnalysisRecord.self, from: data)
        guard record.recordVersion == currentVersion else { throw AnalysisRecordError.unsupportedVersion(record.recordVersion) }
        return record
    }
}

enum AnalysisRecordError: Error, Equatable {
    case unsupportedVersion(Int)
}

extension SourceFacts {
    static func encode(_ facts: SourceFacts) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(facts)
    }

    static func decode(_ data: Data) throws -> SourceFacts {
        try JSONDecoder().decode(SourceFacts.self, from: data)
    }
}
