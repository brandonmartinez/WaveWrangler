import Foundation

/// Show-window destinations (IA §4.2). Later ones are visible, focusable and selectable, and show a
/// blocked panel with the reason and the way forward (IA-12).
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
        case .review: "Review"
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
        isAvailableInThisVersion ? nil : "Not available in this version"
    }

    /// Help text for each destination segment.
    public var helpText: String {
        switch self {
        case .setup: "Set up sources and speakers for this episode"
        case .alignment: "Inspect and correct recorder alignment"
        case .review: "Inspect the provisional transcript and timeline review shell"
        case .export: "Later: not available in this version"
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
                heading: "Export isn't available yet",
                body: "Exporting cleaned speaker tracks comes in a later version of WaveWrangler. Nothing has been exported."
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
