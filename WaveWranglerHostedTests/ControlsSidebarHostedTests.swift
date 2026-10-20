import AppKit
import SwiftUI
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Logic-style tools, listening presets, and sidebar activities", .serialized)
struct ControlsSidebarHostedTests {
    @Test func nativeToolMenusPublishSelectionAndRefreshTheirCheckedActions() async throws {
        let listening = EpisodeListeningState()
        let host = HostedTimelineWindow(width: 160, height: 40, content: TimelineToolControls(listening: listening))
        defer { host.close() }
        try await host.settle()
        let buttons = host.descendants.compactMap { $0 as? NativeActionMenu.Button }
        let primary = try #require(buttons.first { $0.accessibilityIdentifier() == "alignment.waveforms.tool" })
        let command = try #require(buttons.first { $0.accessibilityIdentifier() == "alignment.waveforms.commandTool" })
        #expect(primary.accessibilityLabel() == "Primary tool")
        #expect(command.accessibilityLabel() == "Command-click tool")
        #expect(primary.accessibilityValue() as? String == "Pointer")
        for (button, title) in [(primary, "Reviewed"), (command, "Reject")] {
            let menu = try #require(button.menu)
            let index = menu.indexOfItem(withTitle: title)
            try #require(index > 0)
            menu.performActionForItem(at: index)
            try await host.settle()
            #expect(button.accessibilityValue() as? String == title)
            let refreshed = try #require(button.menu)
            #expect(refreshed.items.filter { $0.state == .on }.map(\.title) == [title])
        }
        #expect(listening.tool == .reviewed && listening.commandTool == .reject)
        listening.tool = .move
        try await host.settle()
        #expect(primary.accessibilityValue() as? String == EpisodeListeningState.Tool.move.rawValue)
        #expect(listening.commandTool == .reject)
    }

    @Test func nativeCommandFlagsTemporarilySelectSecondaryToolAndResetOnRemoval() throws {
        let listening = EpisodeListeningState()
        let monitor = TimelineToolModifierMonitor.MonitorView(listening: listening)
        defer { monitor.stop() }
        for primary in EpisodeListeningState.Tool.allCases {
            for secondary in EpisodeListeningState.Tool.allCases {
                listening.tool = primary
                listening.commandTool = secondary
                monitor.process(try flags(.command))
                #expect(listening.effectiveTool == secondary && listening.tool == primary)
                monitor.process(try flags([]))
                #expect(listening.effectiveTool == primary && listening.commandTool == secondary)
            }
        }
        monitor.process(try flags([.command, .shift]))
        #expect(listening.commandHeld)
        monitor.stop()
        #expect(!listening.commandHeld && listening.effectiveTool == listening.tool)
        #expect(EpisodeListeningState.Tool.reviewed.reviewDecision == .reviewed)
        #expect(EpisodeListeningState.Tool.reject.reviewDecision == .rejected)
        #expect(EpisodeListeningState.Tool.move.reviewDecision == nil)
    }

    @Test func immediatePresetsKeepSavedPolicyEditingOptInAndExplicitMuteChoices() throws {
        let primary = SourceRecord(displayNameHint: "Synthetic primary")
        let backup = SourceRecord(displayNameHint: "Synthetic backup")
        let speaker = Speaker(name: "Synthetic")
        let episode = Episode(title: "Synthetic", sources: [primary, backup], speakerAssignments: [
            .init(speakerID: speaker.id, primary: .init(sourceID: primary.id, statedChannel: 0))
        ], workspace: .init(editingPlaybackPolicy: .keepChoices))
        let store = ShowDocumentStore(model: .init(show: Show(title: "Synthetic"),
                                                  speakers: [speaker], episodes: [episode]))
        let original = store.model
        let listening = EpisodeListeningState()
        listening.playback.setMuted(true, scope: .source(primary.id))
        let initial = listening.playback
        #expect(try listening.applyListeningPreset(.soloBackups, in: episode))
        #expect(listening.listeningPresetIsActive(.soloBackups, in: episode))
        #expect(!listening.listeningPresetIsActive(.soloPrimaries, in: episode))
        #expect(listening.playback.audibleSources(in: episode) == [backup.id])
        #expect(try listening.applyListeningPreset(.soloPrimaries, in: episode))
        #expect(listening.playback.muted.contains(.source(primary.id)), "Explicit mute always wins.")
        #expect(listening.previousPlayback == initial, "Repeated presets keep the original restore point.")
        #expect(listening.editingPolicyRevision == nil, "Immediate listening is not Begin editing.")
        #expect(store.model == original && store.model.episodes[0].workspace?.editingPlaybackPolicy == .keepChoices)
        let current = listening.playback
        #expect(try !listening.applyListeningPreset(.keepChoices, in: episode))
        #expect(listening.playback == current)
        #expect(throws: DomainError.self) {
            try listening.applyListeningPreset(.soloPrimaries, in: Episode(title: "No Primaries"))
        }
        #expect(listening.playback == current, "An unavailable preset cannot silently change listening.")
    }

    @Test func modifierMonitorRebindsWithoutRetainingAnotherEpisodesCommandState() throws {
        let first = EpisodeListeningState()
        let second = EpisodeListeningState()
        let monitor = TimelineToolModifierMonitor.MonitorView(listening: first)
        defer { monitor.stop() }
        monitor.process(try flags(.command))
        #expect(first.commandHeld)
        monitor.updateListening(second)
        #expect(!first.commandHeld && !second.commandHeld)
        monitor.process(try flags(.command))
        #expect(second.commandHeld && !first.commandHeld)
        monitor.stop()
        #expect(!second.commandHeld)
    }

    @Test func sidebarTogglesShareOneInspectorAndPreserveItsActivityWhenHidden() {
        let episode = Episode(title: "Synthetic")
        let state = ShowWindowState(store: .init(model: .init(show: Show(title: "Synthetic"),
                                                            episodes: [episode])), episodeID: episode.id)
        #expect(state.workspaceInspector == .recording && state.inspectorPresented)
        state.toggleWorkspaceInspector(.alignment)
        #expect(state.workspaceInspector == .alignment && state.inspectorPresented)
        state.toggleWorkspaceInspector(.alignment)
        #expect(state.workspaceInspector == .alignment && !state.inspectorPresented)
        state.toggleWorkspaceInspector(.transcript)
        #expect(state.workspaceInspector == .transcript && state.inspectorPresented)
        state.toggleInspector()
        #expect(!state.inspectorPresented && state.workspaceInspector == .transcript)
        state.toggleInspector()
        #expect(state.inspectorPresented && state.workspaceInspector == .transcript)
        #expect(state.compactInspectorWidth == 300)
        state.select(.setup)
        #expect(state.compactInspectorWidth == 190)
    }

    @Test(arguments: [
        (100.0, 200.0, 80.0, 500.0, 150.0),
        (0.0, 10.0, 330.0, 500.0, 165.0),
        (490.0, 500.0, 330.0, 500.0, 335.0),
        (0.0, 10.0, 330.0, 190.0, 95.0),
        (0.0, 0.0, 148.0, 0.0, 0.0),
    ])
    func selectionToolbarCentersAndClampsToVisibleTrack(_ values: (Double, Double, Double, Double, Double)) {
        #expect(TimelineToolbarPlacement.center(selectionStart: values.0, selectionEnd: values.1,
                                                toolbarWidth: values.2, trackWidth: values.3) == values.4)
    }

    @Test func reviewToolsClearReviewAndRevertUseDocumentUndoWithoutEditingSources() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 6)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        let model = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        defer { model.cancel() }
        let prepared = try await f.runtime.prepareCleanup(model: f.document.store.model, episode: f.model.episodeID)
        model.plan = prepared.plan
        model.identities = prepared.identities
        let lane = try #require(prepared.plan.lanes.first)
        let frames = try #require(lane.sourceRange(start: 2, end: 2.25))
        let transcript = SpeakerTranscript(speaker: lane.speaker, primary: lane.primary, sourceRate: lane.sourceRate,
            sourceIdentity: try #require(prepared.identities[lane.primary.sourceID]),
            alignmentRevision: try #require(prepared.plan.alignmentRevision), model: "Synthetic controls fixture",
            workingRange: nil, words: [.init(text: "Um,", sourceStartFrame: frames.lowerBound,
                sourceEndFrame: frames.upperBound, alignedStart: 2, alignedEnd: 2.25)])
        try #require(f.document.store.apply("Seed synthetic review") { snapshot throws(DomainError) in
            try snapshot.settingCleanup(.init(transcripts: [transcript]), in: model.episodeID)
        })
        model.proposeFillers()
        let detected = try #require(model.fillerReviews.first)
        model.selectFiller(detected.id, reveal: false)
        model.setWindow(start: 1.9, duration: 0.5)
        try #require(model.selectedFillerID == detected.id && model.canReviewFillers)
        let host = HostedTimelineWindow(width: 744, height: 110,
            content: FillerTimingOverlay(model: model, reviews: [detected]))
        defer { host.close() }
        host.window.makeKeyAndOrderFront(nil)
        try await host.settle()
        try host.capture("Compact marker controls before native input")
        let views = host.descendants.map {
            "\(type(of: $0)): frame=\($0.frame), id=\($0.accessibilityIdentifier() ?? ""), label=\($0.accessibilityLabel() ?? "")"
        }.joined(separator: "\n")
        Attachment.record(Data("""
            host=\(host.view.frame), key=\(host.window.isKeyWindow), active=\(NSApp.isActive)
            children=\(String(describing: host.view.accessibilityChildren()))
            \(views)
            """.utf8), named: "compact-marker-native-view-tree.txt")
        func clickControl(_ identifier: String, index: Int, audition: Bool) async throws {
            let frames = host.controlFrames.filter {
                audition ? $0.height < 15 && $0.width < 30 : (19...21).contains($0.height) && $0.width >= 31
            }.sorted { $0.minX < $1.minX }
            try #require(frames.count == 4, "\(identifier): expected four visible native controls, got \(frames)")
            let frame = frames[index]
            let point = CGPoint(x: frame.midX, y: frame.midY)
            Attachment.record(Data("""
                \(identifier): local=\(frame)
                hit=\(String(describing: host.view.hitTest(point)))
                native control frames=\(host.controlFrames)
                """.utf8), named: "\(identifier)-hit.txt")
            try await host.click(point)
        }
        try await clickControl("ww.cleanup.filler.loop", index: 2, audition: true)
        #expect(model.loopsFillerAudition)
        try await clickControl("ww.cleanup.filler.loop", index: 2, audition: true)
        #expect(!model.loopsFillerAudition)
        try await clickControl("ww.cleanup.filler.reject", index: 1, audition: false)
        #expect(model.selectedFiller?.decision == .rejected)
        try await clickControl("ww.cleanup.filler.clearReview", index: 2, audition: false)
        #expect(model.selectedFiller?.decision == .pending)
        try host.capture("Native compact marker action hit testing")
        let original = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        for tool in [EpisodeListeningState.Tool.reviewed, .reject] {
            model.listening.tool = .select
            model.listening.commandTool = tool
            model.listening.updateCommandModifier(true)
            undo.beginUndoGrouping()
            model.activateFillerMarker(detected.id)
            undo.endUndoGrouping()
            #expect(model.selectedFiller?.decision == tool.reviewDecision)
            #expect(model.listening.selection == 2...2.25)
            undo.undo()
            #expect(f.document.store.model == original)
            undo.redo()
            #expect(model.selectedFiller?.decision == tool.reviewDecision)
            undo.undo()
            model.listening.updateCommandModifier(false)
        }
        undo.beginUndoGrouping()
        model.setFillerBounds(detected.id, start: 1.99, end: 2.26)
        undo.endUndoGrouping()
        let adjusted = try #require(model.selectedFiller)
        undo.beginUndoGrouping()
        model.decideFiller(detected.id, decision: .pending)
        undo.endUndoGrouping()
        #expect(model.selectedFiller?.decision == .pending)
        #expect(model.selectedFiller?.bounds == adjusted.bounds)
        #expect(model.selectedFiller?.detectedBounds == detected.detectedBounds)
        undo.undo()
        #expect(model.selectedFiller == adjusted)
        undo.beginUndoGrouping()
        model.revertFiller(detected.id)
        undo.endUndoGrouping()
        #expect(model.selectedFiller == detected)
        model.isRefreshing = true
        model.listening.tool = .reject
        model.activateFillerMarker(detected.id)
        #expect(model.selectedFiller == detected && model.error != nil)
        #expect(model.episode?.cleanup?.transcripts == original.episodes[0].cleanup?.transcripts)
        #expect(model.episode?.alignment == original.episodes[0].alignment)
        #expect(model.episode?.sources == original.episodes[0].sources)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    private func flags(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
