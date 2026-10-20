import Foundation
import WWAlignEstimate
import WWAutoAlign
import WWDecode
import WWTimeMap

enum AutomaticAnalysis {
    static let estimatorIdentifier = AutomaticAlignment.identifier
    static let recipe = "[auto=ww-auto-align/4;fingerprint=ww-spectral-fingerprint/1;discovery=full-10Hz;passages=4s-3x16;fine=speech150-ncc-phat-bilateral-polarity-rate-sinc12-2s-9x16;fit=consensus-1ms-80%;decode=stream-index-sparse-refine-1]"

    static func run(unit: AnalysisUnit, environment: PipelineEnvironment) async throws(AlignmentWorkFailure) -> Data {
        do {
            guard unit.referenceFacts.frameCount > 0, unit.targetFacts.frameCount > 0,
                  unit.referenceFacts.frameCount <= Int64(unit.referenceFacts.sampleRate) * Int64(SpectralFingerprint.maximumSeconds),
                  unit.targetFacts.frameCount <= Int64(unit.targetFacts.sampleRate) * Int64(SpectralFingerprint.maximumSeconds) else {
                throw AlignEstimateError.invalidParameter("whole-track alignment supports channels up to two hours")
            }
            let chunks = 6 * unit.chunkFrames * max(unit.referenceFacts.channelCount, unit.targetFacts.channelCount) * MemoryLayout<Float>.size
            let referenceFactor = try AnalysisUnit.factor(unit.referenceFacts.sampleRate, unit.configuration.minimumAnalysisRate)
            let targetFactor = try AnalysisUnit.factor(unit.targetFacts.sampleRate, unit.configuration.minimumAnalysisRate)
            let maximumRate = max(
                unit.configuration.minimumAnalysisRate * 2,
                max(unit.referenceFacts.sampleRate / referenceFactor, unit.targetFacts.sampleRate / targetFactor)
            )
            // Both feature indexes, cached binary payloads, reusable reference spectra, candidate FFTs,
            // all sparse fine buffers and multichannel gateway chunks remain inside this single admission.
            let fineBytes = 48 * 10 * maximumRate * 4 + 10 * maximumRate * 32 + chunks
            let record = try await environment.gate.withAdmission(bytes: fineBytes + (160 << 20)) {
                try await analyze(unit: unit, environment: environment)
            }
            return try EpochAnalysisRecord.encode(record)
        } catch let error as AlignEstimateError {
            throw .estimator(error)
        } catch let error as TimeMapError {
            throw .estimator(.timeMap(error))
        } catch { throw workFailure(error) }
    }

    private static func analyze(unit: AnalysisUnit, environment: PipelineEnvironment) async throws -> EpochAnalysisRecord {
        let targetRate = Double(unit.targetFacts.sampleRate)
        let referenceRate = Double(unit.referenceFacts.sampleRate)
        let duration = Double(unit.targetFacts.frameCount) / targetRate
        let referenceDuration = Double(unit.referenceFacts.frameCount) / referenceRate
        var referenceParticipant = try unit.participant(
            unit.referenceChoice.group, unit.referenceChoice.epoch, unit.reference, unit.referenceFacts, range: unit.referenceRange
        )
        var targetParticipant = try unit.participant(
            unit.targetGroup, unit.targetEpoch, unit.target, unit.targetFacts, range: unit.targetRange
        )
        let referenceFingerprint = try await FingerprintAnalysis.load(
            source: unit.reference, facts: unit.referenceFacts, channel: unit.referenceChannel,
            minimumRate: unit.configuration.minimumAnalysisRate, environment: environment
        )
        let targetFingerprint = try await FingerprintAnalysis.load(
            source: unit.target, facts: unit.targetFacts, channel: unit.targetChannel,
            minimumRate: unit.configuration.minimumAnalysisRate, environment: environment
        )
        let plan = try FingerprintAlignment.plan(reference: referenceFingerprint, target: targetFingerprint)
        if let abstention = plan.abstention {
            var record = EpochAnalysisRecord(
                recipe: unit.recipe.name, reference: referenceParticipant, target: targetParticipant,
                search: unit.search, abstention: abstention.reason, detail: abstention.detail
            )
            record.estimator = AutomaticAlignment.identifier
            record.fingerprintSeconds = [referenceDuration, duration]
            record.coarseWindows = plan.evidence.map {
                WindowRecord(index: $0.station, groupClockCenter: $0.targetCenter, status: $0.status,
                             peakScore: $0.nccScore, secondPeakScore: $0.nccSecond, periodicityScore: 0,
                             offsetSeconds: $0.offsetSeconds, method: $0.method)
            }
            return record
        }
        let passages = plan.passages.sorted { $0.start < $1.start }
        let targetRanges = passages.map { passage in
            frames(passage.start, passage.start + 4, facts: unit.targetFacts)
        }
        let deviation = 0.35
        let referenceRanges = zip(targetRanges, passages).map { range, passage in
            frames(Double(range.lowerBound) / targetRate + passage.offset - deviation - 0.02,
                   Double(range.upperBound) / targetRate + passage.offset + deviation + 0.02, facts: unit.referenceFacts)
        }
        guard referenceRanges.allSatisfy({ !$0.isEmpty }) else {
            throw AlignEstimateError.invalidParameter("a distributed reference window is outside coverage")
        }
        var attempts: [DelayEvidence] = []
        if !passages.isEmpty {
            let targets = try await buffers(unit.target, facts: unit.targetFacts, ranges: targetRanges, channel: unit.targetChannel, minimumRate: unit.configuration.minimumAnalysisRate, decoder: environment.decoder)
            let references = try await buffers(unit.reference, facts: unit.referenceFacts, ranges: referenceRanges, channel: unit.referenceChannel, minimumRate: unit.configuration.minimumAnalysisRate, decoder: environment.decoder)
            for index in targetRanges.indices {
                try Task.checkCancellation()
                let tp = try unit.participant(unit.targetGroup, unit.targetEpoch, unit.target, unit.targetFacts, range: targetRanges[index])
                let rp = try unit.participant(unit.referenceChoice.group, unit.referenceChoice.epoch, unit.reference, unit.referenceFacts, range: referenceRanges[index])
                attempts += try AutomaticAlignment.measure(
                    reference: unit.track(samples: references[index], participant: rp),
                    target: unit.track(samples: targets[index], participant: tp), station: passages[index].station,
                    predictedOffset: passages[index].offset, deviation: deviation, rateRatio: plan.refinementRateRatio
                )
            }
            targetParticipant.excerptStartFrame = targetRanges.first!.lowerBound
            targetParticipant.excerptEndFrame = targetRanges.last!.upperBound
            referenceParticipant.excerptStartFrame = referenceRanges.map(\.lowerBound).min()!
            referenceParticipant.excerptEndFrame = referenceRanges.map(\.upperBound).max()!
        }
        let result = try AutomaticAlignment.finish(startSeconds: plan.start, endSeconds: plan.end, attempts: attempts,
                                                   expectedStations: plan.stations, sharedSilentStations: plan.sharedSilentStations)
        var record = EpochAnalysisRecord(recipe: unit.recipe.name, reference: referenceParticipant, target: targetParticipant,
                                        search: unit.search, automatic: result, coarse: plan.evidence)
        record.fingerprintSeconds = [referenceDuration, duration]
        record.refinementRatePPM = (plan.refinementRateRatio - 1) * 1e6
        return record
    }

    private static func frames(_ start: Double, _ end: Double, facts: SourceFacts) -> Range<Int64> {
        let lo = Int64(max(0, min(Double(facts.frameCount), ceil(start * Double(facts.sampleRate)))))
        let hi = max(lo, Int64(max(0, min(Double(facts.frameCount), floor(end * Double(facts.sampleRate))))))
        return lo..<hi
    }

    /// All sparse ranges share one revision-checked cursor. Seekable sources skip unrequested prefixes and
    /// gaps; other codecs stream once in source order. No range is padded to hide an incomplete decode.
    static func buffers(
        _ source: AlignmentSource, facts: SourceFacts, ranges: [Range<Int64>], channel: Int?,
        minimumRate: Int, decoder: SourceDecoder
    ) async throws -> [[Float]] {
        guard !ranges.isEmpty, ranges.allSatisfy({ !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= facts.frameCount }),
              channel.map({ $0 >= 0 && $0 < facts.channelCount }) ?? true else {
            throw AlignmentWorkFailure.sourceFactsMismatch
        }
        return try await decoder.withDecodingCursor(source.url, source: source.id) { cursor in
            let interpretation = cursor.interpretation
            try SourceProbe.verify(interpretation, source: source.id, token: facts.revisionToken, recorded: source.recordedFingerprint)
            guard interpretation.sourceSampleRate == facts.sampleRate,
                  interpretation.frames.validFrames == facts.frameCount,
                  interpretation.channelCount == facts.channelCount else { throw AlignmentWorkFailure.sourceFactsMismatch }
            var decimators = try ranges.map { try AnalysisDecimator(sourceRate: facts.sampleRate, minimumRate: minimumRate, range: $0, channel: channel) }
            let end = min(facts.frameCount, decimators.map { $0.neededInput.upperBound }.max()!)
            guard cursor.supportsRandomAccess || end <= Int64(facts.sampleRate) * 7200 else {
                throw AlignEstimateError.invalidParameter("non-seekable automatic analysis exceeds the two-hour sequential decode bound")
            }
            var position: Int64 = 0
            while position < end {
                try Task.checkCancellation()
                let next = decimators.filter { !$0.isComplete }.map { max(position, $0.neededInput.lowerBound) }.min() ?? end
                if cursor.supportsRandomAccess, next > position {
                    try await cursor.seek(toSourceFrame: next)
                    position = next
                }
                if position >= end { break }
                guard let chunk = try await cursor.next(upToSourceFrame: end) else {
                    throw AlignmentWorkFailure.sourceFactsMismatch
                }
                position = chunk.firstSourceFrame + Int64(chunk.frameCount)
                for index in decimators.indices where !decimators[index].isComplete
                    && chunk.firstSourceFrame < decimators[index].neededInput.upperBound
                    && position > decimators[index].neededInput.lowerBound {
                    decimators[index].consume(chunk)
                }
            }
            return decimators.indices.map { decimators[$0].finish() }
        }
    }
}
