import Foundation
import Testing
@testable import WWCore

/// Synthetic in-memory fixture: one show, two speakers, one episode with one recorder group and two sources.
struct Fixture {
    let alice = Speaker(name: "Alice")
    let bob = Speaker(name: "Bob")
    let epoch = RecordingEpoch(label: "Take 1")
    let group: RecorderGroup
    let stereo: SourceRecord
    let unknownChannels: SourceRecord
    let episode: Episode
    let model: ShowDocumentModel

    init() {
        group = RecorderGroup(name: "Field recorder", deviceName: "Synthetic", epochs: [epoch])
        stereo = SourceRecord(
            displayNameHint: "synthetic-stereo",
            observations: SourceObservations(channelCount: .known(2)),
            placement: SourcePlacement(recorderGroupID: group.id, epochID: epoch.id)
        )
        unknownChannels = SourceRecord(displayNameHint: "synthetic-unknown")
        episode = Episode(title: "Pilot", number: 1, recorderGroups: [group], sources: [stereo, unknownChannels])
        model = ShowDocumentModel(show: Show(title: "Synthetic Show"), speakers: [alice, bob], episodes: [episode])
    }

    func channel(_ source: SourceRecord, _ index: Int) -> ChannelReference {
        ChannelReference(sourceID: source.id, channel: index)
    }
}

@Suite("Primary and backup assignment")
struct AssignmentTests {
    let f = Fixture()

    @Test func assignsConfirmedPrimaryAndPromotesUnassignedSource() throws {
        let result = try f.model.assigningPrimary(f.channel(f.stereo, 0), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        let episode = try #require(result.episode(f.episode.id))
        let assignment = try #require(episode.assignment(for: f.alice.id))
        #expect(assignment.primary == f.channel(f.stereo, 0))
        #expect(assignment.primaryConfirmation == .userConfirmed)
        #expect(episode.source(f.stereo.id)?.role == .primary)
        #expect(episode.source(f.stereo.id)?.roleConfirmation == .userConfirmed)
        #expect(result.validationIssues().isEmpty)
        #expect(f.model.episode(f.episode.id)?.speakerAssignments.isEmpty == true, "original value unchanged")
    }

    @Test func refusesChannelBeyondKnownChannelCount() {
        #expect(throws: DomainError.channelOutOfRange(f.channel(f.stereo, 2), channelCount: 2)) {
            try f.model.assigningPrimary(f.channel(f.stereo, 2), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        }
    }

    @Test func allowsAnyNonNegativeChannelWhenCountIsUnknown() throws {
        let result = try f.model.assigningPrimary(f.channel(f.unknownChannels, 7), to: f.alice.id, in: f.episode.id, confirmation: .provisional)
        #expect(result.episode(f.episode.id)?.assignment(for: f.alice.id)?.primaryConfirmation == .provisional)
        #expect(result.episode(f.episode.id)?.source(f.unknownChannels.id)?.observations.channelCount == .unknown)
    }

    @Test func refusesNegativeChannel() {
        #expect(throws: DomainError.invalidChannel(f.channel(f.unknownChannels, -1))) {
            try f.model.assigningPrimary(f.channel(f.unknownChannels, -1), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        }
    }

    @Test func refusesUnknownReferences() {
        let stranger = SpeakerID()
        #expect(throws: DomainError.speakerNotFound(stranger)) {
            try f.model.assigningPrimary(f.channel(f.stereo, 0), to: stranger, in: f.episode.id, confirmation: .userConfirmed)
        }
        let missing = ChannelReference(sourceID: SourceID(), channel: 0)
        #expect(throws: DomainError.sourceNotFound(missing.sourceID)) {
            try f.model.assigningPrimary(missing, to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        }
        let noEpisode = EpisodeID()
        #expect(throws: DomainError.episodeNotFound(noEpisode)) {
            try f.model.assigningPrimary(f.channel(f.stereo, 0), to: f.alice.id, in: noEpisode, confirmation: .userConfirmed)
        }
    }

    @Test func refusesChannelAlreadyPrimaryForAnotherSpeaker() throws {
        let withAlice = try f.model.assigningPrimary(f.channel(f.stereo, 0), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        #expect(throws: DomainError.channelIsPrimaryOfAnotherSpeaker(f.channel(f.stereo, 0), f.alice.id)) {
            try withAlice.assigningPrimary(f.channel(f.stereo, 0), to: f.bob.id, in: f.episode.id, confirmation: .userConfirmed)
        }
        let bobOnRight = try withAlice.assigningPrimary(f.channel(f.stereo, 1), to: f.bob.id, in: f.episode.id, confirmation: .userConfirmed)
        #expect(bobOnRight.validationIssues().isEmpty)
    }

    @Test func refusesPrimaryOnDesignatedBackupSource() throws {
        let backupRole = try f.model.settingSourceRole(.backup, confirmation: .userConfirmed, source: f.unknownChannels.id, in: f.episode.id)
        #expect(throws: DomainError.sourceIsDesignatedBackup(f.unknownChannels.id)) {
            try backupRole.assigningPrimary(f.channel(f.unknownChannels, 0), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        }
    }

    @Test func addsBackupsAndRefusesDuplicatesOrPrimary() throws {
        let primary = try f.model.assigningPrimary(f.channel(f.stereo, 0), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        let backup = try primary.addingBackup(f.channel(f.unknownChannels, 0), to: f.alice.id, in: f.episode.id)
        let episode = try #require(backup.episode(f.episode.id))
        #expect(episode.assignment(for: f.alice.id)?.backups == [f.channel(f.unknownChannels, 0)])
        #expect(episode.source(f.unknownChannels.id)?.role == .backup)

        #expect(throws: DomainError.duplicateBackup(f.channel(f.unknownChannels, 0))) {
            try backup.addingBackup(f.channel(f.unknownChannels, 0), to: f.alice.id, in: f.episode.id)
        }
        #expect(throws: DomainError.channelIsSpeakersPrimary(f.channel(f.stereo, 0))) {
            try backup.addingBackup(f.channel(f.stereo, 0), to: f.alice.id, in: f.episode.id)
        }
        #expect(backup.validationIssues().isEmpty)
    }

    @Test func promotingABackupRemovesItFromBackups() throws {
        let backup = try f.model.addingBackup(f.channel(f.stereo, 1), to: f.alice.id, in: f.episode.id)
        let promoted = try backup.assigningPrimary(f.channel(f.stereo, 1), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
        let assignment = try #require(promoted.episode(f.episode.id)?.assignment(for: f.alice.id))
        #expect(assignment.primary == f.channel(f.stereo, 1))
        #expect(assignment.backups.isEmpty)
        #expect(promoted.validationIssues().isEmpty)
    }

    @Test func removesBackupAndClearsPrimary() throws {
        let staged = try f.model
            .assigningPrimary(f.channel(f.stereo, 0), to: f.alice.id, in: f.episode.id, confirmation: .userConfirmed)
            .addingBackup(f.channel(f.stereo, 1), to: f.alice.id, in: f.episode.id)
        let removed = try staged.removingBackup(f.channel(f.stereo, 1), from: f.alice.id, in: f.episode.id)
        #expect(removed.episode(f.episode.id)?.assignment(for: f.alice.id)?.backups.isEmpty == true)
        #expect(throws: DomainError.backupNotFound(f.channel(f.stereo, 1))) {
            try removed.removingBackup(f.channel(f.stereo, 1), from: f.alice.id, in: f.episode.id)
        }
        let cleared = try removed.clearingPrimary(of: f.alice.id, in: f.episode.id)
        #expect(cleared.episode(f.episode.id)?.assignment(for: f.alice.id)?.primary == nil)
    }
}

@Suite("Show and episode operations")
struct ShowOperationTests {
    let f = Fixture()

    @Test func renamesShowTrimmingAndRefusesEmpty() throws {
        #expect(try f.model.renamingShow(to: "  New Name \n").show.title == "New Name")
        #expect(throws: DomainError.emptyTitle) { try f.model.renamingShow(to: "   ") }
    }

    @Test func addsAndRemovesEpisodes() throws {
        let second = Episode(title: "Second", number: 2)
        let added = try f.model.addingEpisode(second)
        #expect(added.episodes.map(\.id) == [f.episode.id, second.id])
        #expect(throws: DomainError.duplicateEpisode(second.id)) { try added.addingEpisode(second) }
        let removed = try added.removingEpisode(f.episode.id)
        #expect(removed.episodes.map(\.id) == [second.id])
        #expect(throws: DomainError.episodeNotFound(f.episode.id)) { try removed.removingEpisode(f.episode.id) }
        #expect(try added.renamingEpisode(second.id, to: "Renamed").episode(second.id)?.title == "Renamed")
    }

    @Test func addingSourceValidatesPlacement() throws {
        let strayGroup = RecorderGroupID()
        let bad = SourceRecord(displayNameHint: "x", placement: SourcePlacement(recorderGroupID: strayGroup))
        #expect(throws: DomainError.recorderGroupNotFound(strayGroup)) { try f.model.addingSource(bad, to: f.episode.id) }
        let strayEpoch = RecordingEpochID()
        let badEpoch = SourceRecord(displayNameHint: "y", placement: SourcePlacement(recorderGroupID: f.group.id, epochID: strayEpoch))
        #expect(throws: DomainError.epochNotFound(strayEpoch)) { try f.model.addingSource(badEpoch, to: f.episode.id) }
        #expect(throws: DomainError.duplicateSource(f.stereo.id)) { try f.model.addingSource(f.stereo, to: f.episode.id) }
        let good = SourceRecord(displayNameHint: "z", placement: SourcePlacement(recorderGroupID: f.group.id, epochID: f.epoch.id))
        #expect(try f.model.addingSource(good, to: f.episode.id).episode(f.episode.id)?.sources.count == 3)
    }

    @Test func addsSpeakersAndRecorderGroups() throws {
        let carol = Speaker(name: "Carol")
        let withCarol = try f.model.addingSpeaker(carol)
        #expect(withCarol.speakers.count == 3)
        #expect(throws: DomainError.duplicateSpeaker(carol.id)) { try withCarol.addingSpeaker(carol) }
        #expect(throws: DomainError.duplicateRecorderGroup(f.group.id)) { try f.model.addingRecorderGroup(f.group, to: f.episode.id) }
    }
}

@Suite("Validation")
struct ValidationTests {
    let f = Fixture()

    @Test func fixtureIsValid() {
        #expect(f.model.validationIssues().isEmpty)
    }

    @Test func detectsDanglingAndConflictingReferences() {
        var model = f.model
        model.episodes[0].speakerAssignments = [
            SpeakerAssignment(speakerID: f.alice.id, primary: f.channel(f.stereo, 0)),
            SpeakerAssignment(speakerID: f.bob.id, primary: f.channel(f.stereo, 0)),
            SpeakerAssignment(speakerID: SpeakerID(), primary: ChannelReference(sourceID: SourceID(), channel: 0)),
        ]
        let codes = Set(model.validationIssues().map(\.code))
        #expect(codes.isSuperset(of: [.conflictingPrimary, .danglingReference]))
    }

    @Test func detectsDuplicateIDsAndSchemaMismatch() {
        var model = f.model
        model.episodes.append(f.episode)
        model.schemaVersion = 99
        let codes = Set(model.validationIssues().map(\.code))
        #expect(codes.isSuperset(of: [.duplicateID, .schemaVersionMismatch]))
    }

    @Test func libraryRequiresCollectionsToReferenceEntries() {
        let show = ShowID()
        let valid = LibraryModel(
            entries: [LibraryShowEntry(showID: show, lastKnownTitle: "A")],
            collections: [LibraryCollection(name: "Fav", showIDs: [show])],
            recentShowIDs: [show]
        )
        #expect(valid.validationIssues().isEmpty)
        var invalid = valid
        invalid.collections[0].showIDs.append(ShowID())
        #expect(invalid.validationIssues().map(\.code) == [.danglingReference])
    }
}

@Suite("Value types")
struct ValueTypeTests {
    @Test func logicalIDEncodesAsBareUUID() throws {
        let id = SourceID()
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(id.rawValue.uuidString)\"]")
        #expect(try JSONDecoder().decode([SourceID].self, from: data) == [id])
    }

    @Test func knowledgeKeepsUnknownDistinctFromValues() throws {
        let values: [Knowledge<Int>] = [.unknown, .known(0), .known(2)]
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([Knowledge<Int>].self, from: data) == values)
        #expect(Knowledge<Int>.unknown.value == nil)
        #expect(Knowledge<Int>.known(0).isKnown)
    }

    @Test(arguments: ["2026-02-29", "2026-13-01", "26-01-01", "2026-1-01", "x"])
    func calendarDayRejectsInvalid(_ string: String) {
        #expect(CalendarDay(isoString: string) == nil)
    }

    @Test func calendarDayRoundTrips() throws {
        let day = try #require(CalendarDay(isoString: "2024-02-29"))
        #expect(day.description == "2024-02-29")
        let data = try JSONEncoder().encode(day)
        #expect(try JSONDecoder().decode(CalendarDay.self, from: data) == day)
    }

    @Test func historyRecordingDiscardsRedoTail() {
        let now = Date(timeIntervalSince1970: 0)
        var history = EditHistory()
            .recording(EditRecord(actionName: "A", timestamp: now))
            .recording(EditRecord(actionName: "B", timestamp: now))
        history.cursor = 1
        #expect(history.redoActionName == "B")
        let next = history.recording(EditRecord(actionName: "C", timestamp: now))
        #expect(next.entries.map(\.actionName) == ["A", "C"])
        #expect(next.undoActionName == "C")
        #expect(!next.canRedo)
    }
}
