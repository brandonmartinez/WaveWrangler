import AppKit
import Observation
import SwiftUI
import WWCore
import WWMix

typealias MixerBus = MixerBusAddress

extension MixerBusAddress {
    var identifier: String {
        switch self {
        case .speaker(let id): id.description
        case .audioTrack(let id): "audio.\(id)"
        case .master: "master"
        }
    }
}

/// Window ownership only. Canonical values and audio belong to the originating editor.
@MainActor @Observable
final class EpisodeMixerPresentation {
    weak var state: ShowWindowState?
    private(set) var detachedWindow: NSWindowController?
    private(set) var editorWindow: MixerEditorWindowController?
    private(set) var editedSlot: AudioUnitSlotID?
    private(set) var parameters: [MixerParameter] = []
    private(set) var components: [MixerComponent] = []
    private(set) var componentGroups: [MixerComponentGroup] = []
    private(set) var isClosed = false
    private var editorRevision: UInt64?
    private var editorWasVisible = false
    private var editorIsGeneric = false
    let insertDragScope = UUID().uuidString

    init(state: ShowWindowState) { self.state = state }

    var model: EpisodeAlignmentModel? { state?.alignmentModel }
    var controller: EpisodeMixerController? { model?.mixer }
    var episode: Episode? { state?.selectedEpisode }
    var mix: EpisodeMixState { episode?.mix ?? EpisodeMixState() }
    var canEdit: Bool { state?.canEdit == true && !isClosed }
    var usesProductionMix: Bool { model?.listening.usesProductionMix != false }
    var canEditMix: Bool { canEdit && usesProductionMix }
    var consoleMeters: MixerConsoleSnapshot {
        usesProductionMix ? controller?.consoleMeters ?? MixerConsoleSnapshot()
            : model?.sourceConsoleMeters ?? MixerConsoleSnapshot()
    }
    var metersUpdatedAt: Date {
        (usesProductionMix ? controller?.metersUpdatedAt : model?.sourceMetersUpdatedAt) ?? .now
    }
    var metersPlaying: Bool {
        usesProductionMix ? controller?.state == .playing
            : model?.isAuditioning == true && model?.listeningMode != .productionMix
    }

    func resetMeterPeaks(for bus: MixerBus) {
        if usesProductionMix { controller?.resetMeterPeaks(for: bus) }
        else { model?.resetSourceMeterPeaks(for: bus) }
    }
    var insertRowCount: Int {
        let racks = (episode?.speakerAssignments ?? []).map { mix.state(for: $0.speakerID).inserts }
            + (episode?.audioArrangement?.tracks ?? []).map { mix.state(for: $0.id).inserts }
            + [mix.master.inserts]
        return MixerInsertRack.rowCount(in: racks)
    }
    var isDetached: Bool { detachedWindow != nil }
    var error: String? {
        state?.store.document?.mixerTransactions.error ?? state?.store.lastError.map(EpisodeSetupModel.describe)
    }
    var canDiscardEditorChanges: Bool {
        guard controller?.hasObservedState == true else { return false }
        if error != nil { return true }
        if case .failed = controller?.state { return true }
        return false
    }

    func discoverEffects() {
        components = MixerAudioUnits.installedEffects()
        componentGroups = MixerAudioUnits.groupedByManufacturer(components)
    }

    func showDocked() {
        guard let state, !isClosed else { return }
        if let window = detachedWindow?.window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        state.select(.alignment)
        state.bottomPaneContent = .mixer
        state.bottomPanePresented = true
    }

    func detach() {
        guard let state, episode != nil, controller != nil, !isClosed else { return }
        if state.bottomPaneContent == .mixer { state.bottomPanePresented = false }
        if let existing = detachedWindow {
            existing.showWindow(nil)
            existing.window?.deminiaturize(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MixerView(presentation: self, detached: true).wwAppEnvironment())
        hosting.sizingOptions = []
        let window = EpisodeAuxiliaryWindow(contentViewController: hosting)
        window.originatingState = state
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.tabbingMode = .disallowed
        window.setAccessibilityIdentifier("ww.mixer.window")
        let owner = MixerDetachedWindowController(window: window)
        owner.presentation = self
        detachedWindow = owner
        ShowWindowRegistry.register(state, for: window)
        updateTitle()
        owner.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func reattach() {
        let owner = detachedWindow
        detachedWindow = nil
        owner?.close()
        guard !isClosed, let state else { return }
        state.select(.alignment)
        state.bottomPaneContent = .mixer
        state.bottomPanePresented = true
        state.window?.makeKeyAndOrderFront(nil)
    }

    func detachedDidClose() {
        detachedWindow = nil
    }

    func updateTitle() {
        detachedWindow?.window?.title = "\(episode?.title ?? "Episode Unavailable") - Mixer"
        detachedWindow?.window?.subtitle = state?.store.residentModel.show.title ?? ""
    }

    func modelDidChange(from prior: ShowDocumentModel) {
        updateTitle()
        guard let state, let id = state.selectedEpisodeID, let model else { return }
        guard let episode else {
            closeAuxiliaryWindows()
            return
        }
        if model.listeningMode == .sourceAudition,
           prior.episode(id)?.mix?.inputGains != episode.mix?.inputGains,
           !model.hasStreamingSourcePlayback {
            model.stopAudition()
        }
        let changedTopology = prior.episode(id).map {
            !EpisodeProcessingInputs($0).hasSameMixerTopology(as: EpisodeProcessingInputs(episode), allowingLiveBypass: true)
        } ?? true
        if changedTopology {
            model.stopAudition()
            if controller?.hasObservedState != true {
                dismissEditorsAfterCapture()
                controller?.invalidatePreparedInstance()
            }
        }
    }

    func instanceDidChange() {
        guard let editorRevision, editorRevision != controller?.instanceRevision else { return }
        dismissEditorsAfterCapture()
    }

    func setFader(_ gain: Double, bus: MixerBus) {
        guard canEditMix, let state, let id = state.selectedEpisodeID else { return }
        state.store.apply("Adjust Mixer Fader", coalescing: "mixer.\(id).\(bus.identifier).gain") { model throws(DomainError) in
            var mix = model.episode(id)?.mix ?? EpisodeMixState()
            switch bus {
            case .speaker(let speaker):
                var strip = mix.state(for: speaker)
                strip.gainDB = gain
                return try model.settingSpeakerMix(strip, in: id)
            case .audioTrack(let track):
                var strip = mix.state(for: track)
                strip.gainDB = gain
                return try model.settingAudioTrackMix(strip, in: id)
            case .master:
                mix.master.gainDB = gain
                return try model.settingMasterMix(mix.master, in: id)
            }
        }
    }

    func setPan(_ pan: Double, speaker: SpeakerID) {
        guard canEditMix, let state, let id = state.selectedEpisodeID else { return }
        state.store.apply("Adjust Mixer Pan", coalescing: "mixer.\(id).\(speaker).pan") { model throws(DomainError) in
            var strip = (model.episode(id)?.mix ?? EpisodeMixState()).state(for: speaker)
            strip.pan = pan
            return try model.settingSpeakerMix(strip, in: id)
        }
    }

    func setBalance(_ balance: Double, track: AudioTrackID) {
        guard canEditMix, let state, let id = state.selectedEpisodeID else { return }
        state.store.apply("Adjust Audio Track Balance", coalescing: "mixer.\(id).audio.\(track).balance") {
            model throws(DomainError) in
            var strip = (model.episode(id)?.mix ?? EpisodeMixState()).state(for: track)
            strip.balance = balance
            return try model.settingAudioTrackMix(strip, in: id)
        }
    }

    func inserts(_ bus: MixerBus) -> [AudioUnitSlot] {
        switch bus {
        case .speaker(let speaker): mix.state(for: speaker).inserts
        case .audioTrack(let track): mix.state(for: track).inserts
        case .master: mix.master.inserts
        }
    }

    func changeInserts(_ bus: MixerBus, action: String, replacingInstances: Bool = true,
                       _ edit: @escaping ([AudioUnitSlot]) throws -> [AudioUnitSlot]) {
        guard canEditMix, let state, let id = state.selectedEpisodeID, let document = state.store.document else { return }
        Task {
            do {
                try await document.mixerTransactions.barrier(replacingInstances: replacingInstances, episode: id) {
                    guard state.canEdit, !self.isClosed else { throw MixerFailure.staleDependencies }
                    guard state.selectedEpisodeID == id else { throw MixerFailure.staleDependencies }
                    let edited = try edit(self.inserts(bus))
                    guard replacingInstances || MixerInsertRack.hasSameProcessingState(edited, self.inserts(bus)) else {
                        throw MixerFailure.invalidRecipe("live insert edits may only change bypass")
                    }
                    let applied = state.store.applyMixerEdit(action) { model throws(DomainError) in
                        let mix = model.episode(id)?.mix ?? EpisodeMixState()
                        switch bus {
                        case .speaker(let speaker):
                            var strip = mix.state(for: speaker)
                            strip.inserts = edited
                            return try model.settingSpeakerMix(strip, in: id)
                        case .audioTrack(let track):
                            var strip = mix.state(for: track)
                            strip.inserts = edited
                            return try model.settingAudioTrackMix(strip, in: id)
                        case .master:
                            var master = mix.master
                            master.inserts = edited
                            return try model.settingMasterMix(master, in: id)
                        }
                    }
                    guard applied else { throw MixerFailure.invalidRecipe(state.store.lastError?.localizedDescription ?? "insert edit refused") }
                }
            } catch { document.mixerTransactions.report(error) }
        }
    }

    func openEditor(_ slot: AudioUnitSlot, generic: Bool = false) {
        guard canEdit, let document = state?.store.document else { return }
        if editedSlot == slot.id, generic == editorIsGeneric, let editorWindow {
            editorWindow.showWindow(nil)
            editorWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            do {
                try await document.mixerTransactions.edit {
                    guard !self.isClosed, let controller = self.controller else { throw MixerFailure.staleDependencies }
                    try await self.closeEditor()
                    try await document.mixerTransactions.handoffEditors(to: controller)
                    guard self.controller === controller else {
                        throw MixerFailure.invalidRecipe("the originating editor changed during effect-editor handoff")
                    }
                    if !controller.preparedInstanceIsCurrent || {
                        if case .failed = controller.state { return true }
                        return false
                    }() {
                        try await controller.prepareForEditing()
                    }
                    guard let processor = controller.processor else { throw MixerFailure.staleDependencies }
                    let revision = controller.instanceRevision
                    let parameters = try await processor.parameters(slot: slot.id)
                    let native = generic ? nil : try await processor.editor(slot: slot.id).requestViewController()
                    guard !self.isClosed, self.controller === controller,
                          revision == controller.instanceRevision, self.canEdit else {
                        throw MixerFailure.invalidRecipe("the editor request was superseded by a new processing instance")
                    }
                    try await controller.beginEditorObservation(coalescing: "mixer.editor.\(slot.id)")
                    self.parameters = parameters
                    self.editedSlot = slot.id
                    self.editorRevision = revision
                    self.editorIsGeneric = native == nil
                    let content: NSViewController
                    if let native {
                        content = MixerNativeEditorHost(editor: native)
                    } else {
                        let hosting = NSHostingController(rootView: MixerParameterView(presentation: self).wwAppEnvironment())
                        hosting.sizingOptions = []
                        content = hosting
                    }
                    let window = EpisodeAuxiliaryWindow(contentViewController: content)
                    window.originatingState = self.state
                    window.styleMask = [.titled, .closable, .resizable]
                    if let host = content as? MixerNativeEditorHost {
                        host.configure(window, available: MixerNativeEditorHost.availableContentSize(for: window))
                    } else {
                        window.contentMinSize = NSSize(width: 360, height: 220)
                        window.setContentSize(NSSize(width: 640, height: 480))
                    }
                    window.title = "\(self.episode?.title ?? "Episode") - \(slot.productName ?? "Audio Unit")"
                    window.setAccessibilityIdentifier("ww.mixer.editor")
                    let owner = MixerEditorWindowController(window: window)
                    owner.presentation = self
                    self.editorWindow = owner
                    if let state = self.state { ShowWindowRegistry.register(state, for: window) }
                    owner.showWindow(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            } catch { document.mixerTransactions.report(error) }
        }
    }

    func setParameter(_ parameter: MixerParameter, value: Double) {
        guard canEdit, let controller, let slot = editedSlot, let document = state?.store.document else { return }
        Task {
            do {
                try await document.mixerTransactions.edit {
                    guard self.editedSlot == slot, self.editorRevision == controller.instanceRevision else {
                        throw MixerFailure.invalidRecipe("the parameter editor belongs to a replaced processor; reopen it")
                    }
                    try await controller.setParameter(slot: slot, address: parameter.address, value: Float(value),
                        coalescing: "mixer.editor.\(slot)")
                    self.parameters = try await controller.processor?.parameters(slot: slot) ?? []
                }
            } catch { document.mixerTransactions.report(error) }
        }
    }

    func requestCloseEditor() {
        guard let document = state?.store.document else { return }
        Task {
            do { try await document.mixerTransactions.edit { try await self.closeEditor() } }
            catch { document.mixerTransactions.report(error) }
        }
    }

    func discardFailedEditorChanges() {
        guard let state, let document = state.store.document else { return }
        Task {
            do {
                try await discardFailedEditorChanges {
                    await Dialogs.confirm(in: self.editorWindow?.window ?? state.window,
                        message: "Discard unsaved Audio Unit changes?",
                        informative: "The last document state will be reloaded. Changes that could not be captured from this editor will be discarded.",
                        confirmTitle: "Discard Editor Changes", destructiveIsDefault: false)
                }
            } catch { document.mixerTransactions.report(error) }
        }
    }

    func discardFailedEditorChanges(confirm: @MainActor () async -> Bool) async throws {
        guard let document = state?.store.document, canDiscardEditorChanges else { return }
        let revision = editorRevision, slot = editedSlot
        guard await confirm() else { return }
        try await document.mixerTransactions.edit {
            guard self.editorRevision == revision, self.editedSlot == slot, let controller = self.controller else {
                throw MixerFailure.staleDependencies
            }
            self.hideEditorsForBarrier()
            await controller.suspendEditorObservation()
            self.dismissEditorsAfterCapture()
            self.model?.stopAudition()
            try await controller.discardUncapturedEditorState()
            try await controller.prepareForEditing()
        }
    }

    private func closeEditor() async throws {
        guard editorWindow != nil else { return }
        hideEditorsForBarrier()
        do { try await controller?.endEditorObservation() }
        catch { restoreEditorsAfterBarrier(); throw error }
        dismissEditorsAfterCapture()
    }

    func hideEditorsForBarrier() {
        editorWasVisible = editorWindow?.window?.isVisible == true
        editorWindow?.window?.orderOut(nil)
    }

    func restoreEditorsAfterBarrier() {
        if editorWasVisible { editorWindow?.showWindow(nil) }
        editorWasVisible = false
    }

    func dismissEditorsAfterCapture() {
        let owner = editorWindow
        editorWindow = nil
        editedSlot = nil
        editorRevision = nil
        parameters = []
        owner?.close()
    }

    func originDidClose() {
        guard !isClosed else { return }
        isClosed = true
        closeAuxiliaryWindows()
    }

    private func closeAuxiliaryWindows() {
        dismissEditorsAfterCapture()
        let detached = detachedWindow
        detachedWindow = nil
        detached?.close()
        model?.suspend()
        controller?.invalidatePreparedInstance()
    }
}

@MainActor
final class EpisodeAuxiliaryWindow: NSWindow {
    weak var originatingState: ShowWindowState?
    override var undoManager: UndoManager? { originatingState?.store.document?.undoManager }
}

@MainActor
private final class MixerDetachedWindowController: NSWindowController, NSWindowDelegate {
    weak var presentation: EpisodeMixerPresentation?
    override init(window: NSWindow?) { super.init(window: window); window?.delegate = self }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ShowWindowRegistry.unregister(window) }
        presentation?.detachedDidClose()
    }
}

@MainActor
final class MixerEditorWindowController: NSWindowController, NSWindowDelegate {
    weak var presentation: EpisodeMixerPresentation?
    override init(window: NSWindow?) { super.init(window: window); window?.delegate = self }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        presentation?.requestCloseEditor()
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ShowWindowRegistry.unregister(window) }
    }
}
