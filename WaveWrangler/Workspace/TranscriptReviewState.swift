import Observation
import WWOrganizer

/// Evidence presentation retained for selected-Primary transcript handoffs.
/// The live Review workspace is backed by EpisodeCleanupModel.
@MainActor
@Observable
final class TranscriptReviewState {
    var presentation: TranscriptReviewPresentation = .syntheticFixture

    func present(_ presentation: TranscriptReviewPresentation) {
        self.presentation = presentation
    }
}
