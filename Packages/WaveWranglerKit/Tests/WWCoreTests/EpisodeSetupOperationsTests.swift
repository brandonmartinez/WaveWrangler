import Foundation
import Testing
@testable import WWCore

/// Synthetic setup fixture: one episode, one group with one epoch, three sources (two grouped).
private struct SetupFixture {
    let ana = Speaker(name: "Ana")
    let ben = Speaker(name: "Ben")
    let group = RecorderGroup(name: "Recorder A", epochs: [RecordingEpoch(label: "1")])
    let tr1: SourceRecord
    let tr2: SourceRecord
    let loose = SourceRecord(displayNameHint: "loose.wav")
    let episode: Episode
    let model: ShowDocumentModel

    init() {
        tr1 = SourceRecord(displayNameHint: "tr1.wav", placement: SourcePlacement(recorderGroupID: group.id, epochID: group.epochs[0].id))
        tr2 = SourceRecord(displayNameHint: "tr2.wav", placement: SourcePlacement(recorderGroupID: group.id, epochID: group.epochs[0].id))
        episode = Episode(title: "Pilot", recorderGroups: [group], sources: [tr1, tr2, loose])
        model = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
    }

    func ep(_ model: ShowDocumentModel) throws -> Episode { try #require(model.episode(episode.id)) }
}

@Suite("Episode setup operations")
struct EpisodeSetupOperationTests {
    private let f = SetupFixture()

    @Test func deletingAGroupKeepsItsSourcesAsUngrouped() throws {
        let result = try f.model.removingRecorderGroup(f.group.id, in: f.episode.id)
        let episode = try f.ep(result)
        #expect(episode.recorderGroups.isEmpty)
        #expect(episode.sources.count == 3)
        #expect(episode.sources.allSatisfy { $0.placement.recorderGroupID == nil && $0.placement.epochID == nil })
        #expect(result.validationIssues().isEmpty)
    }

    @Test func renamingAGroupTrimsAndRefusesEmpty() throws {
        let result = try f.model.renamingRecorderGroup(f.group.id, in: f.episode.id, to: "  Zoom  ")
        #expect(try f.ep(result).recorderGroup(f.group.id)?.name == "Zoom")
        #expect(throws: DomainError.emptyTitle) { try f.model.renamingRecorderGroup(f.group.id, in: f.episode.id, to: " ") }
    }

    @Test func epochNumbersAreOneBasedAndCreateEpochsOnDemand() throws {
        var result = try f.model.settingEpochNumber(3, forSources: [f.tr1.id], in: f.episode.id)
        var episode = try f.ep(result)
        #expect(episode.epochNumber(of: f.tr1.id) == 3)
        #expect(episode.epochNumber(of: f.tr2.id) == 1)
        #expect(episode.recorderGroup(f.group.id)?.epochs.map(\.label) == ["1", "2", "3"])
        result = try result.startingNewEpoch(forSources: [f.tr1.id, f.tr2.id], in: f.episode.id)
        episode = try f.ep(result)
        #expect(episode.epochNumber(of: f.tr1.id) == 4)
        #expect(episode.epochNumber(of: f.tr2.id) == 2)
        #expect(result.validationIssues().isEmpty)
    }

    @Test func epochRefusesZeroAndUngroupedSources() {
        #expect(throws: DomainError.invalidEpochNumber(0)) { try f.model.settingEpochNumber(0, forSources: [f.tr1.id], in: f.episode.id) }
        #expect(throws: DomainError.sourceNotInRecorderGroup(f.loose.id)) { try f.model.settingEpochNumber(2, forSources: [f.loose.id], in: f.episode.id) }
    }

    @Test func movingIntoAGroupKeepsEpochNumberOrStartsAtOne() throws {
        let other = RecorderGroup(name: "Laptop")
        var result = try f.model.addingRecorderGroup(other, to: f.episode.id)
        result = try result.settingEpochNumber(2, forSources: [f.tr1.id], in: f.episode.id)
        result = try result.assigningSources([f.tr1.id, f.loose.id], toRecorderGroup: other.id, in: f.episode.id)
        let episode = try f.ep(result)
        #expect(episode.source(f.tr1.id)?.placement.recorderGroupID == other.id)
        #expect(episode.epochNumber(of: f.tr1.id) == 2)
        #expect(episode.epochNumber(of: f.loose.id) == 1)
        let ungrouped = try result.assigningSources([f.tr1.id], toRecorderGroup: nil, in: f.episode.id)
        #expect(try f.ep(ungrouped).epochNumber(of: f.tr1.id) == nil)
        #expect(result.validationIssues().isEmpty && ungrouped.validationIssues().isEmpty)
    }

    @Test func speakerAssignmentStartsUnconfirmedAndPrimaryDemotesPrevious() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr2.id, in: f.episode.id)
        var episode = try f.ep(result)
        #expect(episode.assignment(for: f.ana.id)?.primary == nil)
        #expect(episode.source(f.tr1.id)?.roleConfirmation == .provisional)

        let tr1 = ChannelReference(sourceID: f.tr1.id, channel: 0)
        let tr2 = ChannelReference(sourceID: f.tr2.id, channel: 0)
        result = try result.usingAsPrimary(tr1, for: f.ana.id, in: f.episode.id)
        result = try result.usingAsPrimary(tr2, for: f.ana.id, in: f.episode.id)
        episode = try f.ep(result)
        let assignment = try #require(episode.assignment(for: f.ana.id))
        #expect(assignment.primary == tr2)
        #expect(assignment.primaryConfirmation == .userConfirmed)
        #expect(assignment.backups == [tr1], "previous primary stays referenced as a backup")
        #expect(episode.source(f.tr1.id)?.role == .backup)
        #expect(episode.source(f.tr2.id)?.role == .primary)
        #expect(result.validationIssues().isEmpty)
    }

    @Test func usingAsBackupClearsPrimaryAndSettingPrimaryNoneKeepsTheChannel() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        let tr1 = ChannelReference(sourceID: f.tr1.id, channel: 0)
        result = try result.usingAsPrimary(tr1, for: f.ana.id, in: f.episode.id)
        let none = try result.settingPrimary(nil, for: f.ana.id, in: f.episode.id)
        #expect(try f.ep(none).assignment(for: f.ana.id)?.primary == nil)
        #expect(try f.ep(none).assignment(for: f.ana.id)?.backups == [tr1])
        #expect(throws: DomainError.channelNotAssignedToSpeaker(ChannelReference(sourceID: f.tr2.id, channel: 0), f.ana.id)) {
            try result.usingAsPrimary(ChannelReference(sourceID: f.tr2.id, channel: 0), for: f.ana.id, in: f.episode.id)
        }
    }

    @Test func reassigningASourceMovesItBetweenSpeakers() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id).addingSpeaker(f.ben, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        result = try result.usingAsPrimary(ChannelReference(sourceID: f.tr1.id, channel: 0), for: f.ana.id, in: f.episode.id)
        result = try result.assigningSpeaker(f.ben.id, toSource: f.tr1.id, in: f.episode.id)
        let episode = try f.ep(result)
        #expect(episode.assignment(for: f.ana.id)?.primary == nil)
        #expect(episode.references(to: f.tr1.id).map(\.speakerID) == [f.ben.id])
        let cleared = try result.assigningSpeaker(nil, toSource: f.tr1.id, in: f.episode.id)
        #expect(try f.ep(cleared).references(to: f.tr1.id).isEmpty)
        #expect(try f.ep(cleared).source(f.tr1.id)?.role == .unassigned)
    }

    @Test func multiSelectAssignKeepsTheExistingSpeakersConfirmedPrimary() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id).addingSpeaker(f.ben, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        let tr1 = ChannelReference(sourceID: f.tr1.id, channel: 0)
        result = try result.usingAsPrimary(tr1, for: f.ana.id, in: f.episode.id)
        result = try result.assigningSpeaker(f.ben.id, toSource: f.tr2.id, in: f.episode.id)
        let before = result

        // Assign Speaker "Ana" to [tr1, tr2]: tr1 already references Ana (no-op); tr2 moves from Ben to Ana.
        for source in [f.tr1.id, f.tr2.id] {
            result = try result.assigningSpeaker(f.ana.id, toSource: source, in: f.episode.id)
        }
        let episode = try f.ep(result)
        let ana = try #require(episode.assignment(for: f.ana.id))
        #expect(ana.primary == tr1)
        #expect(ana.primaryConfirmation == .userConfirmed)
        #expect(ana.backups == [ChannelReference(sourceID: f.tr2.id, channel: 0)])
        #expect(episode.source(f.tr1.id)?.role == .primary)
        #expect(episode.source(f.tr1.id)?.roleConfirmation == .userConfirmed)
        #expect(episode.assignment(for: f.ben.id)?.backups.isEmpty == true, "only other speakers' references are stripped")
        #expect(try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id) == result, "reassigning the same speaker is a no-op")
        #expect(before != result)
        #expect(result.validationIssues().isEmpty)
    }

    @Test func statedChannelIsUnknownUntilTheUserSetsIt() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        #expect(try f.ep(result).statedChannel(of: f.tr1.id) == nil)
        result = try result.settingStatedChannel(1, forSource: f.tr1.id, in: f.episode.id)
        var episode = try f.ep(result)
        #expect(episode.statedChannel(of: f.tr1.id) == 1)
        #expect(episode.references(to: f.tr1.id).first?.channel.channel == 1)
        #expect(episode.source(f.tr1.id)?.observations.channelCount == .unknown, "never observed from the file")
        result = try result.settingStatedChannel(nil, forSource: f.tr1.id, in: f.episode.id)
        episode = try f.ep(result)
        #expect(episode.statedChannel(of: f.tr1.id) == nil)
        #expect(throws: DomainError.invalidChannel(ChannelReference(sourceID: f.tr1.id, channel: -1))) {
            try result.settingStatedChannel(-1, forSource: f.tr1.id, in: f.episode.id)
        }
    }

    @Test func deletingASpeakerUnassignsTheirSources() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        result = try result.removingSpeaker(f.ana.id, fromEpisode: f.episode.id)
        let episode = try f.ep(result)
        #expect(episode.speakerAssignments.isEmpty)
        #expect(episode.source(f.tr1.id)?.role == .unassigned)
        #expect(result.speakers.isEmpty, "unreferenced show speaker is removed")
        #expect(episode.sources.count == 3, "no source is removed")
    }

    @Test func renamingASpeakerIsShowWide() throws {
        let result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id).renamingSpeaker(f.ana.id, to: "Ana B.")
        #expect(result.speaker(f.ana.id)?.name == "Ana B.")
    }

    @Test func removingASourceDropsItsReferencesOnly() throws {
        var result = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id)
        result = try result.assigningSpeaker(f.ana.id, toSource: f.tr1.id, in: f.episode.id)
        result = try result.usingAsPrimary(ChannelReference(sourceID: f.tr1.id, channel: 0), for: f.ana.id, in: f.episode.id)
        result = try result.removingSource(f.tr1.id, from: f.episode.id)
        let episode = try f.ep(result)
        #expect(episode.source(f.tr1.id) == nil)
        #expect(episode.assignment(for: f.ana.id)?.primary == nil)
        #expect(result.validationIssues().isEmpty)
    }

    @Test func movingASourceStaysWithinItsGroup() throws {
        let down = try f.model.movingSource(f.tr1.id, .down, in: f.episode.id)
        #expect(try f.ep(down).sources.map(\.id) == [f.tr2.id, f.tr1.id, f.loose.id])
        let edge = try f.model.movingSource(f.tr2.id, .down, in: f.episode.id)
        #expect(edge == f.model, "no neighbour in the same group")
    }

    @Test func importAppliesOnlyConfirmedNamesAndReusesExistingOnes() throws {
        let base = try f.model.addingSpeaker(f.ana, toEpisode: f.episode.id)
        let a = SourceRecord(displayNameHint: "a.wav")
        let b = SourceRecord(displayNameHint: "b.wav")
        let c = SourceRecord(displayNameHint: "c.wav")
        let result = try base.importingSources([
            SourceImportItem(source: a, recorderGroupName: "Recorder A", speakerName: "Ana"),
            SourceImportItem(source: b, recorderGroupName: "New Device", speakerName: "Guest"),
            SourceImportItem(source: c),
        ], into: f.episode.id)
        let episode = try f.ep(result)
        #expect(episode.recorderGroups.map(\.name) == ["Recorder A", "New Device"])
        #expect(episode.source(a.id)?.placement.recorderGroupID == f.group.id)
        #expect(episode.epochNumber(of: b.id) == 1)
        #expect(episode.source(c.id)?.placement.recorderGroupID == nil)
        #expect(result.speakers.map(\.name) == ["Ana", "Guest"])
        #expect(episode.references(to: a.id).first?.speakerID == f.ana.id)
        #expect(episode.references(to: c.id).isEmpty)
        #expect(result.validationIssues().isEmpty)
        #expect(throws: DomainError.duplicateSource(a.id)) {
            try result.importingSources([SourceImportItem(source: a)], into: f.episode.id)
        }
    }
}
