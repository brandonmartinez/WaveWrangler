import WWAutoAlign
import WWCore
import WWDecode

enum QuietTimingAnalysis {
    static func verifyCurrent(
        source: AlignmentSource, facts: SourceFacts, environment: PipelineEnvironment
    ) async throws {
        try await environment.decoder.withDecodingCursor(source.url, source: source.id) { cursor in
            let interpretation = cursor.interpretation
            try SourceProbe.verify(interpretation, source: source.id, token: facts.revisionToken,
                                   recorded: source.recordedFingerprint)
            guard interpretation.sourceSampleRate == facts.sampleRate,
                  interpretation.frames.validFrames == facts.frameCount,
                  interpretation.channelCount == facts.channelCount else {
                throw AlignmentWorkFailure.sourceFactsMismatch
            }
            try await cursor.verifyUnchanged()
        }
    }

    static func profile(
        source: AlignmentSource, facts: SourceFacts, channel: Int?, allChannels: Bool,
        environment: PipelineEnvironment
    ) async throws -> QuietAudioProfile {
        guard let channel else { throw AlignmentWorkFailure.sourceFactsMismatch }
        return try await environment.decoder.withDecodingCursor(source.url, source: source.id) { cursor in
            let interpretation = cursor.interpretation
            try SourceProbe.verify(interpretation, source: source.id, token: facts.revisionToken,
                                   recorded: source.recordedFingerprint)
            guard interpretation.sourceSampleRate == facts.sampleRate,
                  interpretation.frames.validFrames == facts.frameCount,
                  interpretation.channelCount == facts.channelCount else {
                throw AlignmentWorkFailure.sourceFactsMismatch
            }
            var builder = try QuietAudioProfileBuilder(sampleRate: facts.sampleRate,
                channelCount: facts.channelCount, selectedChannel: channel, allChannels: allChannels)
            var position: Int64 = 0
            while let chunk = try await cursor.next() {
                try Task.checkCancellation()
                guard chunk.channelCount == facts.channelCount, chunk.firstSourceFrame == position else {
                    throw AlignmentWorkFailure.sourceFactsMismatch
                }
                try builder.append(chunk.samples, firstFrame: chunk.firstSourceFrame, frameCount: chunk.frameCount)
                position += Int64(chunk.frameCount)
            }
            guard position == facts.frameCount else { throw AlignmentWorkFailure.sourceFactsMismatch }
            try await cursor.verifyUnchanged()
            return try builder.finish()
        }
    }
}
