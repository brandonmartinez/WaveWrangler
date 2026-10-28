import SwiftUI
import WWCore

struct AudioTimelineWordIndex: Sendable {
    let words: [TranscriptWord]
    let averageDuration: Double
    private let maximumEnds: [Double]

    init(words: [TranscriptWord], cuts: ManualCutTimeline = .unedited,
         sourceBounds: ClosedRange<Double>? = nil) {
        let timed = words.enumerated().compactMap { offset, word -> (Int, TranscriptWord)? in
            guard let start = word.alignedStart, let end = word.alignedEnd,
                  start.isFinite, end.isFinite, end > start, (end - start).isFinite else { return nil }
            if let sourceBounds, end <= sourceBounds.lowerBound || start >= sourceBounds.upperBound { return nil }
            var projected = word
            projected.alignedStart = cuts.editedTime(forAlignedTime: start)
            projected.alignedEnd = cuts.editedTime(forAlignedTime: end)
            guard let lo = projected.alignedStart, let hi = projected.alignedEnd, hi > lo else { return nil }
            return (offset, projected)
        }.sorted {
            let a = $0.1.alignedStart ?? 0, b = $1.1.alignedStart ?? 0
            return a == b ? $0.0 < $1.0 : a < b
        }.map(\.1)
        self.words = timed
        averageDuration = timed.isEmpty ? 0 : timed.reduce(0) {
            $0 + (($1.alignedEnd ?? 0) - ($1.alignedStart ?? 0)) / Double(timed.count)
        }
        var latest = -Double.infinity
        maximumEnds = timed.map {
            latest = max(latest, $0.alignedEnd ?? latest)
            return latest
        }
    }

    func visible(start: Double, end: Double) -> [TranscriptWord] {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if maximumEnds[mid] <= start { lo = mid + 1 } else { hi = mid }
        }
        let first = lo
        hi = words.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if (words[mid].alignedStart ?? .infinity) < end { lo = mid + 1 } else { hi = mid }
        }
        return words[first..<lo].filter { ($0.alignedEnd ?? -.infinity) > start }
    }

    @concurrent
    static func prepare(words: [TranscriptWord], cuts: ManualCutTimeline,
                        sourceBounds: ClosedRange<Double>? = nil) async -> Self {
        Self(words: words, cuts: cuts, sourceBounds: sourceBounds)
    }
}

struct AudioTimelineWordLayout: Equatable {
    enum Detail: Int {
        case hidden, sentence, phrase, word, timing

        var title: String {
            switch self {
            case .hidden: "Hidden"
            case .sentence: "Sentences"
            case .phrase: "Phrases"
            case .word: "Words"
            case .timing: "Words with timing markers"
            }
        }
    }

    struct Placement: Identifiable, Equatable {
        let words: [TranscriptWord]
        let x: Double
        let width: Double
        let labelWidth: Double
        let text: String
        var word: TranscriptWord { words[0] }
        var id: UUID { word.id }
        var row: Int { 0 }
        var showsLabel: Bool { !text.isEmpty }
    }

    let placements: [Placement]
    let densityRanges: [Range<Double>]
    let uncertainRanges: [Range<Double>]
    let wordCount: Int
    let detail: Detail
    var isDense: Bool { detail == .hidden }
    var height: Double { 24 }

    static func make(words: [TranscriptWord], start: Double, duration: Double, width: Double,
                     uncertainWordIDs: Set<UUID> = []) -> Self {
        make(index: AudioTimelineWordIndex(words: words), start: start, duration: duration, width: width,
             uncertainWordIDs: uncertainWordIDs)
    }

    static func make(index: AudioTimelineWordIndex, start: Double, duration: Double, width: Double,
                     uncertainWordIDs: Set<UUID> = []) -> Self {
        let empty = Self(placements: [], densityRanges: [], uncertainRanges: [], wordCount: 0, detail: .hidden)
        guard start.isFinite, duration.isFinite, duration > 0, (start + duration).isFinite,
              width.isFinite, width > 0 else { return empty }
        let visible = index.visible(start: start, end: start + duration)
        guard !visible.isEmpty else { return empty }
        func coordinates(start lower: Double, end upper: Double) -> (x: Double, width: Double) {
            let lo = max(0, (lower - start) / duration * width)
            let hi = min(width, (upper - start) / duration * width)
            return (lo, max(0, hi - lo))
        }
        func coordinates(_ words: [TranscriptWord]) -> (x: Double, width: Double) {
            var lower: Double?, upper: Double?
            for word in words {
                if let time = word.alignedStart { lower = min(lower ?? time, time) }
                if let time = word.alignedEnd { upper = max(upper ?? time, time) }
            }
            return coordinates(start: lower ?? start, end: upper ?? start)
        }
        func coverage(_ words: [TranscriptWord]) -> [Range<Double>] {
            var result: [Range<Double>] = []
            for word in words {
                let span = coordinates(start: word.alignedStart ?? start, end: word.alignedEnd ?? start)
                let lo = floor(span.x), hi = min(width, max(lo + 1, ceil(span.x + span.width)))
                if let last = result.last, lo <= last.upperBound {
                    result[result.count - 1] = last.lowerBound..<max(last.upperBound, hi)
                } else { result.append(lo..<hi) }
            }
            return result
        }
        let pixelsPerSecond = width / duration
        let wordWidth = index.averageDuration * pixelsPerSecond
        let detail: Detail = pixelsPerSecond < 8 || wordWidth < 4 ? .hidden
            : wordWidth < 16 ? .sentence : wordWidth < 40 ? .phrase
            : wordWidth < 80 ? .word : .timing
        let uncertain = coverage(visible.filter { uncertainWordIDs.contains($0.id) })
        if detail == .hidden {
            return Self(placements: [], densityRanges: coverage(visible), uncertainRanges: uncertain,
                        wordCount: visible.count, detail: detail)
        }
        var units: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in visible {
            if let last = current.last, let end = last.alignedEnd, let next = word.alignedStart,
               next - end > 1.2 {
                units.append(current)
                current = []
            }
            current.append(word)
            let ending = word.text.last { !$0.isWhitespace && !"\"')]}".contains($0) }
            let punctuation = ending.map { ".!?".contains($0) } == true
            let phraseBoundary = ending.map { ",;:".contains($0) } == true
            if detail.rawValue >= Detail.word.rawValue || punctuation
                || (detail == .phrase && (current.count >= 5 || phraseBoundary)) {
                units.append(current)
                current = []
            }
        }
        if !current.isEmpty { units.append(current) }
        let spans = units.map(coordinates)
        let placements = units.enumerated().map { index, unit in
            let span = spans[index]
            let nextStart = index + 1 < spans.count ? spans[index + 1].x : width
            let labelWidth = min(span.width, max(0, nextStart - span.x))
            return Placement(words: unit, x: span.x, width: span.width, labelWidth: labelWidth,
                             text: abbreviated(unit.map(\.text), capacity: max(0, Int((labelWidth - 6) / 6))))
        }
        return Self(placements: placements, densityRanges: [], uncertainRanges: uncertain,
                    wordCount: visible.count, detail: detail)
    }

    static func abbreviated(_ words: [String], capacity: Int) -> String {
        let full = words.joined(separator: " ")
        if full.count <= capacity { return full }
        guard capacity >= 3, let first = words.first, let last = words.last else { return "" }
        if words.count == 1 { return String(first.prefix(max(0, capacity - 1))) + "…" }
        var opening = [first], ending = [last]
        guard (first + " … " + last).count <= capacity else {
            return first.count + 2 <= capacity ? first + " …" : "…"
        }
        var lo = 1, hi = words.count - 2
        while lo <= hi {
            let next = opening.joined(separator: " ") + " " + words[lo] + " … " + ending.joined(separator: " ")
            guard next.count <= capacity else { break }
            opening.append(words[lo])
            lo += 1
            if lo <= hi {
                let tail = opening.joined(separator: " ") + " … " + words[hi] + " " + ending.joined(separator: " ")
                if tail.count <= capacity { ending.insert(words[hi], at: 0); hi -= 1 }
            }
        }
        return opening.joined(separator: " ") + " … " + ending.joined(separator: " ")
    }
}

@MainActor
final class AudioTimelineWordLayoutCache {
    private struct Request: Equatable {
        let start: Double
        let duration: Double
        let width: Double
        let uncertainWordIDs: Set<UUID>
    }

    private let index: AudioTimelineWordIndex
    private var prepared: (request: Request, layout: AudioTimelineWordLayout)?
    private(set) var preparationCount = 0

    init(index: AudioTimelineWordIndex) { self.index = index }

    func layout(start: Double, duration: Double, width: Double,
                uncertainWordIDs: Set<UUID> = []) -> AudioTimelineWordLayout {
        let request = Request(start: start, duration: duration, width: width, uncertainWordIDs: uncertainWordIDs)
        if let prepared, prepared.request == request { return prepared.layout }
        let layout = AudioTimelineWordLayout.make(index: index, start: start, duration: duration,
            width: width, uncertainWordIDs: uncertainWordIDs)
        preparationCount += 1
        prepared = (request, layout)
        return layout
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
    var cuts: ManualCutTimeline = .unedited
    var sourceBounds: ClosedRange<Double>? = nil
    var selectUnit: (([TranscriptWord]) -> Void)? = nil
    @State private var availableWidth = 0.0
    private struct Input: Equatable {
        let words: [TranscriptWord]
        let cuts: ManualCutTimeline
        let sourceBounds: ClosedRange<Double>?
    }
    @State private var prepared: (input: Input, cache: AudioTimelineWordLayoutCache)?

    var body: some View {
        let input = Input(words: words, cuts: cuts, sourceBounds: sourceBounds)
        let layout = layout(for: input)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(layout.placements) { item in
                    unitButton(item, detail: layout.detail)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(height: layout.height)
        .contentShape(Rectangle())
        .onGeometryChange(for: Double.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: input) {
            let index = await AudioTimelineWordIndex.prepare(
                words: input.words, cuts: input.cuts, sourceBounds: input.sourceBounds)
            guard !Task.isCancelled else { return }
            prepared = (input, AudioTimelineWordLayoutCache(index: index))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.transcript.timeline")
        .accessibilityLabel("Timeline transcript: \(layout.detail.title)."
            + (layout.isDense ? " Read the full transcript in the inspector." : ""))
    }

    private func layout(for input: Input) -> AudioTimelineWordLayout {
        if let prepared, prepared.input == input {
            return prepared.cache.layout(start: start, duration: duration, width: availableWidth,
                uncertainWordIDs: uncertainWordIDs)
        }
        let index = AudioTimelineWordIndex(words: words.count <= 512 ? words : [], cuts: cuts, sourceBounds: sourceBounds)
        return AudioTimelineWordLayout.make(index: index, start: start, duration: duration,
            width: availableWidth, uncertainWordIDs: uncertainWordIDs)
    }

    private func unitButton(_ item: AudioTimelineWordLayout.Placement,
                            detail: AudioTimelineWordLayout.Detail) -> some View {
        let uncertain = item.words.contains { uncertainWordIDs.contains($0.id) }
        let selected = item.words.contains { $0.id == selectedWord }
        let fill: Color = uncertain ? .orange.opacity(0.2)
            : selected ? .accentColor.opacity(0.3) : .secondary.opacity(0.1)
        let marker: Color = uncertain ? .orange : .primary.opacity(0.55)
        let text = item.words.map(\.text).joined(separator: " ")
        let interval = String(format: "Approximate aligned interval %.3f to %.3f seconds%@",
            item.words.compactMap(\.alignedStart).min() ?? start,
            item.words.compactMap(\.alignedEnd).max() ?? start,
            uncertain ? ". Uncertain repetitive recognition; listen to verify." : "")
        return Button {
            let ids = Set(item.words.map(\.id))
            let originals = words.filter { ids.contains($0.id) }
            if let selectUnit { selectUnit(originals) }
            else if let first = originals.first { select(first) }
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
                .overlay {
                    if uncertain {
                        RoundedRectangle(cornerRadius: 3).stroke(Color.orange, lineWidth: 1)
                    }
                    if detail == .timing {
                        timingMarkers(for: item).stroke(marker, lineWidth: 1)
                    }
                }
                .overlay(alignment: .leading) {
                    Text(item.text).font(.system(size: 11)).lineLimit(1)
                        .padding(.horizontal, 3)
                        .frame(width: item.labelWidth, height: 21, alignment: .leading)
                        .clipped()
                }
                .frame(width: max(0.5, item.width), height: 21)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).offset(x: item.x)
        .help("Approximate recognition timing, not a cut boundary. " + text)
        .accessibilityLabel(text)
        .accessibilityValue(detail.title + ". " + interval)
        .accessibilityIdentifier("ww.cleanup.word.\(item.id)")
    }

    private func timingMarkers(for item: AudioTimelineWordLayout.Placement) -> Path {
        let right = CGFloat(max(0.5, item.width - 0.5))
        let lower = item.words.compactMap(\.alignedStart).min() ?? start
        let upper = item.words.compactMap(\.alignedEnd).max() ?? start + duration
        return Path { path in
            if lower >= start {
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: 20.5))
            }
            path.move(to: CGPoint(x: 0.5, y: 20.5))
            path.addLine(to: CGPoint(x: right, y: 20.5))
            if upper <= start + duration {
                path.move(to: CGPoint(x: right, y: 20.5))
                path.addLine(to: CGPoint(x: right, y: 0))
            }
        }
    }
}
