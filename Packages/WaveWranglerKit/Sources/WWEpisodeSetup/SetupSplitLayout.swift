import Foundation

/// Heights of the stacked Sources and Speakers tables (IA §4.3: stacked, resizable; default sizes must
/// be usable without dragging). Minimums keep the section header, column header and several rows
/// visible in each table, and scale with the in-app text size.
public enum SetupSplitLayout {
    public static let defaultSpeakersFraction = 0.4
    public static let fractionRange = 0.15...0.85
    /// Base heights at 100% text: section header row with its padding, table column header, one row.
    static let sectionHeader = 48.0
    static let columnHeader = 28.0
    static let row = 24.0

    public static func minimumSpeakersHeight(scale: Double) -> Double {
        (sectionHeader + columnHeader + 5 * row) * scale
    }

    public static func minimumSourcesHeight(scale: Double) -> Double {
        (sectionHeader + columnHeader + 4 * row) * scale
    }

    /// Splits `total` (excluding the handle). The Speakers share follows `speakersFraction` but never goes
    /// below its minimum or leaves Sources below its minimum; when both minimums don't fit, the space is
    /// shared in proportion to them (each table then scrolls).
    public static func heights(total: Double, scale: Double, speakersFraction: Double) -> (sources: Double, speakers: Double) {
        let total = max(total, 0)
        let minSpeakers = minimumSpeakersHeight(scale: scale)
        let minSources = minimumSourcesHeight(scale: scale)
        guard total >= minSpeakers + minSources else {
            let speakers = (total * minSpeakers / (minSpeakers + minSources)).rounded(.down)
            return (total - speakers, speakers)
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
