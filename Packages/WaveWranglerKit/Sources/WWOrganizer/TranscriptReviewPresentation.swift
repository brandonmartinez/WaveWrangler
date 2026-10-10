import Foundation

/// A display-only transcript supplied by a future, source-bound in-process producer.
///
/// This deliberately carries no source handle, media URL, inference capability, proposal, or edit authority.
public struct SelectedPrimaryTranscriptReviewInput: Equatable, Sendable {
    public struct Segment: Equatable, Sendable, Identifiable {
        public struct Word: Equatable, Sendable, Identifiable {
            public let id: String
            public let text: String
            /// Source-frame timing is optional. Absence must remain absent rather than being estimated.
            public let sourceFrameRange: ClosedRange<Int64>?

            public init(id: String, text: String, sourceFrameRange: ClosedRange<Int64>?) {
                self.id = id
                self.text = text
                self.sourceFrameRange = sourceFrameRange
            }
        }

        public let id: String
        public let text: String
        public let words: [Word]

        public init(id: String, text: String, words: [Word]) {
            self.id = id
            self.text = text
            self.words = words
        }
    }

    public let primarySourceID: String
    public let primarySourceName: String
    public let segments: [Segment]

    public init(primarySourceID: String, primarySourceName: String, segments: [Segment]) {
        self.primarySourceID = primarySourceID
        self.primarySourceName = primarySourceName
        self.segments = segments
    }
}

public enum TranscriptReviewPresentation: Equatable, Sendable {
    public struct Occurrence: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let detail: String
        public let wordTiming: String
    }

    public struct Lane: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let state: String
    }

    public struct Refusal: Equatable, Sendable {
        public let reason: String
    }

    case syntheticFixture
    case supplied(ValidatedSelectedPrimaryTranscript)
    case refusal(Refusal)

    /// Only this validated representation may be displayed as supplied transcript evidence.
    public struct ValidatedSelectedPrimaryTranscript: Equatable, Sendable {
        fileprivate let input: SelectedPrimaryTranscriptReviewInput

        fileprivate init(input: SelectedPrimaryTranscriptReviewInput) {
            self.input = input
        }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case missingPrimarySource
        case missingSegments
        case duplicateSegmentID
        case emptySegment
        case duplicateWordID
        case emptyWord
        case negativeSourceFrame

        public var refusal: Refusal {
            switch self {
            case .missingPrimarySource:
                Refusal(reason: "The supplied transcript was refused because its selected Primary source is not identified.")
            case .missingSegments:
                Refusal(reason: "The supplied transcript was refused because it contains no transcript segments.")
            case .duplicateSegmentID:
                Refusal(reason: "The supplied transcript was refused because segment identifiers are not unique.")
            case .emptySegment:
                Refusal(reason: "The supplied transcript was refused because a segment has no text.")
            case .duplicateWordID:
                Refusal(reason: "The supplied transcript was refused because word identifiers are not unique within a segment.")
            case .emptyWord:
                Refusal(reason: "The supplied transcript was refused because a word has no text.")
            case .negativeSourceFrame:
                Refusal(reason: "The supplied transcript was refused because a word timing contains a negative source frame.")
            }
        }
    }

    public static func validate(
        _ input: SelectedPrimaryTranscriptReviewInput
    ) -> Result<ValidatedSelectedPrimaryTranscript, ValidationError> {
        guard !input.primarySourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.primarySourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingPrimarySource)
        }
        guard !input.segments.isEmpty else { return .failure(.missingSegments) }

        var segmentIDs = Set<String>()
        for segment in input.segments {
            guard segmentIDs.insert(segment.id).inserted else { return .failure(.duplicateSegmentID) }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.emptySegment)
            }

            var wordIDs = Set<String>()
            for word in segment.words {
                guard wordIDs.insert(word.id).inserted else { return .failure(.duplicateWordID) }
                guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(.emptyWord)
                }
                if let sourceFrameRange = word.sourceFrameRange, sourceFrameRange.lowerBound < 0 {
                    return .failure(.negativeSourceFrame)
                }
            }
        }
        return .success(ValidatedSelectedPrimaryTranscript(input: input))
    }

    public var occurrences: [Occurrence] {
        switch self {
        case .syntheticFixture:
            TranscriptReviewShellPresentation.occurrences.map {
                Occurrence(id: $0.id, text: $0.title, detail: $0.note, wordTiming: "Timing unavailable")
            }
        case .supplied(let transcript):
            transcript.input.segments.map { segment in
                Occurrence(
                    id: segment.id,
                    text: segment.text,
                    detail: "Selected Primary: \(transcript.input.primarySourceName) · supplied in memory",
                    wordTiming: Self.timingState(for: segment.words)
                )
            }
        case .refusal:
            []
        }
    }

    public var lanes: [Lane] {
        switch self {
        case .syntheticFixture:
            TranscriptReviewShellPresentation.lanes.map { Lane(id: $0.id, label: $0.label, state: $0.state) }
        case .supplied(let transcript):
            [
                Lane(
                    id: "selected-primary",
                    label: "\(transcript.input.primarySourceName) — Primary",
                    state: "Validated transcript supplied in memory; no source read or inference from Review"
                ),
                Lane(
                    id: "backup-excluded",
                    label: "Backup",
                    state: "Explicitly excluded from this selected-Primary transcript view"
                ),
            ]
        case .refusal:
            [
                Lane(
                    id: "primary-unavailable",
                    label: "Primary",
                    state: "No accepted transcript is available"
                ),
                Lane(
                    id: "backup-excluded",
                    label: "Backup",
                    state: "Excluded; Review does not substitute or infer from Backup"
                ),
            ]
        }
    }

    public var notice: String {
        switch self {
        case .syntheticFixture:
            "Provisional UI shell · synthetic fixture only · no media read or speech analysis."
        case .supplied(let transcript):
            "Validated in-memory transcript for selected Primary “\(transcript.input.primarySourceName)” · Backup excluded · no source read or speech analysis."
        case .refusal(let refusal):
            "Review transcript unavailable. \(refusal.reason)"
        }
    }

    public var blockedReason: String {
        switch self {
        case .syntheticFixture:
            TranscriptReviewShellPresentation.noLiveSourceReason
        case .supplied:
            "Transcript evidence is display-only. No filler, cut, audition, preview, or edit authority is available."
        case .refusal(let refusal):
            refusal.reason
        }
    }

    public var permitsProposals: Bool {
        if case .syntheticFixture = self { return true }
        return false
    }

    public var isSynthetic: Bool {
        if case .syntheticFixture = self { return true }
        return false
    }

    private static func timingState(for words: [SelectedPrimaryTranscriptReviewInput.Segment.Word]) -> String {
        let timedWords = words.compactMap(\.sourceFrameRange)
        guard !timedWords.isEmpty else { return "Word timing unavailable" }
        guard timedWords.count == words.count else {
            return "Word timing available for \(timedWords.count) of \(words.count) words; missing timings remain unavailable"
        }
        return "Word timing supplied for \(timedWords.count) words"
    }
}
