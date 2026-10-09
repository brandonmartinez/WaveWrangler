#if DEBUG
import Foundation
import WWCore
import WWDecode
import WWDerived
import WWSources

/// Untrusted observations from a synthetic callback, not an ASR transcript or edit authority.
/// A missing pair of boundaries remains absent; recognition confidence is never synthesized.
package struct SyntheticWordObservation: Sendable {
    package let text: String
    package let startSeconds: Double?
    package let endSeconds: Double?
    package let recognitionConfidence: Double?

    package init(text: String, startSeconds: Double?, endSeconds: Double?,
                 recognitionConfidence: Double? = nil) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.recognitionConfidence = recognitionConfidence
    }
}

package enum SyntheticWordAlignment: Sendable, Equatable {
    case unmapped
}

package struct SyntheticPrimaryWord: Sendable {
    package let text: String
    package let speakerID: SpeakerID
    package let channel: Int
    package let startSeconds: Double?
    package let endSeconds: Double?
    /// A worker-provided recognition value, not validated boundary or cut evidence.
    package let recognitionConfidence: Double?
}

/// Source-coordinate observations only. No accepted occurrence, timeline placement,
/// verified transcript, model identity or permission to edit is inferred from these fields.
package struct SyntheticPrimaryWordEvidence: Sendable {
    package let selection: PrimarySpeechSelection
    package let declaredAuthorization: PrimarySpeechAuthorization
    package let showRevision: UInt64
    package let interpretation: FormatInterpretation
    package let sourceRevision: SourceRevision
    package let selectedSourcePCMHash: String
    package let inputAssetRevision: Int
    package let proxyAssetRevision: Int
    package let inputSHA256: String
    package let frameCount: Int
    package let chunks: [PrimaryPCMChunk]
    package let alignment: SyntheticWordAlignment
    package let words: [SyntheticPrimaryWord]

    init(input: BorrowedPrimaryPCMInput, observations: [SyntheticWordObservation])
        throws(SpeechAdmissionRefusal)
    {
        guard input.format == "f32le", input.sampleRate == SelectedPrimaryPCMProxy.sampleRate,
              input.channelCount == 1, input.frameCount > 0,
              !observations.isEmpty, observations.count <= input.frameCount
        else { throw .invalidWordEvidence }
        let sourceEnd = input.interpretation.origin.sourceDuration
        guard input.interpretation.origin.sourceFrameOfFirstDecodedFrame == 0,
              sourceEnd.frame == input.interpretation.frames.validFrames,
              sourceEnd.sampleRate == input.interpretation.sourceSampleRate,
              sourceEnd.sampleRate > 0
        else { throw .invalidWordEvidence }
        let proxyDuration = Double(input.frameCount) / Double(input.sampleRate)
        let sourceDuration = sourceEnd.seconds
        var lastEnd: Double = 0
        var validated: [SyntheticPrimaryWord] = []
        validated.reserveCapacity(observations.count)
        for word in observations {
            guard !Task.isCancelled else { throw .decode(.cancelled) }
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (word.startSeconds == nil) == (word.endSeconds == nil)
            else { throw .invalidWordEvidence }
            if let start = word.startSeconds, let end = word.endSeconds {
                guard start.isFinite, end.isFinite, start >= lastEnd,
                      start <= proxyDuration, start <= sourceDuration,
                      start < end, end <= proxyDuration, end <= sourceDuration
                else { throw .invalidWordEvidence }
                lastEnd = end
            }
            if let confidence = word.recognitionConfidence {
                guard confidence.isFinite, (0...1).contains(confidence)
                else { throw .invalidWordEvidence }
            }
            validated.append(SyntheticPrimaryWord(
                text: word.text, speakerID: input.selection.speakerID,
                channel: input.selection.channel, startSeconds: word.startSeconds,
                endSeconds: word.endSeconds, recognitionConfidence: word.recognitionConfidence))
        }
        selection = input.selection
        declaredAuthorization = input.declaredAuthorization
        showRevision = input.showRevision
        interpretation = input.interpretation
        sourceRevision = input.sourceRevision
        selectedSourcePCMHash = input.selectedSourcePCMHash
        inputAssetRevision = input.inputAssetRevision
        proxyAssetRevision = input.proxyAssetRevision
        inputSHA256 = input.sha256
        frameCount = input.frameCount
        chunks = input.chunks
        alignment = .unmapped
        words = validated
    }
}

extension PrimarySpeechInputAdapter {
    /// Callback borrows the sealed selected-primary descriptor synchronously. The existing
    /// adapter rechecks the source, organizer and worker after the callback (including after
    /// its final awaited state read); mapped episodes refuse before any content is decoded.
    package func withSyntheticWordEvidence(
        episodeID: EpisodeID,
        speakerID: SpeakerID,
        authorization: PrimarySpeechAuthorization?,
        availability: SourceAvailabilitySetting,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState,
        workerURL: URL,
        workerPin: LocalSpeechAssetPin,
        worker: @escaping @Sendable (BorrowedPrimaryPCMInput)
            throws(SpeechAdmissionRefusal) -> [SyntheticWordObservation]
    ) async throws(SpeechAdmissionRefusal) -> SyntheticPrimaryWordEvidence {
        try await withSealedSyntheticWorkerInput(
            episodeID: episodeID, speakerID: speakerID, authorization: authorization,
            availability: availability, current: current, workerURL: workerURL, workerPin: workerPin
        ) { input throws(SpeechAdmissionRefusal) in
            try SyntheticPrimaryWordEvidence(input: input, observations: worker(input))
        }
    }
}
#endif
