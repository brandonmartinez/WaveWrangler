import AppKit
import Foundation
import SwiftUI
import Testing
import WWCore
import WWPersistence
@testable import WWSpeech
@testable import WaveWrangler

@MainActor
@Suite("Bottom review list and focus-safe timeline controls", .serialized)
struct ReviewPanelHostedTests {
    func fixture() async throws -> (AlignmentWaveformRetentionHostedTests.Fixture, EpisodeCleanupModel, ShowWindowState) {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 12)
        var ready = false
        defer { if !ready { f.close() } }
        f.model.placeGroupsAtSourceTime()
        try await wait {
            !f.model.isWorking && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
                && f.document.verifiedModel == f.document.store.model && f.model.waveformMap != nil
        }
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        state.select(.alignment)
        state.alignmentModel = f.model
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        state.cleanupModel = cleanup
        await cleanup.refresh()
        let snapshot = f.document.store.model
        let transcripts = try await f.runtime.transcribeCleanup(model: snapshot, episode: f.model.episodeID,
            modelRevision: "synthetic-review-panel", chunking: .fixed, transcribeWindow: { _ in
                PCMTranscript(segments: [
                    .init(text: "um", startSeconds: 1, endSeconds: 1.3),
                    .init(text: "uh", startSeconds: 4, endSeconds: 4.4),
                ])
            }, progress: { _ in })
        try #require(try cleanup.publishTranscripts(transcripts, expecting: snapshot))
        await cleanup.refresh()
        try #require(cleanup.fillerReviews.count == 2 && cleanup.canReviewFillers)
        f.model.load()
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms && f.model.canApplyManualCuts }
        ready = true
        return (f, cleanup, state)
    }

    @Test func rowSelectionCentersZoomsAndKeepsReadableTimeWithoutRoundingSavedBounds() async throws {
        let (f, cleanup, _) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        let before = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        let rows = cleanup.reviewRows
        #expect(rows.map(\.phrase) == ["um", "uh"])
        #expect(rows.map(\.status) == ["Needs review", "Needs review"])
        #expect(rows[0].time == "00:00:01.000" && rows[0].duration == "0.30 s")
        cleanup.focusReviewRow(rows[0].id)
        #expect(cleanup.selectedReviewRowID == rows[0].id)
        #expect(abs(f.model.waveformStartSeconds + f.model.waveformDurationSeconds / 2 - 1.15) < 0.000001)
        #expect(f.model.waveformDurationSeconds <= 2)
        #expect(abs(f.model.waveformDurationSeconds - 1.953125) < 0.000001,
                "Automatic filler focus is exactly three 1.25x zoom-out steps wider.")
        f.model.waveformDurationSeconds = 15
        cleanup.focusReviewRow(rows[0].id)
        #expect(abs(f.model.waveformDurationSeconds - 1.953125) < 0.000001,
                "Repeated focus uses the automatic context, not the current viewport's zoom.")
        #expect(cleanup.listening.selection == 1...1.3)
        #expect(cleanup.state.workspaceInspector == .transcript && cleanup.state.inspectorPresented)
        #expect(f.document.store.model == before)
        cleanup.windowStart = 3
        #expect(cleanup.reviewRows == rows)
        #expect(cleanup.reviewRowsSnapshot?.generation == f.document.store.modelGeneration)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func waveformFillerVisibilitySharesClassificationAndInvalidatesWithSourceEvidence() async throws {
        let (f, cleanup, _) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        let lane = try #require(cleanup.plan?.lanes.first)
        cleanup.windowStart = 0
        cleanup.windowDuration = 12
        #expect(cleanup.visibleFillers(for: lane).map(\.id) == cleanup.fillerReviews.map(\.id))
        #expect(cleanup.reviewRowsSnapshot?.generation == f.document.store.modelGeneration)
        cleanup.windowStart = 3
        cleanup.windowDuration = 3
        #expect(cleanup.visibleFillers(for: lane).map(\.id) == [cleanup.fillerReviews[1].id])
        let identities = cleanup.identities
        cleanup.identities = [:]
        #expect(cleanup.visibleFillers(for: lane).isEmpty)
        cleanup.identities = identities
        #expect(cleanup.visibleFillers(for: lane).map(\.id) == [cleanup.fillerReviews[1].id])
    }

    @Test(arguments: [
        CGSize(width: 460, height: 440),
        CGSize(width: 760, height: 440),
        CGSize(width: 1024, height: 572),
        CGSize(width: 1100, height: 800),
    ])
    func timelineControlsStayAboveTheSplitWhenBottomPanesOpenAndResize(_ size: CGSize) async throws {
        let (f, cleanup, state) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        state.bottomPanePresented = false
        let host = HostedTimelineWindow(width: size.width, height: size.height,
            content: AlignmentWorkspace(state: state, model: f.model, showInspector: {}))
        defer { host.close() }
        try await host.settle()
        func controls() throws -> (NSSlider, NSPopUpButton) {
            let zoom = try #require(host.descendants.compactMap { $0 as? NSSlider }.first {
                $0.accessibilityIdentifier() == "alignment.waveforms.zoom"
            })
            let tools = try #require(host.descendants.compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityIdentifier() == "alignment.waveforms.tool"
            })
            return (zoom, tools)
        }
        let (zoom, tools) = try controls()
        let initialZoom = host.view.convert(zoom.bounds, from: zoom)
        let initialTools = host.view.convert(tools.bounds, from: tools)
        f.model.listening.workspace.reviewPanelHeight = 1200
        state.reviewPanelPresented = true
        try await host.settle()
        let split = try #require(host.descendants.compactMap { $0 as? NSSplitView }.first { !$0.isVertical })
        for pane in EpisodeBottomPaneContent.allCases {
            state.bottomPaneContent = pane
            try await host.settle()
            split.setPosition(min(80, split.bounds.height / 3), ofDividerAt: 0)
            try await host.settle()
            let (zoom, tools) = try controls()
            #expect(!zoom.isDescendant(of: split) && !tools.isDescendant(of: split),
                    "Timeline chrome must not share the bottom pane's constrained split child.")
            let viewport = host.view.convert(host.window.contentLayoutRect, from: nil)
            let zoomFrame = host.view.convert(zoom.bounds, from: zoom)
            let toolFrame = host.view.convert(tools.bounds, from: tools)
            #expect(viewport.contains(zoomFrame) && viewport.contains(toolFrame),
                    "Opening or resizing \(pane.rawValue) must not clip fixed controls at \(size).")
            #expect(abs(zoomFrame.minY - initialZoom.minY) < 1)
            #expect(abs(toolFrame.minY - initialTools.minY) < 1)
        }
        state.bottomPanePresented = false
        try await host.settle()
        let (restoredZoom, _) = try controls()
        #expect(abs(host.view.convert(restoredZoom.bounds, from: restoredZoom).minY - initialZoom.minY) < 1)
        try host.capture("Docked controls \(Int(size.width))x\(Int(size.height))")
    }

    @Test func plusMinusAndRowCutsUseExistingUndoAndPreserveRawTranscriptAndRecordings() async throws {
        let (f, cleanup, _) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        let before = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        let review = try #require(cleanup.fillerReviews.first)
        cleanup.focusReviewRow(review.id)
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        cleanup.resizeReviewInterval(review.id, expanding: true)
        undo.endUndoGrouping()
        let expanded = try #require(cleanup.selectedFiller)
        #expect(abs(expanded.bounds.alignedStart - 0.99) < 1e-12)
        #expect(abs(expanded.bounds.alignedEnd - 1.31) < 1e-12)
        #expect(expanded.initialBounds == review.initialBounds && expanded.word == review.word)
        #expect(cleanup.reviewRows.first?.status == "Adjusted")
        undo.undo()
        #expect(f.document.store.model == before)
        undo.redo()
        #expect(cleanup.fillerReviews.first?.bounds == expanded.bounds)
        undo.undo()
        cleanup.synchronizeCutTimeline()
        undo.beginUndoGrouping()
        cleanup.autoCutReviewRow(review.id)
        undo.endUndoGrouping()
        let cut = try #require(cleanup.activeManualCuts.first, "\(cleanup.error ?? "")")
        #expect(cut.markerID == review.id && cut.startFrame == 48_000 && cut.endFrame == 62_400)
        #expect(cleanup.reviewRows.first?.category == .cut)
        #expect(cleanup.episode?.cleanup?.transcripts == before.episodes[0].cleanup?.transcripts)
        #expect(cleanup.episode?.alignment == before.episodes[0].alignment)
        let cutModel = f.document.store.model
        undo.beginUndoGrouping()
        cleanup.resizeReviewInterval(review.id, expanding: true)
        undo.endUndoGrouping()
        #expect(cleanup.activeManualCuts.first?.startFrame == 47_520)
        #expect(cleanup.activeManualCuts.first?.endFrame == 62_880)
        undo.undo()
        cleanup.synchronizeCutTimeline()
        #expect(f.document.store.model == cutModel)
        undo.undo()
        cleanup.synchronizeCutTimeline()
        #expect(f.document.store.model == before && cleanup.activeManualCuts.isEmpty)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
        let unchanged = f.document.store.model
        cleanup.resizeReviewInterval(review.id, expanding: false, seconds: 0.2)
        #expect(cleanup.error != nil && f.document.store.model == unchanged)
        cleanup.isRefreshing = true
        cleanup.autoCutReviewRow(review.id)
        #expect(f.document.store.model == unchanged)
        cleanup.isRefreshing = false
        let stale = FillerTimingReview(origin: .manual, speaker: review.speaker, primary: review.primary,
            sourceRate: review.sourceRate, sourceIdentity: String(repeating: "b", count: 64),
            alignmentRevision: review.alignmentRevision, initialBounds: review.initialBounds)
        var history = try #require(cleanup.episode?.cleanup)
        history.fillerReviews?.append(stale)
        undo.beginUndoGrouping()
        let appended = cleanup.state.store.apply("Synthetic stale review") { model throws(DomainError) in
            try model.settingCleanup(history, in: cleanup.episodeID)
        }
        undo.endUndoGrouping()
        try #require(appended)
        let retained = f.document.store.model
        #expect(cleanup.reviewRows.first { $0.id == stale.id }?.category == .inactive)
        cleanup.autoCutReviewRow(stale.id)
        #expect(cleanup.error != nil && f.document.store.model == retained)
    }

    @Test func rowAuditionPlaysCurrentBoundsAndCutAudioWithoutEditingTheDocument() async throws {
        let (f, cleanup, _) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        let detected = try #require(cleanup.fillerReviews.first)
        cleanup.resizeReviewInterval(detected.id, expanding: true)
        let review = try #require(cleanup.selectedFiller)
        let before = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        cleanup.requestReviewRowFocus(review.id)
        cleanup.auditionReviewRow(review.id)
        try #require(f.model.canStopAudition, "\(cleanup.error ?? f.model.auditionLabel)")
        try await wait { !f.model.canStopAudition }
        #expect(f.model.auditionLabel == "Finished selection audition.")
        #expect(abs(f.model.waveformPlayheadSeconds - review.bounds.alignedEnd) < 1 / 48_000)
        #expect(f.document.store.model == before)
        cleanup.autoCutReviewRow(review.id)
        let cut = try #require(cleanup.activeManualCuts.first)
        cleanup.showManualCut(cut.id, expanded: false)
        let withCut = f.document.store.model
        cleanup.auditionReviewRow(review.id)
        try #require(f.model.canStopAudition, "\(cleanup.error ?? f.model.auditionLabel)")
        try await wait { !f.model.canStopAudition }
        #expect(f.model.auditionLabel == "Finished selection audition.")
        #expect(cleanup.listening.expandedManualCutID == cut.id)
        #expect(abs(f.model.waveformPlayheadSeconds
            - cleanup.cutTimeline.editedTime(forAlignedTime: cut.alignedEnd)) < 1 / 48_000)
        #expect(f.document.store.model == withCut)
        cleanup.isRefreshing = true
        cleanup.auditionReviewRow(review.id)
        #expect(!f.model.canStopAudition && cleanup.error != nil)
        cleanup.isRefreshing = false
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func bottomPanelIsResizableAndTheSidebarNoLongerContainsTheWholeReviewHistory() async throws {
        let (f, cleanup, state) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        state.reviewPanelPresented = true
        let before = f.document.store.model
        var host = HostedTimelineWindow(width: 1100, height: 800,
            content: AlignmentWorkspace(state: state, model: f.model, showInspector: {}))
        defer { host.close() }
        NSApp.activate()
        host.window.makeKeyAndOrderFront(nil)
        try await host.settle()
        let split = try #require(host.descendants.compactMap { $0 as? NSSplitView }.first { !$0.isVertical })
        #expect(split.arrangedSubviews.count == 2)
        let original = split.arrangedSubviews[1].frame.height
        split.setPosition(split.arrangedSubviews[0].frame.height - 40, ofDividerAt: 0)
        try await host.settle()
        #expect(split.arrangedSubviews[1].frame.height > original + 20)
        let savedHeight = split.arrangedSubviews[1].frame.height
        #expect(abs(f.model.listening.workspace.reviewPanelHeight - savedHeight) < 1)
        host.close()
        host = HostedTimelineWindow(width: 1100, height: 800,
            content: AlignmentWorkspace(state: state, model: f.model, showInspector: {}))
        host.window.makeKeyAndOrderFront(nil)
        try await host.settle()
        let restoredSplit = try #require(host.descendants.compactMap { $0 as? NSSplitView }.first { !$0.isVertical })
        #expect(abs(restoredSplit.arrangedSubviews[1].frame.height - savedHeight) < 1,
            "Reopening restores the actual divider position, not just its preference value.")
        let table = try #require(host.descendants.compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 2)
        let phrase = table.rect(ofColumn: 1)
        let row = table.rect(ofRow: 0)
        try await host.click(host.view.convert(CGPoint(x: phrase.midX, y: row.midY), from: table))
        #expect(cleanup.selectedReviewRowID == cleanup.reviewRows.first?.id)
        #expect(f.model.waveformDurationSeconds <= 2)
        let origin = try #require(cleanup.fillerReviews.first)
        var history = try #require(cleanup.episode?.cleanup)
        history.fillerReviews = cleanup.fillerReviews + (0..<700).map { index in
            let start = Int64(index * 80 + 80)
            return FillerTimingReview(origin: .manual, speaker: origin.speaker, primary: origin.primary,
                sourceRate: origin.sourceRate, sourceIdentity: origin.sourceIdentity,
                alignmentRevision: origin.alignmentRevision, initialBounds: FillerTimingBounds(
                    sourceStartFrame: start, sourceEndFrame: start + 40,
                    alignedStart: Double(start) / Double(origin.sourceRate),
                    alignedEnd: Double(start + 40) / Double(origin.sourceRate)))
        }
        try #require(state.store.apply("Synthetic large review list") { model throws(DomainError) in
            try model.settingCleanup(history, in: cleanup.episodeID)
        })
        try await host.settle()
        #expect(table.numberOfRows == 702)
        #expect(table.rows(in: table.visibleRect).length < 40)
        table.scrollRowToVisible(700)
        try await host.settle()
        #expect(NSLocationInRange(700, table.rows(in: table.visibleRect)),
                "visible=\(table.visibleRect), rows=\(table.rows(in: table.visibleRect)), last=\(table.rect(ofRow: 700)), frame=\(table.frame), clip=\(String(describing: table.enclosingScrollView?.contentView.bounds))")
        try host.capture("Resizable bottom review table")
        host.window.setContentSize(NSSize(width: 460, height: 540))
        try await host.settle()
        #expect(table.enclosingScrollView != nil)
        #expect(restoredSplit.arrangedSubviews.first.map { $0.frame.height >= 64 } == true)
        #expect(restoredSplit.arrangedSubviews.allSatisfy { $0.frame.height >= 0 },
                "The bottom pane yields space before it can clip the fixed control bar.")
        #expect(f.document.store.model.episodes[0].alignment == before.episodes[0].alignment)
        state.reviewPanelPresented = false
        try await host.settle()
        #expect(!state.reviewPanelPresented)
    }

    @Test func spaceAndConfigurableTrackJumpsRespectTextButtonsTablesAndSheets() async throws {
        let (f, cleanup, state) = try await fixture()
        defer { cleanup.cancel(); f.close() }
        let settings = AppSettings.shared
        let prior = settings.timelineJumpInterval
        defer { settings.timelineJumpInterval = prior }
        let host = HostedTimelineWindow(width: 900, height: 640,
            content: AlignmentWorkspace(state: state, model: f.model, showInspector: {}))
        defer { host.close() }
        state.window = host.window
        ShowWindowRegistry.register(state, for: host.window)
        NSApp.activate()
        host.window.makeKeyAndOrderFront(nil)
        try await host.settle()
        host.view.setAccessibilityRole(.group)
        host.view.setAccessibilityIdentifier("ww.alignment.workspaceRoot")
        let targets = host.descendants.filter {
            $0.acceptsFirstResponder && abs($0.frame.height - 44) < 0.5 && $0.frame.width > 300
        }
        let ruler = try #require(targets.first, "Ruler focus targets: \(targets)")
        try #require(host.window.makeFirstResponder(ruler))
        AlignmentKeyHandler.install()
        #expect(!AlignmentKeyHandler.hasInteractiveFocus(in: host.window),
            "Timeline focus: \(type(of: ruler)), control=\(ruler is NSControl), role=\(String(describing: ruler.accessibilityRole()))")
        func event(_ code: UInt16, characters: String, repeatKey: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeatKey, keyCode: code))
        }
        func send(_ event: NSEvent, until completed: () -> Bool) async throws {
            try #require(event.windowNumber == host.window.windowNumber)
            NSApp.sendEvent(event)
            try await wait(timeout: .seconds(2),
                           context: "Dispatched key \(event.keyCode) did not produce the expected timeline state.",
                           completed)
        }
        let space = try event(49, characters: " ")
        try await send(space) { f.model.isPreparingAudition || f.model.isAuditioning }
        #expect(f.model.isPreparingAudition || f.model.isAuditioning)
        // Synchronous dispatch acknowledges the no-change repeat before its state assertion.
        NSApp.sendEvent(try event(49, characters: " ", repeatKey: true))
        #expect(f.model.canStopAudition)
        try await send(space) { !f.model.canStopAudition }
        #expect(!f.model.canStopAudition)
        settings.timelineJumpInterval = .two
        f.model.seekEnabledTracks(to: 4)
        try await send(event(124, characters: "\u{f703}")) { f.model.waveformPlayheadSeconds == 6 }
        #expect(f.model.waveformPlayheadSeconds == 6)
        try await send(event(123, characters: "\u{f702}")) { f.model.waveformPlayheadSeconds == 4 }
        #expect(f.model.waveformPlayheadSeconds == 4)
        settings.timelineJumpInterval = .ten
        try await send(event(124, characters: "\u{f703}")) { f.model.waveformPlayheadSeconds == 12 }
        #expect(f.model.waveformPlayheadSeconds == 12)
        let container = NSView(frame: host.view.frame)
        host.window.contentView = container
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
        let button = NSButton(title: "Synthetic action", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 30)
        container.addSubview(button)
        try #require(host.window.makeFirstResponder(button))
        #expect(!AlignmentKeyHandler.handle(space) && !f.model.canStopAudition)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        container.addSubview(editor)
        try #require(host.window.makeFirstResponder(editor))
        #expect(!AlignmentKeyHandler.handle(space))
        #expect(try !AlignmentKeyHandler.handle(event(123, characters: "\u{f702}")))
        state.reviewPanelPresented = true
        try await host.settle()
        let table = try #require(host.descendants.compactMap { $0 as? NSTableView }.first)
        try #require(host.window.makeFirstResponder(table))
        #expect(!AlignmentKeyHandler.handle(space))
        #expect(try !AlignmentKeyHandler.handle(event(124, characters: "\u{f703}")))
        _ = host.window.makeFirstResponder(host.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        host.window.beginSheet(sheet, completionHandler: { _ in })
        #expect(!AlignmentKeyHandler.handle(space))
        host.window.endSheet(sheet)
        sheet.orderOut(nil)
    }

    private func wait(
        timeout: Duration = .seconds(40),
        context: String = "The synthetic review workspace did not finish preparing.",
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), Comment(rawValue: context))
    }
}
