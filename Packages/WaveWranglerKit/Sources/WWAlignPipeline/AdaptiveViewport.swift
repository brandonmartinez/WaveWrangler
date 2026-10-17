import WWCore

/// Direct source-frame coverage; no synthetic recorder epochs or clock maps.
enum AdaptiveViewport {
    static func ranges(
        _ correction: SourceTimingCorrection, source: SourceID, rate: Int, totalFrames: Int64,
        start: Double? = nil, end: Double? = nil
    ) throws -> [Range<Int64>] {
        guard correction.isValid, correction.source == source, correction.sourceRate == rate,
              correction.sourceFrames == totalFrames else { throw WaveformWindowError.mapDoesNotMatchSource }
        var result: [Range<Int64>] = []
        for segment in correction.segments {
            let firstTime = max(start ?? segment.alignedStart, segment.alignedStart)
            let lastTime = min(end ?? segment.alignedEnd, segment.alignedEnd)
            guard lastTime > firstTime else { continue }
            let firstSource = segment.sourceStart + (firstTime - segment.alignedStart) / segment.rateRatio
            let lastSource = segment.sourceStart + (lastTime - segment.alignedStart) / segment.rateRatio
            let lower = max(0, Int64((segment.sourceStart * Double(rate)).rounded(.up)),
                            Int64((firstSource * Double(rate)).rounded(start == nil ? .up : .down)))
            let upper = min(totalFrames, Int64((segment.sourceEnd * Double(rate)).rounded(.up)),
                            Int64((lastSource * Double(rate)).rounded(.up)))
            if lower < upper { result.append(lower..<upper) }
        }
        guard result.count <= WaveformWindowReader.maximumBins else { throw WaveformWindowError.overviewBudgetExceeded }
        for pair in zip(result, result.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            throw WaveformWindowError.mapDoesNotMatchSource
        }
        return result
    }
}
