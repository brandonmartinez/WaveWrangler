import Foundation
import WWCore
import WWTimeMap

/// A word's logical lane and decoded source occurrence, never a filename or bookmark.
public struct SpeechWordOrigin: Sendable, Equatable, Codable {
    public let episodeID: EpisodeID
    public let speakerID: SpeakerID
    public let channel: ChannelReference
    public let occurrence: SourceOccurrence
    public let recorderGroupID: RecorderGroupID
    public let epochID: RecordingEpochID

    public init(episodeID: EpisodeID, speakerID: SpeakerID, channel: ChannelReference,
                occurrence: SourceOccurrence, recorderGroupID: RecorderGroupID, epochID: RecordingEpochID) {
        self.episodeID = episodeID
        self.speakerID = speakerID
        self.channel = channel
        self.occurrence = occurrence
        self.recorderGroupID = recorderGroupID
        self.epochID = epochID
    }
}

/// Upstream identity, supplied by the owner of the current canonical selection and derived assets.
/// Any changed component invalidates the entire batch; strings are opaque revisions, not paths.
public struct SpeechWordVersions: Sendable, Equatable, Codable {
    public let selection: String
    public let source: String
    public let format: String
    public let alignment: Int?
    public let transcript: String
    public let derivedAsset: String
    public let modelID: String
    public let modelRevision: String
    public let decoderRevision: String
    public let locale: String
    public let assetID: String
    public let assetRevision: String

    public init(selection: String, source: String, format: String, alignment: Int?,
                transcript: String, derivedAsset: String, modelID: String, modelRevision: String,
                decoderRevision: String, locale: String, assetID: String, assetRevision: String) {
        self.selection = selection
        self.source = source
        self.format = format
        self.alignment = alignment
        self.transcript = transcript
        self.derivedAsset = derivedAsset
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.decoderRevision = decoderRevision
        self.locale = locale
        self.assetID = assetID
        self.assetRevision = assetRevision
    }

    fileprivate var hasCompleteIdentity: Bool {
        [selection, source, format, transcript, derivedAsset, modelID, modelRevision,
         decoderRevision, locale, assetID, assetRevision]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (alignment.map { $0 > 0 } ?? true)
    }
}

/// A current, independently obtained canonical/source snapshot, not an assertion by the recognizer.
/// The caller must supply the *current* selected occurrence and revision tokens from trusted owners.
public struct SpeechWordContext: Sendable {
    public let origin: SpeechWordOrigin
    public let versions: SpeechWordVersions

    public init(origin: SpeechWordOrigin, versions: SpeechWordVersions) {
        self.origin = origin
        self.versions = versions
    }
}

/// Paired, half-open decoded SOURCE frames. Nil means no word-level timing was supplied.
/// Range checks alone do not prove independent timing support or an accepted timeline mapping.
public struct SourceWordBoundaries: Sendable, Equatable, Codable {
    public let startFrame: Int64
    public let endFrame: Int64

    public init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// Per-word proof required before a future bridge may label either boundary supported.
/// No current inference path verifies the independent word evidence or proxy/map chain,
/// so this type intentionally has no public issuer.
public struct SupportedWordBoundaryProvenance: Sendable, Equatable {
    public let wordID: String
    public let origin: SpeechWordOrigin
    public let versions: SpeechWordVersions
    public let sourceFrames: SourceWordBoundaries
    public let proxyChunkID: String
    public let proxyFramesPerSecond: Int64
    public let proxyToSourceRevision: String
    public let acceptedAlignmentRevision: Int
    public let independentBoundaryEvidenceID: String

    private init(wordID: String, origin: SpeechWordOrigin, versions: SpeechWordVersions,
                 sourceFrames: SourceWordBoundaries, proxyChunkID: String,
                 proxyFramesPerSecond: Int64, proxyToSourceRevision: String,
                 acceptedAlignmentRevision: Int, independentBoundaryEvidenceID: String) {
        self.wordID = wordID
        self.origin = origin
        self.versions = versions
        self.sourceFrames = sourceFrames
        self.proxyChunkID = proxyChunkID
        self.proxyFramesPerSecond = proxyFramesPerSecond
        self.proxyToSourceRevision = proxyToSourceRevision
        self.acceptedAlignmentRevision = acceptedAlignmentRevision
        self.independentBoundaryEvidenceID = independentBoundaryEvidenceID
    }
}

/// A raw segment timestamp is never proof of the words inside that segment.
public enum WordBoundaryProvenance: Sendable, Equatable {
    case unavailable
    case unsupported
    case supported(SupportedWordBoundaryProvenance)
}

/// Only an actually supplied engine value, in its reported units (not assumed to be a probability).
public struct WordRecognitionConfidence: Sendable, Equatable, Codable {
    public let value: Double
    public let units: String

    public init(value: Double, units: String) {
        self.value = value
        self.units = units
    }
}

public struct SpeechWordEvidence: Sendable, Equatable, Codable {
    public let id: String
    public let text: String
    public let origin: SpeechWordOrigin
    public let boundaries: SourceWordBoundaries?
    public let confidence: WordRecognitionConfidence?

    public init(id: String, text: String, origin: SpeechWordOrigin,
                boundaries: SourceWordBoundaries? = nil, confidence: WordRecognitionConfidence? = nil) {
        self.id = id
        self.text = text
        self.origin = origin
        self.boundaries = boundaries
        self.confidence = confidence
    }
}

public enum SpeechWordEvidenceError: Error, Sendable, Equatable {
    case unsupportedVersion
    case invalidIdentity
    case mismatchedOrigin
    case unselectedPrimary
    case staleUpstream
    case duplicateIdentifier
    case invalidWord
    case invalidBoundary
    case invalidOrder
    case invalidConfidence
}

/// An inert observation batch. Validation is required before any future proposal/scoring bridge;
/// validating does not infer speech, make a cut, or mark source-frame times as timing-supported.
public struct SpeechWordEvidenceBatch: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public let version: Int
    public let origin: SpeechWordOrigin
    public let versions: SpeechWordVersions
    public let words: [SpeechWordEvidence]

    public init(version: Int = currentVersion, origin: SpeechWordOrigin,
                versions: SpeechWordVersions, words: [SpeechWordEvidence]) {
        self.version = version
        self.origin = origin
        self.versions = versions
        self.words = words
    }

    public func validated(against current: SpeechWordContext,
                          model: ShowDocumentModel) throws(SpeechWordEvidenceError) -> ValidatedSpeechWordEvidence {
        guard version == Self.currentVersion else { throw .unsupportedVersion }
        guard versions.hasCompleteIdentity, current.versions.hasCompleteIdentity,
              origin.channel.sourceID == origin.occurrence.source,
              origin.channel.channel.value != nil else { throw .invalidIdentity }
        guard origin == current.origin else { throw .mismatchedOrigin }
        do {
            try SpeechInference().requireSelectedPrimary(
                model: model, episodeID: origin.episodeID,
                speakerID: origin.speakerID, channel: origin.channel)
        } catch {
            throw .unselectedPrimary
        }
        guard let episode = model.episode(origin.episodeID),
              let source = episode.source(origin.occurrence.source),
              source.placement.recorderGroupID == origin.recorderGroupID,
              source.placement.epochID == origin.epochID,
              episode.recorderGroups.filter({ $0.id == origin.recorderGroupID }).count == 1,
              episode.recorderGroup(origin.recorderGroupID)?.epochs.filter({ $0.id == origin.epochID }).count == 1
        else { throw .mismatchedOrigin }
        if let alignment = versions.alignment {
            guard episode.alignment?.map(revision: alignment) != nil else { throw .staleUpstream }
        }
        guard versions.alignment == episode.alignment?.acceptedRevision,
              current.versions.alignment == episode.alignment?.acceptedRevision,
              versions == current.versions else { throw .staleUpstream }

        var ids = Set<String>()
        var previousEnd: Int64?
        for word in words {
            guard word.origin == origin else { throw .mismatchedOrigin }
            guard !word.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw .invalidWord }
            guard ids.insert(word.id).inserted else { throw .duplicateIdentifier }
            if let bounds = word.boundaries {
                guard bounds.startFrame >= 0, bounds.endFrame > bounds.startFrame,
                      bounds.endFrame <= origin.occurrence.frameCount else { throw .invalidBoundary }
                if let previousEnd, bounds.startFrame < previousEnd { throw .invalidOrder }
                previousEnd = bounds.endFrame
            }
            if let confidence = word.confidence {
                guard confidence.value.isFinite,
                      !confidence.units.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw .invalidConfidence }
            }
        }
        return ValidatedSpeechWordEvidence(version: version, origin: origin, versions: versions, words: words)
    }
}

/// Only produced after the full batch passes; still NOT an authorized edit or timing-support proof.
public struct ValidatedSpeechWordEvidence: Sendable {
    public let version: Int
    public let origin: SpeechWordOrigin
    public let versions: SpeechWordVersions
    public let words: [SpeechWordEvidence]

    /// Validation of source-frame ranges alone never upgrades raw or missing times to supported.
    public var boundaryProvenance: [WordBoundaryProvenance] {
        words.map { word in
            guard word.boundaries != nil else { return .unavailable }
            return .unsupported
        }
    }

    fileprivate init(version: Int, origin: SpeechWordOrigin, versions: SpeechWordVersions,
                     words: [SpeechWordEvidence]) {
        self.version = version
        self.origin = origin
        self.versions = versions
        self.words = words
    }
}
