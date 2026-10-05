import AppKit
import Observation
import WWOrganizer

/// The save-status seam (states-and-recovery §2). The persistence lane makes its document (or a status
/// object it owns) conform; the show window reads `store.document as? DocumentStatusProviding` first.
/// Conformers must be observable so SwiftUI updates when `saveStatus` changes.
@MainActor
protocol DocumentStatusProviding: AnyObject {
    var saveStatus: DocumentSaveStatus { get }
}

/// Optional: lets the persistence lane handle popover/message-bar actions (Resolve…, Try Again, …).
@MainActor
protocol DocumentStatusActionHandling: AnyObject {
    /// Returns `true` when handled.
    func performSaveStatusAction(_ action: SaveStatusAction, from window: NSWindow?) -> Bool
}

/// Honest fallback used until the persistence lane's status model is connected. It reads only in-memory
/// NSDocument state (no file I/O). Without coherent publication evidence it never reports "Saved": a
/// clean document is "Unknown", an edited one is "Edited"/"Not saved".
@MainActor
@Observable
final class NativeDocumentStatusObserver: DocumentStatusProviding {
    static let unconfirmedReason = "this version can't confirm saves yet"

    private(set) var saveStatus: DocumentSaveStatus
    @ObservationIgnored private weak var document: NSDocument?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let settings: AppSettings

    init(document: NSDocument?, settings: AppSettings = .shared) {
        self.document = document
        self.settings = settings
        saveStatus = DocumentSaveStatus(state: .checking, autosaveEnabled: AutosavePolicyConnection.effectiveAutosaveEnabled)
        refresh()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    isolated deinit {
        timer?.invalidate()
    }

    func refresh() {
        guard let document else { return }
        let edited = document.isDocumentEdited
        let next: DocumentSaveStatus
        if edited {
            next = DocumentSaveStatus(state: .edited, autosaveEnabled: AutosavePolicyConnection.effectiveAutosaveEnabled, hasUnsavedChanges: true)
        } else {
            next = DocumentSaveStatus(
                state: .unknown(reason: Self.unconfirmedReason),
                autosaveEnabled: AutosavePolicyConnection.effectiveAutosaveEnabled,
                hasUnsavedChanges: false
            )
        }
        if next != saveStatus { saveStatus = next }
    }
}
