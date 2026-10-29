import AppKit
import Foundation
import SwiftUI
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Nonblocking measured waveform refinement", .serialized)
struct WaveformRefinementHostedTests {
    private func wait(_ reason: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), Comment(rawValue: reason()))
    }

    private func fixture() async throws -> AlignmentWaveformRetentionHostedTests.Fixture {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        f.model.placeGroupsAtSourceTime()
        try await wait(f.model.lastError ?? f.model.waveformMessage) {
            !f.model.isWorking && !f.model.isLoadingWaveforms && !f.model.isLoadingOverview
                && f.document.verifiedModel == f.document.store.model && f.model.waveformMap != nil
        }
        return f
    }

    @Test func slowPanRefinementKeepsVerifiedWaveformsAndNavigationInteractive() async throws {
        let f = try await fixture()
        defer { f.close() }
        let before = f.document.store.model
        let overview = f.model.waveformOverviewSnapshotID
        let indices = f.model.waveformOverviewIndices.mapValues(\.id)
        f.model.waveformPublicationDelayForTesting = .seconds(2)
        f.model.waveformStartSeconds = 25
        f.model.waveformDurationSeconds = 1
        f.model.loadWaveforms(keepingSnapshot: true)
        try #require(f.model.isLoadingWaveforms)
        #expect(f.model.hasUsableWaveformPresentation && f.model.trackProcessingOperation == nil)
        let host = HostedTimelineWindow(width: 1000, height: 600,
            content: AlignmentWaveformView(model: f.model, showInspector: {}))
        defer { host.close() }
        try await host.settle()
        let zoom = try #require(host.descendants.compactMap { $0 as? NSSlider }.first {
            $0.accessibilityIdentifier() == "alignment.waveforms.zoom"
        })
        #expect(zoom.isEnabled)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(f.model.isLoadingWaveforms && f.model.trackProcessingOperation == nil,
                "Even refinement beyond the waveform grace period must not become a blocking operation.")
        #expect(zoom.isEnabled && f.model.waveformOverviewSnapshotID == overview)
        #expect(f.model.waveformOverviewIndices.mapValues(\.id) == indices)
        #expect(f.model.previewWaveformViewport(start: 26, duration: 1))
        f.model.cancelWaveforms(keepingSnapshot: true)
        #expect(f.model.hasUsableWaveformPresentation)
        #expect(f.document.store.model == before)
    }

    @Test func coldPreparationStillBlocksAndAReadyWindowDoesNotWaitForTheOverview() async throws {
        let f = try await fixture()
        defer { f.close() }
        f.model.cancelWaveforms()
        f.model.cancelWaveformOverview()
        f.model.waveformPublicationDelayForTesting = .seconds(2)
        f.model.loadWaveforms()
        #expect(!f.model.hasUsableWaveformPresentation)
        #expect(f.model.trackProcessingOperation?.kind == .waveforms)
        f.model.cancelWaveforms()
        f.model.waveformPublicationDelayForTesting = nil
        f.model.loadWaveforms()
        try await wait(f.model.waveformMessage) { !f.model.isLoadingWaveforms && !f.model.waveformTracks.isEmpty }
        f.model.waveformPublicationDelayForTesting = .seconds(2)
        f.model.loadWaveformOverview()
        #expect(f.model.isLoadingOverview && f.model.hasUsableWaveformPresentation)
        #expect(f.model.trackProcessingOperation == nil)
        f.model.cancelWaveformOverview(keepingSnapshot: true)
    }

    @Test func cutsAdoptReprojectedOverviewWithoutStartingAnotherPreparation() async throws {
        let f = try await fixture()
        defer { f.close() }
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let before = f.document.store.model
        let originalBins = f.model.waveformOverviewTracks.map { track in
            track.envelope.bins.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        }
        f.model.listening.selection = 1...2
        cleanup.applyManualCut()
        try #require(cleanup.error == nil, "\(cleanup.error ?? "")")
        try await wait(f.model.waveformMessage) { !f.model.isLoadingWaveforms }
        let projection = f.model.waveformOverviewSnapshotID
        f.model.waveformPublicationDelayForTesting = .seconds(2)
        f.model.ensureWaveformOverview()
        #expect(!f.model.isLoadingOverview, "The freshly cut-projected overview must not be re-prepared.")
        #expect(f.model.hasUsableWaveformPresentation && f.model.trackProcessingOperation == nil)
        #expect(f.model.waveformOverviewTracks.map { track in
            track.envelope.bins.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        } == originalBins)
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.model.waveformOverviewSnapshotID == projection)
        #expect(!f.model.isLoadingOverview)
        #expect(f.document.store.model.episodes[0].alignment == before.episodes[0].alignment)
        #expect(f.model.cutTimeline.removals == [48_000..<96_000])
    }
}
