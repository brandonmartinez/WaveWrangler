import SwiftUI
import WWCore

struct AudioTimelineWordLayout {
    struct Placement: Identifiable {
        let word: TranscriptWord
        let x: Double
        let width: Double
        let row: Int
        let labelWidth: Double
        let showsLabel: Bool
        var id: UUID { word.id }
    }

    let placements: [Placement]
    let densityRanges: [Range<Double>]
    let uncertainRanges: [Range<Double>]
    let wordCount: Int
    let isDense: Bool
    var height: Double {
        isDense ? 28 : Double((placements.map(\.row).max() ?? 0) + 1) * 24
    }

    static func make(words: [TranscriptWord], start: Double, duration: Double, width: Double,
                     uncertainWordIDs: Set<UUID> = [])
        -> Self
    {
        guard start.isFinite, duration.isFinite, duration > 0, (start + duration).isFinite,
            width.isFinite, width > 0
        else {
            return Self(placements: [], densityRanges: [], uncertainRanges: [], wordCount: 0, isDense: false)
        }
        let spans = words.compactMap { word -> (word: TranscriptWord, x: Double, width: Double)? in
            guard let a = word.alignedStart, let b = word.alignedEnd,
                a.isFinite, b.isFinite, b > a, b > start, a < start + duration
            else { return nil }
            let x = max(0, (a - start) / duration * width)
            let end = min(width, (b - start) / duration * width)
            return (word, x, max(0, end - x))
        }.sorted { $0.x == $1.x ? $0.word.id.uuidString < $1.word.id.uuidString : $0.x < $1.x }
        func coverage(_ spans: [(word: TranscriptWord, x: Double, width: Double)]) -> [Range<Double>] {
            var ranges: [Range<Double>] = []
            for span in spans {
                let lower = floor(span.x)
                let upper = min(width, max(lower + 1, ceil(span.x + span.width)))
                if let last = ranges.last, lower <= last.upperBound {
                    ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
                } else {
                    ranges.append(lower..<upper)
                }
            }
            return ranges
        }
        let uncertain = coverage(spans.filter { uncertainWordIDs.contains($0.word.id) })
        let dense = spans.count > max(1, Int(min(2_100, width) / 7))
        if dense {
            return Self(
                placements: [], densityRanges: coverage(spans), uncertainRanges: uncertain,
                wordCount: spans.count, isDense: true)
        }
        var occupiedUntil = [Double](repeating: -.infinity, count: 3)
        let placements = spans.map { span in
            let available = occupiedUntil.firstIndex { $0 <= span.x }
            let row =
                available ?? occupiedUntil.enumerated().min(by: { $0.element < $1.element })!.offset
            let labelWidth = min(
                width - span.x, 180, max(24, Double(span.word.text.utf16.count) * 7 + 8, span.width)
            )
            if available != nil { occupiedUntil[row] = span.x + labelWidth + 3 }
            return Placement(
                word: span.word, x: span.x, width: span.width,
                row: row, labelWidth: labelWidth, showsLabel: available != nil)
        }
        return Self(
            placements: placements, densityRanges: [], uncertainRanges: uncertain,
            wordCount: spans.count, isDense: false)
    }
}

struct AudioTimelineWords: View {
    let words: [TranscriptWord]
    let start: Double
    let duration: Double
    let selectedWord: UUID?
    let select: (TranscriptWord) -> Void
    let zoom: (Double) -> Void
    var uncertainWordIDs: Set<UUID> = []
    @State private var availableWidth = 0.0

    var body: some View {
        let layout = AudioTimelineWordLayout.make(
            words: words, start: start, duration: duration, width: availableWidth,
            uncertainWordIDs: uncertainWordIDs)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if layout.isDense {
                    Canvas { context, _ in
                        for range in layout.densityRanges {
                            context.fill(
                                Path(
                                    CGRect(
                                        x: range.lowerBound, y: 0,
                                        width: range.upperBound - range.lowerBound, height: 5)),
                                with: .color(.accentColor.opacity(0.6)))
                        }
                        for range in layout.uncertainRanges {
                            context.fill(Path(CGRect(x: range.lowerBound, y: 0,
                                width: range.upperBound - range.lowerBound, height: 5)),
                                with: .color(.orange))
                        }
                    }
                    .allowsHitTesting(false)
                    Label(
                        "Zoom in to read \(layout.wordCount) timed words",
                        systemImage: "plus.magnifyingglass"
                    )
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 9)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { point in
                            zoom(
                                start + max(0, min(1, point.x / max(1, geometry.size.width)))
                                    * duration)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(layout.uncertainRanges.isEmpty
                            ? "Word timing overview. Zoom in to read words."
                            : "Word timing overview contains uncertain repetitive recognition. Zoom in to review.")
                        .accessibilityAction { zoom(start + duration / 2) }
                        .accessibilityIdentifier("ww.cleanup.words.density")
                } else {
                    ForEach(layout.placements) { item in
                        let uncertain = uncertainWordIDs.contains(item.id)
                        Button {
                            select(item.word)
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    uncertain ? Color.orange.opacity(item.word.id == selectedWord ? 0.4 : 0.2)
                                    : item.word.id == selectedWord
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.secondary.opacity(0.12)
                                )
                                .frame(
                                    width: max(0.5, item.width), height: item.showsLabel ? 21 : 4
                                )
                                .overlay {
                                    if uncertain {
                                        RoundedRectangle(cornerRadius: 2).stroke(Color.orange, lineWidth: 1)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    if item.showsLabel {
                                        Text(item.word.text)
                                            .font(.system(size: 11, design: .monospaced))
                                            .lineLimit(1)
                                            .padding(.leading, 2)
                                            .frame(
                                                width: item.labelWidth, height: 21,
                                                alignment: .leading
                                            )
                                            .clipped()
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .offset(x: item.x, y: Double(item.row) * 24)
                        .help(
                            uncertain
                                ? "\(item.word.text) · uncertain repetitive recognition; listen to verify. Raw text preserved."
                                : "\(item.word.text) · approximate recognizer timing, not a cut boundary"
                        )
                        .accessibilityLabel(
                            "\(item.word.text), approximately \(String(format: "%.3f", item.word.alignedStart ?? start)) aligned seconds"
                        )
                        .accessibilityValue(
                            (uncertain ? "Uncertain repetitive recognition. " : "") + String(
                                format: "Approximate aligned interval %.6f to %.6f seconds",
                                item.word.alignedStart ?? start, item.word.alignedEnd ?? start)
                        )
                        .accessibilityIdentifier("ww.cleanup.word.\(item.id)")
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(height: layout.height)
        .onGeometryChange(for: Double.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
    }
}
