import Foundation
import Testing
import WWCore
import WWSpeech
import WWTimeMap

@Suite("Inert selected-primary word evidence")
struct WordEvidenceTests {
    private struct Fixture {
        let model: ShowDocumentModel
        let origin: SpeechWordOrigin
        let revisions: SpeechWordVersions

        func word(
            id: String = "word-1", text: String = "synthetic",
            origin: SpeechWordOrigin? = nil, bounds: SourceWordBoundaries? = nil,
            confidence: WordRecognitionConfidence? = nil
        ) -> SpeechWordEvidence {
            SpeechWordEvidence(id: id, text: text, origin: origin ?? self.origin,
                               boundaries: bounds, confidence: confidence)
        }

        func batch(
            _ words: [SpeechWordEvidence], version: Int = SpeechWordEvidenceBatch.currentVersion,
            origin: SpeechWordOrigin? = nil, revisions: SpeechWordVersions? = nil
        ) -> SpeechWordEvidenceBatch {
            SpeechWordEvidenceBatch(version: version, origin: origin ?? self.origin,
                                    versions: revisions ?? self.revisions, words: words)
        }

        func validate(
            _ batch: SpeechWordEvidenceBatch, current: SpeechWordVersions? = nil,
            origin: SpeechWordOrigin? = nil, model: ShowDocumentModel? = nil
        ) throws -> ValidatedSpeechWordEvidence {
            try batch.validated(
                against: SpeechWordContext(origin: origin ?? self.origin,
                                           versions: current ?? revisions),
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
        let revisions = SpeechWordVersions(
            selection: "selection-1", source: "source-1", format: "format-1",
            alignment: nil, transcript: "transcript-1", derivedAsset: "derived-1",
            modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
            locale: "en-US", assetID: "local-asset", assetRevision: "asset-1")
        return Fixture(model: ShowDocumentModel(show: Show(title: "Synthetic show"),
                                                speakers: [speaker], episodes: [episode]),
                       origin: origin, revisions: revisions)
    }

    @Test func validInertBatchRetainsAbsentTimingAndConfidence() throws {
        let f = try fixture()
        let timed = f.word(bounds: SourceWordBoundaries(startFrame: 0, endFrame: 300),
                           confidence: WordRecognitionConfidence(value: -0.7, units: "log-probability"))
        let untimed = f.word(id: "word-2", text: "untimed")
        let later = f.word(id: "word-3", bounds: SourceWordBoundaries(startFrame: 300, endFrame: 48_000))
        let result = try f.validate(f.batch([timed, untimed, later]))
        #expect(result.words.count == 3)
        #expect(result.boundaryProvenance == [.unsupported, .unavailable, .unsupported])
        #expect(result.words[0].confidence?.value == -0.7)
        #expect(result.words[1].boundaries == nil)
        #expect(result.words[1].confidence == nil)
        let encoded = try JSONEncoder().encode(f.batch([timed, untimed, later]))
        let decoded = try JSONDecoder().decode(SpeechWordEvidenceBatch.self, from: encoded)
        #expect(decoded == f.batch([timed, untimed, later]))
        #expect(throws: SpeechRefusal.engineUnavailable) {
            try SpeechInference().infer(model: f.model, episodeID: f.origin.episodeID,
                                        speakerID: f.origin.speakerID, channel: f.origin.channel)
        }
    }

    @Test func segmentOrCallerBoundsNeverBecomeSupportedWordTiming() throws {
        let f = try fixture()
        let segment = SourceWordBoundaries(startFrame: 0, endFrame: 48_000)
        let words = [f.word(id: "part-1", text: "inter"),
                     f.word(id: "part-2", text: "national"),
                     f.word(id: "segment-only", bounds: segment)]
        let result = try f.validate(f.batch(words))
        #expect(result.boundaryProvenance == [.unavailable, .unavailable, .unsupported])
        #expect(result.words[0].boundaries == nil)
        #expect(result.words[1].boundaries == nil)
        #expect(result.words[2].boundaries == segment)
        let invented = try SourceOccurrence(id: f.origin.occurrence.id, source: f.origin.channel.sourceID,
                                            nominalRate: NominalRate(48_000), frameCount: 96_000)
        let callerOrigin = SpeechWordOrigin(
            episodeID: f.origin.episodeID, speakerID: f.origin.speakerID, channel: f.origin.channel,
            occurrence: invented, recorderGroupID: f.origin.recorderGroupID, epochID: f.origin.epochID)
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word(origin: callerOrigin, bounds: segment)],
                                   origin: callerOrigin))
        }
    }

    @Test func timedMultiwordSegmentCannotSupplyLexicalBoundaries() throws {
        let f = try fixture()
        let segmentText = "first second"
        let segmentStartSeconds = 0.0
        let segmentEndSeconds = 1.0
        #expect(segmentEndSeconds > segmentStartSeconds)
        let words = segmentText.split(separator: " ").enumerated().map { index, text in
            f.word(id: "segment-word-\(index)", text: String(text))
        }
        let result = try f.validate(f.batch(words))
        #expect(result.words.count == 2)
        #expect(result.words.allSatisfy { $0.boundaries == nil && $0.confidence == nil })
        #expect(result.boundaryProvenance == [.unavailable, .unavailable])

        let withConfidence = try f.validate(f.batch([
            f.word(confidence: WordRecognitionConfidence(value: 0.9, units: "raw-engine-value"))
        ]))
        #expect(withConfidence.words[0].confidence?.value == 0.9)
        #expect(withConfidence.words[0].boundaries == nil)
        #expect(withConfidence.boundaryProvenance == [.unavailable])
    }

    @Test func punctuationSubwordsAndOverlapCannotMintTimingSupport() throws {
        let f = try fixture()
        let tokens = [
            f.word(id: "prefix", text: "inter"),
            f.word(id: "punctuation", text: "!"),
            f.word(id: "suffix", text: "national"),
        ]
        let untimed = try f.validate(f.batch(tokens))
        #expect(untimed.boundaryProvenance == [.unavailable, .unavailable, .unavailable])

        let overlapping = [
            f.word(id: "first", bounds: SourceWordBoundaries(startFrame: 0, endFrame: 30_000)),
            f.word(id: "second", bounds: SourceWordBoundaries(startFrame: 10_000, endFrame: 48_000)),
        ]
        #expect(throws: SpeechWordEvidenceError.invalidOrder) {
            try f.validate(f.batch(overlapping))
        }
        let nonoverlapping = try f.validate(f.batch([
            f.word(id: "first", bounds: SourceWordBoundaries(startFrame: 0, endFrame: 10_000)),
            f.word(id: "second", bounds: SourceWordBoundaries(startFrame: 10_000, endFrame: 48_000)),
        ]))
        #expect(nonoverlapping.boundaryProvenance == [.unsupported, .unsupported])
    }

    @Test func generationAndRevisionMismatchRefusePublication() throws {
        let f = try fixture()
        let newOccurrence = try SourceOccurrence(source: f.origin.channel.sourceID,
                                                  nominalRate: NominalRate(48_000), frameCount: 48_000)
        let newOrigin = SpeechWordOrigin(
            episodeID: f.origin.episodeID, speakerID: f.origin.speakerID, channel: f.origin.channel,
            occurrence: newOccurrence, recorderGroupID: f.origin.recorderGroupID, epochID: f.origin.epochID)
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word(origin: newOrigin)], origin: newOrigin))
        }
        let stale = SpeechWordVersions(
            selection: "selection-1", source: "source-1", format: "format-1",
            alignment: nil, transcript: "transcript-2", derivedAsset: "derived-1",
            modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
            locale: "en-US", assetID: "local-asset", assetRevision: "asset-1")
        #expect(throws: SpeechWordEvidenceError.staleUpstream) {
            try f.validate(f.batch([f.word()]), current: stale)
        }
        let mapped = SpeechWordVersions(
            selection: "selection-1", source: "source-1", format: "format-1",
            alignment: 1, transcript: "transcript-1", derivedAsset: "derived-1",
            modelID: "local-model", modelRevision: "model-1", decoderRevision: "decoder-1",
            locale: "en-US", assetID: "local-asset", assetRevision: "asset-1")
        #expect(throws: SpeechWordEvidenceError.staleUpstream) {
            try f.validate(f.batch([f.word()], revisions: mapped), current: mapped)
        }
    }

    @Test func wrongLaneBackupAndUnconfirmedSelectionRefuse() throws {
        let f = try fixture()
        let other = SpeechWordOrigin(
            episodeID: f.origin.episodeID, speakerID: f.origin.speakerID,
            channel: ChannelReference(sourceID: f.origin.channel.sourceID, statedChannel: 1),
            occurrence: f.origin.occurrence, recorderGroupID: f.origin.recorderGroupID,
            epochID: f.origin.epochID)
        #expect(throws: SpeechWordEvidenceError.mismatchedOrigin) {
            try f.validate(f.batch([f.word(origin: other)]))
        }
        var changed = f.model
        changed.episodes[0].speakerAssignments[0].backups = [f.origin.channel]
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

    @Test func invalidRangeOrderingAndConfidenceRefuse() throws {
        let f = try fixture()
        for bounds in [
            SourceWordBoundaries(startFrame: -1, endFrame: 1),
            SourceWordBoundaries(startFrame: 0, endFrame: 0),
            SourceWordBoundaries(startFrame: 47_999, endFrame: 48_001),
        ] {
            #expect(throws: SpeechWordEvidenceError.invalidBoundary) {
                try f.validate(f.batch([f.word(bounds: bounds)]))
            }
        }
        #expect(throws: SpeechWordEvidenceError.invalidOrder) {
            try f.validate(f.batch([
                f.word(bounds: SourceWordBoundaries(startFrame: 100, endFrame: 400)),
                f.word(id: "word-2", bounds: SourceWordBoundaries(startFrame: 300, endFrame: 500)),
            ]))
        }
        for confidence in [
            WordRecognitionConfidence(value: .nan, units: "log-probability"),
            WordRecognitionConfidence(value: .infinity, units: "log-probability"),
            WordRecognitionConfidence(value: 0.5, units: " "),
        ] {
            #expect(throws: SpeechWordEvidenceError.invalidConfidence) {
                try f.validate(f.batch([f.word(confidence: confidence)]))
            }
        }
    }

    @Test func versionDuplicateIdentifierAndBlankTokenRefuse() throws {
        let f = try fixture()
        #expect(throws: SpeechWordEvidenceError.unsupportedVersion) {
            try f.validate(f.batch([f.word()], version: 2))
        }
        #expect(throws: SpeechWordEvidenceError.duplicateIdentifier) {
            try f.validate(f.batch([f.word(), f.word()]))
        }
        #expect(throws: SpeechWordEvidenceError.invalidWord) {
            try f.validate(f.batch([f.word(text: " \t ")]))
        }
    }
}
