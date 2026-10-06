import Foundation
import WWAlignEstimate
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
    public static let analysis = AssetSpec(kind: "ww.alignment-analysis", revision: 1)
    /// One output channel of one aligned segment (`AlignedAudioSegment`). The revision is WWRender's output
    /// asset format version, so a format bump stales every aligned asset.
    public static let alignedAudio = AssetSpec(kind: "ww.aligned-audio-segment", revision: RenderVersions.outputAssetFormat)

    public static let estimatorIdentifier = AcousticEstimator.identifier
    public static let rendererVersion = RenderVersions.renderer
    public static let renderRecipeVersion = RenderRecipe.currentVersion
    /// The recipe recorded on every map revision this module creates.
    public static let acceptanceRecipe = RecipeReference(name: "ww.alignment-acceptance", revision: 1)

    static let all = [sourceFacts, analysis, alignedAudio]
}

/// A source as the caller (the app) currently knows it: where it is and its Setup availability. The
/// pipeline reads content only for sources that are ON and carry an explicit `ContentWorkAuthorization`.
public struct AlignmentSource: Sendable, Equatable {
    public let id: SourceID
    public let url: URL
    public let availability: SourceAvailabilitySetting

    public init(id: SourceID, url: URL, availability: SourceAvailabilitySetting) {
        self.id = id
        self.url = url
        self.availability = availability
    }
}

/// The occurrence identity the pipeline uses for a source (one occurrence per source, deterministic so map
/// revisions, analysis records and aligned assets agree across runs).
public func alignmentOccurrenceID(for source: SourceID) -> SourceOccurrenceID {
    SourceOccurrenceID(source.rawValue)
}

// MARK: - Source facts

/// What a header-only probe established about a source (no sample was read).
public struct SourceFacts: Sendable, Codable, Equatable {
    public var source: SourceID
    public var sampleRate: Int
    public var frameCount: Int64
    public var channelCount: Int
    public var formatInterpretationVersion: Int
    public var envelopeVersion: Int
    /// The metadata revision token the probe verified against (the coordinator's current token).
    public var revisionToken: String

    public init(source: SourceID, sampleRate: Int, frameCount: Int64, channelCount: Int, formatInterpretationVersion: Int, envelopeVersion: Int, revisionToken: String) {
        self.source = source
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.formatInterpretationVersion = formatInterpretationVersion
        self.envelopeVersion = envelopeVersion
        self.revisionToken = revisionToken
    }
}

// MARK: - Analysis records (persisted payload of an analysis job)

/// One side of an analysed pair.
public struct AnalysisParticipant: Sendable, Codable, Equatable {
    public var group: RecorderGroupID
    public var epoch: RecordingEpochID
    public var source: SourceID
    public var occurrence: SourceOccurrenceID
    public var revisionToken: String
    public var sourceRate: Int
    public var sourceFrames: Int64
    public var channelCount: Int
    /// Source frames analysed (half-open).
    public var excerptStartFrame: Int64
    public var excerptEndFrame: Int64
    /// Decimated analysis rate (an exact divisor of `sourceRate`).
    public var analysisRate: Int
}

public struct WindowRecord: Sendable, Codable, Equatable {
    public var index: Int
    public var groupClockCenter: Double
    /// `WindowStatus` raw value.
    public var status: String
    public var peakScore: Double
    public var secondPeakScore: Double
    public var periodicityScore: Double
    public var offsetSeconds: Double?
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
}

public struct AbstentionRecord: Sendable, Codable, Equatable {
    /// `AbstentionReason` raw value.
    public var reason: String
    public var detail: String

    public var abstentionReason: AbstentionReason? { AbstentionReason(rawValue: reason) }
}

/// The full, versioned result of analysing one epoch against the timeline reference.
public struct EpochAnalysisRecord: Sendable, Codable, Equatable {
    public static let currentVersion = 1

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
    }

    /// A record for an epoch the pipeline could not analyse for a structural reason it decided itself (no
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
