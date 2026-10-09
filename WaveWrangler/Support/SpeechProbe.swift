import WWCore
import WWSpeech

/// The app's production speech entry point never reads media or starts a recognizer until an
/// independently qualified, linked engine and source adapter replace the explicit refusal.
enum AppSpeech {
    static func infer(
        model: ShowDocumentModel, episodeID: EpisodeID, speakerID: SpeakerID,
        channel: ChannelReference
    ) throws(SpeechRefusal) {
        try SpeechInference().infer(model: model, episodeID: episodeID, speakerID: speakerID, channel: channel)
    }
}

#if DEBUG
import Darwin

enum SpeechProbe {
    static func run() -> Int32 {
        let speaker = Speaker(name: "Synthetic speaker")
        let source = SourceRecord(
            displayNameHint: "synthetic-only",
            observations: SourceObservations(channelCount: .known(1)),
            role: .primary, roleConfirmation: .userConfirmed
        )
        let backupSource = SourceRecord(
            displayNameHint: "synthetic-backup-only",
            observations: SourceObservations(channelCount: .known(1)),
            role: .backup, roleConfirmation: .userConfirmed
        )
        let channel = ChannelReference(sourceID: source.id, statedChannel: 0)
        let backup = ChannelReference(sourceID: backupSource.id, statedChannel: 0)
        let episode = Episode(
            title: "Synthetic episode", sources: [source, backupSource],
            speakerAssignments: [SpeakerAssignment(
                speakerID: speaker.id, primary: channel, primaryConfirmation: .userConfirmed,
                backups: [backup]
            )]
        )
        let model = ShowDocumentModel(
            show: Show(title: "Synthetic show"), speakers: [speaker], episodes: [episode]
        )
        do {
            try AppSpeech.infer(model: model, episodeID: episode.id, speakerID: speaker.id, channel: channel)
            fputs("speech production refusal missing\n", stderr)
            return 1
        } catch SpeechRefusal.engineUnavailable {
            // Expected: even a confirmed Primary cannot reach an unqualified production engine.
        } catch {
            fputs("speech production boundary failed\n", stderr)
            return 1
        }
        do {
            let inference = SpeechInference()
            guard SpeechInference.nativeCPULinked else {
                fputs("speech native CPU bridge unavailable\n", stderr)
                return 1
            }
            do {
                _ = try inference.syntheticProbe(
                    model: model, episodeID: episode.id, speakerID: speaker.id, channel: backup
                )
                fputs("speech backup admission failed\n", stderr)
                return 1
            } catch SpeechRefusal.unselectedPrimary {
                // A backup cannot reach even the generated-sample diagnostic.
            }
            let result = try inference.syntheticProbe(
                model: model, episodeID: episode.id, speakerID: speaker.id, channel: channel
            )
            guard result.processID == getpid(),
                  result.syntheticFrameCount == 4, result.signalEnergy == 0.125,
                  result.recognizedWordCount == 0
            else {
                fputs("speech synthetic process identity failed\n", stderr)
                return 1
            }
            print("WW_SPEECH_SYNTHETIC_IN_APP pid=\(result.processID) frames=4 words=0 backup=refused native=linked")
            return 0
        } catch {
            fputs("speech synthetic admission failed\n", stderr)
            return 1
        }
    }
}
#endif
