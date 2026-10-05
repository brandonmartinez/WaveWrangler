import Foundation

/// Where the canonical library is stored (states-and-recovery §5.1).
public enum LibraryLocationChoice: Sendable, Equatable {
    case inWaveWrangler
    case folder(displayName: String)

    /// A-07: a fresh install stores the library in WaveWrangler.
    public static let `default` = LibraryLocationChoice.inWaveWrangler
    public static let inWaveWranglerTitle = "In WaveWrangler"
    public static let chooseFolderTitle = "Choose Folder…"

    public var title: String {
        switch self {
        case .inWaveWrangler: Self.inWaveWranglerTitle
        case .folder(let name): name
        }
    }

    public var caption: String {
        switch self {
        case .inWaveWrangler:
            "Your library (collections, recent items and unavailable shows) is stored inside WaveWrangler on this Mac. Your shows stay wherever you saved them."
        case .folder(let name):
            "Your library is stored in “\(name)”. If this folder syncs, WaveWrangler on your other Macs can use the same library. Your shows stay wherever you saved them."
        }
    }

    /// ST-33 step 2 confirmation.
    public var moveConfirmation: (message: String, informative: String, button: String) {
        let message = switch self {
        case .inWaveWrangler: "Move your library back into WaveWrangler?"
        case .folder(let name): "Move your library to “\(name)”?"
        }
        return (
            message,
            "WaveWrangler copies your library there, checks that the copy is complete, and then stops using the old copy. Collections, recent items and unavailable shows are all kept. The old copy stays where it is as a backup; WaveWrangler doesn't delete it.",
            "Move Library"
        )
    }

    public static let choosePanelPrompt = "Choose a folder for your WaveWrangler library"
}

/// Progress of a library move (ST-33 step 3). Indeterminate unless counts are known.
public enum LibraryMovePhase: Sendable, Equatable {
    case copying
    case checking

    public var text: String {
        switch self {
        case .copying: "Moving library — copying…"
        case .checking: "Moving library — checking copy…"
        }
    }
}

/// Library-level states L1–L5. Never shown as a show save state.
public enum LibraryLevelState: Sendable, Equatable {
    case ready
    case unreachable(folderDisplayName: String, pendingChanges: Int)
    case needsPermission(pendingChanges: Int)
    case conflict
    case newerFormat(folderDisplayName: String)
    /// L5 when no readable copy can be shown at all (honest variant of the L5 wording).
    case newerFormatNotViewable(folderDisplayName: String)
    /// The canonical library is damaged or missing; whole earlier versions can be recovered as a new copy.
    /// (Not in Design's L1–L5 table; wording proposed to Design.)
    case damaged

    public var allowsEdits: Bool {
        switch self {
        case .ready, .unreachable, .needsPermission: true
        case .conflict, .newerFormat, .newerFormatNotViewable, .damaged: false
        }
    }

    public var pendingChanges: Int {
        switch self {
        case .unreachable(_, let count), .needsPermission(let count): count
        default: 0
        }
    }
}

public enum LibraryLevelAction: String, Sendable, Equatable, CaseIterable {
    case tryAgain = "Try Again"
    case librarySettings = "Library Settings…"
    case grantAccess = "Grant Access…"
    case combine = "Combine (Keep Everything)"
    case useOtherMacsVersion = "Use Other Mac's Version"
    case recoverEarlierVersion = "Recover Earlier Version…"
}

public struct LibraryLevelPresentation: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var symbolName: String
    public var actions: [LibraryLevelAction]
    /// "<n> library changes not saved yet", when changes are queued.
    public var pendingText: String?

    public init?(_ state: LibraryLevelState) {
        switch state {
        case .ready:
            return nil
        case .unreachable(let folder, let pending):
            heading = "Can't reach your library"
            body = "WaveWrangler can't reach “\(folder)”, where your library is stored. Your shows aren't affected, and you can still open them with File › Open. Library changes are kept on this Mac and saved when the folder is available again."
            symbolName = "icloud.slash"
            actions = [.tryAgain, .librarySettings]
            pendingText = Self.pending(pending)
        case .needsPermission(let pending):
            heading = "WaveWrangler needs permission to use your library folder"
            body = "Choose the folder again to let WaveWrangler use your library."
            symbolName = "key.slash"
            actions = [.grantAccess]
            pendingText = Self.pending(pending)
        case .conflict:
            heading = "Your library was changed on another Mac"
            body = "Another Mac saved changes to your library while this Mac also had changes. WaveWrangler hasn't overwritten either."
            symbolName = "arrow.triangle.branch"
            actions = [.combine, .useOtherMacsVersion]
            pendingText = nil
        case .newerFormatNotViewable(let folder):
            heading = "Your library needs a newer WaveWrangler"
            body = "The library in “\(folder)” was saved by a newer version of WaveWrangler. This version can't show or change it, so its newer information isn't lost. Your shows aren't affected, and you can still open them with File › Open."
            symbolName = "lock.fill"
            actions = [.librarySettings]
            pendingText = nil
        case .damaged:
            heading = "Your library can't be read"
            body = "WaveWrangler couldn't read your library completely and hasn't changed it. You can recover an earlier complete version as a new copy. Your shows aren't affected, and you can still open them with File › Open."
            symbolName = "exclamationmark.lock"
            actions = [.recoverEarlierVersion]
            pendingText = nil
        case .newerFormat(let folder):
            heading = "Your library needs a newer WaveWrangler"
            body = "The library in “\(folder)” was saved by a newer version of WaveWrangler. You can see it, but it can't be changed here, so its newer information isn't lost. Your shows aren't affected."
            symbolName = "lock.fill"
            actions = [.librarySettings]
            pendingText = nil
        }
    }

    static func pending(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 library change not saved yet"
        default: "\(count) library changes not saved yet"
        }
    }

    /// ST-34 quit confirmation when changes are queued.
    public static func quitWarning(pendingChanges: Int) -> (message: String, informative: String)? {
        guard pendingChanges > 0 else { return nil }
        let noun = pendingChanges == 1 ? "1 library change" : "\(pendingChanges) library changes"
        return ("WaveWrangler couldn't save \(noun).", "If you quit now, they'll be lost.")
    }
}

/// Outcome of L3 "Grant Access…" (persistence's `LibraryRegrantOutcome`, mapped by the app adapter).
public enum LibraryRegrantResult: Sendable, Equatable {
    /// Access was granted to the library folder and the library reloaded. Persistence may accept a folder by
    /// its configured path when the library's identity can't be read, so the wording doesn't claim it was
    /// verified to be the same library.
    case regranted(pendingEditsSaved: Bool)
    /// The folder holds a different WaveWrangler library; nothing was changed.
    case differentLibrary(folderDisplayName: String)
    case noLibraryThere(folderDisplayName: String)
    case cannotVerify(reason: String)
}

/// What the Library window should do after a library-level action.
public enum LibraryActionFollowUp: Sendable, Equatable {
    case none
    /// Offer Use That Library · Choose Another Folder… · Cancel (no default) for `folder`; nothing changed yet.
    case offerDifferentLibrary(folderDisplayName: String)
}

public enum LibraryRegrantWording {
    public static let panelMessage = "Choose your library folder again to let WaveWrangler use it."

    /// Message-bar text; `nil` for `.differentLibrary`, which is a sheet (`differentLibrarySheet`).
    public static func message(for result: LibraryRegrantResult) -> String? {
        switch result {
        case .regranted(let pendingSaved):
            pendingSaved
                ? "Access granted to the library folder. Your waiting library changes were saved."
                : "Access granted to the library folder."
        case .differentLibrary:
            nil
        case .noLibraryThere(let folder):
            "There's no WaveWrangler library in “\(folder)”, so nothing was changed. Choose the folder that holds your library."
        case .cannotVerify(let reason):
            "WaveWrangler can't use the library in that folder: \(sentence(reason)) Nothing was changed."
        }
    }

    public static func differentLibrarySheet(folderDisplayName: String) -> (title: String, text: String) {
        (
            "“\(folderDisplayName)” has a different WaveWrangler library",
            "It isn't the library WaveWrangler was using, so nothing was changed. You can use that library instead — your current library is kept as a backup and its collections are added — or choose another folder."
        )
    }

    public static func followUp(for result: LibraryRegrantResult) -> LibraryActionFollowUp {
        if case .differentLibrary(let folder) = result { return .offerDifferentLibrary(folderDisplayName: folder) }
        return .none
    }

    static func sentence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed + "."
    }
}

/// Persistence reports library *file* URLs (`<folder>/Library.wwlibrary`) in move and regrant outcomes.
/// The UI names folders and passes folders back to `useLibrary(in:)`, so it always reduces to the folder.
public enum LibraryFolderURL {
    public static let libraryFileExtension = "wwlibrary"

    /// The folder holding the library: strips a trailing `*.wwlibrary` file component; folders pass through.
    public static func folder(for url: URL) -> URL {
        url.pathExtension.lowercased() == libraryFileExtension ? url.deletingLastPathComponent() : url
    }

    /// Folder display name for UI text (never a path).
    public static func displayName(for url: URL) -> String {
        folder(for: url).lastPathComponent
    }
}
