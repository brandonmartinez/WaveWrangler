import AppKit
import Testing

/// #87 / #195 (M1 gate T26): pins the AppKit behaviour that `ShowDocument.finishSave` relies on. After AppKit's own
/// change-count update for an autosave in place, `isDocumentEdited` is already false, yet AppKit keeps its "recent
/// changes" (not public API; measured on macOS 27), which keep "— Edited" beside the title. A clear guarded by
/// `isDocumentEdited` therefore never runs; the verified autosave clears with `.changeCleared` unconditionally.
@MainActor
@Suite("AppKit autosave-in-place edited state")
struct AutosaveEditedStateTests {
    private final class Probe: NSDocument {
        override class var autosavesInPlace: Bool { true }
        override func data(ofType typeName: String) throws -> Data { Data() }
    }

    @Test func autosaveInPlaceTokenAlreadyClearsIsDocumentEdited() {
        let document = Probe()
        document.updateChangeCount(.changeDone)
        #expect(document.isDocumentEdited && document.hasUnautosavedChanges)
        document.updateChangeCount(withToken: document.changeCountToken(for: .autosaveInPlaceOperation), for: .autosaveInPlaceOperation)
        #expect(!document.isDocumentEdited, "so `if isDocumentEdited { clear }` after a verified autosave in place never clears")
        #expect(!document.hasUnautosavedChanges)
        document.updateChangeCount(.changeCleared)
        #expect(!document.isDocumentEdited && !document.hasUnautosavedChanges, "clearing again is harmless")
    }
}
