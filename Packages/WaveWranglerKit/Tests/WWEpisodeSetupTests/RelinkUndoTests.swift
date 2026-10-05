import Foundation
import Testing
import WWCore
@testable import WWEpisodeSetup

@MainActor
@Suite("Relink undo (device-local, synchronous inverse registration)")
struct RelinkUndoTests {
    @Test func undoReachesEarlierEditsAndRedoWorks() async throws {
        let group = RecorderGroup(name: "Zoom H6")
        let episodeID = EpisodeID()
        let source = SourceRecord(displayNameHint: "tr2.wav")
        let editor = UndoingEditor(ShowDocumentModel(show: Show(title: "S"), episodes: [Episode(id: episodeID, title: "E", recorderGroups: [group], sources: [source])]))
        let commands = SetupEditCommands(editor: editor, episodeID: episodeID)
        let engine = InMemorySourceSetupEngine(statuses: [source.id: SourceStatusSnapshot(location: .missing(sameNamedFileAtOriginalLocation: true), access: .granted, residency: .local, identity: .notChecked)])
        let registrar = RelinkUndoRegistrar(undoManager: editor.undoManager, engine: engine)
        let original = editor.showModel

        // Edit A
        #expect(commands.renameGroup(group.id, to: "Zoom"))
        let afterA = editor.showModel

        // Relink
        registrar.relink(source.id, to: URL(filePath: "/synthetic/tr2.wav"), identity: .detailsMatch, actionName: "Relink “tr2.wav”")
        await registrar.settle()
        #expect(engine.status(of: source.id)?.location == .known)
        #expect(editor.undoManager.undoActionName == "Relink “tr2.wav”")

        // Undo relink → engine reverts; next undo is A, redo is the relink.
        editor.undoManager.undo()
        await registrar.settle()
        #expect(engine.status(of: source.id)?.location == .missing(sameNamedFileAtOriginalLocation: true))
        #expect(editor.undoManager.undoActionName == "Rename Recorder Group")
        #expect(editor.undoManager.redoActionName == "Relink “tr2.wav”")

        // Undo A
        editor.undoManager.undo()
        #expect(editor.showModel == original)
        #expect(!editor.undoManager.canUndo)

        // Redo A, then redo relink
        editor.undoManager.redo()
        #expect(editor.showModel == afterA)
        #expect(editor.undoManager.redoActionName == "Relink “tr2.wav”")
        editor.undoManager.redo()
        await registrar.settle()
        #expect(engine.status(of: source.id)?.location == .known)
        #expect(!editor.undoManager.canRedo)
        #expect(editor.undoManager.undoActionName == "Relink “tr2.wav”")

        // And it can be undone again (no alternation, no stuck stack).
        editor.undoManager.undo()
        await registrar.settle()
        #expect(engine.status(of: source.id)?.location == .missing(sameNamedFileAtOriginalLocation: true))
        #expect(editor.undoManager.undoActionName == "Rename Recorder Group")

        let relinkCalls = engine.calls.filter {
            if case .commitRelink = $0 { return true }
            if case .revertRelink = $0 { return true }
            return false
        }
        #expect(relinkCalls == [.commitRelink(source.id), .revertRelink(source.id), .commitRelink(source.id), .revertRelink(source.id)])
    }
}
