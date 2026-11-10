import AppKit
import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWMix
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Sustained mixed-load production playback (controlled test media)", .serialized)
struct SustainedProductionPlaybackHostedTests {
    private func wait(_ reason: @autoclosure () -> String, timeout: Duration = .seconds(25),
                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), Comment(rawValue: reason()))
    }

    private func installTiming(in f: AlignmentWaveformRetentionHostedTests.Fixture) throws -> Int {
        let currentEpisode = f.document.store.model.episode(f.model.episodeID)
        let episode = try #require(currentEpisode)
        let targetTrack = f.model.waveformTracks.first { $0.id == f.target }
        let target = try #require(targetTrack)
        let referenceSource = episode.speakerAssignments.first?.primary?.sourceID
        let reference = try #require(referenceSource)
        let smoothEnd = Double(target.envelope.totalFrames) / Double(target.envelope.sampleRate) - 8
        var segments = [SourceTimingSegment(sourceStart: 0, sourceEnd: smoothEnd, alignedStart: 0,
            rateRatio: 1.000125, kind: .estimated)]
        var aligned = segments[0].alignedEnd
        // Recording-sized metadata stays outside both playback and its five-second cache tiles.
        for index in 0..<4096 {
            let segment = SourceTimingSegment(sourceStart: smoothEnd + Double(index) / 512,
                sourceEnd: smoothEnd + Double(index + 1) / 512, alignedStart: aligned,
                rateRatio: index.isMultiple(of: 2) ? 0.999 : 1.001, kind: .estimated)
            segments.append(segment)
            aligned = segment.alignedEnd
        }
        let correction = SourceTimingCorrection(source: f.target, group: target.group, epoch: target.epoch,
            reference: reference, sourceRate: target.envelope.sampleRate,
            sourceFrames: target.envelope.totalFrames, channelCount: target.envelope.channelCount,
            analysisDigest: String(repeating: "a", count: 64),
            processing: PitchPreservingAudio.identifier, segments: segments)
        let valid = correction.isValid
        try #require(valid)
        let alignment = episode.alignment
        var timing = try #require(alignment)
        let acceptedIndex = timing.maps.firstIndex { $0.revision == timing.acceptedRevision }
        let accepted = try #require(acceptedIndex)
        timing.maps[accepted].sourceCorrections = [correction]
        let changed = timing
        let episodeIndex = f.document.store.model.episodes.firstIndex { $0.id == episode.id }
        let index = try #require(episodeIndex)
        let applied = f.document.store.apply("Install Sustained Synthetic Timing") { model throws(DomainError) in
            var result = model
            result.episodes[index].alignment = changed
            return result
        }
        try #require(applied)
        return try JSONEncoder().encode(timing.maps[accepted]).count
    }

    private func saveAndVerify(_ document: ShowDocument) async throws {
        try await MixerHostedTests().save(document)
        let expected = document.store.model
        let verified = document.verifiedModel == expected
        let saved = document.status.saveStatus.state.isVerifiedOnDisk
        let edited = document.isDocumentEdited
        #expect(verified && saved && !edited)
        let fileURL = document.fileURL
        let url = try #require(fileURL)
        let decoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(Data(contentsOf: url)).payload
        let matches = decoded == expected
        #expect(matches)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_PRODUCTION_TIMING_TESTS"] == "1",
        "Opt-in sustained production qualification on a leased macOS VM; synthetic media only."))
    func adaptiveProductionSurvivesLiveInsertEditingSavingAndTranscriptLayout() async throws {
        try await run(episodeSoak: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_EPISODE_SOAK_TESTS"] == "1",
        "Opt-in 15-minute real-time VM qualification; requires explicitly staged reusable test media."))
    func fifteenMinuteEpisodeWithStockCompressionEQEditingAndSaves() async throws {
        try await run(episodeSoak: true)
    }

    private func stockSlot(subtype: UInt32) throws -> AudioUnitSlot {
        let installed = MixerAudioUnits.installedEffects().first {
            $0.identity.manufacturer == 0x6170706C && $0.identity.subtype == subtype
        }
        let component = try #require(installed)
        return AudioUnitSlot(component: component.identity, productName: component.name)
    }

    private func run(episodeSoak: Bool) async throws {
        let programSeconds = episodeSoak ? 900.0 : 32.0
        var sourceFiles: [URL]?
        if episodeSoak {
            let directory = ProcessInfo.processInfo.environment["WW_EPISODE_SOAK_MEDIA"]
            let path = try #require(directory, "Explicitly stage reusable test media before enabling the soak test.")
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            sourceFiles = ["reader-one.wav", "reader-two.wav"].map { folder.appendingPathComponent($0) }
        }
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(
            cleanupPrimaries: 2, durationSeconds: 48, sourceFiles: sourceFiles)
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.placeGroupsAtSourceTime()
        try await wait("Verified initial synthetic timing") {
            !f.model.isWorking && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
                && f.document.verifiedModel == f.document.store.model
        }
        let mapBytes = try installTiming(in: f)
        try await saveAndVerify(f.document)
        f.model.loadWaveforms(keepingSnapshot: true)
        try await wait("Reloaded synthetic adaptive timing") {
            !f.model.isWorking && !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
                && f.document.verifiedModel == f.document.store.model
        }
        let currentEpisode = f.document.store.model.episode(f.model.episodeID)
        let episode = try #require(currentEpisode)
        if episodeSoak {
            let editor = f.model.audioEditor
            editor.refresh()
            try await wait("Episode production geometry loaded") { editor.production != nil }
            let currentComposition = editor.composition
            let composition = try #require(currentComposition)
            let range = EpisodeProductionRange(
                start: try composition.timeline.unpinnedAnchor(atProgramFrame: 0),
                end: try composition.timeline.unpinnedAnchor(atProgramFrame: 43_200_000))
            let bounded = editor.setBoundaryTimes(range: range, speakerIn: nil, speakerOut: nil)
            try #require(bounded)
            try await saveAndVerify(f.document)
            f.model.synchronizeWaveforms()
            try await wait("Verified 15-minute episode boundaries") {
                !f.model.isLoadingWaveforms && !f.model.waveformNeedsRefreshAfterSave
            }
        }
        let slots = try (0..<3).map { _ in
            try episodeSoak ? stockSlot(subtype: 0x706D6571) : MixerHostedTests().appleSlot()
        }
        let compressors = try episodeSoak ? (0..<3).map { _ in try stockSlot(subtype: 0x64636D70) } : []
        let inserted = f.document.store.apply("Add Sustained Apple Monitoring Inserts") { model throws(DomainError) in
            var result = model
            for (index, assignment) in episode.speakerAssignments.enumerated() {
                let inserts = episodeSoak ? [compressors[index], slots[index]] : [slots[index]]
                result = try result.settingSpeakerMix(
                    SpeakerMixState(speaker: assignment.speakerID, inserts: inserts), in: episode.id)
            }
            let master = episodeSoak ? [compressors[2], slots[2]] : [slots[2]]
            return try result.settingMasterMix(MasterMixState(inserts: master), in: episode.id)
        }
        try #require(inserted)
        try await saveAndVerify(f.document)
        if episodeSoak {
            let controller = f.model.mixer
            _ = try await controller.prepare(programFrames: 0..<43_200_000)
            for slot in compressors {
                try await controller.setParameter(slot: slot.id, address: 0, value: -24, coalescing: "soak.setup")
                try await controller.setParameter(slot: slot.id, address: 1, value: 6, coalescing: "soak.setup")
            }
            for slot in slots {
                try await controller.setParameter(slot: slot.id, address: 0, value: 1200, coalescing: "soak.setup")
                try await controller.setParameter(slot: slot.id, address: 2, value: 2, coalescing: "soak.setup")
            }
            try await saveAndVerify(f.document)
        }
        let initial = f.document.store.model
        let timing = initial.episode(episode.id)?.alignment
        let coldStates = await f.runtime.coordinator.states()
        let initialTileCount = coldStates.values.compactMap(\.key).filter {
            $0.asset.kind == "ww.adaptive-audio-pcm"
        }.count
        try #require(initialTileCount == 0, "The sustained run must start with cold adaptive audio tiles.")
        let words = (0..<40_000).map { index in
            TranscriptWord(text: "synthetic", alignedStart: Double(index) / 10,
                alignedEnd: Double(index) / 10 + 0.08)
        }
        let wordIndex = AudioTimelineWordIndex(words: words)
        let owner = MixerHostedTests().owner(f)
        defer { owner.close() }
        owner.showWindow(nil)
        try await wait("Synthetic alignment window is ready") {
            owner.state.isWindowAttached && f.model.hasUsableWaveformPresentation
                && !f.model.isLoadingWaveforms && !f.model.isLoadingOverview
        }
        let presentation = owner.state.mixerPresentation
        let controller = f.model.mixer
        let requestedAt = ContinuousClock.now
        f.model.playProductionMix(interval: 0...programSeconds, repeating: false)
        try await wait("Production audio started: \(f.model.auditionLabel); preparing=\(f.model.isPreparingAudition)") {
            f.model.isAuditioning || f.model.lastError != nil
        }
        let started = f.model.isAuditioning
        let startupError = f.model.lastError
        try #require(started && startupError == nil, Comment(rawValue: startupError ?? "Playback did not start"))
        let startedAt = ContinuousClock.now
        let deadline = startedAt.advanced(by: .seconds(programSeconds + 60))
        let hasClock = f.model.playbackClockForTesting != nil
        try #require(hasClock)
        // Clock values are snapshots capped at the currently scheduled horizon; read a fresh one.
        let playhead: @MainActor () -> Double = {
            f.model.playbackClockForTesting?.playhead() ?? f.model.waveformPlayheadSeconds
        }
        let liveProcessor = controller.processor
        let processor = try #require(liveProcessor)
        let revision = controller.instanceRevision
        let recipeCount = await f.runtime.productionRecipeConstructionCount
        presentation.openEditor(slots[2], generic: true)
        try await wait("Generic Apple effect editor opened") {
            presentation.editorWindow != nil || presentation.error != nil
        }
        let editorError = presentation.error
        let editorVisible = presentation.editorWindow?.window?.isVisible == true
        let observing = controller.editorObservationKey != nil
        try #require(editorError == nil && editorVisible && observing)
        let editableParameter = presentation.parameters.first {
            $0.writable && $0.minimum < 1000 && $0.maximum > 2000
        }
        let parameter = try #require(editableParameter)
        let observationKey = controller.editorObservationKey
        let coalescing = try #require(observationKey)
        let undoManager = f.document.undoManager
        let undo = try #require(undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        let groupedByEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.removeAllActions()
        undo.beginUndoGrouping()
        defer {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo.groupsByEvent = groupedByEvent
        }
        var captures = 0, lateCaptures = 0
        controller.didCaptureNativeStates = { ids in
            captures += ids.count
            if playhead() > 21 { lateCaptures += ids.count }
        }
        defer { controller.didCaptureNativeStates = nil }
        var explicitEdits = 0, observedEdits = 0, lateExplicitEdits = 0, lateObservedEdits = 0
        var layouts = 0, lateLayouts = 0, coveredWords = 0
        var layoutTime: Duration = .zero
        var saveTimes: [Double] = []
        let saveMilestones = episodeSoak ? Array(stride(from: 30.0, to: programSeconds, by: 60)) : [12, 25]
        var reportedMinutes: Set<Int> = []
        var nextEdit = 0.0
        var finalValue: Float = parameter.value
        var checkedMute = false
        while f.model.canStopAudition, ContinuousClock.now < deadline {
            let playbackError = f.model.lastError
            let editingError = presentation.error
            let sameInstance = controller.processor === processor && controller.instanceRevision == revision
            try #require(playbackError == nil && editingError == nil && sameInstance,
                Comment(rawValue: playbackError ?? editingError ?? "Live processor was replaced"))
            let position = playhead()
            if position >= nextEdit, position < programSeconds - 2 {
                let explicit = (explicitEdits + observedEdits).isMultiple(of: 2)
                finalValue = explicit ? 1000 : 2000
                if explicit {
                    try await controller.setParameter(slot: slots[2].id, address: parameter.address,
                        value: finalValue, coalescing: coalescing)
                    explicitEdits += 1
                    if position > 21 { lateExplicitEdits += 1 }
                } else {
                    let priorState = f.document.store.model.episode(episode.id)?.mix?.master.inserts
                        .first { $0.id == slots[2].id }?.documentState
                    let beforeCapture = captures
                    try await processor.setParameter(slot: slots[2].id, address: parameter.address, value: finalValue)
                    // No explicit capture here: normal editor observation must publish the native edit.
                    try await wait("Normal observation captured the native parameter edit", timeout: .seconds(5)) {
                        captures > beforeCapture
                            && f.document.store.model.episode(episode.id)?.mix?.master.inserts
                                .first { $0.id == slots[2].id }?.documentState != priorState
                    }
                    observedEdits += 1
                    if position > 21 { lateObservedEdits += 1 }
                }
                let parameters = try await processor.parameters(slot: slots[2].id)
                let currentValue = parameters.first { $0.address == parameter.address }?.value
                let value = try #require(currentValue)
                #expect(abs(value - finalValue) < 0.1)
                nextEdit = playhead() + 0.35
            }
            if !checkedMute, position >= 3 {
                try await wait("Live DSP has audible output", timeout: .seconds(5)) {
                    controller.meters?.masterMeters.contains { $0.peak > 0 } == true
                }
                controller.masterMuted = true
                try await wait("Live master mute reached rendered DSP meters", timeout: .seconds(5)) {
                    controller.meters?.masterMeters.allSatisfy { $0.peak == 0 } == true
                }
                controller.masterMuted = false
                try await wait("Live master unmute reached rendered DSP meters", timeout: .seconds(5)) {
                    controller.meters?.masterMeters.contains { $0.peak > 0 } == true
                }
                checkedMute = true
            }
            if saveTimes.count < saveMilestones.count, position >= saveMilestones[saveTimes.count] {
                let savePosition = playhead()
                let playingBefore = f.model.isAuditioning
                try await saveAndVerify(f.document)
                let playingAfter = f.model.isAuditioning
                let editorStillActive = presentation.editorWindow?.window?.isVisible == true
                    && controller.editorObservationKey == coalescing
                try #require(playingBefore && playingAfter && editorStillActive)
                saveTimes.append(savePosition)
            }
            if episodeSoak, reportedMinutes.insert(Int(position / 60)).inserted {
                print("EPISODE_SOAK_PROGRESS second=\(position) edits=\(explicitEdits + observedEdits) "
                    + "captures=\(captures) saves=\(saveTimes.count) layouts=\(layouts)")
            }
            let layoutStarted = ContinuousClock.now
            let burstEnd = layoutStarted.advanced(by: .milliseconds(100))
            let lateLayout = playhead() > 21
            repeat {
                coveredWords += AudioTimelineWordLayout.make(index: wordIndex,
                    start: 0, duration: 5000, width: 1400).wordCount
                layouts += 1
                if lateLayout { lateLayouts += 1 }
            } while ContinuousClock.now < burstEnd
            layoutTime += layoutStarted.duration(to: .now)
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = startedAt.duration(to: .now)
        controller.didCaptureNativeStates = nil
        let error = f.model.lastError
        let presentationError = presentation.error
        let label = f.model.auditionLabel
        let end = f.model.waveformPlayheadSeconds
        let stopped = !f.model.canStopAudition
        let sameInstance = controller.processor === processor && controller.instanceRevision == revision
        let unitCount = controller.unitStatuses.count
        let constructionCount = await f.runtime.productionRecipeConstructionCount
        try #require(stopped && error == nil && presentationError == nil,
            Comment(rawValue: error ?? presentationError ?? "Production exceeded its real-time completion deadline"))
        #expect(label == "Production mix reached the end of the selected program.")
        #expect(end == programSeconds && sameInstance && unitCount == slots.count + compressors.count)
        #expect(elapsed >= .seconds(programSeconds - 1), "Qualification requires real-time playback, not an offline render.")
        if episodeSoak { #expect(reportedMinutes == Set(0..<15)) }
        #expect(constructionCount == recipeCount)
        #expect(checkedMute && saveTimes.count == saveMilestones.count)
        #expect(explicitEdits > 0 && observedEdits > 0 && captures > 0)
        #expect(lateExplicitEdits > 0 && lateObservedEdits > 0 && lateCaptures > 0 && lateLayouts > 0)
        #expect(layouts > 0 && coveredWords > 0 && layoutTime > .zero)
        let states = await f.runtime.coordinator.states()
        let tileCount = states.values.compactMap(\.key).filter {
            $0.asset.kind == "ww.adaptive-audio-pcm"
        }.count
        #expect(tileCount >= Int(ceil(programSeconds / 5)),
            "Playback must prepare cold adaptive tiles across the full episode.")
        try await saveAndVerify(f.document)
        let edited = f.document.store.model
        undo.endUndoGrouping()
        let changed = edited != initial
        try #require(changed)
        undo.undo()
        try await wait("Undo restored the complete pre-playback document") {
            f.document.store.model == initial && controller.processor == nil
                && !f.document.mixerTransactions.isBusy
        }
        undo.redo()
        try await wait("Redo restored the captured live edits") {
            f.document.store.model == edited && !f.document.mixerTransactions.isBusy
        }
        try await saveAndVerify(f.document)
        _ = try await controller.prepare(programFrames: 0..<1)
        let recalledParameters = try await controller.processor?.parameters(slot: slots[2].id)
        let recalledValue = recalledParameters?.first { $0.address == parameter.address }?.value
        let recalled = try #require(recalledValue)
        #expect(abs(recalled - finalValue) < 0.1)
        let unchangedTiming = f.document.store.model.episode(episode.id)?.alignment == timing
        let unchangedOriginals = try f.files.map { try Data(contentsOf: $0) } == originals
        #expect(unchangedTiming && unchangedOriginals)
        print("SUSTAINED_PRODUCTION seconds=\(programSeconds) units=\(unitCount) segments=4097 mapBytes=\(mapBytes) "
            + "startup=\(requestedAt.duration(to: startedAt)) elapsed=\(elapsed) tiles=\(tileCount) "
            + "explicitEdits=\(explicitEdits) observedEdits=\(observedEdits) captures=\(captures) "
            + "lateExplicitEdits=\(lateExplicitEdits) lateObservedEdits=\(lateObservedEdits) "
            + "lateCaptures=\(lateCaptures) layouts=\(layouts) lateLayouts=\(lateLayouts) "
            + "layoutTime=\(layoutTime) saveProgramSeconds=\(saveTimes)")
    }
}
