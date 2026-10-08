import Foundation
import WWCore

/// Decides whether a whole-model replacement that was computed from a snapshot may still be published.
///
/// Every window open on a show shares one `ShowDocumentStore`, and some edits replace the entire model
/// after a sequence of awaits: Alignment's "Start New Epoch at Anchor" persists the show, activates the
/// runtime and runs the split before it applies the accepted model. An edit made in another window during
/// any of those awaits is already in the live model, so publishing the snapshot's successor would silently
/// discard it (#219). The replacement is therefore published only while the live model is still exactly the
/// snapshot the work was computed from.
enum SharedModelPublication {
    enum Decision: Equatable {
        /// The live model is unchanged, so the replacement still describes the user's show.
        case publish
        /// The live model moved on, so the replacement is stale and must be refused.
        case superseded
    }

    static func decide(live: ShowDocumentModel, expected: ShowDocumentModel) -> Decision {
        live == expected ? .publish : .superseded
    }

    /// Shown instead of a silent refusal, naming both what was kept and how to retry.
    static let supersededSplitMessage =
        "This show changed in another window while the new epoch was being prepared, so nothing was "
        + "split and that change is intact. Select the anchor again and choose Start New Epoch at Anchor."

    /// The same refusal for an accepted or rejected correction, which is prepared across one await.
    static let supersededCorrectionMessage =
        "This show changed in another window while the correction was being prepared, so nothing was "
        + "applied and that change is intact. Choose the correction again."
}
