import AppKit
import SwiftUI
import WWCore
import WWPersistence

/// The portable show document (`.wwshow`).
///
/// M1 foundation: read/write the canonical value through `JSONEnvelopeCoder` and rely on NSDocument's
/// native save/autosave/versions. Publication hardening (prior checkpoint, coordinated cloud publication,
/// acknowledgement uncertainty, autosave ON/configurable/OFF policy) is owned by `Document/` persistence
/// work and replaces these overrides; the coder stays isolated in WWPersistence.
@objc(ShowDocument)
final class ShowDocument: NSDocument {
    let store: ShowDocumentStore
    private let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
    /// Publication of the last coherent value read or successfully written (`nil` for a new document).
    /// `revision` is only an ordering hint; the publication ID and checksum identify what is on disk.
    private(set) var publication: PublicationStamp?
    private var pendingPublication: PublicationStamp?

    var revision: Int { publication?.revision ?? 0 }

    override init() {
        store = ShowDocumentStore(model: .untitled())
        super.init()
        store.document = self
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let hosting = NSHostingController(rootView: ShowWorkspaceView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 520))
        window.tabbingMode = .preferred
        addWindowController(NSWindowController(window: window))
    }

    // NSDocument declares reading/writing nonisolated because subclasses may opt into concurrent reading
    // or asynchronous writing. This class keeps both disabled (the defaults), so AppKit calls these on the
    // main thread; `assumeIsolated` enforces that rather than silently racing the store.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool {
        false
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try coder.decode(data)
        MainActor.assumeIsolated {
            store.replaceLoadedModel(decoded.payload)
            publication = decoded.publication
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            let encoded = try coder.encodeDocument(store.model, revision: revision + 1, publicationID: UUID())
            pendingPublication = encoded.publication
            return encoded.data
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // The model is already current (edits apply live); end any coalesced burst so that an edit made
        // after this save registers new undo and marks the document dirty again.
        store.endCoalescing()
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if let self, error == nil, let pending = self.pendingPublication {
                self.publication = pending
            }
            self?.pendingPublication = nil
            completionHandler(error)
        }
    }

    /// Duplicate (File ▸ Duplicate) creates a distinct show with a new `ShowID`, so the original and the
    /// copy can coexist in the library. Show-scoped IDs (episodes, sources, speakers…) are kept.
    override func duplicate() throws -> NSDocument {
        let copy = try super.duplicate()
        guard let show = copy as? ShowDocument else { return copy }
        show.store.replaceLoadedModel(store.model.duplicatedAsNewShow())
        show.publication = nil
        show.updateChangeCount(.changeDone)
        return show
    }
}
