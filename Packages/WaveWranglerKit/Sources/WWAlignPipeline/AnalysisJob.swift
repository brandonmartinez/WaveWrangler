import Foundation
import WWAlignEstimate
import WWCore
import WWDecode
import WWDerived
import WWTimeMap

/// The dependencies every pipeline job shares.
struct PipelineEnvironment: Sendable {
    let coordinator: DerivedJobCoordinator
    let decoder: SourceDecoder
    let configuration: AlignmentPipelineConfiguration
    let gate: ResourceGate
    func withAdmission<T: Sendable>(bytes: Int, _ body: @Sendable () async throws -> T) async throws -> T {
        try await gate.withAdmission(bytes: bytes) {
            try await ResourceGate.process.withAdmission(bytes: bytes, body)
        }
    }
    #if DEBUG
    var hooks = AlignmentPipelineTestHooks()
    #endif
}

#if DEBUG
/// Test-only seams (DEBUG builds only).
struct AlignmentPipelineTestHooks: Sendable {
    /// Called in a group render after a segment is rendered and verified, before its currency re-check and
    /// publication, while every gateway cursor of the group is still open.
    var beforeSegmentPublish: (@Sendable (RecorderGroupID, Int64) async -> Void)?
    /// Negative control: `false` runs group renders untracked, so `shutdown()` neither cancels nor awaits them.
    var trackRenders = true
    /// Negative control: `false` keys the accepted-map identity without its source revisions, so a change to
    /// another source of the map no longer invalidates segments keyed on it.
    var mapIdentityKeysSources = true
}
#endif

// MARK: - Source probe (header only)

enum SourceProbe {
    /// A probe opens the format and reads no samples; its admission is nominal.
    static let admissionBytes = 1 << 20

    static func key(source: SourceID, token: String) -> DerivedAssetKey {
        DerivedAssetKey(
            asset: AlignmentAssetKinds.sourceFacts,
            sources: [SourceRevision(source: source, token: token)],
            format: .current,
            occurrence: alignmentOccurrenceID(for: source)
        )
    }

    /// Opens `source` through the gateway, checks the decoder's interpretation against the registered
    /// revision and format, and returns its facts. No sample is decoded.
    static func run(_ source: AlignmentSource, token: String, environment: PipelineEnvironment) async throws(AlignmentWorkFailure) -> SourceFacts {
        let decoder = environment.decoder
        do {
            return try await environment.withAdmission(bytes: admissionBytes) {
                try await decoder.withDecodingCursor(source.url, source: source.id) { cursor in
                    let interpretation = cursor.interpretation
                    try verify(interpretation, source: source.id, token: token)
                    return SourceFacts(interpretation: interpretation, revisionToken: token)
                }
            }
        } catch {
            throw workFailure(error)
        }
    }

    /// The interpretation must use this build's format revision, and (for a metadata revision) the file the
    /// decoder opened must still be the one the app registered.
    static func verify(_ interpretation: FormatInterpretation, source: SourceID, token: String) throws(AlignmentWorkFailure) {
        let format = FormatRevision.current
        guard interpretation.formatInterpretationVersion == format.interpretationVersion,
              interpretation.envelopeVersion == format.envelopeVersion
        else {
            throw .formatRevisionMismatch(interpretation: interpretation.formatInterpretationVersion, envelope: interpretation.envelopeVersion)
        }
        if token.hasPrefix("metadata:"),
           SourceRevision.metadata(source, fingerprint: interpretation.sourceFingerprint).token != token {
            throw .sourceChangedSinceRegistration
        }
    }
}

// MARK: - Analysis unit

/// One planned estimator run: a target epoch's excerpt against the bounded part of the reference that the
/// search can reach.
struct AnalysisUnit: Sendable {
    let referenceChoice: AlignmentReferenceChoice
    let reference: AlignmentSource
    let referenceFacts: SourceFacts
    let targetGroup: RecorderGroupID
    let targetEpoch: RecordingEpochID
    let target: AlignmentSource
    let targetFacts: SourceFacts
    let configuration: AlignmentPipelineConfiguration
    let chunkFrames: Int

    var targetOccurrence: SourceOccurrenceID { alignmentOccurrenceID(for: target.id) }

    /// The analysis recipe for this unit. The reference epoch is part of it: the same file re-placed in a
    /// different epoch re-keys the analysis.
    var recipe: RecipeReference {
        RecipeReference(name: configuration.analysisRecipeName + "[ref=\(referenceChoice.group)/\(referenceChoice.epoch)]", revision: 1)
    }

    func recipe(peers: [AnalysisUnit]) -> RecipeReference {
        guard !peers.isEmpty else { return recipe }
        let cohort = peers.map { "\($0.targetGroup)/\($0.targetEpoch)" }.joined(separator: ",")
        return RecipeReference(name: recipe.name + "[cycle=\(cohort);peerExcerpt=20]", revision: 1)
    }

    func key(peers: [AnalysisUnit]) -> DerivedAssetKey {
        DerivedAssetKey(
            asset: AlignmentAssetKinds.analysis,
            sources: [
                SourceRevision(source: reference.id, token: referenceFacts.revisionToken),
                SourceRevision(source: target.id, token: targetFacts.revisionToken),
            ] + peers.map { SourceRevision(source: $0.target.id, token: $0.targetFacts.revisionToken) },
            format: .current,
            epoch: targetEpoch,
            occurrence: targetOccurrence,
            recipe: recipe(peers: peers)
        )
    }

    var key: DerivedAssetKey { key(peers: []) }

    /// Centred target excerpt, source frames.
    var targetRange: Range<Int64> {
        let n = targetFacts.frameCount
        let length = Swift.min(n, Int64(configuration.targetExcerptSeconds) * Int64(targetFacts.sampleRate))
        let start = (n - length) / 2
        return start ..< (start + length)
    }

    /// The reference frames any offset inside the search range (plus drift margin) can align the excerpt to,
    /// clamped to the reference. Empty when the search cannot reach the reference at all.
    var referenceRange: Range<Int64> {
        let ft = Double(targetFacts.sampleRate)
        let fr = Double(referenceFacts.sampleRate)
        let range = targetRange
        let center = Double(configuration.searchCenterSeconds)
        let deviation = Double(configuration.searchDeviationSeconds)
        let startSeconds = Double(range.lowerBound) / ft + center - deviation
        let endSeconds = Double(range.upperBound) / ft + center + deviation
        // Drift margin: up to 1000 ppm across the excerpt's span plus 2 s for edge windows.
        let margin = 2 + 0.001 * Swift.max(abs(startSeconds), abs(endSeconds))
        let lo = Swift.max(0, Int64(((startSeconds - margin) * fr).rounded(.down)))
        let hi = Swift.min(referenceFacts.frameCount, Int64(((endSeconds + margin) * fr).rounded(.up)))
        return lo < hi ? lo ..< hi : 0 ..< 0
    }

    var search: SearchRange {
        // Both values are validated by the configuration's clamps.
        try! SearchRange(centerOffsetSeconds: Double(configuration.searchCenterSeconds), maximumDeviationSeconds: Double(configuration.searchDeviationSeconds))
    }

    /// Estimated peak working set of the unit: decimated buffers (output, estimator copies, proxy resample
    /// and per-window scratch ≈ 32 B per analysis sample), the largest correlation FFT (≈ 56 B per point),
    /// decode chunks in flight for the wider source and fixed overhead. Measured against real peaks in the
    /// heavy suite (`PipelineMemoryTests`).
    func estimatedWorkingSetBytes(peers: [AnalysisUnit] = []) throws(AlignmentWorkFailure) -> Int {
        let minimum = configuration.minimumAnalysisRate
        let referenceFactor = try Self.factor(referenceFacts.sampleRate, minimum)
        let targetFactor = try Self.factor(targetFacts.sampleRate, minimum)
        let referenceOut = AnalysisDecimator.outputCount(frames: Int64(referenceRange.count), factor: referenceFactor)
        let targetOut = AnalysisDecimator.outputCount(frames: Int64(targetRange.count), factor: targetFactor)
        var fft = 1
        while fft < 2 * configuration.searchDeviationSeconds * 4000 + 8000 { fft <<= 1 }
        let channels = Swift.max(referenceFacts.channelCount, targetFacts.channelCount)
        let chunks = 3 * chunkFrames * channels * MemoryLayout<Float>.size * 2
        var peerBytes = 0
        for peer in peers {
            let factor = try Self.factor(peer.targetFacts.sampleRate, minimum)
            let frames = Int64(peer.cycleTargetRange.count)
            peerBytes += AnalysisDecimator.outputCount(frames: frames, factor: factor) * 32
        }
        return (referenceOut + targetOut) * 32 + peerBytes + fft * 56 + chunks + (8 << 20)
    }

    /// A peer needs enough shared windows to close a cycle, not the full long-form excerpt being reported.
    var cycleTargetRange: Range<Int64> {
        let full = targetRange
        let length = Swift.min(Int64(full.count), 20 * Int64(targetFacts.sampleRate))
        let start = full.lowerBound + (Int64(full.count) - length) / 2
        return start ..< (start + length)
    }

    static func factor(_ rate: Int, _ minimum: Int) throws(AlignmentWorkFailure) -> Int {
        switch Result(catching: { () throws(AnalysisDecimator.Refusal) -> Int in try AnalysisDecimator.factor(sourceRate: rate, minimumRate: minimum) }) {
        case .success(let factor): return factor
        case .failure: throw .sourceRateBelowAnalysisMinimum(rate: rate, minimum: minimum)
        }
    }

    func participant(_ group: RecorderGroupID, _ epoch: RecordingEpochID, _ source: AlignmentSource, _ facts: SourceFacts, range: Range<Int64>) throws(AlignmentWorkFailure) -> AnalysisParticipant {
        let factor = try Self.factor(facts.sampleRate, configuration.minimumAnalysisRate)
        return AnalysisParticipant(
            group: group, epoch: epoch, source: source.id, occurrence: alignmentOccurrenceID(for: source.id),
            revisionToken: facts.revisionToken, sourceRate: facts.sampleRate, sourceFrames: facts.frameCount,
            channelCount: facts.channelCount, excerptStartFrame: range.lowerBound, excerptEndFrame: range.upperBound,
            analysisRate: facts.sampleRate / factor
        )
    }

    /// Decodes both excerpts (sequentially, inside one admission), runs the estimator and returns the
    /// encoded `EpochAnalysisRecord`.
    func run(
        environment: PipelineEnvironment, peers: [AnalysisUnit] = [],
        cache: CycleExcerptCache? = nil, retainedBytes: Int = 0
    ) async throws(AlignmentWorkFailure) -> Data {
        let referenceRange = referenceRange
        let targetRange = targetRange
        let referenceParticipant = try participant(referenceChoice.group, referenceChoice.epoch, reference, referenceFacts, range: referenceRange)
        let targetParticipant = try participant(targetGroup, targetEpoch, target, targetFacts, range: targetRange)
        let record: EpochAnalysisRecord
        if referenceRange.isEmpty {
            record = EpochAnalysisRecord(
                recipe: recipe(peers: peers).name, reference: referenceParticipant, target: targetParticipant, search: search,
                abstention: .insufficientCoverage,
                detail: "The search range cannot reach the reference recording from this epoch's excerpt."
            )
        } else {
            let bytes = try estimatedWorkingSetBytes(peers: peers) + retainedBytes
            let unit = self
            do {
                record = try await environment.withAdmission(bytes: bytes) {
                    let referenceSamples = try await unit.decodeAnalysisBuffer(unit.reference, facts: unit.referenceFacts, range: referenceRange, decoder: environment.decoder)
                    try Task.checkCancellation()
                    let targetSamples = try await unit.decodeAnalysisBuffer(unit.target, facts: unit.targetFacts, range: targetRange, decoder: environment.decoder)
                    try Task.checkCancellation()
                    if let cache {
                        await cache.rememberTarget(unit, samples: targetSamples)
                    }
                    var peerTracks: [EstimatorTrack] = []
                    for peer in peers {
                        let range = peer.cycleTargetRange
                        let participant = try peer.participant(peer.targetGroup, peer.targetEpoch, peer.target, peer.targetFacts, range: range)
                        let samples: [Float]
                        if let cache {
                            samples = try await cache.samples(for: peer, decoder: environment.decoder)
                        } else {
                            samples = try await peer.decodeAnalysisBuffer(peer.target, facts: peer.targetFacts, range: range, decoder: environment.decoder)
                        }
                        peerTracks.append(try unit.track(samples: samples, participant: participant))
                        try Task.checkCancellation()
                    }

                    return try unit.estimate(
                        referenceSamples: referenceSamples, referenceParticipant: referenceParticipant,
                        targetSamples: targetSamples, targetParticipant: targetParticipant,
                        peerTracks: peerTracks, recipe: unit.recipe(peers: peers).name
                    )
                }
            } catch {
                throw workFailure(error)
            }
        }
        switch Result(catching: { try EpochAnalysisRecord.encode(record) }) {
        case .success(let data): return data
        case .failure(let error): throw .encoding(String(describing: error))
        }
    }

    /// Streams one source through the gateway into a decimated mono buffer for `range`. Stops reading once
    /// the range (plus filter context) is covered.
    func decodeAnalysisBuffer(_ source: AlignmentSource, facts: SourceFacts, range: Range<Int64>, decoder: SourceDecoder) async throws -> [Float] {
        try await Self.decodeAnalysisBuffer(source, facts: facts, range: range, minimumRate: configuration.minimumAnalysisRate, decoder: decoder)
    }

    static func decodeAnalysisBuffer(
        _ source: AlignmentSource, facts: SourceFacts, range: Range<Int64>, minimumRate minimum: Int, decoder: SourceDecoder
    ) async throws -> [Float] {
        try await decoder.withDecodingCursor(source.url, source: source.id) { cursor in
            let interpretation = cursor.interpretation
            try SourceProbe.verify(interpretation, source: source.id, token: facts.revisionToken)
            guard interpretation.sourceSampleRate == facts.sampleRate,
                  interpretation.frames.validFrames == facts.frameCount,
                  interpretation.channelCount == facts.channelCount
            else { throw AlignmentWorkFailure.sourceFactsMismatch }
            var decimator: AnalysisDecimator
            switch Result(catching: { () throws(AnalysisDecimator.Refusal) -> AnalysisDecimator in
                try AnalysisDecimator(sourceRate: facts.sampleRate, minimumRate: minimum, range: range)
            }) {
            case .success(let value): decimator = value
            case .failure(.rateBelowMinimum(let rate, let minimum)): throw AlignmentWorkFailure.sourceRateBelowAnalysisMinimum(rate: rate, minimum: minimum)
            case .failure(.emptyRange): throw AlignmentWorkFailure.sourceFactsMismatch
            }
            let needed = decimator.neededInput
            while let chunk = try await cursor.next() {
                if chunk.firstSourceFrame >= needed.upperBound { break }
                decimator.consume(chunk)
                if chunk.firstSourceFrame + Int64(chunk.frameCount) >= needed.upperBound { break }
            }
            return decimator.finish()
        }
    }

    func track(samples: [Float], participant: AnalysisParticipant) throws(AlignmentWorkFailure) -> EstimatorTrack {
        do throws(AlignEstimateError) {
            let start: ExactRational
            do throws(TimeMapError) {
                start = try ExactRational(participant.excerptStartFrame, Int64(participant.sourceRate))
            } catch {
                throw .timeMap(error)
            }
            return EstimatorTrack(
                group: participant.group, epoch: participant.epoch, occurrence: participant.occurrence,
                groupClockStart: start, buffer: try SampleBuffer(samples: samples, sampleRate: participant.analysisRate)
            )
        } catch {
            throw .estimator(error)
        }
    }

    func estimate(
        referenceSamples: [Float], referenceParticipant: AnalysisParticipant,
        targetSamples: [Float], targetParticipant: AnalysisParticipant,
        peerTracks: [EstimatorTrack] = [], recipe: String? = nil
    ) throws(AlignmentWorkFailure) -> EpochAnalysisRecord {
        let referenceTrack = try track(samples: referenceSamples, participant: referenceParticipant)
        let targetTrack = try track(samples: targetSamples, participant: targetParticipant)
        let report: EstimationReport
        do throws(AlignEstimateError) {
            report = try AcousticEstimator.estimate(EstimationRequest(reference: referenceTrack, tracks: [targetTrack] + peerTracks, search: search))
        } catch {
            throw .estimator(error)
        }
        guard let estimate = report.epochs.first(where: { $0.epoch == targetEpoch }) else {
            throw .estimator(.invalidParameter("the estimator returned no result for the target epoch"))
        }
        var record = EpochAnalysisRecord(recipe: recipe ?? self.recipe.name, reference: referenceParticipant, target: targetParticipant, search: search, estimate: estimate)
        if estimate.flags.contains(.coverageGap), record.abstention?.abstentionReason != .cycleInconsistent {
            record.proposal = nil
            record.abstention = AbstentionRecord(
                reason: AbstentionReason.discontinuous.rawValue,
                detail: "Internal coverage gap: declare an epoch boundary or place anchors manually; no inverse is available across the gap."
            )
        }
        if peerTracks.contains(where: { $0.group != targetGroup }), record.cycleTriangles == 0, record.proposal != nil {
            record.proposal = nil
            record.abstention = AbstentionRecord(
                reason: AbstentionReason.insufficientCoverage.rawValue,
                detail: "No shared peer windows closed a recorder cycle; place anchors manually or retry with overlapping recordings."
            )
        }
        return record
    }
}

/// One run's bounded, decimated peer excerpts. The caller serializes multi-recorder units so the
/// gateway is opened at most once per source revision; nothing persists beyond that analysis run.
actor CycleExcerptCache {
    private var excerpts: [SourceRevision: [Float]] = [:]

    func rememberTarget(_ unit: AnalysisUnit, samples: [Float]) {
        let revision = SourceRevision(source: unit.target.id, token: unit.targetFacts.revisionToken)
        guard excerpts[revision] == nil else { return }
        let peer = unit.cycleTargetRange
        guard let factor = try? AnalysisUnit.factor(unit.targetFacts.sampleRate, unit.configuration.minimumAnalysisRate) else { return }
        let offset = peer.lowerBound - unit.targetRange.lowerBound
        guard offset % Int64(factor) == 0 else { return }
        let start = Int(offset / Int64(factor))
        let count = AnalysisDecimator.outputCount(frames: Int64(peer.count), factor: factor)
        guard start + count <= samples.count else { return }
        excerpts[revision] = Array(samples[start ..< start + count])
    }

    func samples(for peer: AnalysisUnit, decoder: SourceDecoder) async throws -> [Float] {
        let revision = SourceRevision(source: peer.target.id, token: peer.targetFacts.revisionToken)
        if let samples = excerpts[revision] { return samples }
        let samples = try await peer.decodeAnalysisBuffer(
            peer.target, facts: peer.targetFacts, range: peer.cycleTargetRange, decoder: decoder
        )
        excerpts[revision] = samples
        return samples
    }
}
