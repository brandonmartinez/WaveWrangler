import AppKit
import SwiftUI
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Blocking track progress and cancellation", .serialized)
struct TrackProcessingOverlayHostedTests {
    private func cancelFrame<Content: View>(in host: HostedTimelineWindow<Content>) throws -> CGRect {
        let frames = host.controlFrames.filter { $0.width < 100 && $0.height >= 16 }
        try #require(frames.count == 1, "Expected one Cancel control, got \(host.controlFrames)")
        return try #require(frames.first)
    }

    @Test(arguments: [
        CGSize(width: 320, height: 100),
        CGSize(width: 900, height: 320),
        CGSize(width: 420, height: 64),
    ])
    func cancelRemainsReachableWhileTrackControlsAreBlocked(_ size: CGSize) async throws {
        var trackActions = 0
        var cancellations = 0
        let operation = TrackProcessingOperation(kind: .waveforms, title: "Preparing waveforms",
            detail: "Restoring verified synthetic waveform data.", fraction: 0.4, canCancel: true)
        let host = HostedTimelineWindow(width: size.width, height: size.height, content:
            NativeTimelineSlider(value: .constant(0.5), range: 0...1,
                label: "Synthetic track control", identifier: "test.trackAction",
                onEditingChanged: { _ in trackActions += 1 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(TrackProcessingPresentation(operation: operation, cancel: { cancellations += 1 })))
        defer { host.close() }
        try await host.settle()
        let track = try #require(host.descendants.compactMap { $0 as? NSSlider }.first {
            $0.accessibilityIdentifier() == "test.trackAction"
        })
        #expect(!track.isEnabled)
        let cancel = try cancelFrame(in: host)
        #expect(host.view.bounds.contains(cancel),
            "Cancel must remain inside even a compact track viewport.")
        try await host.click(CGPoint(x: cancel.midX, y: cancel.midY))
        #expect(cancellations == 1 && trackActions == 0)
        try host.capture("Blocking track progress \(Int(size.width))x\(Int(size.height))")
    }

    @Test func finalVerifiedUpdatesDoNotOfferAnUnsafeCancellation() async throws {
        var cancellations = 0
        let operation = TrackProcessingOperation(kind: .timingUpdate, title: "Saving timing",
            detail: "Waiting for independent save verification.", fraction: nil, canCancel: false)
        let host = HostedTimelineWindow(width: 520, height: 240,
            content: TrackProcessingOverlay(operation: operation, cancel: { cancellations += 1 }))
        defer { host.close() }
        try await host.settle()
        let cancel = try cancelFrame(in: host)
        try await host.click(CGPoint(x: cancel.midX, y: cancel.midY))
        #expect(cancellations == 0)
    }

    @Test func alignmentCancellationLeavesTheDocumentAndOriginalsUnchanged() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2)
        defer { f.close() }
        let original = f.document.store.model
        let bytes = try f.files.map { try Data(contentsOf: $0) }
        f.model.analyzeTracks()
        let operation = try #require(TrackProcessingOperation.current(alignment: f.model, cleanup: nil))
        #expect(operation.kind == .alignmentAnalysis && operation.canCancel && operation.fraction == nil)
        TrackProcessingOperation.cancel(alignment: f.model, cleanup: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while f.model.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!f.model.isWorking && f.model.lastError == nil, "\(f.model.lastError ?? "")")
        #expect(f.document.store.model == original)
        #expect(try f.files.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func transcriptionUsesTheSameOverlayWithoutInventingProgress() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID)
        defer { cleanup.cancel() }
        let original = f.document.store.model
        cleanup.isBusy = true
        cleanup.message = "Waiting for local transcription resources."
        let operation = try #require(TrackProcessingOperation.current(alignment: f.model, cleanup: cleanup))
        #expect(operation.kind == .transcription && operation.fraction == nil && operation.canCancel)
        TrackProcessingOperation.cancel(alignment: f.model, cleanup: cleanup)
        #expect(!cleanup.isBusy)
        #expect(cleanup.message == "Transcription canceled. No partial result was saved.")
        #expect(f.document.store.model == original)
    }

    @Test func commandReturnCannotStartAuditionBehindTranscription() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (f.model.trackProcessingOperation != nil || f.model.waveformNeedsRefreshAfterSave),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        f.model.selection = try #require(f.model.rows.first { $0.state.remedies.contains("Audition") }?.epochID)
        try #require(f.model.canAudition, "\(f.model.message)")
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        state.select(.alignment)
        state.alignmentModel = f.model
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID)
        defer { cleanup.cancel() }
        state.cleanupModel = cleanup
        cleanup.isBusy = true
        let host = HostedTimelineWindow(width: 520, height: 240, content: Color.clear)
        defer { host.close() }
        state.window = host.window
        ShowWindowRegistry.register(state, for: host.window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(AlignmentKeyHandler.handle(event))
        #expect(!f.model.canStopAudition && cleanup.isBusy)
    }
}
