import Foundation

/// Audible-word timing for human review, never an editorial cut interval.
public struct FillerTimingBounds: Sendable, Equatable, Codable {
    public let sourceStartFrame: Int64
    public let sourceEndFrame: Int64
    public let alignedStart: Double
    public let alignedEnd: Double

    public init(sourceStartFrame: Int64, sourceEndFrame: Int64, alignedStart: Double, alignedEnd: Double) {
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.alignedStart = alignedStart
        self.alignedEnd = alignedEnd
    }

    public init?(word: TranscriptWord) {
        guard word.isValid, let a = word.sourceStartFrame, let b = word.sourceEndFrame,
              let start = word.alignedStart, let end = word.alignedEnd else { return nil }
        self.init(sourceStartFrame: a, sourceEndFrame: b, alignedStart: start, alignedEnd: end)
    }

    public var isValid: Bool {
        sourceStartFrame >= 0 && sourceEndFrame > sourceStartFrame && sourceEndFrame <= 192_000 * 86_400
            && alignedStart.isFinite && alignedEnd.isFinite
            && abs(alignedStart) <= 86_400 && abs(alignedEnd) <= 86_400 && alignedEnd > alignedStart
    }
}

public enum FillerReviewOrigin: String, Sendable, Codable { case detected, manual }
public enum FillerReviewDecision: String, Sendable, Codable { case pending, reviewed, rejected }

/// Captured origins remain immutable even after the live transcript, source or accepted map is replaced.
/// Human judgments are reference data, not phonetic ground truth or cut authorization.
public struct FillerTimingReview: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let origin: FillerReviewOrigin
    public let speaker: SpeakerID
    public let primary: ChannelReference
    public let sourceRate: Int
    public let sourceIdentity: String
    public let alignmentRevision: Int
    public let transcriptID: UUID?
    public let word: TranscriptWord?
    public let modelRecipe: String?
    public let analyzedRange: EpisodeWorkingRange?
    public let detectorRecipe: String?
    public let initialBounds: FillerTimingBounds
    public let detectedBounds: FillerTimingBounds?
    public var humanBounds: FillerTimingBounds?
    public var decision: FillerReviewDecision

    public init(id: UUID = UUID(), origin: FillerReviewOrigin, speaker: SpeakerID,
                primary: ChannelReference, sourceRate: Int, sourceIdentity: String, alignmentRevision: Int,
                transcriptID: UUID? = nil, word: TranscriptWord? = nil, modelRecipe: String? = nil,
                analyzedRange: EpisodeWorkingRange? = nil, detectorRecipe: String? = nil,
                initialBounds: FillerTimingBounds, detectedBounds: FillerTimingBounds? = nil,
                humanBounds: FillerTimingBounds? = nil, decision: FillerReviewDecision = .pending) {
        self.id = id
        self.origin = origin
        self.speaker = speaker
        self.primary = primary
        self.sourceRate = sourceRate
        self.sourceIdentity = sourceIdentity
        self.alignmentRevision = alignmentRevision
        self.transcriptID = transcriptID
        self.word = word
        self.modelRecipe = modelRecipe
        self.analyzedRange = analyzedRange
        self.detectorRecipe = detectorRecipe
        self.initialBounds = initialBounds
        self.detectedBounds = detectedBounds
        self.humanBounds = humanBounds
        self.decision = decision
    }

    public var bounds: FillerTimingBounds { humanBounds ?? initialBounds }
    public var isAdjusted: Bool { humanBounds.map { $0 != initialBounds } ?? false }
    public var status: String {
        if decision == .rejected { return "Not a filler" }
        if decision == .pending { return origin == .manual ? "Manual · pending" : "Pending" }
        if origin == .manual { return "Manual · reviewed" }
        return isAdjusted ? "Adjusted" : "Reviewed unchanged"
    }

    public var isValid: Bool {
        guard (8000...192000).contains(sourceRate), alignmentRevision > 0,
              primary.channel.value.map({ $0 >= 0 }) == true,
              sourceIdentity.count == 64, sourceIdentity.allSatisfy(\.isHexDigit),
              initialBounds.isValid, humanBounds?.isValid != false,
              word?.isValid != false, analyzedRange?.isValid != false,
              analyzedRange.map({ $0.alignmentRevision == alignmentRevision }) != false,
              modelRecipe.map({ !$0.isEmpty && $0.utf8.count <= 256 }) != false,
              (transcriptID == nil) == (modelRecipe == nil),
              word == nil || transcriptID != nil else { return false }
        switch origin {
        case .detected:
            return transcriptID != nil && Self.isHesitation(word?.text ?? "")
                && word.flatMap(FillerTimingBounds.init(word:)) == detectedBounds
                && detectedBounds == initialBounds && detectorRecipe == Self.detectorVersion
        case .manual:
            return detectedBounds == nil && detectorRecipe == nil
        }
    }

    public mutating func revertToDetected() {
        guard let detectedBounds else { return }
        humanBounds = nil
        decision = .pending
        assert(bounds == detectedBounds)
    }

    public static let detectorVersion = "exact-hesitations/1:um,uh,erm,er"

    public static func isHesitation(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        return ["um", "uh", "erm", "er"].contains(token)
    }

    public static func detections(in transcript: SpeakerTranscript) -> [Self] {
        guard transcript.isValid else { return [] }
        return transcript.words.compactMap { word in
            guard isHesitation(word.text), let bounds = FillerTimingBounds(word: word) else { return nil }
            return Self(origin: .detected, speaker: transcript.speaker, primary: transcript.primary,
                sourceRate: transcript.sourceRate, sourceIdentity: transcript.sourceIdentity,
                alignmentRevision: transcript.alignmentRevision, transcriptID: transcript.id, word: word,
                modelRecipe: transcript.model, analyzedRange: transcript.workingRange,
                detectorRecipe: detectorVersion, initialBounds: bounds, detectedBounds: bounds)
        }
    }

    /// Does not rebind by text or proximity when a transcript is replaced.
    public func matches(_ transcript: SpeakerTranscript) -> Bool {
        matchesOrigin(of: transcript) && word.map { captured in transcript.words.contains(captured) } != false
    }

    public func matchesOrigin(of transcript: SpeakerTranscript) -> Bool {
        transcriptID == transcript.id && speaker == transcript.speaker && primary == transcript.primary
            && sourceRate == transcript.sourceRate && sourceIdentity == transcript.sourceIdentity
            && alignmentRevision == transcript.alignmentRevision && modelRecipe == transcript.model
            && analyzedRange == transcript.workingRange
    }
}
