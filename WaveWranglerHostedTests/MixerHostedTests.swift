import AppKit
import Foundation
import SwiftUI
import Testing
import WWCore
import WWMix
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Document-bound mixer integration (synthetic and Apple units)", .serialized)
struct MixerHostedTests {
    @Test func nativeStateDictionaryOrderingDoesNotRewriteUnchangedSerializedBytes() throws {
        let state: [String: Any] = ["name": "Synthetic", "opaque": Data([1, 2, 3]), "value": 2.5]
        let xml = try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
        let binary = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        #expect(xml != binary)
        #expect(try EpisodeMixerController.sameNativeState(xml, binary, slot: AudioUnitSlotID()))
        let changed = try PropertyListSerialization.data(fromPropertyList: ["opaque": Data([1, 2, 4])],
                                                        format: .binary, options: 0)
        #expect(try !EpisodeMixerController.sameNativeState(xml, changed, slot: AudioUnitSlotID()))
    }

    func ready(durationSeconds: Int = 4) async throws -> AlignmentWaveformRetentionHostedTests.Fixture {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: durationSeconds)
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        return f
    }

    func owner(_ f: AlignmentWaveformRetentionHostedTests.Fixture) -> EpisodeWindowController {
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        state.alignmentModel = f.model
        state.select(.alignment)
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        if let window = owner.window { owner.state.attach(to: window) }
        return owner
    }

    func wait(_ context: @autoclosure () -> String = "mixer condition", _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), Comment(rawValue: context()))
    }

    func appleSlot() throws -> AudioUnitSlot {
        let component = try #require(MixerAudioUnits.installedEffects().first {
            $0.identity.manufacturer == 0x6170706C && $0.identity.subtype == 0x6C706173
        })
        return AudioUnitSlot(component: component.identity, productName: component.name)
    }

    func insert(_ slot: AudioUnitSlot, into f: AlignmentWaveformRetentionHostedTests.Fixture) throws {
        let episode = f.model.episodeID
        try #require(f.document.store.apply("Add Apple Test Effect") { model throws(DomainError) in
            try model.settingMasterMix(MasterMixState(inserts: [slot]), in: episode)
        })
    }

    func save(_ document: ShowDocument) async throws {
        let url = try #require(document.fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: DocumentTypes.show, for: .saveOperation) {
                if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test func dockDetachReattachUsesOneOriginatingRuntimeAndNoImplicitPlayback() async throws {
        let f = try await ready()
        defer { f.close() }
        let owner = owner(f)
        let state = owner.state, presentation = owner.state.mixerPresentation
        let before = f.document.store.model
        let controller = f.model.mixer
        state.reviewPanelPresented = true
        state.listeningState(for: f.model.episodeID).workspace.reviewPanelHeight = 310
        presentation.showDocked()
        #expect(state.bottomPaneContent == .mixer && state.bottomPanePresented)
        presentation.detach()
        let first = try #require(presentation.detachedWindow?.window)
        #expect(first.styleMask.contains(.resizable) && first.title.contains("Synthetic"))
        #expect(ShowWindowRegistry.state(for: first) === state)
        #expect(first.undoManager === f.document.undoManager)
        presentation.detach()
        #expect(presentation.detachedWindow?.window === first)
        #expect(state.alignmentModel === f.model && presentation.controller === controller)
        #expect(!f.model.canStopAudition && f.document.store.model == before)
        state.reviewPanelPresented = true
        #expect(state.bottomPaneContent == .review && presentation.isDetached)
        presentation.reattach()
        #expect(!presentation.isDetached && !first.isVisible)
        #expect(state.bottomPaneContent == .mixer && state.bottomPanePresented)
        #expect(state.listeningState(for: f.model.episodeID).workspace.reviewPanelHeight == 310)
        #expect(f.model.mixer === controller && f.document.store.model == before)
        presentation.detach()
        let last = try #require(presentation.detachedWindow?.window)
        owner.close()
        try await wait { !last.isVisible }
        #expect(presentation.isClosed && !presentation.isDetached)
    }

    @Test func multipleEditorsAndDocumentsDoNotShareMixOrDetachedOwners() async throws {
        let a = try await ready(), b = try await ready()
        defer { a.close(); b.close() }
        let first = owner(a), other = owner(b)
        let firstMix = first.state.mixerPresentation, otherMix = other.state.mixerPresentation
        firstMix.setFader(-12, bus: .master)
        firstMix.detach()
        otherMix.detach()
        #expect(firstMix.controller !== otherMix.controller)
        #expect(firstMix.detachedWindow?.window !== otherMix.detachedWindow?.window)
        #expect(firstMix.mix.master.gainDB == -12 && otherMix.mix.master.gainDB == 0)
        first.close()
        #expect(firstMix.isClosed && !otherMix.isClosed && otherMix.isDetached)
        otherMix.reattach()
    }

    @Test func twoEpisodesInOneDocumentOwnIndependentMixerWindows() async throws {
        let f = try await ready()
        defer { f.close() }
        let second = Episode(title: "Second Synthetic Episode")
        try #require(f.document.store.apply("Add second episode") { model throws(DomainError) in
            try model.addingEpisode(second)
        })
        let a = owner(f)
        let b = EpisodeWindowController(store: f.document.store, episodeID: second.id)
        b.state.alignmentModel = EpisodeAlignmentModel(document: f.document, episodeID: second.id, runtime: f.runtime)
        f.document.addWindowController(b)
        if let window = b.window { b.state.attach(to: window) }
        let first = a.state.mixerPresentation, other = b.state.mixerPresentation
        first.detach()
        other.detach()
        first.setFader(-9, bus: .master)
        #expect(first.mix.master.gainDB == -9 && other.mix.master.gainDB == 0)
        #expect(first.controller !== other.controller)
        #expect(other.detachedWindow?.window?.title.contains(second.title) == true)
        b.close()
        #expect(other.isClosed && !first.isClosed)
        first.reattach()
    }

    @Test func orderedSlotsSupportBypassReorderingRemovalAndUndo() async throws {
        let f = try await ready()
        defer { f.close() }
        let presentation = owner(f).state.mixerPresentation
        let a = try appleSlot(), b = try appleSlot()
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        presentation.changeInserts(.master, action: "Add Two Effects") { $0 + [a, b] }
        try await wait("add: \(presentation.error ?? "")") { presentation.inserts(.master).count == 2 }
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        presentation.changeInserts(.master, action: "Reorder Effects") { Array($0.reversed()) }
        try await wait { presentation.inserts(.master).first?.id == b.id }
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        presentation.changeInserts(.master, action: "Bypass Effect") { slots in
            var slots = slots
            slots[0].bypassed = true
            return slots
        }
        try await wait { presentation.inserts(.master).first?.bypassed == true }
        undo.endUndoGrouping()
        let retained = presentation.inserts(.master)
        undo.beginUndoGrouping()
        presentation.changeInserts(.master, action: "Remove Effect") { $0.filter { $0.id != a.id } }
        try await wait { presentation.inserts(.master).count == 1 && !f.document.mixerTransactions.needsBarrier }
        undo.endUndoGrouping()
        undo.undo()
        #expect(presentation.inserts(.master) == retained)
    }

    @Test func productionListeningIsExplicitAndSharesTheExistingTransportWhenDetached() async throws {
        let f = try await ready()
        defer { f.close() }
        let presentation = owner(f).state.mixerPresentation
        let before = f.document.store.model, diagnostic = f.model.listening.playback
        presentation.detach()
        #expect(!f.model.canStopAudition)
        f.model.playProductionMix(interval: 0...2)
        try await wait(f.model.auditionLabel) { f.model.isAuditioning || f.model.lastError != nil }
        try #require(f.model.isAuditioning, "\(f.model.auditionLabel), \(f.model.lastError ?? "")")
        #expect(f.model.listeningMode == .productionMix)
        #expect(f.model.mixer.meters != nil)
        presentation.setFader(-12, bus: .master)
        presentation.controller?.masterMuted = true
        presentation.reattach()
        #expect(f.model.listening.playback == diagnostic)
        #expect(f.model.isAuditioning)
        f.model.stopAudition()
        #expect(f.document.store.model.episode(f.model.episodeID)?.mix?.master.gainDB == -12)
        #expect(f.document.store.model.episode(f.model.episodeID)?.alignment == before.episode(f.model.episodeID)?.alignment)
    }

    @Test func productionWithTwoSpeakerInsertsAndAMasterInsertRunsThroughTheProgramEnd() async throws {
        try await runInsertedProduction(drift: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_PRODUCTION_TIMING_TESTS"] == "1",
        "Opt-in drift throughput qualification; real-time completion requires optimized WWRender."))
    func driftCorrectedProductionWithInsertsCrossesMultipleSourceWindows() async throws {
        try await runInsertedProduction(drift: true)
    }

    private func runInsertedProduction(drift: Bool) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(
            cleanupPrimaries: 2, durationSeconds: drift ? 8 : 4)
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        if drift {
            let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
            f.model.setPositionLocked(false, group: target.group)
            f.model.selectWaveform(target)
            f.model.applyNumeric(ratePPM: 125, offsetMilliseconds: 350)
            try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
                && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
            try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        }
        let episode = try #require(f.document.store.model.episode(f.model.episodeID))
        let slots = try (0..<3).map { _ in try appleSlot() }
        try #require(f.document.store.apply("Add Apple Monitoring Inserts") { model throws(DomainError) in
            var result = model
            for (index, assignment) in episode.speakerAssignments.enumerated() {
                result = try result.settingSpeakerMix(
                    SpeakerMixState(speaker: assignment.speakerID, inserts: [slots[index]]), in: episode.id)
            }
            return try result.settingMasterMix(MasterMixState(inserts: [slots[2]]), in: episode.id)
        })
        try await save(f.document)
        let expected = f.document.store.model
        let end = drift ? 6.0 : 1.5
        f.model.playProductionMix(interval: 0...end)
        try await wait(f.model.lastError ?? f.model.auditionLabel) {
            !f.model.canStopAudition || f.model.lastError != nil
        }
        #expect(f.model.lastError == nil, "\(f.model.lastError ?? ""): \(f.model.auditionLabel)")
        #expect(f.model.auditionLabel == "Production mix reached the end of the selected program.")
        #expect(f.model.waveformPlayheadSeconds == end)
        #expect(f.model.mixer.unitStatuses.count == 3)
        #expect(f.document.store.model == expected)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_PRODUCTION_TIMING_TESTS"] == "1",
        "Opt-in source-preparation and controller timing diagnosis on a leased VM."))
    func syntheticDriftPreparationAndControlRoundTripsReportSeparateTimings() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2, durationSeconds: 8)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.setPositionLocked(false, group: target.group)
        f.model.selectWaveform(target)
        f.model.applyNumeric(ratePPM: 125, offsetMilliseconds: 350)
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model
            && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        _ = try await f.model.mixer.prepare(programFrames: 0..<288_000)
        func milliseconds(_ value: Duration) -> Double {
            let parts = value.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        for window in 0..<6 {
            let first = Int64(window * 48_000)
            let start = ContinuousClock.now
            let input = try await f.model.mixer.preparePCM(first..<(first + 48_000))
            let prepared = milliseconds(ContinuousClock.now - start)
            var renderTimes: [Double] = []
            var next = first
            while next < input.frames.upperBound {
                let end = min(next + 512, input.frames.upperBound)
                let offset = Int(next - first)
                let channels = input.channels.mapValues { Array($0[offset..<(offset + Int(end - next))]) }
                let renderedAt = ContinuousClock.now
                _ = try await f.model.mixer.renderPrepared(.init(frames: next..<end, channels: channels))
                renderTimes.append(milliseconds(ContinuousClock.now - renderedAt))
                next = end
            }
            print("PRODUCTION_SOURCE_TIMING window=\(window) raw_prepare_ms=\(prepared) "
                + "control_render_mean_ms=\(renderTimes.reduce(0, +) / Double(renderTimes.count)) "
                + "control_render_max_ms=\(renderTimes.max() ?? 0)")
        }
        #expect(f.model.lastError == nil)
    }

    @Test func editorRestartCapturesNativeKnobAndDismissesTheOldInstance() async throws {
        let f = try await ready()
        defer { f.close() }
        let presentation = owner(f).state.mixerPresentation, slot = try appleSlot()
        try insert(slot, into: f)
        presentation.openEditor(slot)
        try await wait("native editor: \(presentation.error ?? "")") {
            presentation.editorWindow != nil || presentation.error != nil
        }
        try #require(presentation.error == nil, "\(presentation.error ?? "")")
        let processor = try #require(f.model.mixer.processor)
        let parameter = try #require(try await processor.parameters(slot: slot.id).first {
            $0.writable && $0.minimum < 1500 && $0.maximum > 1500
        })
        let old = try #require(presentation.editorWindow?.window)
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 1500)
        _ = try await f.model.mixer.prepare(programFrames: 0..<1)
        presentation.instanceDidChange()
        #expect(!old.isVisible && presentation.editorWindow == nil)
        #expect(f.document.store.model.episode(f.model.episodeID)?.mix?.master.inserts.first?.documentState != nil)
        #expect(abs(try #require(try await f.model.mixer.processor?.parameters(slot: slot.id).first {
            $0.address == parameter.address
        }?.value) - 1500) < 0.1)
    }

    @Test func inputGainUsesSameDocumentValueAndDoesNotFollowPrimaryReplacement() async throws {
        let f = try await ready()
        defer { f.close() }
        let owner = owner(f), episodeID = f.model.episodeID
        let episode = try #require(f.document.store.model.episode(episodeID))
        let assignment = try #require(episode.speakerAssignments.first), primary = try #require(assignment.primary)
        let backup = ChannelReference(sourceID: f.target, statedChannel: 0)
        try #require(f.document.store.apply("Quiet recording gain") { model throws(DomainError) in
            try model.settingInputGain(12, for: primary, in: episodeID)
        })
        owner.state.mixerPresentation.setFader(-6, bus: .speaker(assignment.speakerID))
        owner.state.mixerPresentation.setPan(0.25, speaker: assignment.speakerID)
        try #require(f.document.store.apply("Replace Primary") { model throws(DomainError) in
            try model.usingAsPrimary(backup, for: assignment.speakerID, in: episodeID)
        })
        let mix = owner.state.mixerPresentation.mix
        #expect(mix.inputGainDB(for: primary.sourceID, channel: 0) == 12)
        #expect(mix.inputGainDB(for: f.target, channel: 0) == 0)
        #expect(mix.state(for: assignment.speakerID).gainDB == -6 && mix.state(for: assignment.speakerID).pan == 0.25)
        try await save(f.document)
        let reopened = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: #require(f.document.fileURL))).payload
        #expect(reopened.episode(episodeID)?.mix == mix)
        #expect(reopened.episode(episodeID)?.alignment == episode.alignment)
    }

    @Test func genericEditorCapturesDirtyStateUndoRedoSaveAndReload() async throws {
        let f = try await ready()
        defer { f.close() }
        let owner = owner(f), slot = try appleSlot()
        try insert(slot, into: f)
        try await save(f.document)
        let presentation = owner.state.mixerPresentation
        presentation.openEditor(slot, generic: true)
        try await wait("editor: \(presentation.error ?? "no error")") { presentation.editorWindow != nil || presentation.error != nil }
        try #require(presentation.error == nil, "\(presentation.error ?? "")")
        #expect(!f.document.isDocumentEdited, "Opening the editor must not rewrite default/nil document state")
        let parameter = try #require(presentation.parameters.first { $0.writable && $0.minimum < 1000 && $0.maximum > 1000 })
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        undo.removeAllActions()
        undo.beginUndoGrouping()
        presentation.setParameter(parameter, value: 1000)
        try await wait("parameter capture: \(presentation.error ?? "no error"); same controller=\(presentation.controller === f.model.mixer), state=\(String(describing: presentation.controller?.state))") {
            presentation.mix.master.inserts.first?.documentState != nil
        }
        undo.endUndoGrouping()
        #expect(f.document.isDocumentEdited)
        let edited = presentation.mix
        undo.undo()
        try await wait("Undo: \(presentation.error ?? "no error"); \(f.model.mixer.dependencyFailure ?? "no dependency failure"); state bytes=\(presentation.mix.master.inserts.first?.documentState?.count ?? -1), same controller=\(presentation.controller === f.model.mixer), processor=\(f.model.mixer.processor != nil); undo=\(undo.undoMenuItemTitle), redo=\(undo.redoMenuItemTitle)") {
            presentation.mix.master.inserts.first?.documentState == nil && !f.document.mixerTransactions.isBusy
        }
        #expect(presentation.editorWindow == nil && f.model.mixer.processor == nil)
        undo.redo()
        try await wait("Redo: \(presentation.error ?? "no error")") {
            presentation.mix == edited && !f.document.mixerTransactions.isBusy
        }
        try await save(f.document)
        #expect(f.document.verifiedModel == f.document.store.model)
        _ = try await f.model.mixer.prepare(programFrames: 0..<1)
        let recalled = try await f.model.mixer.processor?.parameters(slot: slot.id)
        #expect(abs(try #require(recalled?.first { $0.address == parameter.address }?.value) - 1000) < 0.1)
        undo.groupsByEvent = true
    }

    @MainActor private final class CaptureGate {
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        func pauseOnce() async {
            guard !entered else { return }
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        func resume() { release?.resume(); release = nil }
    }

    @Test func overlappingPollAndCloseDrainBeforeFinalCaptureWithoutStalePublication() async throws {
        let f = try await ready()
        defer { f.close() }
        let slot = try appleSlot()
        try insert(slot, into: f)
        let controller = f.model.mixer
        _ = try await controller.prepare(programFrames: 0..<1)
        let processor = try #require(controller.processor)
        let parameter = try #require(try await processor.parameters(slot: slot.id).first {
            $0.writable && $0.minimum < 2000 && $0.maximum > 2000
        })
        let gate = CaptureGate()
        defer { gate.resume() }
        controller.beforeStateCapture = { await gate.pauseOnce() }
        try await controller.beginEditorObservation(coalescing: "overlapping-native-editor")
        try await wait { gate.entered }
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 1000)
        let closing = Task { try await controller.endEditorObservation() }
        await Task.yield()
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 2000)
        gate.resume()
        try await closing.value
        #expect(controller.editorObservationKey == nil)
        #expect(!controller.hasObservedState)
        #expect(controller.state == .ready)
        let captured = try #require(f.document.store.model.episode(f.model.episodeID)?.mix?.master.inserts.first?.documentState)
        #expect(!captured.isEmpty)
        _ = try await controller.prepare(programFrames: 0..<1)
        #expect(abs(try #require(try await controller.processor?.parameters(slot: slot.id).first {
            $0.address == parameter.address
        }?.value) - 2000) < 0.1)
    }

    @Test func saveBarrierCapturesUnpolledNativeStateAndSuspendsBeforeDraining() async throws {
        let f = try await ready()
        defer { f.close() }
        let slot = try appleSlot()
        try insert(slot, into: f)
        let controller = f.model.mixer
        _ = try await controller.prepare(programFrames: 0..<1)
        let processor = try #require(controller.processor)
        let parameter = try #require(try await processor.parameters(slot: slot.id).first {
            $0.writable && $0.minimum < 2000 && $0.maximum > 2000
        })
        let gate = CaptureGate()
        defer { gate.resume() }
        controller.beforeStateCapture = { await gate.pauseOnce() }
        try await controller.beginEditorObservation(coalescing: "native-save")
        try await wait { gate.entered }
        let saving = Task { try await save(f.document) }
        try await wait { controller.editorObservationKey == nil }
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 2000)
        gate.resume()
        try await saving.value
        #expect(f.document.verifiedModel == f.document.store.model && !f.document.isDocumentEdited)
        #expect(controller.editorObservationKey == "native-save")
        try await controller.endEditorObservation()
        _ = try await controller.prepare(programFrames: 0..<1)
        #expect(abs(try #require(try await controller.processor?.parameters(slot: slot.id).first {
            $0.address == parameter.address
        }?.value) - 2000) < 0.1)
    }

    @Test func undoBarrierDrainsPollAndNoLateCaptureCanOverwriteUndoOrRedo() async throws {
        let f = try await ready()
        defer { f.close() }
        let owner = owner(f), slot = try appleSlot()
        try insert(slot, into: f)
        try await save(f.document)
        let controller = f.model.mixer
        _ = try await controller.prepare(programFrames: 0..<1)
        let processor = try #require(controller.processor)
        let parameter = try #require(try await processor.parameters(slot: slot.id).first {
            $0.writable && $0.minimum < 2000 && $0.maximum > 2000
        })
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        undo.removeAllActions()
        defer { undo.groupsByEvent = true }
        let gate = CaptureGate()
        defer { gate.resume() }
        controller.beforeStateCapture = { await gate.pauseOnce() }
        try await controller.beginEditorObservation(coalescing: "native-undo-overlap")
        try await wait { gate.entered }
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 1000)
        undo.undo()
        try await wait { controller.editorObservationKey == nil }
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 2000)
        gate.resume()
        try await wait("overlap Undo: \(owner.state.mixerPresentation.error ?? "")") {
            controller.processor == nil && !f.document.mixerTransactions.isBusy
        }
        #expect(owner.state.mixerPresentation.mix.master.inserts.first?.documentState == nil)
        let restored = f.document.store.model
        for _ in 0..<10 { await Task.yield() }
        #expect(f.document.store.model == restored && !controller.hasObservedState)
        undo.redo()
        #expect(owner.state.mixerPresentation.mix.master.inserts.first?.documentState != nil)
        controller.beforeStateCapture = nil
        _ = try await controller.prepare(programFrames: 0..<1)
        #expect(abs(try #require(try await controller.processor?.parameters(slot: slot.id).first {
            $0.address == parameter.address
        }?.value) - 2000) < 0.1)
    }

    @Test func originCloseCapturesEditorAndEpisodeDeletionCanUndoWithoutOrphanWindows() async throws {
        let f = try await ready()
        defer { f.close() }
        f.document.retainForLibrary(in: nil)
        let owner = owner(f), presentation = owner.state.mixerPresentation, slot = try appleSlot()
        try insert(slot, into: f)
        presentation.detach()
        presentation.openEditor(slot, generic: true)
        try await wait("close editor: \(presentation.error ?? "")") {
            presentation.editorWindow != nil || presentation.error != nil
        }
        try #require(presentation.error == nil)
        let processor = try #require(f.model.mixer.processor)
        let parameter = try #require(try await processor.parameters(slot: slot.id).first {
            $0.writable && $0.minimum < 1500 && $0.maximum > 1500
        })
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: 1500)
        owner.close()
        try await wait("origin close: \(presentation.error ?? "")") { presentation.isClosed }
        #expect(presentation.editorWindow == nil && !presentation.isDetached && f.model.mixer.processor == nil)
        #expect(f.document.store.model.episode(f.model.episodeID)?.mix?.master.inserts.first?.documentState != nil)

        let reopened = try #require(f.document.openEpisode(f.model.episodeID))
        try await wait { reopened.state.alignmentModel != nil }
        let mixer = reopened.state.mixerPresentation
        mixer.detach()
        #expect(mixer.isDetached && !mixer.isClosed)
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        try #require(f.document.store.apply("Delete Synthetic Episode") { model throws(DomainError) in
            try model.removingEpisode(f.model.episodeID)
        })
        undo.endUndoGrouping()
        #expect(!mixer.isDetached && !mixer.isClosed && !mixer.canEdit)
        undo.undo()
        #expect(mixer.canEdit && !mixer.isClosed)
        mixer.detach()
        #expect(mixer.isDetached)
        mixer.reattach()
    }

    @Test func missingUnitRetainsOpaqueStateAndReadOnlyRefusesEdits() async throws {
        let f = try await ready()
        defer { f.close() }
        let owner = owner(f)
        let state = try PropertyListSerialization.data(fromPropertyList: ["vendor": "retained"], format: .binary, options: 0)
        let slot = AudioUnitSlot(component: .init(type: 0x61756678, subtype: 0x77777473, manufacturer: 0x77777473),
            productName: "Synthetic Missing Unit", documentState: state)
        try insert(slot, into: f)
        do {
            _ = try await f.model.mixer.prepare(programFrames: 0..<1)
            Issue.record("Missing unit must not silently bypass")
        } catch MixerFailure.missingUnit(let id) { #expect(id == slot.id) }
        #expect(owner.state.mixerPresentation.mix.master.inserts == [slot])
        f.document.status.setFormatUpdate(.needed)
        let prior = f.document.store.model
        owner.state.mixerPresentation.setFader(-20, bus: .master)
        #expect(f.document.store.model == prior && !owner.state.mixerPresentation.canEdit)
        f.document.status.setFormatUpdate(nil)
    }
}
