import Foundation

/// Modifier keys for menu shortcuts, independent of AppKit so the register is testable headlessly.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    /// AppKit key equivalent string (lower-case letters; function-key code points for arrows).
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let upArrow = "\u{F700}"
    public static let downArrow = "\u{F701}"
    public static let backspace = "\u{8}"

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case Self.upArrow: text += "↑"
        case Self.downArrow: text += "↓"
        case Self.backspace: text += "⌫"
        case "\r": text += "⏎"
        case "\u{1b}": text += "Esc"
        default: text += key.uppercased()
        }
        return text
    }
}

/// Every menu command with a shortcut (commands-keyboard §2). `MainMenu` builds its items from this table,
/// so the register and duplicate checks (A-06) run headlessly against the same data.
public enum MenuCommand: String, CaseIterable, Sendable {
    // App
    case settings, hide, hideOthers, quit
    // File
    case newShow, newEpisode, open, close, closeShow, save, duplicate, saveAs, importSources
    // Edit
    case undo, redo, cut, copy, paste, delete, selectAll, moveUp, moveDown, find
    // View
    case toggleToolbar, toggleSidebar, toggleInspector
    case destinationSetup, destinationAlignment, destinationReview, destinationExport
    case textBigger, textSmaller, textActual, fullScreen
    // Episode
    case episodeInfo, auditionSelection, stopAudition
    // Window
    case minimize, library
    // Help
    case help

    public var shortcut: KeyShortcut {
        switch self {
        case .settings: KeyShortcut(",")
        case .hide: KeyShortcut("h")
        case .hideOthers: KeyShortcut("h", [.command, .option])
        case .quit: KeyShortcut("q")
        case .newShow: KeyShortcut("n")
        case .newEpisode: KeyShortcut("n", [.command, .shift])
        case .open: KeyShortcut("o")
        case .close: KeyShortcut("w")
        case .closeShow: KeyShortcut("w", [.command, .shift])
        case .save: KeyShortcut("s")
        case .duplicate: KeyShortcut("s", [.command, .shift])
        case .saveAs: KeyShortcut("s", [.command, .option, .shift])
        case .importSources: KeyShortcut("i", [.command, .shift])
        case .undo: KeyShortcut("z")
        case .redo: KeyShortcut("z", [.command, .shift])
        case .cut: KeyShortcut("x")
        case .copy: KeyShortcut("c")
        case .paste: KeyShortcut("v")
        case .delete: KeyShortcut(KeyShortcut.backspace, [])
        case .selectAll: KeyShortcut("a")
        case .moveUp: KeyShortcut(KeyShortcut.upArrow, [.command, .option])
        case .moveDown: KeyShortcut(KeyShortcut.downArrow, [.command, .option])
        case .find: KeyShortcut("f")
        case .toggleToolbar: KeyShortcut("t", [.command, .option])
        case .toggleSidebar: KeyShortcut("s", [.command, .control])
        case .toggleInspector: KeyShortcut("i", [.command, .control])
        case .destinationSetup: KeyShortcut("1")
        case .destinationAlignment: KeyShortcut("2")
        case .destinationReview: KeyShortcut("3")
        case .destinationExport: KeyShortcut("4")
        case .textBigger: KeyShortcut("+")
        case .textSmaller: KeyShortcut("-")
        case .textActual: KeyShortcut("0")
        case .fullScreen: KeyShortcut("f", [.command, .control])
        case .episodeInfo: KeyShortcut("i")
        case .auditionSelection: KeyShortcut("\r")
        case .stopAudition: KeyShortcut("\u{1b}", [])
        case .minimize: KeyShortcut("m")
        case .library: KeyShortcut("l", [.command, .shift])
        case .help: KeyShortcut("?")
        }
    }

    /// WaveWrangler's custom register (commands-keyboard "Custom shortcut register").
    public static let customRegister: [MenuCommand] = [
        .newEpisode, .importSources, .saveAs, .library,
        .destinationSetup, .destinationAlignment, .destinationReview, .destinationExport,
        .moveUp, .moveDown, .textBigger, .textSmaller, .textActual, .episodeInfo,
        .auditionSelection, .stopAudition,
    ]
}
