import Foundation
import Testing
import WWCore
@testable import WWEpisodeSetup

@Suite("Selected Primary content-open request (synthetic, no media)")
struct PrimaryOpenRequestTests {
    private let speaker = Speaker(name: "Synthetic speaker")
    private let source = SourceRecord(displayNameHint: "synthetic")
    private let backup = SourceRecord(displayNameHint: "synthetic backup", role: .backup, roleConfirmation: .userConfirmed)
    private let episodeID = EpisodeID()

    private var channel: ChannelReference { ChannelReference(sourceID: source.id, statedChannel: 0) }

    private func fixture() -> ShowDocumentModel {
        let primary = SourceRecord(id: source.id, displayNameHint: source.displayNameHint, role: .primary, roleConfirmation: .userConfirmed)
        return ShowDocumentModel(
            show: Show(title: "Synthetic"),
            speakers: [speaker],
            episodes: [Episode(id: episodeID, title: "Synthetic", sources: [primary, backup],
                               speakerAssignments: [SpeakerAssignment(speakerID: speaker.id, primary: channel, primaryConfirmation: .userConfirmed,
                                                                       backups: [ChannelReference(sourceID: backup.id, statedChannel: 0)])])]
        )
    }

    private func state(_ model: ShowDocumentModel, document: UUID, selection: UUID, relink: UUID,
                       record: UUID? = UUID(), outstandingRelink: Bool = false) -> PrimaryOpenState {
        PrimaryOpenState(model: model, episodeID: episodeID, documentGeneration: document,
                         selectionGeneration: selection, relinkGeneration: relink,
                         accessRecordGeneration: record, outstandingRelink: outstandingRelink,
                         selectedSpeakerID: speaker.id, selectedChannel: channel)
    }

    @Test func explicitConfirmationIsRequiredAndCancellationIsFinal() throws {
        let model = fixture(), document = UUID(), selection = UUID(), relink = UUID(), record = UUID()
        let live = state(model, document: document, selection: selection, relink: relink, record: record)
        let gate = PrimaryOpenRequestGate()
        let request = try gate.begin(speakerID: speaker.id, channel: channel, state: live)
        #expect(throws: PrimaryOpenRefusal.self) { try gate.check(request, state: live) }
        #expect(throws: PrimaryOpenRefusal.self) { try PrimaryOpenRequestGate().check(request, state: live) }
        try gate.confirm(request, state: live)
        #expect(throws: PrimaryOpenRefusal.guardedCaptureUnavailable) { try gate.check(request, state: live) }
        let replacement = try gate.begin(speakerID: speaker.id, channel: channel, state: live)
        #expect(throws: PrimaryOpenRefusal.staleRequest) { try gate.check(request, state: live) }
        #expect(throws: PrimaryOpenRefusal.unconfirmed) { try gate.check(replacement, state: live) }
        gate.cancel(replacement)
        #expect(throws: PrimaryOpenRefusal.staleRequest) { try gate.check(replacement, state: live) }
        gate.cancel(request)
        #expect(throws: PrimaryOpenRefusal.self) { try gate.check(request, state: live) }
    }

    @Test func selectionABAAndRemovalRestoreCannotReviveRequest() throws {
        let model = fixture(), document = UUID(), selection = UUID(), relink = UUID(), record = UUID()
        let live = state(model, document: document, selection: selection, relink: relink, record: record)
        let gate = PrimaryOpenRequestGate()
        let request = try gate.begin(speakerID: speaker.id, channel: channel, state: live)
        try gate.confirm(request, state: live)
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(model, document: document, selection: UUID(), relink: relink, record: record))
        }
        var removed = model
        removed.episodes[0].sources.removeFirst()
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(removed, document: UUID(), selection: selection, relink: relink, record: record))
        }
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(model, document: UUID(), selection: selection, relink: relink, record: record))
        }
    }

    @Test func rejectsBackupWrongChannelSpeakerRoleAndShow() throws {
        let model = fixture(), document = UUID(), selection = UUID(), relink = UUID(), record = UUID()
        let live = state(model, document: document, selection: selection, relink: relink, record: record)
        let gate = PrimaryOpenRequestGate()
        let wrongChannel = ChannelReference(sourceID: source.id, statedChannel: 1)
        let backupChannel = ChannelReference(sourceID: backup.id, statedChannel: 0)
        #expect(throws: PrimaryOpenRefusal.self) { try gate.begin(speakerID: speaker.id, channel: backupChannel, state: live) }
        #expect(throws: PrimaryOpenRefusal.self) { try gate.begin(speakerID: speaker.id, channel: wrongChannel, state: live) }
        #expect(throws: PrimaryOpenRefusal.self) { try gate.begin(speakerID: SpeakerID(), channel: channel, state: live) }
        var otherRole = model
        otherRole.episodes[0].sources[0].role = .backup
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.begin(speakerID: speaker.id, channel: channel,
                           state: state(otherRole, document: document, selection: selection, relink: relink, record: record))
        }
        var unconfirmed = model
        unconfirmed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.begin(speakerID: speaker.id, channel: channel,
                           state: state(unconfirmed, document: document, selection: selection, relink: relink, record: record))
        }
        let unknown = ChannelReference(sourceID: source.id, statedChannel: nil)
        unconfirmed.episodes[0].speakerAssignments[0].primary = unknown
        unconfirmed.episodes[0].speakerAssignments[0].primaryConfirmation = .userConfirmed
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.begin(speakerID: speaker.id, channel: unknown,
                           state: PrimaryOpenState(model: unconfirmed, episodeID: episodeID,
                                                   documentGeneration: document, selectionGeneration: selection,
                                                   relinkGeneration: relink, accessRecordGeneration: record,
                                                   outstandingRelink: false, selectedSpeakerID: speaker.id,
                                                   selectedChannel: unknown))
        }
        let request = try gate.begin(speakerID: speaker.id, channel: channel, state: live)
        try gate.confirm(request, state: live)
        var otherShow = model
        otherShow.show.id = ShowID()
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(otherShow, document: document, selection: selection, relink: relink, record: record))
        }
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: PrimaryOpenState(model: model, episodeID: EpisodeID(),
                                                             documentGeneration: document, selectionGeneration: selection,
                                                             relinkGeneration: relink, accessRecordGeneration: record,
                                                             outstandingRelink: false, selectedSpeakerID: speaker.id,
                                                             selectedChannel: channel))
        }
    }

    @Test func unversionedRecordRelinkAndAlignmentChangeRefuse() throws {
        let model = fixture(), document = UUID(), selection = UUID(), relink = UUID(), record = UUID()
        let live = state(model, document: document, selection: selection, relink: relink, record: record)
        let gate = PrimaryOpenRequestGate()
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.begin(speakerID: speaker.id, channel: channel,
                           state: state(model, document: document, selection: selection, relink: relink, record: nil))
        }
        let request = try gate.begin(speakerID: speaker.id, channel: channel, state: live)
        try gate.confirm(request, state: live)
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(model, document: document, selection: selection, relink: relink,
                                                  record: record, outstandingRelink: true))
        }
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(model, document: document, selection: selection, relink: UUID(), record: record))
        }
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(model, document: document, selection: selection, relink: relink, record: UUID()))
        }
        var changedAlignment = model
        changedAlignment.episodes[0].alignment = EpisodeAlignment()
        #expect(throws: PrimaryOpenRefusal.self) {
            try gate.check(request, state: state(changedAlignment, document: document, selection: selection, relink: relink, record: record))
        }
    }
}
