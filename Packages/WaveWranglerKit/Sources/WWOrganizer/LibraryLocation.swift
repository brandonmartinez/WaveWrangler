import Foundation

/// Where the canonical library is stored (states-and-recovery §5.1).
public enum LibraryLocationChoice: Sendable, Equatable {
    case inWaveWrangler
    case folder(displayName: String)

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

    public var allowsEdits: Bool {
        switch self {
        case .ready, .unreachable, .needsPermission: true
        case .conflict, .newerFormat: false
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
