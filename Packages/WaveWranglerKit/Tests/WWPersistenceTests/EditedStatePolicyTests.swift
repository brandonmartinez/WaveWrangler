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

    /// M1 gate (T26): re-checked after AppKit's own completion of the save. Clears only while the verified publication
    /// is still this document's base and holds exactly the current model.
    @Test func afterCompletionClearsOnlyWhileTheVerifiedPublicationIsCurrent() {
        func clears(_ operation: EditedStatePolicy.Operation = .autosaveInPlace, verified: Bool = true, stillEdited: Bool = true,
                    base: Bool = true, equal: Bool = true) -> Bool {
            EditedStatePolicy.clearsEditedStateAfterCompletion(after: operation, verified: verified, stillEdited: stillEdited,
                                                               baseIsThatPublication: base, publishedEqualsCurrent: equal)
        }
        #expect(clears(), "a retry's verified autosave of the current model, window still says Edited")
        #expect(!clears(stillEdited: false), "already clean: nothing to do")
        #expect(!clears(base: false), "another save (or adoption) replaced the base since: that one decides")
        #expect(!clears(equal: false), "edited (or undone to a different model) after the save started")
        #expect(!clears(verified: false), "not verified")
        for operation in [EditedStatePolicy.Operation.save, .saveAs, .saveTo, .autosaveElsewhere] {
            #expect(!clears(operation), "\(operation)")
        }
    }
}
