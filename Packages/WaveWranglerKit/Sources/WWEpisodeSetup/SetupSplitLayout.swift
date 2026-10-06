import Foundation

/// Heights of the stacked Sources and Speakers tables (IA §4.3: stacked, resizable; default sizes must
/// be usable without dragging). Minimums keep the section header, column header and several rows
/// visible in each table, and scale with the in-app text size.
public enum SetupSplitLayout {
    public static let defaultSpeakersFraction = 0.35
    public static let fractionRange = 0.15...0.85
    /// Base heights at 100% text: section header row with its padding, table column header, one row.
    static let sectionHeader = 48.0
    static let columnHeader = 28.0
    static let row = 24.0

    public static func minimumSpeakersHeight(scale: Double) -> Double {
        (sectionHeader + columnHeader + 4 * row) * scale
    }

    /// Speakers' floor when space is short: header, column header and two rows (#104: Sources first).
    public static func compactSpeakersHeight(scale: Double) -> Double {
        (sectionHeader + columnHeader + 2 * row) * scale
    }

    public static func minimumSourcesHeight(scale: Double) -> Double {
        (sectionHeader + columnHeader + 6 * row) * scale
    }

    /// Splits `total` (excluding the handle). The Speakers share follows `speakersFraction` but never goes
    /// below its minimum or leaves Sources below its minimum; when both minimums don't fit, the space is
    /// shared in proportion to them (each table then scrolls).
    public static func heights(total: Double, scale: Double, speakersFraction: Double) -> (sources: Double, speakers: Double) {
        let total = max(total, 0)
        let minSpeakers = minimumSpeakersHeight(scale: scale)
        let minSources = minimumSourcesHeight(scale: scale)
        guard total >= minSpeakers + minSources else {
            // Sources has priority (#104): Speakers keeps a compact two-row floor, Sources gets the rest.
            let compact = compactSpeakersHeight(scale: scale)
            let speakers = min(max(total - minSources, compact), total / 2).rounded(.down)
            return (total - max(speakers, 0), max(speakers, 0))
        }
        let fraction = min(max(speakersFraction, fractionRange.lowerBound), fractionRange.upperBound)
        let speakers = min(max((total * fraction).rounded(.down), minSpeakers), total - minSources)
        return (total - speakers, speakers)
    }

    /// The fraction for a drag that puts the handle at `y` (from the top of the stack of height `total`).
    public static func fraction(forHandleAt y: Double, total: Double) -> Double {
        guard total > 0 else { return defaultSpeakersFraction }
        return min(max(1 - y / total, fractionRange.lowerBound), fractionRange.upperBound)
    }
}

/// Where Setup's selection details go (#104). Beside the tables when the content is wide; otherwise below
/// them — expanded only when there is room for the tables' minimums, else collapsed to a one-line bar
/// the user can open (keyboard: the bar's button, or Return in a table).
public enum SetupDetailsPlacement: Equatable, Sendable {
    case beside(width: Double)
    case below(height: Double)
    case collapsed(barHeight: Double)

    public static let wideThreshold = 860.0

    public static func plan(width: Double, height: Double, scale: Double, userExpanded: Bool?) -> SetupDetailsPlacement {
        if width >= wideThreshold { return .beside(width: 300) }
        let bar = 32.0 * scale
        let tables = SetupSplitLayout.minimumSourcesHeight(scale: scale) + SetupSplitLayout.minimumSpeakersHeight(scale: scale) + 9 * scale
        let details = max(160 * scale, height * 0.3)
        let fits = height - tables >= details
        switch userExpanded {
        case true?: return .below(height: min(details, max(height - bar - SetupSplitLayout.minimumSourcesHeight(scale: scale), bar)))
        case false?: return .collapsed(barHeight: bar)
        case nil: return fits ? .below(height: details) : .collapsed(barHeight: bar)
        }
    }
}

/// Which Sources columns fit (#104). Status always shows; Name truncates (middle) first; less essential
/// columns are hidden — their values stay in the details panel and the row's VoiceOver value.
public enum SetupSourceColumn: String, CaseIterable, Sendable {
    case name, epoch, channel, speaker, role, status

    /// Ideal widths at 100% text; minimum Name width is `nameMinimum`.
    public func width(scale: Double) -> Double {
        switch self {
        case .name: 150 * scale
        case .epoch: 46 * scale
        case .channel: 34 * scale
        case .speaker: 84 * scale
        case .role: 84 * scale
        case .status: 130 * scale
        }
    }

    public static func nameMinimum(scale: Double) -> Double { 80 * scale }
}

public enum SetupColumnPlan {
    /// Disclosure indent, row insets and the vertical scroller.
    static let fixedOverhead = 40.0
    static let perColumnSpacing = 10.0

    public static let tiers: [[SetupSourceColumn]] = [
        [.name, .epoch, .channel, .speaker, .role, .status],
        [.name, .speaker, .role, .status],
        [.name, .speaker, .status],
        [.name, .status],
    ]

    public static func requiredWidth(_ columns: [SetupSourceColumn], scale: Double) -> Double {
        let others = columns.filter { $0 != .name }.reduce(0) { $0 + $1.width(scale: scale) }
        return SetupSourceColumn.nameMinimum(scale: scale) + others + fixedOverhead + perColumnSpacing * Double(columns.count)
    }

    /// The richest column set whose minimum width fits `width`.
    public static func columns(forWidth width: Double, scale: Double) -> [SetupSourceColumn] {
        guard width.isFinite else { return tiers.last! }
        return tiers.first { requiredWidth($0, scale: scale) <= width } ?? tiers.last!
    }

    /// Ideal column widths are constants (they never depend on the table's measured width): a
    /// width-derived ideal compounds with NSTableView's column autoresizing on every resize and ran away
    /// to a NaN frame width during Window › Zoom (#129). Tiers only choose which columns show.
    /// Whether the visible columns overflow the table's visible width, so they need re-fitting (#129).
    /// Never true for a non-finite or empty available width (nothing sensible to fit to).
    public static func columnsOverflow(widths: [Double], spacing: Double, available: Double) -> Bool {
        guard available.isFinite, available > 0 else { return false }
        let total = widths.reduce(0, +) + spacing * Double(widths.count)
        guard total.isFinite else { return true }
        return total > available + 1
    }

    public static func idealWidth(_ column: SetupSourceColumn, scale: Double) -> Double {
        column.width(scale: scale)
    }
}
