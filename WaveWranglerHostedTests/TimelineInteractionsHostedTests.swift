import AppKit
import SwiftUI
import Testing
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Fitted tracks, paged following, and cycle creation", .serialized)
struct TimelineInteractionsHostedTests {
    @Test func fitUsesActualChromeAndNeverClampsToTheManualMaximum() {
        #expect(AudioTimelineTrackFit.height(current: 64, viewport: 1_000, content: 228,
                                             rows: 2, scale: 2) == 450)
        #expect(AudioTimelineTrackFit.height(current: 450, viewport: 1_000, content: 1_000,
                                             rows: 2, scale: 2) == nil)
        #expect(AudioTimelineTrackFit.height(current: 110, viewport: 200, content: 700,
                                             rows: 4, scale: 2) == 64)
        #expect(AudioTimelineTrackFit.height(current: 64, viewport: 200, content: 516,
                                             rows: 4, scale: 2) == nil)
        #expect(AudioTimelineTrackFit.height(current: 64, viewport: 400, content: 100,
                                             rows: 0, scale: 2) == nil)
    }

    @Test func fittedNativeWorkspaceAdaptsToResizeModesCollapseAndMetadataOnlyRows() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.listening.workspace.fillSpace = true
        f.model.listening.workspace.layout = .recorderGroup
        var measured = (height: 0.0, viewport: 0.0, content: 0.0, rows: 0)
        let host = HostedTimelineWindow(width: 900, height: 680,
            content: AlignmentWaveformView(model: f.model, showInspector: {},
                fitGeometryChanged: { measured = ($0, $1, $2, $3) }))
        defer { host.close() }
        func fits(rows: Int) -> Bool {
            measured.rows == rows && measured.height >= 64
                && abs(measured.viewport - measured.content) <= 2
        }
        try await wait("initial fit: \(measured)") { fits(rows: 2) }
        #expect(f.model.listening.workspace.laneHeight == 110)
        let firstHeight = measured.height
        let initialSize = host.view.bounds.size
        host.window.setContentSize(CGSize(width: initialSize.width, height: initialSize.height - 60))
        try await wait("resized fit: \(measured)") { fits(rows: 2) && measured.height < firstHeight - 20 }
        host.window.setContentSize(initialSize)
        try await wait("restored fit: \(measured)") { fits(rows: 2) && measured.height > 64 }
        let manual = host.descendants.compactMap { $0 as? NativeTimelineSlider.Slider }
            .first { $0.accessibilityIdentifier() == "alignment.waveforms.laneHeight" }
        let slider = try #require(manual)
        slider.doubleValue = 150
        #expect(slider.sendAction(slider.action, to: slider.target))
        #expect(!f.model.listening.workspace.fillSpace && f.model.listening.workspace.laneHeight == 150)
        f.model.listening.workspace.fillSpace = true
        try await wait("fit after manual height: \(measured)") { fits(rows: 2) }
        let group = try #require(f.model.waveformTracks.first?.group)
        f.model.listening.collapsedRecorders.insert(group)
        try await wait("collapsed fit: \(measured)") { fits(rows: 1) }
        #expect(measured.height > 220, "Fitted waveforms may exceed the manual slider maximum")
        f.model.listening.collapsedRecorders.remove(group)
        try await wait("expanded fit: \(measured)") { fits(rows: 2) }
        f.model.listening.workspace.layout = .speakersOnly
        try await wait("Primary fit: \(measured)") { fits(rows: 1) }
        f.model.listening.workspace.layout = .overlay
        try await wait("overlay fit: \(measured)") { fits(rows: 1) }
        f.model.listening.workspace.layout = .speaker
        try await wait("speaker fit: \(measured)") { fits(rows: 2) }
        let beforeMetadata = measured.height
        try #require(f.document.store.apply("Add metadata-only source") { model throws(DomainError) in
            try model.addingSource(SourceRecord(displayNameHint: "Not timed.wav"), to: f.model.episodeID)
        })
        try await wait("metadata fit: \(measured), before=\(beforeMetadata), ungrouped=\(f.model.ungroupedSources.count)") {
            f.model.ungroupedSources.count == 1 && measured.height < beforeMetadata
                && (fits(rows: 2) || measured.height == 64 && measured.content > measured.viewport)
        }
        #expect(!f.model.waveformTracks.contains { $0.name == "Not timed.wav" })
        host.window.setContentSize(CGSize(width: 1_200, height: 400))
        try await wait("minimum overflow: \(measured)") { measured.height == 64 && measured.content > measured.viewport }
        #expect(f.model.listening.workspace.fillSpace)
        try host.capture("Minimum-height overflow retains independent Ungrouped metadata")
    }

    @Test func followsOnlyAtTheEdgeAndManualPanningDisablesUntilExplicitReacquisition() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        defer { f.close() }
        f.model.waveformStartSeconds = 0
        f.model.waveformDurationSeconds = 5
        f.model.waveformPlayheadSeconds = 4.999
        f.model.followPlayheadIfNeeded()
        #expect(f.model.waveformStartSeconds == 0, "Do not recenter at 80 percent")
        f.model.waveformPlayheadSeconds = 5
        f.model.followPlayheadIfNeeded()
        #expect(f.model.waveformStartSeconds == 5 && f.model.waveformPlayheadSeconds == 5)
        try #require(f.model.previewWaveformWindow(start: 20))
        #expect(!f.model.listening.workspace.followPlayhead)
        f.model.waveformPlayheadSeconds = 6
        f.model.followPlayheadIfNeeded()
        #expect(f.model.waveformStartSeconds == 20)
        f.model.setFollowPlayhead(true)
        #expect(f.model.waveformStartSeconds == 6 && f.model.waveformPlayheadSeconds == 6)
        f.model.waveformPlayheadSeconds = 2
        f.model.followPlayheadIfNeeded()
        #expect(f.model.waveformStartSeconds == 2, "A loop returning behind the viewport reacquires its beginning")
    }

    @Test(arguments: [0, 1, 2])
    func playbackPagingAndReacquisitionPreserveTheActualAudioClock(kind: Int) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait(f.model.waveformMessage) {
            !f.model.isWorking && f.document.verifiedModel == f.document.store.model
                && f.model.waveformMap != nil && !f.model.isLoadingWaveforms
        }
        f.model.waveformStartSeconds = 0
        f.model.waveformDurationSeconds = 0.5
        f.model.waveformPlayheadSeconds = 0
        if kind == 1 {
            f.model.listening.setCycleRange(0...4)
            f.model.listening.cycleEnabled = true
            f.model.playEnabledTracks()
        } else if kind == 2 {
            f.model.listening.selection = 0...4
            f.model.playSelection()
        } else {
            f.model.playEnabledTracks()
        }
        try await wait("\(f.model.auditionLabel), start=\(f.model.waveformStartSeconds), follow=\(f.model.listening.workspace.followPlayhead)") {
            f.model.isAuditioning && f.model.waveformStartSeconds >= 0.5
        }
        let clock = try #require(f.model.playbackClockForTesting)
        #expect(f.model.waveformPlayheadSeconds - f.model.waveformStartSeconds < 0.5)
        try #require(f.model.previewWaveformViewport(start: 20, duration: 0.5))
        #expect(!f.model.listening.workspace.followPlayhead && f.model.isAuditioning)
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.model.waveformStartSeconds == 20)
        f.model.setFollowPlayhead(true)
        #expect(f.model.isAuditioning)
        #expect(f.model.waveformStartSeconds == f.model.waveformPlayheadSeconds)
        #expect(f.model.playbackClockForTesting?.startedAt == clock.startedAt,
                "Viewport paging and enable must not stop, seek, or restart the audio clock")
        #expect(f.model.playbackClockForTesting?.startSeconds == clock.startSeconds)
        f.model.pauseEnabledTracks()
        #expect(!f.model.canStopAudition)
    }

    @Test func cycleCreationClampsBothDirectionsAndSynchronizesOnlyItsOwnSelection() {
        #expect(AudioTimelineRuler.cycleSelection(from: 80, to: 20, width: 100,
            start: 10, duration: 5, bounds: 0...40) == 11...14)
        #expect(AudioTimelineRuler.cycleSelection(from: -20, to: 200, width: 100,
            start: 10, duration: 5, bounds: 12...14) == 12...14)
        #expect(AudioTimelineRuler.cycleSelection(from: 20, to: 20, width: 100,
            start: 10, duration: 5, bounds: 0...40) == nil)
        let listening = EpisodeListeningState()
        listening.setCycleRange(0...5)
        #expect(listening.selection == nil, "Enabling Cycle without a selection does not fabricate one")
        listening.setCycleRange(1...3, selecting: true)
        #expect(listening.cycleRange == listening.selection)
        listening.setCycleRange(1...4)
        #expect(listening.selection == 1...4)
        listening.selection = 10...12
        listening.setCycleRange(2...4)
        #expect(listening.selection == 10...12, "Locator edits do not hijack an unrelated transcript selection")
    }

    private func wait(_ context: @autoclosure () -> String = "timeline state", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), Comment(rawValue: context()))
    }
}
