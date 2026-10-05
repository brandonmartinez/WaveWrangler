import WWCore
import WWEpisodeSetup

/// Lets the Setup command layer apply named, undoable edits through the show document's store.
extension ShowDocumentStore: SetupEditing {
    var showModel: ShowDocumentModel { model }
    var lastSetupError: DomainError? { lastError }

    func applySetupEdit(_ actionName: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> Bool {
        apply(actionName, operation)
    }
}
