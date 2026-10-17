import Foundation
import WWAlignEstimate
import WWAutoAlign
import WWCore
import WWDecode
import WWDerived

enum FingerprintAnalysis {
    static func load(
        source: AlignmentSource, facts: SourceFacts, channel: Int?, minimumRate: Int,
        environment: PipelineEnvironment
    ) async throws -> SpectralFingerprint {
        let recipe = RecipeReference(
            name: "\(SpectralFingerprint.identifier)[channel=\(channel.map(String.init) ?? "mix");rate>=\(minimumRate);dec=\(AnalysisDecimator.designVersion)]",
            revision: 1
        )
        let key = DerivedAssetKey(
            asset: AlignmentAssetKinds.fingerprint,
            sources: [SourceRevision(source: source.id, token: facts.revisionToken)], format: .current,
            channel: channel, recipe: recipe
        )
        let slot = DerivedSlot("\(AlignmentAssetKinds.fingerprint.kind)/\(source.id)/\(recipe.name)")
        await environment.coordinator.setAssetRevision(AlignmentAssetKinds.fingerprint)
        await environment.coordinator.setRecipe(recipe)
        let result = await environment.coordinator.run(slot, key: key) { () throws(AlignmentWorkFailure) -> Data in
            do {
                return try await environment.decoder.withDecodingCursor(source.url, source: source.id) { cursor in
                    let interpretation = cursor.interpretation
                    try SourceProbe.verify(interpretation, source: source.id, token: facts.revisionToken, recorded: source.recordedFingerprint)
                    guard interpretation.sourceSampleRate == facts.sampleRate,
                          interpretation.frames.validFrames == facts.frameCount,
                          interpretation.channelCount == facts.channelCount,
                          channel.map({ $0 >= 0 && $0 < facts.channelCount }) ?? true else {
                        throw AlignmentWorkFailure.sourceFactsMismatch
                    }
                    var decimator = try AnalysisDecimator(sourceRate: facts.sampleRate, minimumRate: minimumRate,
                                                          range: 0..<facts.frameCount, channel: channel, streaming: true)
                    var builder = try SpectralFingerprintBuilder(sampleRate: decimator.outputRate)
                    var position: Int64 = 0
                    while let chunk = try await cursor.next() {
                        try Task.checkCancellation()
                        guard chunk.firstSourceFrame == position else { throw AlignmentWorkFailure.sourceFactsMismatch }
                        decimator.consume(chunk)
                        try builder.append(decimator.drainOutput())
                        position += Int64(chunk.frameCount)
                    }
                    guard position == facts.frameCount else { throw AlignmentWorkFailure.sourceFactsMismatch }
                    try builder.append(decimator.finish())
                    return try builder.finish().encoded()
                }
            } catch let error as AlignEstimateError { throw .estimator(error) }
            catch { throw workFailure(error) }
        }
        try Task.checkCancellation()
        guard result.isAvailable else { throw result.typedFailure ?? AlignmentWorkFailure.encoding("fingerprint did not publish") }
        guard await environment.coordinator.staleReasons(for: key).isEmpty,
              let data = environment.coordinator.store.payload(for: key) else {
            throw AlignmentWorkFailure.staleInputs([.sourceChanged(source.id)])
        }
        return try SpectralFingerprint(encoded: data)
    }
}
