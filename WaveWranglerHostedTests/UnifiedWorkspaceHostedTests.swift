import AppKit
import SwiftUI
import Testing
import WWAlignPipeline
import WWCore
@testable import WaveWrangler

@MainActor
@Suite("Integrated native workspace", .serialized)
struct UnifiedWorkspaceHostedTests {
    @Test func rangeSelectionCycleAndPositionProtectionAreIndependent() throws {
        let listening = EpisodeListeningState()
        listening.select(from: 8, to: -2, within: 0...10)
        #expect(listening.selection == 0...8)
        listening.cycleRange = 2...4
        listening.cycleEnabled = true
        listening.select(from: 3, to: 6, within: 0...10)
        #expect(listening.cycleRange == 2...4 && listening.cycleEnabled)
        #expect(listening.auditionRange(context: 0.5, within: 0...6) == 2.5...6)
        #expect(listening.auditionRange(context: 0.5, within: 8...10) == nil)
        #expect(listening.tool == .select)
        listening.select(from: .nan, to: 3, within: 0...10)
        #expect(listening.selection == 3...6)
    }

    @Test func unsavedAppearanceDoesNotBlockPlayheadOrViewportNavigation() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture()
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait {
            !f.model.isWorking && !f.model.isLoadingWaveforms
                && f.document.verifiedModel == f.document.store.model
        }
        f.model.synchronizeWaveforms()
        try await wait { !f.model.isLoadingWaveforms }
        try #require(f.model.previewWaveformPlayhead(to: 2))
        try #require(f.model.previewWaveformWindow(start: 1))
        let speaker = try #require(f.document.store.model.speakers.first?.id)
        let originals = try f.files.map { try Data(contentsOf: $0) }
        try #require(f.document.store.apply("Change speaker appearance") { model throws(DomainError) in
            try model.settingSpeakerAppearance(.init(color: .teal), for: speaker, in: f.model.episodeID)
        })
        f.document.updateChangeCount(.changeDone)
        let edited = f.document.store.model
        try #require(!f.document.status.saveStatus.state.isVerifiedOnDisk)
        #expect(f.model.previewWaveformPlayhead(to: 3))
        #expect(f.model.previewWaveformWindow(start: 2),
                "Navigation does not wait for cached presentation to adopt the new document generation.")
        f.model.load()
        f.model.synchronizeWaveforms()
        #expect(f.model.waveformTracks.allSatisfy { f.model.positionIsLocked($0.group) })
        #expect(f.model.previewWaveformPlayhead(to: 5),
                "Scrubbing is presentation state, not a timing edit or a save operation.")
        #expect(f.model.waveformPlayheadSeconds == 5)
        #expect(f.model.previewWaveformWindow(start: 4),
                "Panning must remain available while unrelated edits are unsaved.")
        #expect(f.model.waveformStartSeconds == 4)
        #expect(!f.model.previewWaveformPlayhead(to: .nan))
        #expect(!f.model.previewWaveformWindow(start: .infinity))
        #expect(f.model.waveformPlayheadSeconds == 5 && f.model.waveformStartSeconds == 4)
        #expect(f.document.store.model == edited)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func alignmentPublicationPreservesLiveAppearanceAndRefusesChangedLocks() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        let before = f.document.store.model
        let report = try await f.runtime.prepareManual(model: before, episode: f.model.episodeID)
        let epoch = try #require(report.plan.epochs.first { $0.group != report.plan.reference?.group })
        let accepted = try await f.runtime.accept(model: before, episode: f.model.episodeID,
            decisions: [epoch.epoch: .numeric(ppm: 0, offsetMilliseconds: 0)])
        let speaker = try #require(before.speakers.first?.id)
        try #require(f.document.store.apply("Change speaker color") { model throws(DomainError) in
            try model.settingSpeakerAppearance(.init(color: .teal), for: speaker, in: f.model.episodeID)
        })
        #expect(f.model.publishAlignment(accepted, expecting: before, actionName: "Accept timing"))
        try await wait { f.document.verifiedModel == f.document.store.model }
        #expect(f.document.store.model.speakerAppearance(speaker, in: f.model.episodeID)?.color == .teal)
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(target)
        #expect(f.model.positionIsLocked(target.group))
        f.model.applyNumeric(ratePPM: 0, offsetMilliseconds: 100)
        #expect(!f.model.isWorking && f.model.lastError != nil)
        f.model.startNewEpochAtSelectedAnchor()
        #expect(f.model.lastError?.contains("before splitting") == true && !f.model.isWorking)
        f.model.setPositionLocked(false, group: target.group)
        let unlocked = f.document.store.model
        let correction = try await f.runtime.shiftGroup(model: unlocked, episode: f.model.episodeID,
                                                       group: target.group, microseconds: 1_000)
        f.model.setPositionLocked(true, group: target.group)
        let relocked = f.document.store.model
        #expect(!f.model.publishAlignment(correction, expecting: unlocked, actionName: "Late correction"))
        #expect(f.document.store.model == relocked)
    }

    @Test func nativeWorkspaceHasOneTransportAndKeepsCachedAudioDuringNavigation() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let state = ShowWindowState(store: f.document.store, episodeID: f.model.episodeID)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        state.cleanupModel = cleanup
        state.alignmentModel = f.model
        let host = HostedTimelineWindow(width: 1100, height: 800,
            content: AlignmentWorkspace(state: state, model: f.model, showInspector: {}))
        defer { host.close() }
        try await host.settle()
        cleanup.seek(to: 2.25)
        cleanup.zoomTimeline(duration: 1)
        #expect(f.model.waveformPlayheadSeconds == 2.25)
        #expect(f.model.waveformStartSeconds == cleanup.windowStart && f.model.waveformDurationSeconds == 1,
                "Inspector and dense-marker navigation use the main waveform transform.")
        try host.capture("Unified all-source workspace with protected reference and native Solo Mute")
        let before = f.document.store.model
        let originalBytes = try f.files.map { try Data(contentsOf: $0) }
        f.model.listening.select(from: 1, to: 1.5, within: f.model.waveformViewingBounds)
        f.model.listening.cycleRange = 2...2.3
        f.model.listening.cycleEnabled = true
        f.model.waveformPlayheadSeconds = 2
        f.model.playSelection()
        #expect(f.model.isPreparingAudition && f.model.canStopAudition,
                "A requested audition is stoppable before its asynchronous task starts.")
        try await wait { f.model.canStopAudition || f.model.lastError != nil }
        try #require(f.model.lastError == nil, "\(f.model.lastError ?? "")")
        try await wait { !f.model.canStopAudition }
        #expect(abs(f.model.waveformPlayheadSeconds - 1.5) < 0.05)
        #expect(f.model.listening.cycleRange == 2...2.3 && f.model.listening.cycleEnabled)
        #expect(cleanup.listening === f.model.listening)
        cleanup.play()
        try await Task.sleep(for: .milliseconds(1500))
        try await wait { cleanup.isPlaying }
        #expect(cleanup.isPlaying && f.model.canStopAudition, "The inspector shares the running, repeating transport.")
        f.model.listening.cycleEnabled = false
        try await wait { !f.model.canStopAudition }
        #expect(!cleanup.isPlaying && !cleanup.isPreparingPlayback)
        cleanup.loopsFillerAudition = true
        cleanup.play(interval: 1...1.2, loop: true)
        #expect(cleanup.isPreparingPlayback && f.model.canStopAudition,
                "Loop restarts keep the shared Stop control continuously available.")
        try await Task.sleep(for: .milliseconds(800))
        try await wait { cleanup.isPlaying }
        #expect(cleanup.isPlaying && f.model.canStopAudition, "Filler loop uses the shared transport without enabling cycle.")
        #expect(!cleanup.listening.cycleEnabled)
        cleanup.stopPlayback()
        #expect(!f.model.canStopAudition && !cleanup.isPlaying)
        cleanup.stop()
        #expect(cleanup.playhead == f.model.waveformStartSeconds
                && f.model.waveformPlayheadSeconds == cleanup.playhead)
        #expect(f.document.store.model == before)
        #expect(cleanup.windowStrokes.isEmpty && cleanup.overviewStrokes.isEmpty,
                "The integrated transcript service does not decode a competing timeline.")
        #expect(try f.files.map { try Data(contentsOf: $0) } == originalBytes)
        try host.capture("Unified workspace temporary selection and separate cycle locators")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
