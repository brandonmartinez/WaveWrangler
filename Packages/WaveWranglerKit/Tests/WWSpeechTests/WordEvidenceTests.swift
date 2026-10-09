import Foundation
import Testing
import WWCore
import WWSpeech
import WWTimeMap

@Suite("Inert source-word evidence")
struct WordEvidenceTests {
    private struct Fixture {
        let model: ShowDocumentModel
        let origin: SpeechWordOrigin
        let versions: SpeechWordVersions

        func word(
            id: String = "word-1", text: String = "synthetic",
            origin: SpeechWordOrigin? = nil, boundaries: SourceWordBoundaries? = nil,
            confidence: WordRecognitionConfidence? = nil
        ) -> SpeechWordEvidence {
            SpeechWordEvidence(id: id, text: text, origin: origin ?? self.origin,
                               boundaries: boundaries, confidence: confidence)
        }

        func batch(_ words: [SpeechWordEvidence], version: Int = SpeechWordEvidenceBatch.currentVersion,
                   origin: SpeechWordOrigin? = nil, versions: SpeechWordVersions? = nil) -> SpeechWordEvidenceBatch {
            SpeechWordEvidenceBatch(version: version, origin: origin ?? self.origin,
                                    versions: versions ?? self.versions, words: words)
        }

        func validate(_ batch: SpeechWordEvidenceBatch, current: SpeechWordVersions? = nil,
                      model: ShowDocumentModel? = nil, origin: SpeechWordOrigin? = nil) throws -> ValidatedSpeechWordEvidence {
            try batch.validated(
                against: SpeechWordContext(origin: origin ?? self.origin, versions: current ?? versions),
                model: model ?? self.model)
        }
    }

    private func fixture() throws -> Fixture {
        let speaker = Speaker(name: "Synthetic speaker")
        let epoch = RecordingEpoch(label: "Synthetic epoch")
        let group = RecorderGroup(name: "Synthetic recorder", epochs: [epoch])
        let source = SourceRecord(
            displayNameHint: "synthetic-only",
            observations: SourceObservations(channelCount: .known(2)),
            placement: SourcePlacement(recorderGroupID: group.id, epochID: epoch.id),
            role: .primary, roleConfirmation: .userConfirmed)
        let channel = ChannelReference(sourceID: source.id, statedChannel: 0)
        let episode = Episode(
            title: "Synthetic episode", recorderGroups: [group], sources: [source],
            speakerAssignments: [SpeakerAssignment(speakerID: speaker.id, primary: channel,
                                                   primaryConfirmation: .userConfirmed)])
        let occurrence = try SourceOccurrence(source: source.id, nominalRate: NominalRate(48_000),
                                              frameCount: 48_000)
        let origin = SpeechWordOrigin(episodeID: episode.id, speakerID: speaker.id, channel: channel,
                                      occurrence: occurrence, recorderGroupID: group.id, epochID: epoch.id)
        let versions = SpeechWordVersions(
            selection: "selection-1", source: "source-1", format: "format-1",
            alignment: nil, transcript: "transcript-1", derivedAsset: "derived-1",
            modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
            locale: "en-US", assetID: "local-asset", assetRevision: "asset-1")
        return Fixture(model: ShowDocumentModel(show: Show(title: "Synthetic show"),
                                                speakers: [speaker], episodes: [episode]),
                       origin: origin, versions: versions)
    }

    @Test func acceptsTimedAndUntimedWordsWithoutSynthesizingMissingEvidence() throws {
        let f = try fixture()
        let timed = f.word(boundaries: SourceWordBoundaries(startFrame: 0, endFrame: 300),
                           confidence: WordRecognitionConfidence(value: -0.7, units: "log-probability"))
        let untimed = f.word(id: "word-2", text: "untimed")
        let later = f.word(id: "word-3", boundaries: SourceWordBoundaries(startFrame: 300, endFrame: 48_000))
        let result = try f.validate(f.batch([timed, untimed, later]))
        #expect(result.words.count == 3)
        #expect(result.words[0].boundaries?.startFrame == 0)
        #expect(result.words[0].confidence?.value == -0.7)
        #expect(result.words[1].boundaries == nil)
        #expect(result.words[1].confidence == nil)
        #expect(result.words[2].boundaries?.endFrame == 48_000)
        let decoded = try JSONDecoder().decode(SpeechWordEvidenceBatch.self,
                                               from: JSONEncoder().encode(f.batch([timed, untimed, later])))
        #expect(decoded.version == SpeechWordEvidenceBatch.currentVersion)
        #expect(decoded.words[1].boundaries == nil)
        #expect(decoded.words[1].confidence == nil)
        #expect(throws: SpeechRefusal.engineUnavailable) {
            try SpeechInference().infer(model: f.model, episodeID: f.origin.episodeID,
                                        speakerID: f.origin.speakerID, channel: f.origin.channel)
        }
    }

    @Test func syntheticSegmentTimingCannotSupportWords() throws {
        let f = try fixture()
        let first = f.word(id: "synthetic-word-1", text: "first")
        let second = f.word(id: "synthetic-word-2", text: "second")
        let inferred = try f.validate(f.batch([first, second]))
        #expect(inferred.boundaryProvenance == [.unavailable, .unavailable])
        #expect(inferred.words.allSatisfy { $0.boundaries == nil && $0.confidence == nil })

        let fragments = try f.validate(f.batch([
            f.word(id: "subword", text: "inter"),
            f.word(id: "punctuation", text: "!"),
            f.word(id: "remainder", text: "national"),
        ]))
        #expect(fragments.boundaryProvenance == [.unavailable, .unavailable, .unavailable])

        let segmentFrames = SourceWordBoundaries(startFrame: 0, endFrame: 48_000)
        let segmentShapedWord = f.word(id: "segment-shaped", boundaries: segmentFrames)
        let unproven = try f.validate(f.batch([segmentShapedWord]))
        #expect(unproven.boundaryProvenance == [.unsupported])
        #expect(unproven.words[0].boundaries == segmentFrames)
        #expect(unproven.words[0].confidence == nil)
        #expect(throws: SpeechWordEvidenceError.invalidOrder) {
            try f.validate(f.batch([
                f.word(id: "overlap-1", boundaries: SourceWordBoundaries(startFrame: 0, endFrame: 30_000)),
                f.word(id: "overlap-2", boundaries: SourceWordBoundaries(startFrame: 10_000, endFrame: 48_000)),
            ]))
        }
    }

    @Test func rejectsUnknownVersionDuplicateIDsAndEmptyWords() throws {
        let f = try fixture()
        let word = f.word()
        #expect(throws: SpeechWordEvidenceError.unsupportedVersion) {
            try f.validate(f.batch([word], version: 2))
        }
        #expect(throws: SpeechWordEvidenceError.duplicateIdentifier) {
            try f.validate(f.batch([word, word]))
        }
        #expect(throws: SpeechWordEvidenceError.invalidWord) {
            try f.validate(f.batch([f.word(text: " \t ")]))
        }
    }

    @Test func refusesCrossLaneAndUnconfirmedSelection() throws {
        let f = try fixture()
        let otherChannel = SpeechWordOrigin(
            episodeID: f.origin.episodeID, speakerID: f.origin.speakerID,
            channel: ChannelReference(sourceID: f.origin.channel.sourceID, statedChannel: 1),
            occurrence: f.origin.occurrence, recorderGroupID: f.origin.recorderGroupID,
            epochID: f.origin.epochID)
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word(origin: otherChannel)]))
        }
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word()], origin: otherChannel))
        }
        let otherOccurrence = try SourceOccurrence(source: f.origin.channel.sourceID,
                                                   nominalRate: NominalRate(48_000), frameCount: 48_000)
        let otherOrigin = SpeechWordOrigin(episodeID: f.origin.episodeID, speakerID: f.origin.speakerID,
                                           channel: f.origin.channel, occurrence: otherOccurrence,
                                           recorderGroupID: f.origin.recorderGroupID, epochID: f.origin.epochID)
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word(origin: otherOrigin)]))
        }
        let otherEpisode = SpeechWordOrigin(
            episodeID: EpisodeID(), speakerID: f.origin.speakerID, channel: f.origin.channel,
            occurrence: f.origin.occurrence, recorderGroupID: f.origin.recorderGroupID,
            epochID: f.origin.epochID)
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word(origin: otherEpisode)]))
        }
        var changed = f.model
        changed.episodes[0].speakerAssignments[0].primary = otherChannel.channel
        #expect(throws: SpeechWordEvidenceError.unselectedPrimary) {
            try f.validate(f.batch([f.word()]), model: changed)
        }
        changed = f.model
        changed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        #expect(throws: SpeechWordEvidenceError.unselectedPrimary) {
            try f.validate(f.batch([f.word()]), model: changed)
        }
        changed = f.model
        changed.episodes[0].sources[0].placement.epochID = RecordingEpochID()
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word()]), model: changed)
        }
    }

    @Test func refusesStaleSelectionAndUpstreamRevisions() throws {
        let f = try fixture()
        let changed: [SpeechWordVersions] = [
            SpeechWordVersions(selection: "selection-2", source: "source-1", format: "format-1",
                               alignment: nil, transcript: "transcript-1", derivedAsset: "derived-1",
                               modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
                               locale: "en-US", assetID: "local-asset", assetRevision: "asset-1"),
            SpeechWordVersions(selection: "selection-1", source: "source-2", format: "format-1",
                               alignment: nil, transcript: "transcript-1", derivedAsset: "derived-1",
                               modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
                               locale: "en-US", assetID: "local-asset", assetRevision: "asset-1"),
            SpeechWordVersions(selection: "selection-1", source: "source-1", format: "format-1",
                               alignment: nil, transcript: "transcript-1", derivedAsset: "derived-1",
                               modelID: "local-model", modelRevision: "model-2", decoderRevision: "decoder-1",
                               locale: "en-US", assetID: "local-asset", assetRevision: "asset-1"),
            SpeechWordVersions(selection: "selection-1", source: "source-1", format: "format-1",
                               alignment: nil, transcript: "transcript-1", derivedAsset: "derived-1",
                               modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
                               locale: "en-US", assetID: "local-asset", assetRevision: "asset-2"),
        ]
        for revision in changed {
            #expect(throws: SpeechWordEvidenceError.staleUpstream) {
                try f.validate(f.batch([f.word()]), current: revision)
            }
        }
        #expect(throws: SpeechWordEvidenceError.invalidIdentity) {
            try f.validate(f.batch([f.word()], versions: SpeechWordVersions(
                selection: "", source: "source-1", format: "format-1", alignment: nil,
                transcript: "transcript-1", derivedAsset: "derived-1", modelID: "local-model",
                modelRevision: "model-1", decoderRevision: "decoder-1", locale: "en-US",
                assetID: "local-asset", assetRevision: "asset-1")))
        }
    }

    @Test func refusesInvalidAndOutOfSourceWordBoundaries() throws {
        let f = try fixture()
        for bounds in [
            SourceWordBoundaries(startFrame: 0, endFrame: 0),
            SourceWordBoundaries(startFrame: 15, endFrame: 3),
            SourceWordBoundaries(startFrame: -1, endFrame: 1),
            SourceWordBoundaries(startFrame: 47_999, endFrame: 48_001),
            SourceWordBoundaries(startFrame: 48_000, endFrame: 48_001),
        ] {
            #expect(throws: SpeechWordEvidenceError.invalidBoundary) {
                try f.validate(f.batch([f.word(boundaries: bounds)]))
            }
        }
        #expect(throws: SpeechWordEvidenceError.invalidOrder) {
            try f.validate(f.batch([
                f.word(boundaries: SourceWordBoundaries(startFrame: 300, endFrame: 400)),
                f.word(id: "word-2", boundaries: SourceWordBoundaries(startFrame: 200, endFrame: 250)),
            ]))
        }
        #expect(throws: SpeechWordEvidenceError.invalidOrder) {
            try f.validate(f.batch([
                f.word(boundaries: SourceWordBoundaries(startFrame: 100, endFrame: 400)),
                f.word(id: "word-2", boundaries: SourceWordBoundaries(startFrame: 300, endFrame: 500)),
            ]))
        }
    }

    @Test func rejectsFabricatedConfidenceAndStaleCanonicalMap() throws {
        let f = try fixture()
        for confidence in [
            WordRecognitionConfidence(value: .nan, units: "log-probability"),
            WordRecognitionConfidence(value: .infinity, units: "log-probability"),
            WordRecognitionConfidence(value: 0.5, units: "  "),
        ] {
            #expect(throws: SpeechWordEvidenceError.invalidConfidence) {
                try f.validate(f.batch([f.word(confidence: confidence)]))
            }
        }
        let mapped = SpeechWordVersions(selection: "selection-1", source: "source-1", format: "format-1",
                                        alignment: 1, transcript: "transcript-1", derivedAsset: "derived-1",
                                        modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
                                        locale: "en-US", assetID: "local-asset", assetRevision: "asset-1")
        #expect(throws: SpeechWordEvidenceError.staleUpstream) {
            try f.validate(f.batch([f.word()], versions: mapped), current: mapped)
        }
    }
}
