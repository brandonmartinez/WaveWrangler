import Foundation

/// When a completed save clears a document's edited state (#87; Design states ST-10, HIG A4: with autosave on,
/// the "— Edited" suffix goes away as soon as autosave occurs).
///
/// AppKit clears the edited state itself after Save and Save As. An autosave in place only records the change
/// as autosaved, so the window would keep saying "Edited" while the save status says "Saved". The edited state
/// is cleared exactly when a **read-back-verified** autosave-in-place publication contains **exactly the current
/// model**: never for exports or autosave-elsewhere copies, never when unverified, and never when edits arrived
/// after the candidate was taken (those stay dirty and the status says "Edited").
public enum EditedStatePolicy {
    public enum Operation: Sendable, Equatable {
        case save, saveAs, autosaveInPlace, saveTo, autosaveElsewhere
    }

    public static func clearsEditedState(after operation: Operation, verified: Bool, publishedEqualsCurrent: Bool) -> Bool {
        operation == .autosaveInPlace && verified && publishedEqualsCurrent
    }
}
