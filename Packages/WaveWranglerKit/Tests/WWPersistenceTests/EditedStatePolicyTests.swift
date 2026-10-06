import Testing
@testable import WWPersistence

/// #87: a verified autosave in place clears "— Edited" exactly when the status says "Saved".
@Suite("Edited state after autosave")
struct EditedStatePolicyTests {
    @Test func onlyAVerifiedAutosaveInPlaceOfTheCurrentModelClears() {
        #expect(EditedStatePolicy.clearsEditedState(after: .autosaveInPlace, verified: true, publishedEqualsCurrent: true))
        // Edits arrived during the save: still edited (and the status says "Edited").
        #expect(!EditedStatePolicy.clearsEditedState(after: .autosaveInPlace, verified: true, publishedEqualsCurrent: false))
        // Not verified (failed, conflict, acknowledgement uncertain): still edited.
        #expect(!EditedStatePolicy.clearsEditedState(after: .autosaveInPlace, verified: false, publishedEqualsCurrent: true))
        // Exports and AppKit's autosave-elsewhere copies never clear this document's edited state; Save and
        // Save As are cleared by AppKit itself.
        for operation in [EditedStatePolicy.Operation.save, .saveAs, .saveTo, .autosaveElsewhere] {
            #expect(!EditedStatePolicy.clearsEditedState(after: operation, verified: true, publishedEqualsCurrent: true))
        }
    }
}
