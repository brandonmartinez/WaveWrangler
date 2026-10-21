import Foundation
import Testing
@testable import WWCore

@Suite("Portable workspace identity")
struct WorkspaceIdentityTests {
    private let host = Speaker(name: "Host")
    private let guest = Speaker(name: "Guest")
    private let episode = Episode(title: "Existing episode")

    private var model: ShowDocumentModel {
        ShowDocumentModel(show: Show(title: "Synthetic"), speakers: [host, guest], episodes: [episode])
    }

    @Test func hostsSeedOnlyNewEpisodesAndNeverInventPrimaryAssignments() throws {
        let profiled = try model.settingHost(host.id, isHost: true)
        #expect(profiled.episodes == model.episodes)
        let next = Episode(title: "Next", speakerAssignments: [SpeakerAssignment(speakerID: guest.id)])
        let seeded = try profiled.addingEpisode(next)
        #expect(seeded.episode(next.id)?.speakerAssignments.map(\.speakerID) == [guest.id, host.id])
        #expect(seeded.episode(next.id)?.assignment(for: host.id)?.primary == nil)
        #expect(seeded.episode(next.id)?.assignment(for: host.id)?.primaryConfirmation == .provisional)
        let changed = try seeded.settingHost(host.id, isHost: false)
        #expect(changed.episodes == seeded.episodes)
        #expect(try profiled.addingEpisode(next, inheritingShowHosts: false).episode(next.id) == next)
        #expect(seeded.validationIssues().isEmpty)
    }

    @Test func appearanceInheritanceAndEpisodeResetAreIndependentOfAudioAndOtherEpisodes() throws {
        let included = try model.includingSpeaker(host.id, inEpisode: episode.id)
        let original = included.speakerAppearance(host.id)
        #expect(original?.color == .defaultColor(for: host.id))
        let blue = SpeakerAppearance(color: .blue)
        let purple = SpeakerAppearance(color: .purple)
        let show = try included.settingSpeakerAppearance(blue, for: host.id)
        let overridden = try show.settingSpeakerAppearance(purple, for: host.id, in: episode.id)
        #expect(overridden.speakerAppearance(host.id) == blue)
        #expect(overridden.speakerAppearance(host.id, in: episode.id) == purple)
        #expect(overridden.episodes[0].sources == included.episodes[0].sources)
        #expect(overridden.episodes[0].alignment == included.episodes[0].alignment)
        let reset = try overridden.settingSpeakerAppearance(nil, for: host.id, in: episode.id)
        #expect(reset.speakerAppearance(host.id, in: episode.id) == blue)
        #expect(reset.episodes[0].speakerAppearanceOverrides == nil)
        #expect(reset.validationIssues().isEmpty)
    }

    @Test func avatarsAreOwnedBoundedPNGBytesAndRoundTripWithoutExternalLocations() throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGIoAAAAASUVORK5CYII="))
        let appearance = SpeakerAppearance(color: .teal, avatarPNG: png)
        #expect(appearance.isValid)
        let stored = try model.settingSpeakerAppearance(appearance, for: host.id)
        let bytes = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(ShowDocumentModel.self, from: bytes)
        #expect(decoded.speakerAppearance(host.id)?.avatarPNG == png)
        #expect(decoded == stored)
        #expect(!SpeakerAppearance(color: .blue, avatarPNG: Data()).isValid)
        #expect(!SpeakerAppearance(color: .blue, avatarPNG: Data(repeating: 0, count: 524_289)).isValid)
        var oversized = png
        oversized.replaceSubrange(16..<20, with: [0, 0, 2, 1])
        #expect(!SpeakerAppearance(color: .blue, avatarPNG: oversized).isValid)
        #expect(throws: DomainError.self) {
            try model.settingSpeakerAppearance(.init(color: .blue, avatarPNG: Data("not an image".utf8)), for: host.id)
        }
    }

    @Test func aggregateAvatarLimitIsEnforcedByTheAppearanceMutation() throws {
        var png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGIoAAAAASUVORK5CYII="))
        png.append(Data(repeating: 0, count: 524_288 - png.count))
        let appearance = SpeakerAppearance(color: .teal, avatarPNG: png)
        #expect(appearance.isValid)
        var bounded = model
        bounded.speakers = (0..<32).map { Speaker(name: "Synthetic \($0)", appearance: appearance) }
        bounded.speakers.append(host)
        #expect(bounded.validationIssues().isEmpty, "Exactly 16 MB of owned images is permitted.")
        #expect(throws: DomainError.self) {
            try bounded.settingSpeakerAppearance(appearance, for: host.id)
        }
        #expect(bounded.speakerAppearance(host.id)?.avatarPNG == nil)
    }

    @Test func savedDefinitionsRejectConflictingPrimaryAndDuplicateSpeakerAssignments() throws {
        let primary = SavedSpeakerAssignment(speaker: host.id, channel: .known(0), isPrimary: true)
        let source = SavedSourceDefinition(name: "Host", assignments: [primary])
        var invalid = model
        invalid.show.profile = ShowProfile(recorderDefinitions: [
            SavedRecorderDefinition(name: "Conflicting microphones", sources: [
                source, SavedSourceDefinition(name: "Other microphone", assignments: [primary]),
            ]),
        ])
        #expect(invalid.validationIssues().contains {
            $0.code == .invalidWorkspace && $0.detail.contains("multiple Primaries")
        })
        let recording = SourceRecord(displayNameHint: "original.wav")
        let imported = try model.addingSource(recording, to: episode.id)
        var duplicate = source
        duplicate.assignments.append(primary)
        #expect(throws: DomainError.self) {
            try imported.applyingSourceDefinition(duplicate, to: recording.id, in: episode.id)
        }
        #expect(imported.episode(episode.id)?.assignment(for: host.id)?.primary == nil)
    }

    @Test func savedRecordersContainDefinitionsNotAudioOrOriginalSourceIdentities() throws {
        let group = RecorderGroup(name: "Desktop", deviceName: "Interface",
                                  epochs: [RecordingEpoch(label: "1")], icon: .computer)
        let source = SourceRecord(displayNameHint: "microphone.wav",
            placement: SourcePlacement(recorderGroupID: group.id, epochID: group.epochs[0].id))
        var show = try model.addingRecorderGroup(group, to: episode.id).addingSource(source, to: episode.id)
        show = try show.assigningPrimary(.init(sourceID: source.id, statedChannel: 0),
                                         to: host.id, in: episode.id, confirmation: .userConfirmed)
        let saved = try show.savingRecorderDefinition(from: group.id, in: episode.id)
        let definition = try #require(saved.show.profile?.recorderDefinitions.first)
        #expect(definition.icon == .computer)
        #expect(definition.sources.count == 1)
        #expect(definition.sources[0].assignments == [.init(speaker: host.id, channel: .known(0), isPrimary: true)])
        #expect(saved.episodes == show.episodes)
        let next = Episode(title: "Next")
        let newGroup = RecorderGroupID()
        let reused = try saved.addingEpisode(next).addingRecorder(from: definition.id, to: next.id, groupID: newGroup)
        #expect(reused.episode(next.id)?.sources.isEmpty == true)
        #expect(reused.episode(next.id)?.recorderGroup(newGroup)?.definitionID == definition.id)
        #expect(reused.episode(next.id)?.recorderGroup(newGroup)?.icon == .computer)
        #expect(reused.validationIssues().isEmpty)
        let definitionBytes = try JSONEncoder().encode(definition)
        #expect(!String(decoding: definitionBytes, as: UTF8.self).contains(source.id.description))
    }

    @Test func savedSourceAssignmentsStayProvisionalAndCannotReplaceExistingPrimaries() throws {
        let source = SourceRecord(displayNameHint: "new.wav")
        let other = SourceRecord(displayNameHint: "existing.wav")
        let definition = SavedSourceDefinition(name: "Host microphone", statedChannel: 0, role: .primary,
            assignments: [.init(speaker: host.id, channel: .known(0), isPrimary: true)])
        let imported = try model.addingSource(source, to: episode.id).addingSource(other, to: episode.id)
        let applied = try imported.applyingSourceDefinition(definition, to: source.id, in: episode.id)
        #expect(applied.episode(episode.id)?.assignment(for: host.id)?.primary?.sourceID == source.id)
        #expect(applied.episode(episode.id)?.assignment(for: host.id)?.primaryConfirmation == .provisional)
        let existing = try imported.assigningPrimary(.init(sourceID: other.id, statedChannel: 0),
            to: host.id, in: episode.id, confirmation: .userConfirmed)
        #expect(throws: DomainError.self) {
            try existing.applyingSourceDefinition(definition, to: source.id, in: episode.id)
        }
        #expect(existing.episode(episode.id)?.assignment(for: host.id)?.primary?.sourceID == other.id)
    }

    @Test func removingMembershipDoesNotDeleteShowHostsOrSavedDefinitionSpeakers() throws {
        let hosted = try model.settingHost(host.id, isHost: true).includingSpeaker(host.id, inEpisode: episode.id)
            .settingSpeakerAppearance(.init(color: .pink), for: host.id, in: episode.id)
        let removed = try hosted.removingSpeaker(host.id, fromEpisode: episode.id)
        #expect(removed.speaker(host.id) == host)
        #expect(removed.episode(episode.id)?.speakerAppearanceOverrides?.isEmpty == true)
        #expect(removed.validationIssues().isEmpty)
    }

    @Test func positionLocksDefaultToProtectingAcceptedMapsAndDeletionCleansReferences() throws {
        let group = RecorderGroup(name: "Recorder")
        var show = try model.addingRecorderGroup(group, to: episode.id)
        #expect(show.episodes[0].positionIsLocked(group.id) == false)
        show.episodes[0].alignment = EpisodeAlignment(
            maps: [TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: []), map: .null)], acceptedRevision: 1)
        #expect(show.episodes[0].positionIsLocked(group.id))
        let unlocked = try show.settingPositionLock(false, group: group.id, in: episode.id)
        #expect(!unlocked.episodes[0].positionIsLocked(group.id))
        #expect(unlocked.episodes[0].alignment == show.episodes[0].alignment)
        let removed = try unlocked.removingRecorderGroup(group.id, in: episode.id)
        #expect(removed.episodes[0].workspace?.positionLocks.isEmpty == true)
        #expect(removed.validationIssues().isEmpty)
        #expect(EpisodeWorkspacePreferences().editingPlaybackPolicy == .keepChoices)
    }

    @Test func oldSchemaClaimsCannotSmuggleNewFieldsAndInvalidReferencesRefuse() {
        var invalid = model
        invalid.show.profile = ShowProfile(hosts: [host.id, host.id])
        #expect(invalid.validationIssues().contains { $0.code == .invalidWorkspace })
        invalid.show.profile = ShowProfile(hosts: [host.id])
        #expect(invalid.validationIssues(expectedSchemaVersion: 6).contains { $0.code == .invalidWorkspace })
        invalid.show.profile = nil
        invalid.episodes[0].speakerAppearanceOverrides = [.init(speaker: host.id, appearance: .init(color: .blue))]
        #expect(invalid.validationIssues().contains { $0.code == .invalidWorkspace })
    }
}
