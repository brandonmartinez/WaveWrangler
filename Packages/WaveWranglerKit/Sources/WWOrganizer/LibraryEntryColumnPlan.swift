import Foundation

/// The Library entry list's columns (#140), in display order.
public enum LibraryEntryColumnKind: String, CaseIterable, Sendable {
    case name, episodes, location, lastOpened, status

    /// Width at 100% in-app text (points). Name is flexible: this is its minimum; it takes the remaining width.
    public var baseWidth: Double {
        switch self {
        case .name: 120
        case .episodes: 70
        case .location: 140
        case .lastOpened: 170
        case .status: 150
        }
    }
}

/// Which entry-list columns are shown, and how wide, for the outline's available width and the in-app text
/// size (#140). Constant per-column widths × text scale, so no width depends on a layout pass, and every width
/// is finite (zooming produced NaN widths in #129). Status, which carries availability, is always shown; when
/// space runs out, Name shrinks to its minimum first, then Episodes, Last Opened and Location are hidden in
/// that order. Hidden values stay in the detail pane and the Name cell's accessibility help.
public enum LibraryEntryColumnPlan {
    /// Outline row insets (leading + trailing) plus room for a legacy vertical scroller.
    static let fixedOverhead = 48.0
    /// Intercell spacing between adjacent columns.
    static let spacing = 17.0

    /// Richest first. Every tier keeps Name and Status.
    public static let tiers: [[LibraryEntryColumnKind]] = [
        [.name, .episodes, .location, .lastOpened, .status],
        [.name, .location, .lastOpened, .status],
        [.name, .location, .status],
        [.name, .status],
    ]

    public struct Plan: Equatable, Sendable {
        /// Visible columns, in display order, with their widths.
        public var widths: [LibraryEntryColumnKind: Double]
        public var visible: [LibraryEntryColumnKind] { LibraryEntryColumnKind.allCases.filter { widths[$0] != nil } }
        public var hidden: [LibraryEntryColumnKind] { LibraryEntryColumnKind.allCases.filter { widths[$0] == nil } }
    }

    /// `scale`: in-app text size (1.0 = 100%). Non-finite or non-positive inputs fall back to safe values.
    public static func plan(availableWidth: Double, scale: Double) -> Plan {
        let scale = scale.isFinite ? min(max(scale, 0.5), 4) : 1
        let width = availableWidth.isFinite ? max(availableWidth, 0) : 0
        let tier = tiers.first { requiredWidth($0, scale: scale) <= width } ?? tiers.last!
        var widths: [LibraryEntryColumnKind: Double] = [:]
        for column in tier where column != .name {
            widths[column] = (column.baseWidth * scale).rounded()
        }
        let others = widths.values.reduce(0, +)
        let overhead = fixedOverhead + spacing * Double(tier.count - 1)
        // Name takes what's left. In the last tier at very large text it may go below its minimum (down to a
        // floor) so that Status still fits.
        let nameFloor = (60 * scale).rounded()
        widths[.name] = max(nameFloor, (width - others - overhead).rounded(.down))
        return Plan(widths: widths)
    }

    /// Minimum outline width for `columns` at `scale` (Name at its minimum).
    public static func requiredWidth(_ columns: [LibraryEntryColumnKind], scale: Double) -> Double {
        columns.reduce(0) { $0 + ($1.baseWidth * scale).rounded() } + fixedOverhead + spacing * Double(columns.count - 1)
    }
}
