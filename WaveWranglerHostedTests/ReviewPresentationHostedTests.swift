import AppKit
import Foundation
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Episode-owned detachable transcript review", .serialized)
struct ReviewPresentationHostedTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    @Test func detachAndReattachKeepFiltersSelectionRuntimeAndTheOriginalDocument() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        owner.showWindow(nil)
        try await settle()
        let before = f.document.store.residentModel
        let review = try #require(cleanup.fillerReviews.first)
        cleanup.reviewSearch = "um"
        cleanup.reviewStatusFilter = .pending
        cleanup.focusReviewRow(review.id)
        state.reviewPanelPresented = true
        let presentation = state.reviewPresentation
        presentation.detach()
        let first = try #require(presentation.detachedWindow?.window)
        try await settle()
        #expect(first.isVisible && first.styleMask.contains(.resizable))
        #expect(first.accessibilityIdentifier() == "ww.review.window")
        #expect(ShowWindowRegistry.state(for: first) === state)
        #expect(first.undoManager === f.document.undoManager)
        #expect(state.cleanupModel === cleanup && state.alignmentModel === f.model)
        #expect(cleanup.reviewSearch == "um" && cleanup.reviewStatusFilter == .pending)
        #expect(cleanup.selectedReviewRowID == review.id)
        #expect(!f.model.canStopAudition && f.document.store.residentModel == before)
        presentation.detach()
        #expect(presentation.detachedWindow?.window === first)
        func indicator(in view: NSView?) -> ReviewPlaybackIndicator.IndicatorView? {
            guard let view else { return nil }
            if let indicator = view as? ReviewPlaybackIndicator.IndicatorView { return indicator }
            return view.subviews.lazy.compactMap { indicator(in: $0) }.first
        }
        cleanup.play(interval: 0...6, loop: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !cleanup.isPlaying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(cleanup.isPlaying)
        try await settle()
        let detachedIndicator = try #require(indicator(in: first.contentView))
        #expect(!detachedIndicator.line.isHidden)
        presentation.reattach()
        try await settle()
        #expect(!presentation.isDetached && !first.isVisible)
        #expect(state.reviewPanelPresented && state.bottomPaneContent == .review)
        #expect(cleanup.reviewSearch == "um" && cleanup.selectedReviewRowID == review.id)
        #expect(f.document.store.residentModel == before)
        #expect(ShowWindowRegistry.state(for: first) == nil)
        #expect(cleanup.isPlaying, "Reattaching the review does not restart or stop the shared transport.")
        let dockedIndicator = try #require(indicator(in: owner.window?.contentView))
        #expect(!dockedIndicator.line.isHidden)
        cleanup.stopPlayback()
        try await settle()
        #expect(dockedIndicator.line.isHidden)
    }

    @Test func detachedEditsUseTheSameUndoHistoryAndClosingTheWindowDoesNotCloseTheEpisode() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        owner.showWindow(nil)
        try await settle()
        let before = f.document.store.residentModel
        let review = try #require(cleanup.fillerReviews.first)
        state.reviewPresentation.detach()
        let window = try #require(state.reviewPresentation.detachedWindow?.window)
        let undo = try #require(window.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        cleanup.resizeReviewInterval(review.id, expanding: true)
        undo.endUndoGrouping()
        let changed = f.document.store.residentModel
        #expect(changed != before)
        #expect(window.undoManager === f.document.undoManager)
        undo.undo()
        #expect(f.document.store.residentModel == before)
        undo.redo()
        #expect(f.document.store.residentModel == changed)
        window.close()
        #expect(!state.reviewPresentation.isDetached && !state.reviewPresentation.isClosed)
        #expect(state.cleanupModel === cleanup && owner.window?.isVisible == true)
        #expect(ShowWindowRegistry.state(for: window) == nil)
        state.reviewPresentation.detach()
        #expect(state.reviewPresentation.isDetached)
        owner.close()
        try await settle()
        #expect(state.reviewPresentation.isClosed && !state.reviewPresentation.isDetached)
    }

    @Test func deletingTheOriginEpisodeClosesOnlyItsOwnDetachedReview() async throws {
        let (first, firstCleanup, firstState) = try await ReviewPanelHostedTests().fixture()
        let (other, otherCleanup, otherState) = try await ReviewPanelHostedTests().fixture()
        defer { firstCleanup.cancel(); otherCleanup.cancel(); first.close(); other.close() }
        firstState.reviewPresentation.detach()
        otherState.reviewPresentation.detach()
        let firstWindow = try #require(firstState.reviewPresentation.detachedWindow?.window)
        let otherWindow = try #require(otherState.reviewPresentation.detachedWindow?.window)
        #expect(firstWindow !== otherWindow)
        #expect(firstWindow.undoManager !== otherWindow.undoManager)
        let removed = first.document.store.apply("Remove synthetic episode") { model throws(DomainError) in
            try model.removingEpisode(first.model.episodeID)
        }
        try #require(removed)
        try await settle()
        #expect(!firstWindow.isVisible && !firstState.reviewPresentation.isDetached)
        #expect(otherWindow.isVisible && otherState.reviewPresentation.isDetached)
        otherState.reviewPresentation.reattach()
    }
}
