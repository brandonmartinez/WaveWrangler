import Foundation
import Testing
import WWCore

@Suite("Portable episode mixer")
struct EpisodeMixTests {
    struct Fixture {
        let host = Speaker(name: "Host")
        let guest = Speaker(name: "Guest")
        let first = SourceRecord(displayNameHint: "Generated first", observations: .init(channelCount: .known(2)))
        let second = SourceRecord(displayNameHint: "Generated second", observations: .init(channelCount: .known(2)))
        let episodeID = EpisodeID()

        var firstChannel: ChannelReference { .init(sourceID: first.id, statedChannel: 0) }
        var secondChannel: ChannelReference { .init(sourceID: second.id, statedChannel: 1) }
        var show: ShowDocumentModel {
            ShowDocumentModel(show: Show(title: "Synthetic"), speakers: [host, guest], episodes: [
                Episode(id: episodeID, title: "Episode", sources: [first, second], speakerAssignments: [
                    .init(speakerID: host.id, primary: firstChannel, primaryConfirmation: .userConfirmed,
                          backups: [secondChannel]),
                    .init(speakerID: guest.id),
                ]),
                Episode(title: "Other"),
            ])
        }
    }

    func slot(_ name: String = "Synthetic effect", state: Data? = nil) -> AudioUnitSlot {
        AudioUnitSlot(component: .init(type: 0x61756678, subtype: 0x74657374, manufacturer: 0x74657374),
                      productName: name, version: "1.0", documentState: state)
    }

    func state(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    @Test func neutralDefaultsAndNoOpEditsDoNotInventCanonicalState() throws {
        let f = Fixture(), original = f.show
        let neutral = EpisodeMixState()
        #expect(original.episodes[0].mix == nil)
        #expect(neutral.inputGainDB(for: f.first.id, channel: 0) == 0)
        #expect(neutral.state(for: f.host.id) == SpeakerMixState(speaker: f.host.id))
        #expect(neutral.master == MasterMixState(gainDB: 0, inserts: []))
        #expect(neutral.validationIssues(in: original.episodes[0]).isEmpty)
        #expect(try original.settingInputGain(0, for: f.firstChannel, in: f.episodeID) == original)
        #expect(try original.settingSpeakerMix(.init(speaker: f.host.id), in: f.episodeID) == original)
        #expect(try original.settingMasterMix(.init(), in: f.episodeID) == original)
        let explicitNeutral = try original.settingMix(neutral, in: f.episodeID)
        #expect(explicitNeutral.hasSameProcessingInputs(as: original, in: f.episodeID))
    }

    @Test func stateRoundTripsWithoutDiscoveryAndPreservesInsertOrderAndIdentity() throws {
        let f = Fixture()
        let payload = try state(["gain": 0.25, "nested": ["opaque": Data([0, 1, 255])]])
        var first = slot("Unavailable third-party effect", state: payload)
        first.bypassed = true
        let second = slot("Another unavailable effect")
        var model = try f.show.settingInputGain(12, for: f.firstChannel, in: f.episodeID)
        model = try model.settingSpeakerMix(.init(speaker: f.host.id, gainDB: -6, pan: -0.25,
                                                  inserts: [first, second]), in: f.episodeID)
        model = try model.settingMasterMix(.init(gainDB: -3, inserts: [slot()]), in: f.episodeID)
        let reopened = try JSONDecoder().decode(ShowDocumentModel.self, from: JSONEncoder().encode(model))
        #expect(reopened == model)
        #expect(reopened.episodes[0].mix?.state(for: f.host.id).inserts == [first, second])
        #expect(reopened.episodes[0].mix?.state(for: f.host.id).inserts[0].documentState == payload)
        #expect(reopened.validationIssues().isEmpty)
    }

    @Test(arguments: [-96.0, 0, 24])
    func gainEndpointsAreAccepted(_ gain: Double) throws {
        let f = Fixture()
        var model = try f.show.settingInputGain(gain, for: f.firstChannel, in: f.episodeID)
        model = try model.settingSpeakerMix(.init(speaker: f.host.id, gainDB: gain), in: f.episodeID)
        model = try model.settingMasterMix(.init(gainDB: gain), in: f.episodeID)
        #expect(model.validationIssues().isEmpty)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -96.001, 24.001])
    func nonfiniteAndOutOfRangeLevelsAreRefused(_ gain: Double) {
        let f = Fixture(), original = f.show
        #expect(throws: DomainError.self) { try original.settingInputGain(gain, for: f.firstChannel, in: f.episodeID) }
        #expect(throws: DomainError.self) {
            try original.settingSpeakerMix(.init(speaker: f.host.id, gainDB: gain), in: f.episodeID)
        }
        #expect(throws: DomainError.self) { try original.settingMasterMix(.init(gainDB: gain), in: f.episodeID) }
        #expect(original.episodes[0].mix == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -1.001, 1.001])
    func invalidPanIsRefused(_ pan: Double) {
        let f = Fixture()
        #expect(throws: DomainError.self) {
            try f.show.settingSpeakerMix(.init(speaker: f.host.id, pan: pan), in: f.episodeID)
        }
    }

    @Test func invalidReferencesAndDuplicateKeysAreRefused() throws {
        let f = Fixture(), original = f.show
        let gain = RecordingInputGain(source: f.first.id, channel: 0, gainDB: 2)
        let strip = SpeakerMixState(speaker: f.host.id, pan: 1)
        let effect = slot()
        let invalid: [EpisodeMixState] = [
            .init(inputGains: [gain, gain]),
            .init(inputGains: [.init(source: SourceID(), channel: 0)]),
            .init(inputGains: [.init(source: f.first.id, channel: -1)]),
            .init(inputGains: [.init(source: f.first.id, channel: 2)]),
            .init(speakers: [strip, strip]),
            .init(speakers: [.init(speaker: SpeakerID())]),
            .init(speakers: [.init(speaker: f.host.id, inserts: [effect, effect])]),
            .init(speakers: [.init(speaker: f.host.id, inserts: [effect])], master: .init(inserts: [effect])),
            .init(master: .init(inserts: (0...EpisodeMixState.maximumInsertsPerBus).map { _ in slot() })),
        ]
        for mix in invalid {
            #expect(!mix.validationIssues(in: original.episodes[0]).isEmpty)
            #expect(throws: DomainError.self) { try original.settingMix(mix, in: f.episodeID) }
            var corrupt = original
            corrupt.episodes[0].mix = mix
            #expect(corrupt.validationIssues().contains { $0.code == .invalidMix })
        }
    }

    @Test func operationTargetsMustExistInTheCorrectEpisode() {
        let f = Fixture()
        let missingEpisode = EpisodeID()
        #expect(throws: DomainError.episodeNotFound(missingEpisode)) {
            try f.show.settingMix(.init(), in: missingEpisode)
        }
        #expect(throws: DomainError.self) {
            try f.show.settingSpeakerMix(.init(speaker: f.host.id, gainDB: -2), in: f.show.episodes[1].id)
        }
        #expect(throws: DomainError.self) {
            try f.show.settingInputGain(2, for: f.firstChannel, in: f.show.episodes[1].id)
        }
    }

    @Test func inputGainNeverInventsAnUnknownChannelOrMovesWhenStatedChannelChanges() throws {
        let f = Fixture()
        let unknown = ChannelReference(sourceID: f.first.id, channel: .unknown)
        #expect(throws: DomainError.invalidChannel(unknown)) {
            try f.show.settingInputGain(6, for: unknown, in: f.episodeID)
        }
        var mono = f.show
        mono.episodes[0].sources[0].observations.channelCount = .known(1)
        #expect(throws: DomainError.invalidChannel(unknown)) {
            try mono.settingInputGain(6, for: unknown, in: f.episodeID)
        }
        #expect(unknown.resolvedChannel(channelCount: 2) == nil)
        #expect(unknown.resolvedChannel(channelCount: nil) == nil)
        #expect(unknown.resolvedChannel(channelCount: 1) == 0)
        let gained = try f.show.settingInputGain(6, for: f.firstChannel, in: f.episodeID)
        let changed = try gained.settingStatedChannel(1, forSource: f.first.id, in: f.episodeID)
        #expect(changed.episodes[0].mix?.inputGainDB(for: f.first.id, channel: 0) == 6)
        #expect(changed.episodes[0].mix?.inputGainDB(for: f.first.id, channel: 1) == 0)
        #expect(changed.episodes[0].assignment(for: f.host.id)?.primary?.channel == .known(1))
        let unresolved = try changed.settingStatedChannel(nil, forSource: f.first.id, in: f.episodeID)
        #expect(unresolved.episodes[0].assignment(for: f.host.id)?.primary?.channel == .unknown)
        #expect(unresolved.episodes[0].mix == gained.episodes[0].mix)
    }

    @Test func primaryReplacementRetainsEachRecordingGainAndTheSpeakerChain() throws {
        let f = Fixture()
        let strip = SpeakerMixState(speaker: f.host.id, gainDB: -3, pan: 0.5, inserts: [slot()])
        var model = try f.show.settingInputGain(12, for: f.firstChannel, in: f.episodeID)
        model = try model.settingInputGain(-4, for: f.secondChannel, in: f.episodeID)
        model = try model.settingSpeakerMix(strip, in: f.episodeID)
        let replacement = try model.usingAsPrimary(f.secondChannel, for: f.host.id, in: f.episodeID)
        #expect(replacement.episodes[0].assignment(for: f.host.id)?.primary == f.secondChannel)
        #expect(replacement.episodes[0].assignment(for: f.host.id)?.backups == [f.firstChannel])
        #expect(replacement.episodes[0].mix == model.episodes[0].mix)
        #expect(replacement.episodes[0].mix?.inputGainDB(for: f.second.id, channel: 1) == -4)
        #expect(replacement.episodes[0].mix?.state(for: f.host.id) == strip)
        let direct = try model.assigningPrimary(f.secondChannel, to: f.host.id, in: f.episodeID, confirmation: .userConfirmed)
        #expect(direct.episodes[0].mix == model.episodes[0].mix)
        let cleared = try replacement.clearingPrimary(of: f.host.id, in: f.episodeID)
        #expect(cleared.episodes[0].mix == replacement.episodes[0].mix)
    }

    @Test func repeatedGainEditsAreNoOpsAndResetTouchesOnlyTheSelectedChannel() throws {
        let f = Fixture()
        let otherChannel = ChannelReference(sourceID: f.first.id, statedChannel: 1)
        var original = try f.show.settingInputGain(2, for: f.firstChannel, in: f.episodeID)
        original = try original.settingInputGain(3, for: otherChannel, in: f.episodeID)
        original = try original.settingInputGain(4, for: f.secondChannel, in: f.episodeID)
        #expect(try original.settingInputGain(2, for: f.firstChannel, in: f.episodeID) == original)
        let changed = try original.settingInputGain(6, for: f.firstChannel, in: f.episodeID)
        #expect(changed.episodes[0].mix?.inputGains.map(\.reference)
                == original.episodes[0].mix?.inputGains.map(\.reference))
        let reset = try original.settingInputGain(0, for: f.firstChannel, in: f.episodeID)
        #expect(reset.episodes[0].mix?.inputGains == [
            .init(source: f.first.id, channel: 1, gainDB: 3), .init(source: f.second.id, channel: 1, gainDB: 4),
        ])
    }

    @Test func deletingSourcesAndSpeakersPrunesOnlyTheirOwnState() throws {
        let f = Fixture()
        var model = try f.show.settingInputGain(8, for: f.firstChannel, in: f.episodeID)
        model = try model.settingInputGain(2, for: f.secondChannel, in: f.episodeID)
        model = try model.settingSpeakerMix(.init(speaker: f.host.id, inserts: [slot()]), in: f.episodeID)
        model = try model.settingSpeakerMix(.init(speaker: f.guest.id, gainDB: -6), in: f.episodeID)
        model = try model.settingMasterMix(.init(gainDB: -1, inserts: [slot()]), in: f.episodeID)
        let removedSource = try model.removingSource(f.first.id, from: f.episodeID)
        #expect(removedSource.episodes[0].mix?.inputGains == [.init(source: f.second.id, channel: 1, gainDB: 2)])
        #expect(removedSource.episodes[0].mix?.speakers == model.episodes[0].mix?.speakers)
        let removedSpeaker = try model.removingSpeaker(f.host.id, fromEpisode: f.episodeID)
        #expect(removedSpeaker.episodes[0].mix?.speakers == [.init(speaker: f.guest.id, gainDB: -6)])
        #expect(removedSpeaker.episodes[0].mix?.inputGains == model.episodes[0].mix?.inputGains)
        #expect(removedSpeaker.episodes[0].mix?.master == model.episodes[0].mix?.master)
        #expect(removedSource.validationIssues().isEmpty && removedSpeaker.validationIssues().isEmpty)
        #expect(removedSpeaker.episodes[1] == model.episodes[1])
        #expect(model.episodes[0].mix?.speakers.count == 2, "Pure edits retain the complete Undo snapshot")
    }

    @Test func insertEditsPreserveStableIDsAndUnrelatedMixState() throws {
        let f = Fixture()
        let first = slot("First"), second = slot("Second")
        let original = try f.show.settingSpeakerMix(.init(speaker: f.host.id, inserts: [first, second]), in: f.episodeID)
        var strip = try #require(original.episodes[0].mix).state(for: f.host.id)
        strip.inserts = [second, first]
        strip.inserts[0].bypassed = true
        strip.inserts[0].documentState = try state(["parameter": 0.75])
        let reordered = try original.settingSpeakerMix(strip, in: f.episodeID)
        #expect(reordered.episodes[0].mix?.state(for: f.host.id).inserts.map(\.id) == [second.id, first.id])
        strip.inserts.removeLast()
        let removed = try reordered.settingSpeakerMix(strip, in: f.episodeID)
        #expect(removed.episodes[0].mix?.state(for: f.host.id).inserts.map(\.id) == [second.id])
        #expect(original.episodes[0].mix?.state(for: f.host.id).inserts == [first, second])
    }

    @Test func pluginStateMustBeABoundedFinitePropertyListDictionary() throws {
        #expect(slot(state: try state(["parameters": [1, 2, 3]], format: .xml)).isValid)
        #expect(slot(state: try state([String: String]())).isValid)
        let invalid = [
            Data(), Data([0, 1, 2]), Data("{ amount = 1; }".utf8), try state(["not a dictionary"]),
            try state(["$archiver": "NSKeyedArchiver", "$objects": []]),
            try state(["parameter": Double.nan]),
            Data(repeating: 0, count: AudioUnitSlot.maximumDocumentStateBytes + 1),
        ]
        let f = Fixture()
        for bytes in invalid {
            let effect = slot(state: bytes)
            #expect(!effect.isValid)
            #expect(throws: DomainError.self) {
                try f.show.settingMasterMix(.init(inserts: [effect]), in: f.episodeID)
            }
        }
        var nested: Any = "leaf"
        for _ in 0..<66 { nested = ["nested": nested] }
        #expect(!slot(state: try state(nested)).isValid)
        var invalidDiagnostic = slot()
        invalidDiagnostic.version = " "
        #expect(!invalidDiagnostic.isValid)
        invalidDiagnostic.version = String(repeating: "x", count: 1025)
        #expect(!invalidDiagnostic.isValid)
        for component in [
            AudioUnitComponentIdentity(type: 0, subtype: 1, manufacturer: 1),
            .init(type: 0x61756D75, subtype: 1, manufacturer: 1),
            .init(type: 0x61756678, subtype: 0, manufacturer: 1),
            .init(type: 0x61756678, subtype: 1, manufacturer: 0),
        ] {
            #expect(!AudioUnitSlot(component: component).isValid)
        }
        #expect(AudioUnitSlot(component: .init(type: 0x61756D66, subtype: 1, manufacturer: 1)).isValid)
    }

    @Test func processingChangesDoNotInvalidateWaveformsTimingOrRawTranscripts() throws {
        let f = Fixture()
        var original = f.show
        original.episodes[0].cleanup = .init(transcripts: [
            .init(speaker: f.host.id, primary: f.firstChannel, sourceRate: 48_000,
                  sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
                  model: "synthetic", workingRange: nil, words: [.init(text: "Original raw text")]),
        ])
        let gain = try original.settingInputGain(4, for: f.firstChannel, in: f.episodeID)
        let speaker = try gain.settingSpeakerMix(.init(speaker: f.host.id, gainDB: -3, pan: -1,
                                                     inserts: [slot()]), in: f.episodeID)
        let master = try speaker.settingMasterMix(.init(gainDB: -2), in: f.episodeID)
        for model in [gain, speaker, master] {
            #expect(model.hasSameMediaInputs(as: original, in: f.episodeID, includingWorkingRange: true))
            #expect(!model.hasSameProcessingInputs(as: original, in: f.episodeID))
            #expect(model.episodes[0].alignment == original.episodes[0].alignment)
            #expect(model.episodes[0].cleanup == original.episodes[0].cleanup)
            #expect(model.episodes[0].speakerAssignments == original.episodes[0].speakerAssignments)
        }
        var renamed = master
        renamed.episodes[0].notes = "Presentation only"
        renamed.speakers[0].name = "Renamed"
        #expect(renamed.hasSameProcessingInputs(as: master, in: f.episodeID))
        #expect(!renamed.hasSameProcessingInputs(as: master, in: EpisodeID()))
        var changedState = speaker
        changedState.episodes[0].mix?.speakers[0].inserts[0].documentState = try state(["value": 1])
        #expect(!changedState.hasSameProcessingInputs(as: speaker, in: f.episodeID))
        #expect(changedState.hasSameMediaInputs(as: speaker, in: f.episodeID))
    }

    @Test func aggregateDocumentStateHasAnIndependentEpisodeBudget() throws {
        let f = Fixture()
        let payload = try state(["opaque": Data(repeating: 0, count: 13 * 1024 * 1024)])
        let effects = (0..<5).map { _ in slot(state: payload) }
        #expect(effects.allSatisfy { $0.isValid }, "Each payload is below the per-slot limit")
        let withinBudget = EpisodeMixState(master: .init(inserts: Array(effects.prefix(4))))
        #expect(withinBudget.validationIssues(in: f.show.episodes[0]).isEmpty)
        let overBudget = EpisodeMixState(master: .init(inserts: effects))
        #expect(effects.reduce(0, { $0 + ($1.documentState?.count ?? 0) })
                > EpisodeMixState.maximumDocumentStateBytes)
        #expect(overBudget.validationIssues(in: f.show.episodes[0]).contains {
            $0.detail.contains("combined insert document state exceeds")
        })
        #expect(throws: DomainError.self) { try f.show.settingMix(overBudget, in: f.episodeID) }
    }

    @Test func processingDependencyIgnoresSparseControlOrderingButNotInsertOrdering() throws {
        let f = Fixture()
        let mix = EpisodeMixState(inputGains: [
            .init(source: f.first.id, channel: 0, gainDB: 2), .init(source: f.second.id, channel: 1, gainDB: 3),
        ], speakers: [
            .init(speaker: f.host.id, inserts: [slot("First"), slot("Second")]), .init(speaker: f.guest.id, pan: 1),
        ])
        let original = try f.show.settingMix(mix, in: f.episodeID)
        var reordered = original
        reordered.episodes[0].mix?.inputGains.reverse()
        reordered.episodes[0].mix?.speakers.reverse()
        #expect(reordered.hasSameProcessingInputs(as: original, in: f.episodeID))
        reordered.episodes[0].mix?.speakers[1].inserts.reverse()
        #expect(!reordered.hasSameProcessingInputs(as: original, in: f.episodeID))
    }

    @Test func pureEditsFitNamedHistoryWithoutRegisteringDuplicateEntries() throws {
        let f = Fixture()
        let timestamp = Date(timeIntervalSince1970: 0)
        let original = f.show
        let operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel = {
            try $0.settingInputGain(6, for: f.firstChannel, in: f.episodeID)
        }
        var edited = try operation(original)
        #expect(edited.history == original.history, "The shared document store owns edit/coalescing registration")
        edited.history = edited.history.recording(.init(actionName: "Change Input Gain", timestamp: timestamp))
        var coalesced = try edited.settingInputGain(8, for: f.firstChannel, in: f.episodeID)
        #expect(coalesced.history == edited.history)
        #expect(coalesced.history.undoActionName == "Change Input Gain")
        coalesced.history.cursor = 0
        var branch = try coalesced.settingMasterMix(.init(gainDB: -3), in: f.episodeID)
        branch.history = branch.history.recording(.init(actionName: "Change Master Gain", timestamp: timestamp))
        #expect(branch.history.entries.map(\.actionName) == ["Change Master Gain"])
        #expect(!branch.history.canRedo)
        #expect(try JSONDecoder().decode(ShowDocumentModel.self, from: JSONEncoder().encode(branch)) == branch)
        #expect(try edited.settingMix(nil, in: f.episodeID).episodes[0] == original.episodes[0])
    }
}
