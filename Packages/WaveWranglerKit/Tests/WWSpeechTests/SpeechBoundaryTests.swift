import Darwin
import Testing
import WWCore
import WWSpeech

@Suite("WW-026 synthetic speech boundary")
struct SpeechBoundaryTests {
    private struct Fixture {
        let model: ShowDocumentModel
        let episodeID: EpisodeID
        let speakerID: SpeakerID
        let primary: ChannelReference
        let backup: ChannelReference
    }

    private func fixture(confirmed: Bool = true) -> Fixture {
        let speaker = Speaker(name: "Synthetic speaker")
        let primarySource = SourceRecord(
            displayNameHint: "synthetic-primary",
            observations: SourceObservations(channelCount: .known(1)),
            role: .primary,
            roleConfirmation: confirmed ? .userConfirmed : .provisional
        )
        let backupSource = SourceRecord(
            displayNameHint: "synthetic-backup",
            observations: SourceObservations(channelCount: .known(1)),
            role: .backup,
            roleConfirmation: .userConfirmed
        )
        let primary = ChannelReference(sourceID: primarySource.id, statedChannel: 0)
        let backup = ChannelReference(sourceID: backupSource.id, statedChannel: 0)
        let episode = Episode(
            title: "Synthetic episode",
            sources: [primarySource, backupSource],
            speakerAssignments: [SpeakerAssignment(
                speakerID: speaker.id, primary: primary,
                primaryConfirmation: confirmed ? .userConfirmed : .provisional,
                backups: [backup]
            )]
        )
        let model = ShowDocumentModel(show: Show(title: "Synthetic show"), speakers: [speaker], episodes: [episode])
        return Fixture(model: model, episodeID: episode.id, speakerID: speaker.id, primary: primary, backup: backup)
    }

    @Test func selectedPrimaryIsStillUnavailableInProductionPath() throws {
        let f = fixture()
        #expect(throws: SpeechRefusal.engineUnavailable) {
            try SpeechInference().infer(model: f.model, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
    }

    @Test func selectedPrimaryWithOutOfRangeChannelIndexRefusesBeforeInference() throws {
        let f = fixture()
        let negative = ChannelReference(sourceID: f.primary.sourceID, statedChannel: -1)
        let firstOutOfRange = ChannelReference(sourceID: f.primary.sourceID, statedChannel: 1)

        for invalidChannel in [negative, firstOutOfRange] {
            var modelSelectingInvalidChannel = f.model
            modelSelectingInvalidChannel.episodes[0].speakerAssignments[0].primary = invalidChannel

            #expect(throws: SpeechRefusal.unselectedPrimary) {
                try SpeechInference().infer(
                    model: modelSelectingInvalidChannel,
                    episodeID: f.episodeID,
                    speakerID: f.speakerID,
                    channel: invalidChannel
                )
            }
            #if DEBUG
            #expect(throws: SpeechRefusal.unselectedPrimary) {
                try SpeechInference().syntheticProbe(
                    model: modelSelectingInvalidChannel,
                    episodeID: f.episodeID,
                    speakerID: f.speakerID,
                    channel: invalidChannel
                )
            }
            #endif
        }
    }

    @Test func backupAndProvisionalAssignmentRefuseBeforeAnyInference() throws {
        let f = fixture()
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: f.model, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.backup)
        }
        let provisional = fixture(confirmed: false)
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: provisional.model, episodeID: provisional.episodeID,
                                        speakerID: provisional.speakerID, channel: provisional.primary)
        }
    }

    @Test func unknownChannelAndPrimaryRevisionChangeRefuse() throws {
        let f = fixture()
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: f.model, episodeID: f.episodeID,
                                        speakerID: f.speakerID,
                                        channel: ChannelReference(sourceID: f.primary.sourceID, statedChannel: nil))
        }
        var changed = f.model
        changed.episodes[0].speakerAssignments[0].primary = f.backup
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: changed, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
    }

    @Test func activatingBackupRequiresNewSelectedPrimary() throws {
        let f = fixture()
        let activated = try f.model.usingAsPrimary(f.backup, for: f.speakerID, in: f.episodeID)
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: activated, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
        #expect(throws: SpeechRefusal.engineUnavailable) {
            try SpeechInference().infer(model: activated, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.backup)
        }
    }

    @Test func ambiguousOrUnobservedSourceRefuses() throws {
        let f = fixture()
        var unobserved = f.model
        unobserved.episodes[0].sources[0].observations.channelCount = .unknown
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: unobserved, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
        var ambiguous = f.model
        ambiguous.episodes[0].sources.append(ambiguous.episodes[0].sources[0])
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: ambiguous, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
    }

    @Test func conflictingRoleOrDuplicateAssignmentRefuses() throws {
        let f = fixture()
        var conflicting = f.model
        conflicting.episodes[0].sources[0].role = .backup
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: conflicting, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
        var duplicated = f.model
        duplicated.episodes[0].speakerAssignments.append(duplicated.episodes[0].speakerAssignments[0])
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: duplicated, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
        var wrongSchema = f.model
        wrongSchema.schemaVersion += 1
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().infer(model: wrongSchema, episodeID: f.episodeID,
                                        speakerID: f.speakerID, channel: f.primary)
        }
    }

    #if DEBUG
    @Test func syntheticProbeRunsOnlyHereWithNoRecognizedWords() throws {
        let f = fixture()
        let result = try SpeechInference().syntheticProbe(
            model: f.model, episodeID: f.episodeID, speakerID: f.speakerID, channel: f.primary
        )
        #expect(result.processID == getpid())
        #expect(result.syntheticFrameCount == 4)
        #expect(result.signalEnergy == 0.125)
        #expect(result.recognizedWordCount == 0)
        #expect(throws: SpeechRefusal.unselectedPrimary) {
            try SpeechInference().syntheticProbe(
                model: f.model, episodeID: f.episodeID, speakerID: f.speakerID, channel: f.backup
            )
        }
    }
    #endif
}
