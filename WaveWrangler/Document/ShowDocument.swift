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
    /// Revision of the last coherent value read or successfully written.
    private(set) var revision = 0
    private var pendingRevision: Int?

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
            revision = decoded.revision
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            let next = revision + 1
            let data = try coder.encode(store.model, revision: next)
            pendingRevision = next
            return data
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if let self, error == nil, let pending = self.pendingRevision {
                self.revision = pending
            }
            self?.pendingRevision = nil
            completionHandler(error)
        }
    }
}
