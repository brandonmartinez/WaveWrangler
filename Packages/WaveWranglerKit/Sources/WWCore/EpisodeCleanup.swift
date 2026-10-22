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
    public var transcriptHistory: [SpeakerTranscript]?
    public var manualCuts: [ManualEpisodeCut]?

    public init(workingRange: EpisodeWorkingRange? = nil, transcripts: [SpeakerTranscript] = [],
                fillerReviews: [FillerTimingReview]? = nil, transcriptHistory: [SpeakerTranscript]? = nil,
                manualCuts: [ManualEpisodeCut]? = nil) {
        self.workingRange = workingRange
        self.transcripts = transcripts
        self.fillerReviews = fillerReviews
        self.transcriptHistory = transcriptHistory
        self.manualCuts = manualCuts
    }

    public var isValid: Bool {
        workingRange?.isValid != false && transcripts.count <= 64
            && transcripts.allSatisfy(\.isValid)
            && Set(transcripts.map(\.speaker)).count == transcripts.count
            && Set(transcripts.map(\.id)).count == transcripts.count
            && transcriptHistory?.allSatisfy(\.isValid) != false
            && Set((transcriptHistory ?? []).map(\.id) + transcripts.map(\.id)).count
                == (transcriptHistory?.count ?? 0) + transcripts.count
            && (fillerReviews?.count ?? 0) <= 100_000
            && fillerReviews?.allSatisfy(\.isValid) != false
            && Set((fillerReviews ?? []).map(\.id)).count == (fillerReviews?.count ?? 0)
            && (manualCuts?.count ?? 0) <= 100_000
            && manualCuts?.allSatisfy(\.isValid) != false
            && Set((manualCuts ?? []).map(\.id)).count == (manualCuts?.count ?? 0)
    }

    public func replacingTranscripts(_ replacement: [SpeakerTranscript]) throws(DomainError) -> Self {
        var result = self
        var history = transcriptHistory ?? []
        for prior in transcripts where !replacement.contains(prior) {
            guard !replacement.contains(where: { $0.id == prior.id }) else { throw .invalidCleanup }
            history.append(prior)
        }
        result.transcriptHistory = history.isEmpty ? nil : history
        result.transcripts = replacement
        if replacement != transcripts {
            result.fillerReviews = fillerReviews?.filter(\.retainsUserJudgment)
        }
        guard result.isValid else { throw .invalidCleanup }
        result = result.proposingFillers()
        guard result.isValid else { throw .invalidCleanup }
        return result
    }

    /// Old reviews and cuts remain recoverable but cannot activate against the new alignment revision.
    public func resettingForReplacementAlignment() throws(DomainError) -> Self {
        var result = self
        let history = (transcriptHistory ?? []) + transcripts
        result.transcriptHistory = history.isEmpty ? nil : history
        result.transcripts = []
        result.workingRange = nil
        guard result.isValid else { throw .invalidCleanup }
        return result
    }

    public func capturedTranscript(for review: FillerTimingReview) -> SpeakerTranscript? {
        let candidates = transcripts + (review.retainsUserJudgment ? transcriptHistory ?? [] : [])
        return candidates.first { review.matches($0) }
    }

    /// Existing decisions, including rejections and stale history, are never overwritten by another scan.
    public func proposingFillers() -> Self {
        var result = self
        var reviews = fillerReviews ?? []
        let validatedEvents = ValidatedFillerEvents(reviews)
        let existing = Set(reviews.compactMap { review -> String? in
            guard let transcript = review.transcriptID, let word = review.word?.id else { return nil }
            return "\(transcript)/\(word)"
        })
        for transcript in transcripts {
            reviews += FillerTimingReview.detections(in: transcript).filter { detection in
                guard let word = detection.word else { return false }
                return !existing.contains("\(transcript.id)/\(word.id)")
                    && !validatedEvents.contains(detection)
            }
        }
        if !reviews.isEmpty { result.fillerReviews = reviews }
        return result
    }
}

/// Merged source-frame intervals keep rescans bounded even with many retained user decisions.
private struct ValidatedFillerEvents {
    private struct Key: Hashable {
        let speaker: SpeakerID
        let primary: ChannelReference
        let rate: Int
        let identity: String
        let revision: Int

        init(_ review: FillerTimingReview) {
            speaker = review.speaker
            primary = review.primary
            rate = review.sourceRate
            identity = review.sourceIdentity
            revision = review.alignmentRevision
        }
    }

    private var intervals: [Key: [Range<Int64>]] = [:]

    init(_ reviews: [FillerTimingReview]) {
        for review in reviews where review.retainsUserJudgment {
            for bounds in [review.initialBounds, review.bounds] {
                intervals[Key(review), default: []].append(bounds.sourceStartFrame..<bounds.sourceEndFrame)
            }
        }
        for key in Array(intervals.keys) {
            var merged: [Range<Int64>] = []
            for interval in intervals[key, default: []].sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let prior = merged.last, prior.upperBound >= interval.lowerBound {
                    merged[merged.count - 1] = prior.lowerBound..<max(prior.upperBound, interval.upperBound)
                } else {
                    merged.append(interval)
                }
            }
            intervals[key] = merged
        }
    }

    func contains(_ review: FillerTimingReview) -> Bool {
        guard let ranges = intervals[Key(review)] else { return false }
        let bounds = review.initialBounds
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound <= bounds.sourceStartFrame { lo = mid + 1 }
            else { hi = mid }
        }
        return lo < ranges.count && ranges[lo].lowerBound < bounds.sourceEndFrame
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
