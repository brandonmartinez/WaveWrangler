import WWCore
import WWWhisperNative

#if DEBUG
import Darwin
#endif

public enum SpeechRefusal: Error, Sendable, Equatable {
    case unselectedPrimary
    case engineUnavailable
}

/// Media-free admission boundary. The caller must supply the current canonical show model, not a
/// cached selection. Production has no sealed source issuer or transcript publisher.
public struct SpeechInference: Sendable {
    public init() {}

    /// Verifies only that the built-in CPU C ABI responds to generated data; no app model is installed.
    public static var nativeCPULinked: Bool {
        let probe = ww_whisper_cpu_probe()
        return probe.linked == 1 && probe.inference_available == 0
    }

    public func infer(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) {
        try requireSelectedPrimary(model: model, episodeID: episodeID, speakerID: speakerID, channel: channel)
        throw .engineUnavailable
    }

    private func requireSelectedPrimary(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) {
        guard model.schemaVersion == SchemaVersion.show,
              model.episodes.filter({ $0.id == episodeID }).count == 1,
              model.speakers.filter({ $0.id == speakerID }).count == 1,
              let episode = model.episode(episodeID),
              episode.speakerAssignments.filter({ $0.speakerID == speakerID }).count == 1,
              let assignment = episode.assignment(for: speakerID),
              assignment.primary == channel,
              assignment.primaryConfirmation == .userConfirmed,
              !assignment.backups.contains(channel),
              episode.speakerAssignments.filter({ $0.primary == channel }).count == 1,
              let index = channel.channel.value, index >= 0,
              episode.sources.filter({ $0.id == channel.sourceID }).count == 1,
              let source = episode.source(channel.sourceID),
              source.role == .primary, source.roleConfirmation == .userConfirmed,
              let count = source.observations.channelCount.value, index < count
        else { throw .unselectedPrimary }
    }

    #if DEBUG
    /// Diagnostic only: generates its own PCM after checking the current confirmed Primary.
    /// A model path cannot supply source audio or authorize an unsealed production decode.
    public func syntheticModelProbe(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference, modelPath: String
    ) throws -> PCMTranscript {
        try requireSelectedPrimary(model: model, episodeID: episodeID, speakerID: speakerID, channel: channel)
        let verifiedModel = try VerifiedTinyModel.load(path: modelPath)
        let generated = (0..<32_000).map { index in
            0.1 * sinf(Float(index) * (2 * .pi * 440 / 16_000))
        }
        return try BoundedPCMInference().transcribe(
            model: verifiedModel, pcm: generated, sampleRate: 16_000, channelCount: 1
        )
    }

    /// Exercises the linked C ABI with its own generated numbers only; no recognition is possible.
    public func syntheticProbe(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) -> SyntheticSpeechProbeResult {
        try requireSelectedPrimary(model: model, episodeID: episodeID, speakerID: speakerID, channel: channel)
        let probe = ww_whisper_cpu_probe()
        guard probe.linked == 1, probe.inference_available == 0,
              probe.synthetic_frame_count == 4, probe.recognized_word_count == 0
        else { throw .engineUnavailable }
        return SyntheticSpeechProbeResult(
            processID: getpid(), syntheticFrameCount: Int(probe.synthetic_frame_count),
            signalEnergy: probe.synthetic_energy, recognizedWordCount: Int(probe.recognized_word_count)
        )
    }
    #endif
}

#if DEBUG
public struct SyntheticSpeechProbeResult: Sendable, Equatable {
    public let processID: Int32
    public let syntheticFrameCount: Int
    public let signalEnergy: Float
    public let recognizedWordCount: Int
}
#endif
