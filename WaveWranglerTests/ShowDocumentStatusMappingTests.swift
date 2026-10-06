import Testing
import WWOrganizer
import WWPersistence

/// ST-11 (#156, #157 review): the save-status popover promises "WaveWrangler will try again automatically" only
/// while ShowDocument really has an automatic retry pending, and never for a state it doesn't retry.
@MainActor
@Suite("Show document status mapping: automatic retry")
struct ShowDocumentStatusMappingTests {
    private func popover(_ state: WWPersistence.DocumentSaveState, autosave: Bool, retrying: Bool) -> (status: WWOrganizer.DocumentSaveStatus, text: String) {
        let status = ShowDocumentStatusMapping.map(state, readOnlyReason: nil, autosaveEnabled: autosave, folderDisplayName: "Shows",
                                                   retryingAutomatically: retrying)
        return (status, SaveStatusPresentation(status, showName: "S", formatTime: { _ in "10:42 PM" }).popoverText)
    }

    private static let failures: [WWPersistence.DocumentSaveState] = [
        .saveFailed(retainedRevision: 2, kind: .unavailable, message: "offline"),   // D7
        .saveFailed(retainedRevision: 2, kind: .diskFull, message: "full"),         // D8
        .saveFailed(retainedRevision: 2, kind: .permissionDenied, message: "no"),   // D9
        .saveFailed(retainedRevision: 2, kind: .other, message: "broken"),          // D9
        .acknowledgementUncertain(message: "unconfirmed"),                          // D5
    ]

    @Test func promisesARetryOnlyWhileOneIsPending() {
        for state in Self.failures {
            let pending = popover(state, autosave: true, retrying: true)
            #expect(pending.status.retryingAutomatically, "\(state)")
            #expect(pending.text.contains("WaveWrangler will try again automatically."), "\(state): \(pending.text)")
            let idle = popover(state, autosave: true, retrying: false)
            #expect(!idle.status.retryingAutomatically, "\(state)")
            #expect(!idle.text.contains("try again automatically"), "\(state): \(idle.text)")
        }
    }

    @Test func neverPromisesARetryWithAutosaveOffOrForUnretriedStates() {
        for state in Self.failures {
            #expect(!popover(state, autosave: false, retrying: true).status.retryingAutomatically, "\(state)")
        }
        let unretried: [WWPersistence.DocumentSaveState] = [
            .saveFailed(retainedRevision: 2, kind: .cancelled, message: "cancelled"),   // D10
            .conflict(onDiskRevision: 3, missing: false),                               // D6
            .edited(autosaveEnabled: true),
            .cancelled,
        ]
        for state in unretried {
            let mapped = popover(state, autosave: true, retrying: true)
            #expect(!mapped.status.retryingAutomatically, "\(state)")
            #expect(!mapped.text.contains("try again automatically"), "\(state): \(mapped.text)")
        }
    }

    @Test func offlineWordingFollowsTheRetry() {
        let offline = WWPersistence.DocumentSaveState.saveFailed(retainedRevision: 2, kind: .unavailable, message: "offline")
        #expect(popover(offline, autosave: true, retrying: true).text.hasSuffix("WaveWrangler will try again automatically."))
        #expect(popover(offline, autosave: false, retrying: false).text.hasSuffix("Choose Try Again when the folder is available."))
    }
}
