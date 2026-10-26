import AppKit
import Foundation
import Testing
import WWCore
import WWMix
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Mixer review regression boundaries", .serialized)
struct MixerReviewRegressionTests {
    private let helper = MixerHostedTests()

    private func offer(_ payload: ShowDocumentModel, for document: ShowDocument) throws -> URL {
        try #require(PersistenceEnvironment.isUITestRun)
        let disk = try Data(contentsOf: #require(document.fileURL))
        let encoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            payload, revision: document.revision + 1, publicationID: UUID()).data
        let schema = try #require(EnvelopeHeaderInfo.peek(encoded)?.schemaVersion)
        try PersistenceEnvironment.recovery.writeEditCheckpoint(snapshot: encoded, base: RevisionFingerprint(of: disk),
            schemaVersion: schema, for: document.documentKey)
        try PersistenceEnvironment.recovery.setAsideEditCheckpoints(for: document.documentKey)
        document.refreshEditCheckpointOffer()
        return try #require(document.status.editCheckpointOffer?.candidate?.url)
    }

    @Test func refusedRecoveryRestoreIsNotMarkedAndVerifiedSaveRetainsTheOffer() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        let owner = helper.owner(f), slot = try helper.appleSlot()
        try helper.insert(slot, into: f)
        try await helper.save(f.document)
        let presentation = owner.state.mixerPresentation
        presentation.openEditor(slot, generic: true)
        try await helper.wait {
            (presentation.editorWindow != nil && !f.document.mixerTransactions.isBusy) || presentation.error != nil
        }
        try #require(presentation.error == nil)
        let original = f.document.store.model
        var changed = slot
        changed.bypassed = true
        let candidate = try original.settingMasterMix(MasterMixState(inserts: [changed]), in: f.model.episodeID)
        let url = try offer(candidate, for: f.document)
        defer { try? PersistenceEnvironment.recovery.discardOfferedEditCheckpoints([url], for: f.document.documentKey) }
        let bytes = try Data(contentsOf: url)
        #expect(f.document.mixerTransactions.refusesReplacement(from: original, to: candidate))
        f.document.restoreOfferedEditCheckpoint()
        #expect(f.document.store.model == original && f.document.store.lastError != nil)
        #expect(!f.document.isEditCheckpointRestoreInEffect)
        #expect(f.document.status.editCheckpointOffer?.candidate?.url == url)
        try await helper.save(f.document)
        #expect(f.document.verifiedModel == original)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(PersistenceEnvironment.recovery.offeredEditCheckpoints(for: f.document.documentKey).contains { $0.url == url })
        presentation.requestCloseEditor()
        try await helper.wait { presentation.editorWindow == nil }
    }

    @Test func sameEpisodeEditorsAwaitHandoffThenSaveAndCloseWithoutStaleCaptures() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        f.document.retainForLibrary(in: nil)
        let first = helper.owner(f), slot = try helper.appleSlot()
        try helper.insert(slot, into: f)
        try await helper.save(f.document)
        let secondState = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        let otherModel = EpisodeAlignmentModel(document: f.document, episodeID: f.model.episodeID, runtime: f.runtime)
        secondState.alignmentModel = otherModel
        let second = EpisodeWindowController(state: secondState)
        f.document.addWindowController(second)
        if let window = second.window { second.state.attach(to: window) }
        let a = first.state.mixerPresentation, b = second.state.mixerPresentation
        a.openEditor(slot)
        try await helper.wait { a.editorWindow != nil || a.error != nil }
        try #require(a.error == nil)
        let oldWindow = try #require(a.editorWindow?.window)
        let oldProcessor = try #require(f.model.mixer.processor)
        let parameter = try #require(try await oldProcessor.parameters(slot: slot.id).first {
            $0.writable && $0.minimum < 2000 && $0.maximum > 2000
        })
        try await oldProcessor.setParameter(slot: slot.id, address: parameter.address, value: 1000)
        b.openEditor(slot)
        try await helper.wait("handoff: \(b.error ?? "")") { b.editorWindow != nil || b.error != nil }
        try #require(b.error == nil,
            "\(b.error ?? ""); first=\(String(describing: a.controller?.state)), \(a.controller?.dependencyFailure ?? "no dependency failure"); second=\(String(describing: b.controller?.state)), \(b.controller?.dependencyFailure ?? "no dependency failure")")
        #expect(a.editorWindow == nil && !oldWindow.isVisible && !f.model.mixer.hasObservedState)
        let current = try #require(otherModel.mixer.processor)
        #expect(abs(try #require(try await current.parameters(slot: slot.id).first {
            $0.address == parameter.address
        }?.value) - 1000) < 0.1)
        try await current.setParameter(slot: slot.id, address: parameter.address, value: 2000)
        try await helper.save(f.document)
        #expect(f.document.verifiedModel == f.document.store.model)
        second.close()
        try await helper.wait("second close: \(b.error ?? "")") { b.isClosed && !f.document.mixerTransactions.isBusy }
        #expect(!a.isClosed && b.editorWindow == nil)
        try await helper.save(f.document)
        _ = try await f.model.mixer.prepare(programFrames: 0..<1)
        #expect(abs(try #require(try await f.model.mixer.processor?.parameters(slot: slot.id).first {
            $0.address == parameter.address
        }?.value) - 2000) < 0.1)
    }

    @Test func failedNativeCaptureRetainsDocumentAndRecoveryUntilConfirmedExternalDiscard() async throws {
        let f = try await helper.ready()
        defer { f.close() }
        f.document.retainForLibrary(in: nil)
        let owner = helper.owner(f), slot = try helper.appleSlot()
        try helper.insert(slot, into: f)
        try await helper.save(f.document)
        let presentation = owner.state.mixerPresentation
        presentation.openEditor(slot)
        try await helper.wait {
            (presentation.editorWindow != nil && !f.document.mixerTransactions.isBusy) || presentation.error != nil
        }
        try #require(presentation.error == nil)
        let original = f.document.store.model
        var changed = slot
        changed.bypassed = true
        let candidate = try original.settingMasterMix(.init(inserts: [changed]), in: f.model.episodeID)
        let url = try offer(candidate, for: f.document)
        defer { try? PersistenceEnvironment.recovery.discardOfferedEditCheckpoints([url], for: f.document.documentKey) }
        let disk = try Data(contentsOf: #require(f.document.fileURL))
        f.model.mixer.beforeStateCapture = { throw MixerFailure.state(slot.id, "synthetic native capture refusal") }
        do {
            try await helper.save(f.document)
            Issue.record("A refused native capture must not save")
        } catch MixerFailure.state(let id, _) { #expect(id == slot.id) }
        owner.close()
        try await helper.wait { !f.document.mixerTransactions.isBusy && presentation.error != nil }
        #expect(!presentation.isClosed && presentation.editorWindow != nil && presentation.canDiscardEditorChanges)
        #expect(f.document.store.model == original)
        #expect(try Data(contentsOf: #require(f.document.fileURL)) == disk)
        f.document.restoreOfferedEditCheckpoint()
        #expect(!f.document.isEditCheckpointRestoreInEffect && FileManager.default.fileExists(atPath: url.path))
        try await presentation.discardFailedEditorChanges(confirm: { false })
        #expect(presentation.editorWindow != nil && f.document.store.model == original)
        try await presentation.discardFailedEditorChanges(confirm: { true })
        #expect(presentation.editorWindow == nil && !f.model.mixer.hasObservedState)
        #expect(f.document.store.model == original && f.model.mixer.preparedInstanceIsCurrent)
        f.model.mixer.beforeStateCapture = nil
        try await helper.save(f.document)
        #expect(f.document.verifiedModel == original && FileManager.default.fileExists(atPath: url.path))
        owner.close()
        try await helper.wait { presentation.isClosed }
    }

    @Test func insertEditInAnotherEpisodePreservesPlayingRuntimeAndOpenEditor() async throws {
        let f = try await helper.ready(durationSeconds: 12)
        defer { f.close() }
        let b = helper.owner(f), slot = try helper.appleSlot()
        let otherEpisode = Episode(title: "Independent mixer edit")
        try #require(f.document.store.apply("Add independent episode") { model throws(DomainError) in
            try model.addingEpisode(otherEpisode)
        })
        try helper.insert(slot, into: f)
        try await helper.save(f.document)
        f.model.load()
        f.model.synchronizeWaveforms()
        try await helper.wait { !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        let otherState = ShowWindowState(store: f.document.store, episodeID: otherEpisode.id)
        otherState.alignmentModel = EpisodeAlignmentModel(document: f.document, episodeID: otherEpisode.id, runtime: f.runtime)
        let a = EpisodeWindowController(state: otherState)
        f.document.addWindowController(a)
        if let window = a.window { a.state.attach(to: window) }
        f.model.playProductionMix(interval: 0...10)
        try await helper.wait(f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.isAuditioning, "\(f.model.lastError ?? "")")
        b.state.mixerPresentation.openEditor(slot)
        try await helper.wait { b.state.mixerPresentation.editorWindow != nil || b.state.mixerPresentation.error != nil }
        try #require(b.state.mixerPresentation.error == nil)
        let editor = try #require(b.state.mixerPresentation.editorWindow?.window)
        let processor = try #require(f.model.mixer.processor)
        let before = b.state.mixerPresentation.mix
        a.state.mixerPresentation.changeInserts(.master, action: "Edit independent episode") { $0 + [slot] }
        try await helper.wait { a.state.mixerPresentation.mix.master.inserts.count == 1 && !f.document.mixerTransactions.isBusy }
        #expect(f.model.isAuditioning && f.model.mixer.processor === processor)
        #expect(b.state.mixerPresentation.editorWindow?.window === editor && editor.isVisible)
        #expect(b.state.mixerPresentation.mix == before)
        b.state.mixerPresentation.requestCloseEditor()
        try await helper.wait { b.state.mixerPresentation.editorWindow == nil }
        f.model.stopAudition()
    }

    @Test func viewingModeAndOtherReadOnlyStatesRefuseTheSharedRecordingGainOperation() async throws {
        let f = try await helper.ready()
        defer { f.document.debugViewingMode = false; f.document.status.setReadOnly(nil); f.close() }
        let owner = helper.owner(f)
        let reference = try #require(f.document.store.model.episode(f.model.episodeID)?.speakerAssignments.first?.primary)
        let original = f.document.store.model
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        f.document.debugViewingMode = true
        #expect(f.document.isInViewingMode && !owner.state.canEdit && !f.document.store.canEdit)
        #expect(!f.document.store.setRecordingInputGain(12, reference: reference, in: f.model.episodeID))
        #expect(f.document.store.model == original && !undo.canUndo)
        f.document.debugViewingMode = false
        f.document.status.setReadOnly("Synthetic recovered read-only show")
        #expect(!f.document.store.setRecordingInputGain(6, reference: reference, in: f.model.episodeID))
        #expect(f.document.store.model == original && !undo.canUndo && f.document.store.lastError != nil)
    }

    @Test func leavingAlignmentStopsDiagnosticButPreservesDeliberateDetachedProduction() async throws {
        let f = try await helper.ready(durationSeconds: 12)
        defer { f.close() }
        let owner = helper.owner(f), state = owner.state
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        state.cleanupModel = cleanup
        owner.showWindow(nil)
        await cleanup.refresh()
        f.model.playEnabledTracks(interval: 0...10)
        try await helper.wait(f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.isAuditioning, "\(f.model.auditionLabel)")
        state.select(.setup)
        #expect(!f.model.canStopAudition && state.alignmentModel === f.model)
        state.select(.alignment)
        state.mixerPresentation.detach()
        f.model.playProductionMix(interval: 0...10)
        try await helper.wait(f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.isAuditioning)
        state.select(.setup)
        state.alignmentWorkspaceDidDisappear()
        #expect(f.model.isAuditioning, "The disappearance policy must not stop deliberate detached production.")
        #expect(state.alignmentModel === f.model && state.mixerPresentation.isDetached)
        state.mixerPresentation.reattach()
        #expect(state.destination == .alignment)
        f.model.stopAudition()
        cleanup.cancel()
    }
}
