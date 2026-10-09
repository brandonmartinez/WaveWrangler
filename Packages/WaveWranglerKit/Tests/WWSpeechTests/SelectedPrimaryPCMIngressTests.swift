import Testing
import WWCore
import WWDecode
import WWSpeech
import WWTimeMap

@Suite("Provisional selected-Primary PCM ingress")
struct SelectedPrimaryPCMIngressTests {
    private func selection() -> (ShowDocumentModel, EpisodeID, SpeakerID, ChannelReference, ChannelReference) {
        let speaker = Speaker(name: "Generated")
        let primarySource = SourceRecord(
            displayNameHint: "generated-primary",
            observations: SourceObservations(channelCount: .known(2)),
            role: .primary, roleConfirmation: .userConfirmed
        )
        let backupSource = SourceRecord(
            displayNameHint: "generated-backup",
            observations: SourceObservations(channelCount: .known(1)),
            role: .backup, roleConfirmation: .userConfirmed
        )
        let primary = ChannelReference(sourceID: primarySource.id, statedChannel: 1)
        let backup = ChannelReference(sourceID: backupSource.id, statedChannel: 0)
        let episode = Episode(
            title: "Generated", sources: [primarySource, backupSource],
            speakerAssignments: [
                SpeakerAssignment(speakerID: speaker.id, primary: primary,
                                  primaryConfirmation: .userConfirmed, backups: [backup])
            ]
        )
        return (
            ShowDocumentModel(show: Show(title: "Generated"), speakers: [speaker], episodes: [episode]),
            episode.id, speaker.id, primary, backup
        )
    }

    @Test func confirmedSelectionStillCannotIssueASourceReceipt() {
        let (model, episode, speaker, primary, _) = selection()
        #expect(throws: SelectedPrimaryIngressRefusal.trustedSourceReceiptUnavailable) {
            try SelectedPrimaryPCMIngress().requireAuthorization(
                model: model, episodeID: episode, speakerID: speaker, channel: primary
            )
        }
    }

    @Test func wrongStaleUnconfirmedAndBackupSelectionsRefuse() {
        let (model, episode, speaker, primary, backup) = selection()
        let ingress = SelectedPrimaryPCMIngress()
        for channel in [backup, ChannelReference(sourceID: primary.sourceID, statedChannel: 0),
                        ChannelReference(sourceID: primary.sourceID, statedChannel: 2)] {
            #expect(throws: SelectedPrimaryIngressRefusal.unselectedPrimary) {
                try ingress.requireAuthorization(model: model, episodeID: episode,
                                                 speakerID: speaker, channel: channel)
            }
        }
        var changed = model
        changed.episodes[0].speakerAssignments[0].primary = backup
        #expect(throws: SelectedPrimaryIngressRefusal.unselectedPrimary) {
            try ingress.requireAuthorization(model: changed, episodeID: episode,
                                             speakerID: speaker, channel: primary)
        }
        changed = model
        changed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        #expect(throws: SelectedPrimaryIngressRefusal.unselectedPrimary) {
            try ingress.requireAuthorization(model: changed, episodeID: episode,
                                             speakerID: speaker, channel: primary)
        }
        changed = model
        changed.episodes[0].sources[0].roleConfirmation = .provisional
        #expect(throws: SelectedPrimaryIngressRefusal.unselectedPrimary) {
            try ingress.requireAuthorization(model: changed, episodeID: episode,
                                             speakerID: speaker, channel: primary)
        }
        changed = model
        changed.episodes[0].sources[0].observations.channelCount = .unknown
        #expect(throws: SelectedPrimaryIngressRefusal.unselectedPrimary) {
            try ingress.requireAuthorization(model: changed, episodeID: episode,
                                             speakerID: speaker, channel: primary)
        }
    }

    private func identity(channel: Int = 1) -> SyntheticPCMIngress.Identity {
        .init(source: SourceID(), revision: "generated-revision",
              occurrence: SourceOccurrenceID(), proxy: .original, channel: channel)
    }

    private func chunks(start: Int64 = 12, channels: Int = 2) -> [DecodedChunk] {
        [0, 16_000].map { offset in
            DecodedChunk(
                firstSourceFrame: start + Int64(offset),
                frameCount: 16_000, channelCount: channels,
                samples: (0..<channels).flatMap { channel in
                    [Float](repeating: channel == 0 ? 0.25 : 0.5, count: 16_000)
                }
            )
        }
    }

    @Test func generatedChunksMapOnlyTheSelectedChannelToExactSourceFrames() throws {
        let id = identity()
        let result = try SyntheticPCMIngress.extract(
            chunks(), identity: id, expected: id, sourceFrameStart: 12,
            decodedFrameCount: 32_012, sourceSampleRate: 16_000, sourceChannelCount: 2
        )
        #expect(result.sourceFrameRange == 12..<32_012)
        #expect(result.pcm.count == 32_000)
        #expect(result.pcm.allSatisfy { $0 == 0.5 })
        try BoundedPCMInference.validateInput(pcm: result.pcm, sampleRate: 16_000, channelCount: 1)
    }

    @Test func mismatchedIdentityRevisionOccurrenceProxyAndChannelRefuse() {
        let id = identity()
        var candidates: [SyntheticPCMIngress.Identity] = []
        var different = id
        different.source = SourceID()
        candidates.append(different)
        different = id
        different.revision = "older"
        candidates.append(different)
        different = id
        different.occurrence = SourceOccurrenceID()
        candidates.append(different)
        different = id
        different.proxy = .derived
        candidates.append(different)
        different = id
        different.channel = 0
        candidates.append(different)
        for candidate in candidates {
            #expect(throws: SyntheticPCMIngressFailure.invalidMapping) {
                try SyntheticPCMIngress.extract(
                    chunks(), identity: candidate, expected: id, sourceFrameStart: 12,
                    decodedFrameCount: 32_012, sourceSampleRate: 16_000, sourceChannelCount: 2
                )
            }
        }
        different = id
        different.proxy = .derived
        #expect(throws: SyntheticPCMIngressFailure.invalidMapping) {
            try SyntheticPCMIngress.extract(
                chunks(), identity: different, expected: different, sourceFrameStart: 12,
                decodedFrameCount: 32_012, sourceSampleRate: 16_000, sourceChannelCount: 2
            )
        }
    }

    @Test func incompleteDiscontinuousOverflowInvalidPCMAndCancellationRefuse() {
        let id = identity()
        let good = chunks()
        let incomplete = Array(good.prefix(1))
        let discontinuous = [good[0], chunks(start: 13)[1]]
        for input in [incomplete, discontinuous] {
            #expect(throws: SyntheticPCMIngressFailure.invalidMapping) {
                try SyntheticPCMIngress.extract(
                    input, identity: id, expected: id, sourceFrameStart: 12,
                    decodedFrameCount: 32_012, sourceSampleRate: 16_000, sourceChannelCount: 2
                )
            }
        }
        #expect(throws: SyntheticPCMIngressFailure.invalidMapping) {
            try SyntheticPCMIngress.extract(
                good, identity: id, expected: id, sourceFrameStart: Int64.max,
                decodedFrameCount: Int64.max, sourceSampleRate: 16_000, sourceChannelCount: 2
            )
        }
        #expect(throws: SyntheticPCMIngressFailure.invalidMapping) {
            try SyntheticPCMIngress.extract(
                good, identity: id, expected: id, sourceFrameStart: 12,
                decodedFrameCount: 32_012, sourceSampleRate: 48_000, sourceChannelCount: 2
            )
        }
        var bad = good
        var samples = bad[1].samples
        samples[16_000] = .nan
        bad[1] = DecodedChunk(
            firstSourceFrame: bad[1].firstSourceFrame, frameCount: 16_000,
            channelCount: 2, samples: samples
        )
        #expect(throws: SyntheticPCMIngressFailure.invalidMapping) {
            try SyntheticPCMIngress.extract(
                bad, identity: id, expected: id, sourceFrameStart: 12,
                decodedFrameCount: 32_012, sourceSampleRate: 16_000, sourceChannelCount: 2
            )
        }
        #expect(throws: SyntheticPCMIngressFailure.cancelled) {
            try SyntheticPCMIngress.extract(
                good, identity: id, expected: id, sourceFrameStart: 12,
                decodedFrameCount: 32_012, sourceSampleRate: 16_000,
                sourceChannelCount: 2, isCancelled: { true }
            )
        }
    }
}
