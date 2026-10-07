import Foundation
import Testing
import WWCore
@testable import WWEpisodeSetup

/// Mirrors `ShowDocumentStore`: applies a pure operation and registers one named undo step.
@MainActor
final class UndoingEditor: SetupEditing {
    private(set) var showModel: ShowDocumentModel
    private(set) var lastSetupError: DomainError?
    let undoManager = UndoManager()

    init(_ model: ShowDocumentModel) {
        showModel = model
        undoManager.groupsByEvent = false
    }

    func applySetupEdit(_ actionName: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) -> Bool {
        do {
            let updated = try operation(showModel)
            lastSetupError = nil
            replace(with: updated, name: actionName)
            return true
        } catch {
            lastSetupError = error
            return false
        }
    }

    private func replace(with model: ShowDocumentModel, name: String) {
        let previous = showModel
        showModel = model
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.replace(with: previous, name: name) }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }
}

@MainActor
@Suite("Setup command layer: one named undo step per command (A-05)")
struct SetupEditCommandTests {
    let group = RecorderGroup(name: "Zoom H6", epochs: [RecordingEpoch(label: "1")])
    let episodeID = EpisodeID()
    let tr1 = SourceRecord(displayNameHint: "tr1.wav")
    let tr2 = SourceRecord(displayNameHint: "tr2.wav")

    func make() -> (UndoingEditor, SetupEditCommands) {
        let model = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [Episode(id: episodeID, title: "E", recorderGroups: [group], sources: [tr1, tr2])])
        let editor = UndoingEditor(model)
        return (editor, SetupEditCommands(editor: editor, episodeID: episodeID))
    }

    func expectUndo(_ editor: UndoingEditor, _ name: String, restores before: ShowDocumentModel, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(editor.undoManager.undoActionName == name, sourceLocation: sourceLocation)
        editor.undoManager.undo()
        #expect(editor.showModel == before, sourceLocation: sourceLocation)
        editor.undoManager.redo()
    }

    @Test func groupingCommandsAreNamed() {
        let (editor, commands) = make()
        var before = editor.showModel
        #expect(commands.assign([tr1.id, tr2.id], toGroup: group.id))
        expectUndo(editor, "Assign to Group “Zoom H6”", restores: before)

        before = editor.showModel
        #expect(commands.setEpoch(2, for: [tr1.id]))
        expectUndo(editor, "Set Epoch", restores: before)

        before = editor.showModel
        #expect(commands.startNewEpoch(for: [tr1.id, tr2.id]))
        expectUndo(editor, "Start New Epoch", restores: before)

        before = editor.showModel
        #expect(commands.setChannel(2, for: [tr1.id]))
        expectUndo(editor, "Set Channel", restores: before)

        before = editor.showModel
        #expect(commands.createGroup(RecorderGroup(name: "Laptop"), assigning: [tr2.id]))
        expectUndo(editor, "New Recorder Group", restores: before)

        before = editor.showModel
        #expect(commands.renameGroup(group.id, to: "Zoom"))
        expectUndo(editor, "Rename Recorder Group", restores: before)

        before = editor.showModel
        #expect(commands.deleteGroup(group.id))
        expectUndo(editor, "Delete Recorder Group", restores: before)
        #expect(editor.showModel.episode(episodeID)?.sources.count == 2, "deleting a group never removes sources")
    }

    @Test func speakerCommandsAreNamed() throws {
        let (editor, commands) = make()
        let ana = Speaker(name: "Ana")
        var before = editor.showModel
        #expect(commands.createSpeaker(ana, assigning: []))
        expectUndo(editor, "New Speaker", restores: before)

        before = editor.showModel
        #expect(commands.assignSpeaker(ana.id, to: [tr1.id, tr2.id]))
        expectUndo(editor, "Assign Speaker “Ana”", restores: before)

        let ref = try #require(editor.showModel.episode(episodeID)?.references(to: tr1.id).first)
        before = editor.showModel
        #expect(commands.useAsPrimary(ref))
        expectUndo(editor, "Change Primary for “Ana”", restores: before)

        let ref2 = try #require(editor.showModel.episode(episodeID)?.references(to: tr2.id).first)
        before = editor.showModel
        #expect(commands.useAsPrimary(ref2))
        #expect(editor.showModel.episode(episodeID)?.assignment(for: ana.id)?.backups == [ref.channel], "old primary becomes a backup")
        expectUndo(editor, "Change Primary for “Ana”", restores: before)

        before = editor.showModel
        #expect(commands.useAsBackup(ref2))
        expectUndo(editor, "Change Backup for “Ana”", restores: before)

        before = editor.showModel
        #expect(commands.renameSpeaker(ana.id, to: "Ana B."))
        expectUndo(editor, "Rename Speaker", restores: before)

        before = editor.showModel
        #expect(commands.deleteSpeaker(ana.id))
        expectUndo(editor, "Delete Speaker", restores: before)

        before = editor.showModel
        #expect(commands.assignSpeaker(nil, to: [tr1.id]))
        expectUndo(editor, "Assign Speaker “Unassigned”", restores: before)
    }

    @Test func sourceCommandsAreNamed() {
        let (editor, commands) = make()
        var before = editor.showModel
        #expect(commands.importSources([SourceImportItem(source: SourceRecord(displayNameHint: "new.wav"), recorderGroupName: "Zoom H6")]))
        expectUndo(editor, "Import 1 Source", restores: before)

        before = editor.showModel
        #expect(commands.moveSource(tr1.id, .down))
        expectUndo(editor, "Move Source", restores: before)

        before = editor.showModel
        #expect(commands.removeSources([tr1.id]))
        expectUndo(editor, "Remove Source", restores: before)
    }

    @Test func multiSelectAssignSpeakerDoesNotDemoteAConfirmedPrimary() throws {
        let (editor, commands) = make()
        let ana = Speaker(name: "Ana")
        #expect(commands.createSpeaker(ana, assigning: [tr1.id]))
        let ref = try #require(editor.showModel.episode(episodeID)?.references(to: tr1.id).first)
        #expect(commands.useAsPrimary(ref))
        #expect(commands.assignSpeaker(ana.id, to: [tr1.id, tr2.id]))
        let assignment = try #require(editor.showModel.episode(episodeID)?.assignment(for: ana.id))
        #expect(assignment.primary == ref.channel)
        #expect(assignment.primaryConfirmation == .userConfirmed)
        #expect(assignment.backups == [ChannelReference(sourceID: tr2.id, channel: .unknown)])
    }

    @Test func refusalsRegisterNoUndoAndExplainWhy() {
        let (editor, commands) = make()
        #expect(!commands.setEpoch(0, for: [tr1.id]))
        #expect(editor.lastSetupError == .invalidEpochNumber(0))
        #expect(!commands.setEpoch(2, for: [tr1.id]))
        #expect(editor.lastSetupError == .sourceNotInRecorderGroup(tr1.id))
        #expect(!commands.setChannel(0, for: [tr1.id]))
        #expect(!editor.undoManager.canUndo)
    }
}
