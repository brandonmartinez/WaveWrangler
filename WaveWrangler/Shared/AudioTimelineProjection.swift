import Foundation
import WWCommonEdit
import WWCore

/// Immutable presentation geometry only. Clip placement, track names, selection and live controls
/// are deliberately absent so they cannot invalidate static dialogue/word/marker geometry.
struct AudioTimelineProjection: Sendable, Equatable {
    static let unedited = AudioTimelineProjection()
    let cuts: ManualCutTimeline
    var removals: [Range<Int64>] { cuts.removals }
    private let canonicalCuts: ManualCutTimeline
    private let dialogue: [ProgramDialogueSpan]
    private let insertions: [ProgramInsertion]
    private let usesProgram: Bool
    private struct Opening: Sendable, Equatable {
        let original: Range<Int64>
        let programSeam: Int64
        let displayStart: Int64
    }
    private let openings: [Opening]

    init(cuts: ManualCutTimeline = .unedited, program: ProgramTimeline? = nil, expanded: ManualEpisodeCut? = nil) {
        self.cuts = cuts
        canonicalCuts = program?.cuts ?? cuts
        dialogue = program?.dialogueSpans ?? []
        insertions = program?.insertions ?? []
        usesProgram = program != nil
        var restored: [Range<Int64>] = []
        if let program, expanded != nil {
            for removal in program.cuts.removals {
                var cursor = removal.lowerBound
                for keptCut in cuts.removals where keptCut.upperBound > cursor && keptCut.lowerBound < removal.upperBound {
                    if cursor < keptCut.lowerBound { restored.append(cursor..<min(keptCut.lowerBound, removal.upperBound)) }
                    cursor = max(cursor, keptCut.upperBound)
                }
                if cursor < removal.upperBound { restored.append(cursor..<removal.upperBound) }
            }
        }
        var offset: Int64 = 0
        openings = restored.map { original in
            let base = (program?.cuts ?? cuts).editedFrame(forAlignedFrame: original.lowerBound)
            let seam = base + (program?.insertions ?? []).filter { $0.baseFrame <= base }
                .reduce(0) { $0 + $1.region.durationFrames }
            let opening = Opening(original: original, programSeam: seam, displayStart: seam + offset)
            offset += Int64(original.count)
            return opening
        }
    }

    var hasInsertions: Bool { !insertions.isEmpty }
    var hasExpandedCut: Bool { !openings.isEmpty }
    var reviewOnlyDisplayRanges: [Range<Double>] {
        openings.map {
            let start = Double($0.displayStart) / 48_000
            return start..<(start + Double($0.original.count) / 48_000)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cuts == rhs.cuts && lhs.canonicalCuts == rhs.canonicalCuts && lhs.dialogue == rhs.dialogue
            && lhs.insertions == rhs.insertions && lhs.usesProgram == rhs.usesProgram
            && lhs.openings == rhs.openings
    }

    func editedTime(forAlignedTime time: Double) -> Double {
        forward(time, followingInsertions: true)
    }

    private func forward(_ time: Double, followingInsertions: Bool) -> Double {
        guard usesProgram else { return cuts.editedTime(forAlignedTime: time) }
        let base = canonicalCuts.editedTime(forAlignedTime: time)
        let restoredEndpoint = openings.contains {
            time > Double($0.original.lowerBound) / 48_000 && time <= Double($0.original.upperBound) / 48_000
        }
        let shift = insertions.filter {
            let boundary = Double($0.baseFrame) / 48_000
            return followingInsertions || restoredEndpoint ? boundary <= base : boundary < base
        }.reduce(0) { $0 + Double($1.region.durationFrames) / 48_000 }
        return cuts.editedTime(forAlignedTime: time) + shift
    }

    func displayTime(forProgramTime time: Double) -> Double {
        time + openings.filter { time >= Double($0.programSeam) / 48_000 }
            .reduce(0) { $0 + Double($1.original.count) / 48_000 }
    }

    /// Expanded removed audio has no production coordinate; insertion-only program time has no
    /// recorder inverse. Neither refusal may be used as an alignment anchor or a saved clip position.
    func programTime(forDisplayTime time: Double) -> Double? {
        guard time.isFinite else { return nil }
        var removed = 0.0
        for opening in openings {
            let start = Double(opening.displayStart) / 48_000
            let duration = Double(opening.original.count) / 48_000
            if time >= start, time < start + duration { return nil }
            if time >= start + duration { removed += duration }
        }
        return time - removed
    }

    /// Keep a cursor inside a retained region, or clamp a removed offset to its new seam.
    /// This is presentation state only, including Show cut's separate display offsets.
    func reprojectInsertedDisplayTime(_ time: Double, to next: Self) -> Double? {
        guard let program = programTime(forDisplayTime: time),
              let index = insertions.firstIndex(where: {
                  program >= Double($0.programFrames.lowerBound) / 48_000
                      && program < Double($0.programFrames.upperBound) / 48_000
              }) else { return nil }
        let prior = insertions[index]
        let offset = program - Double(prior.programFrames.lowerBound) / 48_000
        let destination: Double
        if let retained = next.insertions.first(where: { $0.region.id == prior.region.id }) {
            destination = Double(retained.programFrames.lowerBound) / 48_000
                + min(offset, Double(retained.region.durationFrames) / 48_000)
        } else {
            let base: Int64
            switch prior.region.anchor {
            case .dialogue(let anchor): base = next.canonicalCuts.editedFrame(forAlignedFrame: anchor.frame)
            case .programOrigin(let frame): base = frame
            case .absolute, .insertion: return nil
            }
            let preceding = Set(insertions.prefix(index).map(\.region.id))
            let inserted = next.insertions.filter {
                $0.baseFrame < base || $0.baseFrame == base && preceding.contains($0.region.id)
            }.reduce(0.0) { $0 + Double($1.region.durationFrames) / 48_000 }
            destination = Double(base) / 48_000 + inserted
        }
        return next.displayTime(forProgramTime: destination)
    }

    func originalTime(forDisplayTime time: Double) -> Double? {
        guard time.isFinite, abs(time) <= 172_800 else { return nil }
        guard usesProgram else { return cuts.alignedTime(forEditedTime: time) }
        if let opening = openings.first(where: {
            time >= Double($0.displayStart) / 48_000
                && time < Double($0.displayStart + Int64($0.original.count)) / 48_000
        }) {
            return Double(opening.original.lowerBound) / 48_000 + time - Double(opening.displayStart) / 48_000
        }
        guard let program = programTime(forDisplayTime: time) else { return nil }
        let frame = program * 48_000
        guard let span = dialogue.first(where: {
            frame >= Double($0.programFrames.lowerBound) && frame < Double($0.programFrames.upperBound)
        }) else {
            if let last = dialogue.last, frame == Double(last.programFrames.upperBound) {
                return Double(last.originalFrames.upperBound) / 48_000
            }
            return nil
        }
        return Double(span.originalFrames.lowerBound) / 48_000
            + program - Double(span.programFrames.lowerBound) / 48_000
    }

    /// The upper bound of a half-open dialogue selection belongs to the preceding dialogue,
    /// not the insertion or removed interval that starts there. This is not a sample inverse.
    func originalTime(forExclusiveDisplayEnd time: Double) -> Double? {
        guard time.isFinite, abs(time) <= 172_800 else { return nil }
        guard usesProgram else {
            var removed = 0.0
            for removal in cuts.removals {
                if time <= Double(removal.lowerBound) / 48_000 - removed { break }
                removed += Double(removal.count) / 48_000
            }
            return time + removed
        }
        var program = time
        for opening in openings {
            let start = Double(opening.displayStart) / 48_000
            let end = start + Double(opening.original.count) / 48_000
            if time > start, time <= end { return nil }
            if time > end { program -= Double(opening.original.count) / 48_000 }
        }
        let frame = program * 48_000
        guard let span = dialogue.last(where: {
            frame > Double($0.programFrames.lowerBound) && frame <= Double($0.programFrames.upperBound)
        }) else { return nil }
        return Double(span.originalFrames.lowerBound) / 48_000
            + program - Double(span.programFrames.lowerBound) / 48_000
    }

    func alignedTime(forEditedTime time: Double) -> Double {
        originalTime(forDisplayTime: time) ?? .nan
    }

    func keptAlignedRanges(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        originalRanges(in: range)
    }

    struct Segment: Sendable {
        let aligned: Range<Int64>
        let displayed: Range<Int64>
    }

    func alignedSegments(forDisplayFrames frames: Range<Int64>, includingExpandedCuts: Bool = true) -> [Segment] {
        guard usesProgram else {
            var cursor = frames.lowerBound
            return cuts.alignedRanges(forEditedFrames: frames).map {
                let display = cursor..<(cursor + Int64($0.count))
                cursor = display.upperBound
                return Segment(aligned: $0, displayed: display)
            }
        }
        var result: [Segment] = []
        for span in dialogue {
            let start = Int64((displayTime(forProgramTime: Double(span.programFrames.lowerBound) / 48_000) * 48_000).rounded())
            let end = start + Int64(span.programFrames.count)
            let lo = max(start, frames.lowerBound), hi = min(end, frames.upperBound)
            if lo < hi {
                let original = span.originalFrames.lowerBound + lo - start
                result.append(.init(aligned: original..<(original + hi - lo), displayed: lo..<hi))
            }
        }
        for opening in openings where includingExpandedCuts {
            let seam = opening.displayStart
            let lo = max(seam, frames.lowerBound), hi = min(seam + Int64(opening.original.count), frames.upperBound)
            if lo < hi {
                let original = opening.original.lowerBound + lo - seam
                result.append(.init(aligned: original..<(original + hi - lo), displayed: lo..<hi))
            }
        }
        return result.sorted { $0.displayed.lowerBound < $1.displayed.lowerBound }
    }

    func originalRanges(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let boundaries = dialogue.flatMap { [Double($0.originalFrames.lowerBound) / 48_000,
                                             Double($0.originalFrames.upperBound) / 48_000] }
        return cuts.keptAlignedRanges(in: range).flatMap { kept in
            let splits = [kept.lowerBound] + boundaries.filter { $0 > kept.lowerBound && $0 < kept.upperBound }.sorted()
                + [kept.upperBound]
            return zip(splits, splits.dropFirst()).map { $0...$1 }
        }
    }

    func displayRange(forOriginalRange range: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = forward(range.lowerBound, followingInsertions: true)
        let hi = max(lo, forward(range.upperBound, followingInsertions: false))
        return lo...hi
    }

    func project(_ strokes: [AlignmentWaveformStroke]) -> [AlignmentWaveformStroke] {
        strokes.flatMap { stroke in
            guard stroke.mapped else { return [stroke] }
            return originalRanges(in: stroke.displayRange).map { span in
                let full = stroke.displayRange.upperBound - stroke.displayRange.lowerBound
                let scale = full > 0 ? (stroke.groupRange.upperBound - stroke.groupRange.lowerBound) / full : 0
                let groupStart = stroke.groupRange.lowerBound + (span.lowerBound - stroke.displayRange.lowerBound) * scale
                let groupEnd = stroke.groupRange.lowerBound + (span.upperBound - stroke.displayRange.lowerBound) * scale
                let source = stroke.sourceSeconds + (groupStart + groupEnd) / 2 - stroke.groupSeconds
                let display = displayRange(forOriginalRange: span)
                return AlignmentWaveformStroke(sourceSeconds: source,
                    groupSeconds: (groupStart + groupEnd) / 2,
                    displaySeconds: (display.lowerBound + display.upperBound) / 2,
                    low: stroke.low, high: stroke.high, mapped: true, epoch: stroke.epoch,
                    displayRange: display, groupRange: groupStart...groupEnd)
            }
        }
    }
}
