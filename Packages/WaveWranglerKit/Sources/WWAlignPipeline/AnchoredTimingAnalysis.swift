import Foundation
import WWAutoAlign
import WWCore

enum AnchoredTimingAnalysis {
    static func run(
        timing: AdaptiveTimingResult, unit: AnalysisUnit, environment: PipelineEnvironment,
        reference: SpectralFingerprint, target: SpectralFingerprint,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> AdaptiveTimingResult {
        let slices = AnchoredTiming.searches(in: timing).flatMap { search in
            stride(from: search.sourceStart, to: search.sourceEnd, by: 12).map {
                (search: search, start: $0, end: min($0 + 12, search.sourceEnd))
            }
        }
        var observations: [AnchoredTimingObservation] = []
        func frames(_ start: Double, _ end: Double, _ facts: SourceFacts) -> Range<Int64> {
            let lo = max(0, Int64(floor(start * Double(facts.sampleRate))))
            let hi = max(lo, min(facts.frameCount, Int64(ceil(end * Double(facts.sampleRate)))))
            return lo..<hi
        }
        for batch in stride(from: 0, to: slices.count, by: 4) {
            try Task.checkCancellation()
            let group = Array(slices[batch..<min(batch + 4, slices.count)])
            let targetRanges = group.map { frames($0.start - 0.75, $0.end + 0.75, unit.targetFacts) }
            let referenceRanges = group.map {
                frames($0.start + min($0.search.leftOffset, $0.search.rightOffset) - 0.85,
                       $0.end + max($0.search.leftOffset, $0.search.rightOffset) + 0.85, unit.referenceFacts)
            }
            let targets = try await AutomaticAnalysis.buffers(
                unit.target, facts: unit.targetFacts, ranges: targetRanges, channel: unit.targetChannel,
                minimumRate: unit.configuration.minimumAnalysisRate, decoder: environment.decoder)
            let references = try await AutomaticAnalysis.buffers(
                unit.reference, facts: unit.referenceFacts, ranges: referenceRanges, channel: unit.referenceChannel,
                minimumRate: unit.configuration.minimumAnalysisRate, decoder: environment.decoder)
            for index in group.indices {
                let search = group[index].search
                let centers = Array(stride(from: group[index].start + 0.15, to: group[index].end - 0.149, by: 0.3))
                let hints = try AnchoredTiming.featureHints(search: search, centers: centers, reference: reference, target: target)
                let tp = try unit.participant(unit.targetGroup, unit.targetEpoch, unit.target, unit.targetFacts, range: targetRanges[index])
                let rp = try unit.participant(unit.referenceChoice.group, unit.referenceChoice.epoch,
                                              unit.reference, unit.referenceFacts, range: referenceRanges[index])
                observations += try AnchoredTiming.measure(search: search, centers: centers, hints: hints,
                    reference: unit.track(samples: references[index], participant: rp),
                    target: unit.track(samples: targets[index], participant: tp))
            }
            await progress(Double(batch + group.count) / Double(slices.count))
        }
        return try AnchoredTiming.recovering(timing, observations: observations)
    }
}
