import Foundation

/// Show-window destinations. The serialized export case remains for compatibility;
/// selecting it now opens the document-owned File > Export sheet instead of navigating.
public enum ShowDestination: String, CaseIterable, Sendable, Identifiable {
    case setup
    case alignment
    case review
    case export

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .setup: "Setup"
        case .alignment: "Alignment"
        case .review: "Edit & Cleanup"
        case .export: "Export"
        }
    }

    /// ⌘1–⌘4.
    public var shortcutDigit: Character {
        switch self {
        case .setup: "1"
        case .alignment: "2"
        case .review: "3"
        case .export: "4"
        }
    }

    public var isAvailableInThisVersion: Bool { self == .setup || self == .alignment || self == .review }

    /// VoiceOver value for the segment when not selected; `nil` when nothing extra is said.
    public var unavailableValue: String? {
        if self == .export { return "Available in File > Export" }
        return isAvailableInThisVersion ? nil : "Not available in this version"
    }

    /// Help text for each destination segment.
    public var helpText: String {
        switch self {
        case .setup: "Set up sources and speakers for this episode"
        case .alignment: "Inspect and correct recorder alignment"
        case .review: "Transcribe aligned Primary speakers and set the shared episode working range"
        case .export: "Export the whole episode using File > Export"
        }
    }

    public var blockedPanel: BlockedPanel? {
        switch self {
        case .setup:
            nil
        case .alignment:
            nil
        case .review:
            nil
        case .export:
            BlockedPanel(
                heading: "Export is in the File menu",
                body: "Choose File > Export or use the Export toolbar button to export the whole episode."
            )
        }
    }
}

public struct BlockedPanel: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var buttonTitle: String { "Go to Setup" }

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}
