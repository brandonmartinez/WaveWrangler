import WWCore
import WWTimeMap

enum WaveformViewport {
    static func overviewRanges(
        source: SourceID, rate: Int, totalFrames: Int64, groupMap: GroupTimeMap?
    ) throws -> [Range<Int64>] {
        guard rate > 0, totalFrames >= 0,
              Int128(totalFrames) <= Int128(rate) * Int128(WaveformWindowReader.maximumOverviewSourceSeconds)
        else { throw WaveformWindowError.overviewBudgetExceeded }
        guard let groupMap else { return totalFrames > 0 ? [0..<totalFrames] : [] }
        guard let placement = groupMap.placements.first(where: { $0.occurrence.source == source }),
              placement.occurrence.nominalRate.framesPerSecond == Int64(rate),
              placement.occurrence.frameCount == totalFrames
        else { throw WaveformWindowError.mapDoesNotMatchSource }
        let frequency = ExactRational(Int64(rate))
        var ranges: [Range<Int64>] = []
        for span in placement.spans {
            guard let epoch = groupMap.epochs.first(where: { $0.epoch == span.epoch }) else {
                throw WaveformWindowError.mapDoesNotMatchSource
            }
            switch epoch.mapping {
            case .unsupported:
                ranges.append(span.startFrame..<span.endFrame)
            case let .mapped(segments, _):
                for segment in segments {
                    // Whole-frame boundaries keep a coarse bin inside one affine segment.
                    append(
                        lower: try segment.groupClockStart.subtracting(span.groupClockOffset).multiplied(by: frequency).ceil(),
                        upper: try segment.groupClockEnd.subtracting(span.groupClockOffset).multiplied(by: frequency).ceil(),
                        span: span, to: &ranges
                    )
                }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        guard ranges.count <= WaveformWindowReader.maximumBins else {
            throw WaveformWindowError.overviewBudgetExceeded
        }
        for index in ranges.indices.dropFirst() where ranges[index].lowerBound < ranges[index - 1].upperBound {
            throw WaveformWindowError.mapDoesNotMatchSource
        }
        return ranges
    }

    static func verifyDecodeBudget(ranges: [Range<Int64>], rate: Int, randomAccess: Bool = false) throws {
        guard rate > 0,
              randomAccess || Int128(ranges.last?.upperBound ?? 0)
                <= Int128(rate) * Int128(WaveformWindowReader.maximumDecodedPrefixSeconds)
        else { throw WaveformWindowError.decodeBudgetExceeded }
    }

    static func frameRanges(
        source: SourceID, rate: Int, totalFrames: Int64, groupMap: GroupTimeMap?,
        startSeconds: Double, durationSeconds: Double
    ) throws -> [Range<Int64>] {
        guard startSeconds.isFinite, startSeconds >= 0, startSeconds <= 86_400,
              durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 30,
              rate > 0, totalFrames >= 0
        else { throw WaveformWindowError.invalidWindow }
        let start = try seconds(startSeconds)
        let end = try seconds(startSeconds + durationSeconds)
        let frequency = ExactRational(Int64(rate))
        guard let groupMap else {
            let lower = max(0, Int64(try start.multiplied(by: frequency).floor()))
            let upper = min(totalFrames, Int64(try end.multiplied(by: frequency).ceil()))
            return lower < upper ? [lower..<upper] : []
        }
        guard let placement = groupMap.placements.first(where: { $0.occurrence.source == source }),
              placement.occurrence.nominalRate.framesPerSecond == Int64(rate),
              placement.occurrence.frameCount == totalFrames
        else { throw WaveformWindowError.mapDoesNotMatchSource }
        var ranges: [Range<Int64>] = []
        for span in placement.spans {
            guard let epoch = groupMap.epochs.first(where: { $0.epoch == span.epoch }) else {
                throw WaveformWindowError.mapDoesNotMatchSource
            }
            switch epoch.mapping {
            case .unsupported:
                append(
                    lower: try start.multiplied(by: frequency).floor(),
                    upper: try end.multiplied(by: frequency).ceil(), span: span, to: &ranges
                )
            case let .mapped(segments, _):
                for segment in segments {
                    let u0 = max(
                        segment.groupClockStart,
                        try start.subtracting(segment.alignedOffset).divided(by: segment.rateRatio)
                    )
                    let u1 = min(
                        segment.groupClockEnd,
                        try end.subtracting(segment.alignedOffset).divided(by: segment.rateRatio)
                    )
                    guard u0 < u1 else { continue }
                    append(
                        lower: try u0.subtracting(span.groupClockOffset).multiplied(by: frequency).floor(),
                        upper: try u1.subtracting(span.groupClockOffset).multiplied(by: frequency).ceil(),
                        span: span, to: &ranges
                    )
                }
            }
        }
        var merged: [Range<Int64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        // A positive clock ratio can expand a 30-second viewport to 60 source seconds.
        guard merged.count <= WaveformWindowReader.maximumBins,
              merged.reduce(Int64(0), { $0 + Int64($1.count) }) <= Int64(rate) * 60 + Int64(merged.count * 2)
        else { throw WaveformWindowError.invalidWindow }
        return merged
    }

    private static func append(
        lower: Int128, upper: Int128, span: EpochSpan, to ranges: inout [Range<Int64>]
    ) {
        let first = max(Int128(span.startFrame), lower)
        let last = min(Int128(span.endFrame), upper)
        if first < last { ranges.append(Int64(first)..<Int64(last)) }
    }

    private static func seconds(_ value: Double) throws -> ExactRational {
        try ExactRational(numerator: Int128((value * 1_000_000_000).rounded()), denominator: 1_000_000_000)
    }
}
