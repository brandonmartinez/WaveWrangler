import Foundation

/// Shared aligned-time boundaries. Omitted ends include the available recording; originals are never trimmed.
/// The revision prevents old markers being silently interpreted under different accepted timing.
public struct EpisodeWorkingRange: Sendable, Equatable, Codable {
    public var alignmentRevision: Int
    public var tracksIn: Double?
    public var tracksOut: Double?

    public init(alignmentRevision: Int, tracksIn: Double? = nil, tracksOut: Double? = nil) {
        self.alignmentRevision = alignmentRevision
        self.tracksIn = tracksIn
        self.tracksOut = tracksOut
    }

    public var isValid: Bool {
        alignmentRevision > 0
            && [tracksIn, tracksOut].compactMap { $0 }.allSatisfy { $0.isFinite && abs($0) <= 86_400 }
            && (tracksIn == nil || tracksOut == nil || tracksIn! < tracksOut!)
    }
}

/// Engine-produced approximate timing, not supported cut boundaries or an assertion that a word is correct.
public struct TranscriptWord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var text: String
    public var sourceStartFrame: Int64?
    public var sourceEndFrame: Int64?
    public var alignedStart: Double?
    public var alignedEnd: Double?

    public init(id: UUID = UUID(), text: String, sourceStartFrame: Int64? = nil,
                sourceEndFrame: Int64? = nil, alignedStart: Double? = nil, alignedEnd: Double? = nil) {
        self.id = id
        self.text = text
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.alignedStart = alignedStart
        self.alignedEnd = alignedEnd
    }

    public var isValid: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 4096 else { return false }
        switch (sourceStartFrame, sourceEndFrame, alignedStart, alignedEnd) {
        case (nil, nil, nil, nil): return true
        case let (start?, end?, a?, b?):
            return start >= 0 && end > start && end <= 192_000 * 86_400
                && a.isFinite && b.isFinite && abs(a) <= 86_400 && abs(b) <= 86_400 && b > a
        default: return false
        }
    }
}

public struct SpeakerTranscript: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var speaker: SpeakerID
    public var primary: ChannelReference
    public var sourceRate: Int
    public var sourceIdentity: String
    public var alignmentRevision: Int
    public var model: String
    public var workingRange: EpisodeWorkingRange?
    public var words: [TranscriptWord]

    public init(id: UUID = UUID(), speaker: SpeakerID, primary: ChannelReference, sourceRate: Int,
                sourceIdentity: String, alignmentRevision: Int, model: String,
                workingRange: EpisodeWorkingRange?, words: [TranscriptWord]) {
        self.id = id
        self.speaker = speaker
        self.primary = primary
        self.sourceRate = sourceRate
        self.sourceIdentity = sourceIdentity
        self.alignmentRevision = alignmentRevision
        self.model = model
        self.workingRange = workingRange
        self.words = words
    }

    public var isValid: Bool {
        (8000...192000).contains(sourceRate) && alignmentRevision > 0
            && primary.channel.value.map { $0 >= 0 } == true
            && sourceIdentity.count == 64 && sourceIdentity.allSatisfy(\.isHexDigit)
            && !model.isEmpty && model.utf8.count <= 256 && workingRange?.isValid != false
            && workingRange.map { $0.alignmentRevision == alignmentRevision } != false
            && words.count <= 100_000 && words.allSatisfy(\.isValid)
            && Set(words.map(\.id)).count == words.count
    }
}

public struct EpisodeCleanup: Sendable, Equatable, Codable {
    public var workingRange: EpisodeWorkingRange?
    public var transcripts: [SpeakerTranscript]
    public var fillerReviews: [FillerTimingReview]?

    public init(workingRange: EpisodeWorkingRange? = nil, transcripts: [SpeakerTranscript] = [],
                fillerReviews: [FillerTimingReview]? = nil) {
        self.workingRange = workingRange
        self.transcripts = transcripts
        self.fillerReviews = fillerReviews
    }

    public var isValid: Bool {
        workingRange?.isValid != false && transcripts.count <= 64
            && transcripts.allSatisfy(\.isValid)
            && Set(transcripts.map(\.speaker)).count == transcripts.count
            && Set(transcripts.map(\.id)).count == transcripts.count
            && (fillerReviews?.count ?? 0) <= 100_000
            && fillerReviews?.allSatisfy(\.isValid) != false
            && Set((fillerReviews ?? []).map(\.id)).count == (fillerReviews?.count ?? 0)
    }

    /// Existing decisions, including rejections and stale history, are never overwritten by another scan.
    public func proposingFillers() -> Self {
        var result = self
        var reviews = fillerReviews ?? []
        let existing = Set(reviews.compactMap { review -> String? in
            guard let transcript = review.transcriptID, let word = review.word?.id else { return nil }
            return "\(transcript)/\(word)"
        })
        for transcript in transcripts {
            reviews += FillerTimingReview.detections(in: transcript).filter {
                guard let word = $0.word else { return false }
                return !existing.contains("\(transcript.id)/\(word.id)")
            }
        }
        if !reviews.isEmpty { result.fillerReviews = reviews }
        return result
    }
}

extension ShowDocumentModel {
    public func settingCleanup(_ cleanup: EpisodeCleanup?, in episodeID: EpisodeID) throws(DomainError) -> Self {
        guard cleanup?.isValid != false else { throw .invalidCleanup }
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { throw .episodeNotFound(episodeID) }
        var result = self
        result.episodes[index].cleanup = cleanup
        return result
    }
}
