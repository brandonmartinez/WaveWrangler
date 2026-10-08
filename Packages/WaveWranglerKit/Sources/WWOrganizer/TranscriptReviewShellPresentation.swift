import Foundation

public struct TranscriptReviewShellOccurrence: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tokenStubID: String
    public let note: String

    public init(id: String, title: String, tokenStubID: String, note: String) {
        self.id = id
        self.title = title
        self.tokenStubID = tokenStubID
        self.note = note
    }
}

public struct TranscriptReviewShellLane: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let state: String

    public init(id: String, label: String, state: String) {
        self.id = id
        self.label = label
        self.state = state
    }
}

/// Synthetic-only copy for the native Review shell; this is not a transcript, source, or edit-policy model.
public enum TranscriptReviewShellPresentation {
    public static let occurrences = [
        TranscriptReviewShellOccurrence(
            id: "synthetic-001",
            title: "Synthetic example occurrence 1",
            tokenStubID: "token-stub-001",
            note: "Example text only — no transcript analysis or timing."
        ),
        TranscriptReviewShellOccurrence(
            id: "synthetic-002",
            title: "Synthetic example occurrence 2",
            tokenStubID: "token-stub-002",
            note: "Untimed synthetic span — no timestamp is inferred."
        ),
    ]

    public static let lanes = [
        TranscriptReviewShellLane(
            id: "speaker-a-primary",
            label: "Speaker A — Primary",
            state: "Synthetic role example · not analyzed"
        ),
        TranscriptReviewShellLane(
            id: "speaker-a-backup",
            label: "Speaker A — Backup",
            state: "Synthetic role example · not analyzed · no transcript"
        ),
        TranscriptReviewShellLane(
            id: "speaker-b-primary",
            label: "Speaker B — Primary",
            state: "Synthetic role example · not analyzed"
        ),
    ]

    public static let noLiveSourceReason =
        "No live Primary or source is connected to this provisional shell. Choose or confirm the Primary in Setup when Review is integrated."
    public static let editBlockedReason =
        "Disabled: transcript timing, current alignment, all-lane backing, protection coverage, and an edit policy are not connected."
    public static let fullPreviewBlockedReason =
        "Complete preview is blocked: every affected lane, the common map, source backing, and protection coverage are unverified."
    public static let singleLaneAuditionBlockedReason =
        "Single-lane audition — not a full preview. Disabled because no authorized Primary source is bound."
    public static let timeNotEstablished = "Not established — no analysis or current map"
    public static let noProposalState = "None — no analysis or proposal is connected"

    public static let timeDomains = [
        ("source", "Source time"),
        ("group", "Group time"),
        ("aligned", "Aligned time"),
        ("output", "Output time"),
    ]
}
