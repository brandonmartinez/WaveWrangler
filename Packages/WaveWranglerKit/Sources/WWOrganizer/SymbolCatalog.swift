import Foundation

/// Every SF Symbol name the organizer UI uses, for the A-01 symbol-resolution check.
public enum SymbolCatalog {
    public static var all: Set<String> {
        var names: Set<String> = [
            // Library sidebar and window
            "books.vertical", "clock", "exclamationmark.triangle", "rectangle.stack", "plus",
            // Show window
            "music.mic", "info.circle", "lock.fill", "sidebar.left", "sidebar.right", "waveform.path", "folder",
            // Settings
            "gearshape",
        ]
        names.formUnion(SettingsPane.allCases.map(\.symbolName))
        let date = Date(timeIntervalSince1970: 0)
        let saveStates: [DocumentSaveState] = [
            .checking, .unknown(reason: "x"), .saved(at: date, folderDisplayName: nil), .edited, .saving(cancellable: true),
            .notConfirmed, .conflict(changedAt: nil), .locationUnavailable, .diskFull(volumeName: "x"),
            .failed(reason: "x"), .cancelled, .recovered(incompleteSaveAt: nil, openedVersionAt: nil),
            .readOnlyNewerFormat, .readOnlyDamaged, .updateNeeded, .updateFailed, .readOnlyLocation,
        ]
        for state in saveStates {
            for autosave in [true, false] {
                let presentation = SaveStatusPresentation(DocumentSaveStatus(state: state, autosaveEnabled: autosave), showName: "x")
                if let symbol = presentation.symbolName { names.insert(symbol) }
            }
        }
        let entryStates: [LibraryEntryState] = [
            .checking, .available, .notFound(folderDisplayName: nil), .needsPermission, .locationUnavailable,
            .newerFormat, .damaged, .outOfDate, .recordedUnavailable(note: "x"),
        ]
        for state in entryStates {
            if let symbol = LibraryEntryStatePresentation(state, showName: "x").symbolName { names.insert(symbol) }
        }
        return names
    }
}
