import Foundation
import WWCore

/// Something that applies a pure show operation as one named, undoable edit (the show document store).
@MainActor
public protocol SetupEditing: AnyObject {
    var showModel: ShowDocumentModel { get }
    var lastSetupError: DomainError? { get }
    /// Applies `operation` as one undo step named `actionName`; returns false (and records the error)
    /// when the operation refuses.
    func applySetupEdit(_ actionName: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> Bool
}

/// Canonical Setup edits with the exact undo names from commands-keyboard §3. Each call is exactly one
/// undo step; nothing here touches device-local records or referenced files.
@MainActor
public struct SetupEditCommands {
    public let editor: any SetupEditing
    public let episodeID: EpisodeID

    public init(editor: any SetupEditing, episodeID: EpisodeID) {
        self.editor = editor
        self.episodeID = episodeID
    }

    private var model: ShowDocumentModel { editor.showModel }
    private var episode: Episode? { model.episode(episodeID) }

    public func speakerName(_ id: SpeakerID) -> String { model.speaker(id)?.name ?? "Unknown speaker" }

    public func groupName(_ id: RecorderGroupID?) -> String {
        guard let id else { return "Ungrouped" }
        return episode?.recorderGroup(id)?.name ?? "Recorder group"
    }

    @discardableResult
    public func assign(_ sourceIDs: [SourceID], toGroup groupID: RecorderGroupID?) -> Bool {
        guard !sourceIDs.isEmpty else { return false }
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.assignToGroup(groupName(groupID))) { model throws(DomainError) in
            try model.assigningSources(sourceIDs, toRecorderGroup: groupID, in: id)
        }
    }

    @discardableResult
    public func createGroup(_ group: RecorderGroup, assigning sourceIDs: [SourceID]) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.newRecorderGroup) { model throws(DomainError) in
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyTitle }
            var result = try model.addingRecorderGroup(group, to: id)
            if !sourceIDs.isEmpty { result = try result.assigningSources(sourceIDs, toRecorderGroup: group.id, in: id) }
            return result
        }
    }

    @discardableResult
    public func renameGroup(_ groupID: RecorderGroupID, to name: String) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.renameRecorderGroup) { model throws(DomainError) in try model.renamingRecorderGroup(groupID, in: id, to: name) }
    }

    @discardableResult
    public func deleteGroup(_ groupID: RecorderGroupID) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.deleteRecorderGroup) { model throws(DomainError) in try model.removingRecorderGroup(groupID, in: id) }
    }

    @discardableResult
    public func setEpoch(_ number: Int, for sourceIDs: [SourceID]) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.setEpoch) { model throws(DomainError) in try model.settingEpochNumber(number, forSources: sourceIDs, in: id) }
    }

    @discardableResult
    public func startNewEpoch(for sourceIDs: [SourceID]) -> Bool {
        guard !sourceIDs.isEmpty else { return false }
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.startNewEpoch) { model throws(DomainError) in try model.startingNewEpoch(forSources: sourceIDs, in: id) }
    }

    /// `channel` is 1-based as typed; nil = Unknown.
    @discardableResult
    public func setChannel(_ channel: Int?, for sourceIDs: [SourceID]) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.setChannel) { model throws(DomainError) in
            if let channel, channel < 1 { throw .invalidChannel(ChannelReference(sourceID: sourceIDs.first ?? SourceID(), channel: .known(channel - 1))) }
            var result = model
            for source in sourceIDs { result = try result.settingStatedChannel(channel.map { $0 - 1 }, forSource: source, in: id) }
            return result
        }
    }

    @discardableResult
    public func assignSpeaker(_ speakerID: SpeakerID?, to sourceIDs: [SourceID]) -> Bool {
        guard !sourceIDs.isEmpty else { return false }
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.assignSpeaker(speakerID.map(speakerName) ?? "Unassigned")) { model throws(DomainError) in
            var result = model
            for source in sourceIDs { result = try result.assigningSpeaker(speakerID, toSource: source, in: id) }
            return result
        }
    }

    @discardableResult
    public func createSpeaker(_ speaker: Speaker, assigning sourceIDs: [SourceID]) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.newSpeaker) { model throws(DomainError) in
            var result = try model.addingSpeaker(speaker, toEpisode: id)
            for source in sourceIDs { result = try result.assigningSpeaker(speaker.id, toSource: source, in: id) }
            return result
        }
    }

    @discardableResult
    public func renameSpeaker(_ speakerID: SpeakerID, to name: String) -> Bool {
        editor.applySetupEdit(SetupUndoName.renameSpeaker) { model throws(DomainError) in try model.renamingSpeaker(speakerID, to: name) }
    }

    @discardableResult
    public func deleteSpeaker(_ speakerID: SpeakerID) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.deleteSpeaker) { model throws(DomainError) in try model.removingSpeaker(speakerID, fromEpisode: id) }
    }

    @discardableResult
    public func useAsPrimary(_ ref: SpeakerChannelReference) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.changePrimary(speakerName(ref.speakerID))) { model throws(DomainError) in
            try model.usingAsPrimary(ref.channel, for: ref.speakerID, in: id)
        }
    }

    @discardableResult
    public func useAsBackup(_ ref: SpeakerChannelReference) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.changeBackup(speakerName(ref.speakerID))) { model throws(DomainError) in
            try model.usingAsBackup(ref.channel, for: ref.speakerID, in: id)
        }
    }

    @discardableResult
    public func setPrimary(_ channel: ChannelReference?, for speakerID: SpeakerID) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.changePrimary(speakerName(speakerID))) { model throws(DomainError) in
            try model.settingPrimary(channel, for: speakerID, in: id)
        }
    }

    @discardableResult
    public func removeSources(_ sourceIDs: [SourceID]) -> Bool {
        guard !sourceIDs.isEmpty else { return false }
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.removeSource) { model throws(DomainError) in
            var result = model
            for source in sourceIDs { result = try result.removingSource(source, from: id) }
            return result
        }
    }

    @discardableResult
    public func moveSource(_ sourceID: SourceID, _ direction: MoveDirection) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.moveSource) { model throws(DomainError) in try model.movingSource(sourceID, direction, in: id) }
    }

    @discardableResult
    public func moveSpeaker(_ speakerID: SpeakerID, _ direction: MoveDirection) -> Bool {
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.moveSpeaker) { model throws(DomainError) in try model.movingSpeaker(speakerID, direction, in: id) }
    }

    /// One undoable "Import N Sources" action for the reviewed batch.
    @discardableResult
    public func importSources(_ items: [SourceImportItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let id = episodeID
        return editor.applySetupEdit(SetupUndoName.importSources(items.count)) { model throws(DomainError) in try model.importingSources(items, into: id) }
    }
}
