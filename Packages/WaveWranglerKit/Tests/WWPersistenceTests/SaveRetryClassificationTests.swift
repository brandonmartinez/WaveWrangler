import Foundation
import Testing
@testable import WWPersistence

/// ST-11: which save states are retried automatically while autosave is on (#156, #157 review). Every state is
/// listed, so a new state has to be classified on purpose.
@Suite("Automatic save retry classification")
struct SaveRetryClassificationTests {
    private static let now = Date(timeIntervalSince1970: 1_000)

    @Test(arguments: [
        (DocumentSaveState.clean(revision: nil), false),
        (.clean(revision: 3), false),
        (.edited(autosaveEnabled: true), false),
        (.edited(autosaveEnabled: false), false),
        (.saving, false),
        (.saved(revision: 3, at: now), false),
        (.savedFollowUpIncomplete(revision: 3, at: now), false),
        // D7 location unavailable, D8 disk full, D9 failed (permission / other): retried.
        (.saveFailed(retainedRevision: 2, kind: .unavailable, message: "offline"), true),
        (.saveFailed(retainedRevision: 2, kind: .diskFull, message: "full"), true),
        (.saveFailed(retainedRevision: 2, kind: .permissionDenied, message: "denied"), true),
        (.saveFailed(retainedRevision: nil, kind: .other, message: "other"), true),
        // D10: the user cancelled; never retried behind their back.
        (.saveFailed(retainedRevision: 2, kind: .cancelled, message: "cancelled"), false),
        // D6: a conflict needs the user's decision; retrying would only fail the base check again.
        (.conflict(onDiskRevision: 4, missing: false), false),
        (.conflict(onDiskRevision: nil, missing: true), false),
        // D5: the candidate may be on disk; the retry first adopts it if it is (ShowDocument).
        (.acknowledgementUncertain(message: "unconfirmed"), true),
        (.recoveryCheckpoint(at: now), false),
        (.autosaveSkipped, false),
        (.readOnlyNewerFormat(found: 9, supported: 1), false),
        (.recoveredReadOnly(revision: 2), false),
        (.cancelled, false),
    ])
    func retryable(_ state: DocumentSaveState, _ expected: Bool) {
        #expect(state.isAutomaticallyRetryable == expected, "\(state)")
    }
}
