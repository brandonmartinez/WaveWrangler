import AppKit
import Foundation
import SwiftUI
import Testing
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWSources
import WWTimeMap
@testable import WaveWrangler

@MainActor
@Suite("Waveform retention and accepted timeline playback (synthetic only)", .serialized)
struct AlignmentWaveformRetentionHostedTests {
    @MainActor struct Fixture {
        let folder: URL
        let document: ShowDocument
        let model: EpisodeAlignmentModel
        let runtime: AlignmentRuntime
        let target: SourceID
        let files: [URL]

        func close() {
            model.suspend()
            NSDocumentController.shared.removeDocument(document)
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func fixture(cleanupPrimaries: Int = 0, durationSeconds: Int = 40,
                 pauses: [Range<Double>] = [], extraSources: Int = 0,
                 targetStepSeconds: Double = 0, extraGroups: Int = 0) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let referenceEpoch = RecordingEpoch(label: "Reference")
        let targetEpoch = RecordingEpoch(label: "Target")
        let referenceGroup = RecorderGroup(name: "Reference", epochs: [referenceEpoch])
        let targetGroup = RecorderGroup(name: "Target", epochs: [targetEpoch])
        let reference = SourceRecord(displayNameHint: "reference.wav",
            placement: .init(recorderGroupID: referenceGroup.id, epochID: referenceEpoch.id))
        let target = SourceRecord(displayNameHint: "target.wav",
            placement: .init(recorderGroupID: targetGroup.id, epochID: targetEpoch.id))
        let speaker = Speaker(name: "Synthetic")
        var episode = Episode(title: "Synthetic", recorderGroups: [referenceGroup, targetGroup],
            sources: [reference, target], speakerAssignments: [
                SpeakerAssignment(speakerID: speaker.id,
                    primary: ChannelReference(sourceID: reference.id, statedChannel: 0),
                    backups: [ChannelReference(sourceID: target.id, statedChannel: 0)])
            ])
        var speakers = [speaker]
        for index in 0..<extraSources {
            episode.sources.append(SourceRecord(displayNameHint: "extra-\(index).wav",
                placement: .init(recorderGroupID: targetGroup.id, epochID: targetEpoch.id)))
        }
        for index in 0..<extraGroups {
            let epoch = RecordingEpoch(label: "Unplaced \(index)")
            let group = RecorderGroup(name: "Unplaced \(index)", epochs: [epoch])
            episode.recorderGroups.append(group)
            episode.sources.append(SourceRecord(displayNameHint: "unplaced-\(index).wav",
                placement: .init(recorderGroupID: group.id, epochID: epoch.id)))
        }
        if cleanupPrimaries > 0 {
            episode.sources[0].role = .primary
            episode.sources[0].roleConfirmation = .userConfirmed
            episode.sources[1].role = .backup
            episode.sources[1].roleConfirmation = .userConfirmed
            episode.speakerAssignments[0].primaryConfirmation = .userConfirmed
            if cleanupPrimaries == 2 {
                let guest = Speaker(name: "Guest")
                speakers.append(guest)
                episode.sources[1].role = .primary
                episode.speakerAssignments[0].backups = []
                episode.speakerAssignments.append(SpeakerAssignment(speakerID: guest.id,
                    primary: ChannelReference(sourceID: target.id, statedChannel: 0),
                    primaryConfirmation: .userConfirmed))
            }
        }
        let initial = ShowDocumentModel(show: Show(title: "Retention fixture"), speakers: speakers, episodes: [episode])
        let accessStore = FileDeviceAccessStore(fileURL: folder.appendingPathComponent("access.json"))
        let io = SystemSourceIO()
        let decoder = SourceDecoder(access: SourceAccessContext(io: io))
        var files: [URL] = []
        for (index, source) in episode.sources.enumerated() {
            let file = folder.appendingPathComponent(source.displayNameHint)
            try Self.wave(target: index == 1, durationSeconds: durationSeconds,
                          pauses: pauses, stepSeconds: targetStepSeconds).write(to: file)
            files.append(file)
            guard case let .success(metadata) = io.metadata(at: file) else { throw DecodeFailure.notFound }
            let witness = try await decoder.captureRawIdentity(file, matching: metadata.fingerprint)
            try await accessStore.save(DeviceAccessRecord(
                showID: initial.show.id, sourceID: source.id,
                bookmark: try io.makeReadOnlyBookmark(for: file), lastKnownPath: file.path,
                recordedIdentity: RecordedIdentity(fingerprint: metadata.fingerprint, confirmation: .userConfirmed,
                                                 recordedAt: Date(), rawWitness: witness), createdAt: Date()
            ))
        }
        let url = folder.appendingPathComponent("show.wwshow")
        try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(
            initial, revision: 1, publicationID: UUID()
        ).data.write(to: url)
        let raw = try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show)
        let document = try #require(raw as? ShowDocument)
        NSDocumentController.shared.addDocument(document)
        let runtime = try await AlignmentRuntime.make(
            showID: initial.show.id, accessStore: accessStore, access: SourceAccessContext(io: io)
        )
        let model = EpisodeAlignmentModel(document: document, episodeID: episode.id, runtime: runtime)
        model.load()
        model.loadWaveforms()
        try await wait { model.rows.count == 2 + extraGroups
            && model.waveformTracks.count == 2 + extraSources + extraGroups && !model.isLoadingWaveforms }
        model.ensureWaveformOverview()
        try await wait { !model.isLoadingOverview && model.waveformOverviewTracks.count == 2 + extraSources + extraGroups }
        return Fixture(folder: folder, document: document, model: model, runtime: runtime, target: target.id, files: files)
    }

    private func wait(_ context: @autoclosure () -> String = "synthetic model", _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(25)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Timed out waiting for \(context())")
    }

    private func binAddresses(_ tracks: [AlignmentWaveformTrack]) -> [SourceID: Int] {
        Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.id, track.envelope.bins.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) })
        })
    }

    private actor OverviewActivityLog {
        var scans = 0
        func record(_ activity: AlignmentRuntime.OverviewActivity) {
            if case .measuring = activity { scans += 1 }
        }
    }

    @Test(arguments: [false, true])
    func freshRuntimeRestoresPreparedOverviewsWithoutRescanning(accepted: Bool) async throws {
        let f = try await fixture()
        defer { f.close() }
        if accepted {
            f.model.placeGroupsAtSourceTime()
            try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        }
        f.model.loadWaveformOverview()
        try await wait { !f.model.isLoadingOverview && f.model.waveformOverviewTracks.count == 2 }
        let original = f.document.store.model
        let strokes = f.model.waveformOverviewStrokes
        let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        let fresh = try await AlignmentRuntime.make(showID: original.show.id,
            accessStore: access, access: SourceAccessContext(io: SystemSourceIO()))
        let activity = OverviewActivityLog()
        let loaded = try await fresh.waveformTracks(model: original, episode: f.model.episodeID,
            startSeconds: 0, durationSeconds: 1, overview: true,
            overviewActivity: { await activity.record($0) })
        #expect(loaded.refusals.isEmpty && loaded.mapWarning == nil)
        #expect(await activity.scans == 0)
        let prepared = try await fresh.prepareWaveformOverview(load: loaded,
            episode: original.episode(f.model.episodeID), cuts: .unedited)
        #expect(prepared.errors.isEmpty && prepared.restoredTracks == 2)
        #expect(prepared.strokes == strokes)
        let reopened = EpisodeAlignmentModel(document: f.document, episodeID: f.model.episodeID,
            runtime: fresh, listening: EpisodeListeningState())
        reopened.loadWaveformOverview()
        try await wait(reopened.waveformOverviewMessage) { !reopened.isLoadingOverview }
        #expect(reopened.waveformOverviewMessage.hasPrefix("2 waveform displays restored from cache; 0 rebuilt"))
        #expect(reopened.waveformOverviewRefusals.isEmpty)
        reopened.suspend()
        await fresh.coordinator.shutdown()
        #expect(f.document.store.model == original)
    }

    @Test func preparedOverviewCacheNeverBypassesRevokedSourceAccess() async throws {
        let f = try await fixture()
        defer { f.close() }
        let original = f.document.store.model
        let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        try await access.removeRecord(for: DeviceAccessKey(showID: original.show.id, sourceID: f.target))
        let fresh = try await AlignmentRuntime.make(showID: original.show.id,
            accessStore: access, access: SourceAccessContext(io: SystemSourceIO()))
        let loaded = try await fresh.waveformTracks(model: original, episode: f.model.episodeID,
            startSeconds: 0, durationSeconds: 1, overview: true)
        #expect(!loaded.tracks.contains { $0.id == f.target })
        #expect(loaded.refusals.contains { $0.id == f.target })
        let prepared = try await fresh.prepareWaveformOverview(load: loaded,
            episode: original.episode(f.model.episodeID), cuts: .unedited)
        #expect(prepared.restoredTracks == 1 && prepared.strokes[f.target] == nil)
        await fresh.coordinator.shutdown()
        #expect(f.document.store.model == original)
    }

    @Test(arguments: [false, true])
    func coldZoomedOutWorkspaceLoadsTracksOverviewAndVerifiedPlayback(accepted: Bool) async throws {
        let f = try await fixture(cleanupPrimaries: 1)
        defer { f.close() }
        if accepted {
            f.model.placeGroupsAtSourceTime()
            try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        }
        let original = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let listening = EpisodeListeningState()
        listening.workspace.layout = .speakersOnly
        listening.workspace.startSeconds = -80
        listening.workspace.durationSeconds = 568.749
        listening.workspace.playheadSeconds = 20
        let savedView = listening.workspace
        let reopened = EpisodeAlignmentModel(document: f.document, episodeID: f.model.episodeID,
            runtime: f.runtime, listening: listening)
        defer { reopened.suspend() }
        #expect(reopened.waveformTracks.isEmpty && reopened.waveformFitRange == nil)
        reopened.load()
        reopened.loadWaveforms(keepingSnapshot: true)
        reopened.ensureWaveformOverview()
        try await wait(reopened.waveformMessage) {
            !reopened.isLoadingWaveforms && !reopened.isLoadingOverview
                && reopened.waveformTracks.count == 2 && reopened.waveformOverviewTracks.count == 2
        }
        #expect(reopened.listening.workspace == savedView, "Loading must preserve the wide saved viewport and playhead")
        #expect(reopened.primaryWaveformGroups.flatMap(\.tracks).count == 1)
        #expect(reopened.waveformTracks.allSatisfy {
            reopened.waveformOverviewIndices[$0.id]?.hasVisible(start: -80, duration: 568.749) == true
        })
        #expect(!reopened.waveformTileSlices.isEmpty)
        #expect(reopened.waveformTileSlices.allSatisfy { $0.range.upperBound - $0.range.lowerBound <= 30 },
                "The display span never becomes an oversized exact audio read")
        #expect(!reopened.waveformMessage.contains("Choose a finite"))
        #expect(reopened.lastError == nil)
        #expect((reopened.waveformMap != nil) == accepted)
        if accepted {
            reopened.playEnabledTracks()
            try await wait(reopened.auditionLabel) { reopened.isAuditioning }
            reopened.stopAudition()
        }
        #expect(f.document.store.model == original)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func acceptingAnalysisAndUndoRedoRetainMainTracksAndTheirDecodedBins() async throws {
        let f = try await fixture()
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let tracks = f.model.waveformTracks
        let addresses = binAddresses(tracks)
        let overviewAddresses = binAddresses(f.model.waveformOverviewTracks)
        let target = try #require(tracks.first { $0.id == f.target })
        f.model.selectWaveform(target)
        try #require(!f.model.selectedSpeakerPairs.isEmpty)
        f.model.analyze()
        try await wait { !f.model.isWorking }
        try #require(f.model.canAcceptProposal, "\(f.model.message); \(String(describing: f.model.lastError)); \(String(describing: f.model.selectedAnalysis?.abstention))")
        let liveBeforePreview = f.document.store.model
        let ghost = f.model.proposedWaveformStrokes(for: target)
        #expect(!ghost.isEmpty)
        #expect(f.document.store.model == liveBeforePreview)
        #expect(!f.model.isAuditioning)
        f.model.setTrack(target.id, enabled: false)
        f.model.waveformStartSeconds = 1
        f.model.waveformPlayheadSeconds = 2
        f.model.acceptProposal()
        while f.model.isWorking {
            #expect(Set(f.model.waveformTracks.map(\.id)) == Set(tracks.map(\.id)))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await wait("acceptance: \(f.model.waveformMessage); \(String(describing: f.model.lastError)); map=\(String(describing: f.model.waveformMapRevision)); loading=\(f.model.isLoadingWaveforms); verified=\(f.document.verifiedModel == f.document.store.model); saved=\(f.document.status.saveStatus.state.isVerifiedOnDisk)") {
            f.model.waveformMapRevision != nil && !f.model.isLoadingWaveforms
                && f.document.verifiedModel == f.document.store.model
                && f.model.waveformMessage.contains("updated in place")
        }
        #expect(binAddresses(f.model.waveformTracks) == addresses, "Acceptance must not decode replacement main buffers")
        #expect(binAddresses(f.model.waveformOverviewTracks) == overviewAddresses)
        #expect(!f.model.retainedWaveformStrokes(for: target.id).isEmpty)
        #expect(f.model.waveformStartSeconds == 1 && f.model.waveformPlayheadSeconds == 2)
        #expect(!f.model.trackEnabled(target.id))
        #expect(f.model.proposedWaveformStrokes(for: target).isEmpty)
        let accepted = f.document.store.model
        let manager = try #require(f.document.undoManager)
        try #require(manager.canUndo)
        manager.undo()
        try await wait("Undo: \(f.model.waveformMessage)") {
            f.document.verifiedModel == liveBeforePreview && !f.model.isLoadingWaveforms
                && f.model.waveformMap == nil
        }
        #expect(binAddresses(f.model.waveformTracks) == addresses)
        #expect(f.model.waveformMap == nil)
        try #require(manager.canRedo)
        manager.redo()
        try await wait("Redo: \(f.model.waveformMessage)") {
            f.document.verifiedModel == accepted && !f.model.isLoadingWaveforms
                && f.model.waveformMap != nil
        }
        #expect(binAddresses(f.model.waveformTracks) == addresses)
        #expect(f.model.waveformMap != nil)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func changedOriginalCannotReuseAnAcceptedWaveformProjection() async throws {
        let f = try await fixture()
        defer { f.close() }
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(target)
        try Self.wave(target: true).write(to: f.files[1], options: .atomic)
        await #expect(throws: (any Error).self) {
            try await f.runtime.revalidateWaveforms(
                model: f.document.store.model, episode: f.model.episodeID, tracks: f.model.waveformTracks
            )
        }
        f.model.applyNumeric(ratePPM: 0, offsetMilliseconds: 180)
        try await wait { !f.model.isWorking }
        #expect(f.model.lastError != nil)
        #expect(f.document.store.model.episodes[0].alignment?.acceptedRevision == nil)
        #expect(f.model.waveformMap == nil)
    }

    private func savedProposalFixture() async throws -> Fixture {
        let f = try await fixture(durationSeconds: 12)
        var ready = false
        defer { if !ready { f.close() } }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.model.waveformMap != nil
            && f.document.verifiedModel == f.document.store.model && !f.model.isLoadingWaveforms }
        let prior = f.document.store.model
        let episode = try #require(prior.episode(f.model.episodeID))
        let revision = try #require(episode.alignment?.acceptedRevision)
        let version = try #require(episode.alignment?.map(revision: revision))
        let map = try prior.timeMap(revision: revision, in: episode.id)
        let target = try #require(episode.source(f.target)?.placement.epochID)
        let proposal = try AcousticConsistencyProposal(estimator: "Synthetic saved proposal", evidenceScore: 7,
            measurements: AcousticConsistencyMeasurements(windowCount: 7, overlapSpanFraction: 0.86,
                eligibleWindowFraction: 0.86, acousticResidualP95Milliseconds: 3.1,
                acousticResidualMaxMilliseconds: 4.4))
        let groups = try map.groups.map { group in
            let epochs = group.epochs.map { epoch in
                guard epoch.epoch == target, case let .mapped(segments, _) = epoch.mapping else { return epoch }
                return EpochClockMap(epoch: target, mapping: .mapped(
                    segments: segments, provenance: .acousticConsistentProposal(proposal)))
            }
            return try GroupTimeMap(group: group.group, reference: group.reference,
                                    epochs: epochs, placements: group.placements)
        }
        let proposedMap = try AlignedTimelineMap(reference: map.reference, groups: groups)
        let recorded = try prior.recordingMap(proposedMap, in: episode.id,
            inputs: version.inputs.sources, recipe: version.inputs.recipe, derivedFrom: revision)
        let saved = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: episode.id)
        try #require(f.document.store.applyReplacement("Seed synthetic saved proposal", expecting: prior, model: saved) { _ in
            f.model.load()
        })
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        f.model.load()
        f.model.loadWaveforms()
        try await wait { f.model.waveformMap == proposedMap && !f.model.isLoadingWaveforms
            && f.model.rows.contains { $0.epochID == target && $0.state.heading.hasPrefix("Proposed") } }
        let track = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(track)
        f.model.setPositionLocked(false, group: track.group)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        try await wait { f.document.verifiedModel == f.document.store.model }
        ready = true
        return f
    }

    @Test(arguments: [false, true])
    func savedProposalReviewPublishesAndSupportsUndoRedo(reject: Bool) async throws {
        let f = try await savedProposalFixture()
        defer { f.close() }
        let prior = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let epoch = try #require(f.model.selection)
        try #require(f.model.selectedAnalysis == nil && f.model.canAcceptProposal)
        if reject { f.model.rejectProposal() } else { f.model.acceptProposal() }
        try await wait { !f.model.isWorking }
        try #require(f.model.lastError == nil, "\(String(describing: f.model.lastError))")
        try #require(f.document.store.model != prior)
        try await wait { f.document.verifiedModel == f.document.store.model }
        let changed = f.document.store.model
        let revision = try #require(changed.episode(f.model.episodeID)?.alignment?.acceptedRevision)
        let map = try changed.timeMap(revision: revision, in: f.model.episodeID)
        let mapping = try #require(map.groups.flatMap(\.epochs).first { $0.epoch == epoch }?.mapping)
        if reject {
            #expect(mapping == .unsupported(.notAttempted))
        } else if case let .mapped(_, .manual(correction)) = mapping {
            #expect(correction.basis == .acceptedAcousticProposal)
        } else {
            Issue.record("Saved proposal must become a manual accepted-acoustic-proposal decision.")
        }
        let undo = try #require(f.document.undoManager)
        undo.undo()
        try await wait { f.document.verifiedModel == prior }
        undo.redo()
        try await wait { f.document.verifiedModel == changed }
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func changedOriginalCannotPublishSavedProposalReview() async throws {
        let f = try await savedProposalFixture()
        defer { f.close() }
        let prior = f.document.store.model
        try #require(f.model.canAcceptProposal)
        try Self.wave(target: true, durationSeconds: 13).write(to: f.files[1], options: .atomic)
        f.model.acceptProposal()
        try await wait { !f.model.isWorking }
        #expect(f.model.lastError != nil)
        #expect(f.document.store.model == prior)
    }

    @Test func savedProposalReviewRespectsPositionLocksAndTheReference() async throws {
        let f = try await savedProposalFixture()
        defer { f.close() }
        let target = try #require(f.model.waveformTracks.first { $0.id == f.target })
        let reference = try #require(f.model.waveformTracks.first { $0.id != f.target })
        f.model.selectWaveform(reference)
        #expect(!f.model.canAcceptProposal)
        f.model.selectWaveform(target)
        try #require(f.model.canAcceptProposal)
        f.model.setPositionLocked(true, group: target.group)
        #expect(!f.model.canAcceptProposal)
        f.model.setPositionLocked(false, group: target.group)
        #expect(f.model.canAcceptProposal)
    }

    @Test func cleanupPlaysBothPrimariesAcrossChunksAndMarkersWithoutStoppingForZoom() async throws {
        let f = try await fixture(cleanupPrimaries: 2)
        defer { f.close() }
        let originals = try f.files.map { try Data(contentsOf: $0) }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let revision = try #require(f.document.store.model.episodes[0].alignment?.acceptedRevision)
        let state = ShowWindowState(store: f.document.store)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 2, outValue: 4)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true, "\(cleanup.error ?? ""); \(cleanup.plan?.blockers ?? [])")
        try #require(cleanup.canNavigate && cleanup.plan?.lanes.count == 2)
        try await wait(cleanup.error ?? "Primary waveforms") {
            !cleanup.isLoadingWaveforms && !cleanup.isLoadingOverview
        }
        let speakers = Set(try #require(cleanup.plan).lanes.map(\.speaker))
        #expect(Set(cleanup.overviewStrokes.keys) == speakers)
        #expect(Set(cleanup.windowStrokes.keys) == speakers)
        for speaker in speakers { cleanup.setSpeaker(speaker, enabled: false) }
        cleanup.seek(to: 0)
        cleanup.play()
        try await wait(cleanup.error ?? cleanup.transportMessage) { cleanup.isPlaying && cleanup.playhead > 0.5 }
        #expect(cleanup.transportMessage.contains("all speakers muted"))
        let beforeZoom = cleanup.playhead
        cleanup.setWindow(start: 10, duration: 2)
        cleanup.zoomTimeline(duration: 1)
        #expect(cleanup.isPlaying)
        #expect(cleanup.playhead == beforeZoom && cleanup.windowDuration == 1)
        #expect(abs(cleanup.windowStart + cleanup.windowDuration / 2 - beforeZoom) < 0.000_001)
        try await wait(cleanup.error ?? cleanup.transportMessage) {
            cleanup.playhead > 6 || (!cleanup.isPlaying && !cleanup.isPreparingPlayback)
        }
        try #require(cleanup.isPlaying, "\(cleanup.error ?? cleanup.transportMessage)")
        #expect(cleanup.playhead > 6 && cleanup.playhead > beforeZoom)
        #expect(cleanup.playhead > (cleanup.episode?.cleanup?.workingRange?.tracksOut ?? .infinity))
        cleanup.stopPlayback()
        let paused = cleanup.playhead
        try await Task.sleep(for: .milliseconds(200))
        #expect(!cleanup.isPlaying && abs(cleanup.playhead - paused) < 1 / 48_000)
        cleanup.stop()
        #expect(cleanup.playhead == cleanup.windowStart)
        let end = cleanup.bounds.upperBound
        cleanup.seek(to: end - 0.3)
        cleanup.play()
        try await wait(cleanup.error ?? cleanup.transportMessage) {
            !cleanup.isPlaying && !cleanup.isPreparingPlayback
        }
        #expect(cleanup.error == nil)
        #expect(abs(cleanup.playhead - end) < 1 / 48_000, "A short tail starts without waiting for ten seconds of audio")
        #expect(cleanup.transportMessage.hasPrefix("Reached the end"))
        cleanup.play()
        cleanup.stopPlayback()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!cleanup.isPlaying && !cleanup.isPreparingPlayback, "Canceling preparation never starts late audio")
        #expect(cleanup.episode?.alignment?.acceptedRevision == revision)
        #expect(cleanup.episode?.cleanup?.workingRange?.tracksIn == 2)
        #expect(cleanup.episode?.cleanup?.workingRange?.tracksOut == 4)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test func cleanupMeasuresOnlyThePrimaryAndQueuesFractionalWindowsWithoutLosingFrames() async throws {
        let f = try await fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let state = ShowWindowState(store: f.document.store)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true, "\(cleanup.error ?? "Cleanup not ready")")
        let lane = try #require(cleanup.plan?.lanes.first)
        try await wait(cleanup.error ?? "Primary-only waveforms") {
            !cleanup.isLoadingWaveforms && !cleanup.isLoadingOverview
        }
        #expect(cleanup.overviewStrokes.count == 1 && cleanup.windowStrokes.count == 1)
        #expect(cleanup.waveformIndex(for: lane.speaker).strokes == cleanup.strokes(for: lane.speaker))
        #expect(cleanup.identities.keys.contains(lane.primary.sourceID))
        #expect(!cleanup.identities.keys.contains(f.target))
        let snapshot = f.document.store.model
        let first = try await f.runtime.cleanupPreview(model: snapshot, episode: f.model.episodeID,
            start: 0.123456, duration: 1.25, respectWorkingRange: false)
        let next = try await f.runtime.cleanupPreview(model: snapshot, episode: f.model.episodeID,
            start: first.start + first.duration, duration: 1.5, respectWorkingRange: false)
        let whole = try await f.runtime.cleanupPreview(model: snapshot, episode: f.model.episodeID,
            start: 0.123456, duration: 2.75, respectWorkingRange: false)
        #expect(Set(first.channels.keys) == [lane.speaker] && first.channels.count == 1)
        let firstSamples = try #require(first.channels[lane.speaker])
        let nextSamples = try #require(next.channels[lane.speaker])
        let wholeSamples = try #require(whole.channels[lane.speaker])
        #expect(firstSamples.count == 60_000 && nextSamples.count == 72_000)
        #expect(firstSamples.count + nextSamples.count == wholeSamples.count)
        #expect(firstSamples + nextSamples == wholeSamples)
        #expect(first.start + first.duration == next.start)
        #expect(abs(next.start + next.duration - (whole.start + whole.duration)) < 1 / 48_000)
        #expect(firstSamples.allSatisfy(\.isFinite) && firstSamples.contains { abs($0) > 0.001 })
        #expect(f.document.store.model == snapshot)
    }

    @Test func closeZoomGroupPreviewUsesShiftedCacheCoverageWithoutChangingSamples() async throws {
        let f = try await fixture(durationSeconds: 12)
        defer { f.close() }
        let track = try #require(f.model.waveformTracks.first { $0.id == f.target })
        f.model.selectWaveform(track)
        f.model.waveformStartSeconds = 2
        f.model.waveformDurationSeconds = 0.5
        let before = f.model.waveformTileSlices(for: track.group)
        f.model.groupDraftMilliseconds = 250
        let shifted = f.model.waveformTileSlices(for: track.group)
        let slice = try #require(shifted.first)
        #expect(slice.range == 1.75...2.25)
        #expect(slice.indices[track.id]?.id == before.first?.indices[track.id]?.id)
        #expect(f.model.hasVisibleWaveformStrokes(for: track))
        let clip = try #require(AlignmentWaveformProjection.viewportClip(
            range: slice.range, start: 2, duration: 0.5, width: 640, shift: 0.25))
        #expect(clip.origin == 0 && clip.width == 640)
        #expect(f.document.store.model.episode(f.model.episodeID)?.alignment == nil)
    }

    @Test func offscreenTrackRowsAreLazyAndMaterializeWhenScrolled() async throws {
        let f = try await fixture(durationSeconds: 3, extraSources: 30)
        defer { f.close() }
        f.model.listening.workspace.layout = .recorderGroup
        var appeared: Set<SourceID> = []
        var visible: Set<SourceID> = []
        var scrollProxy: ScrollViewProxy?
        let host = HostedTimelineWindow(width: 1_200, height: 650,
            content: ScrollViewReader { proxy in
                AlignmentWaveformView(model: f.model, showInspector: {},
                    trackVisibilityChanged: { source, isVisible in
                        if isVisible {
                            appeared.insert(source)
                            visible.insert(source)
                        } else { visible.remove(source) }
                    })
                    .onAppear { scrollProxy = proxy }
            })
        defer { host.close() }
        host.window.setContentSize(NSSize(width: 1_200, height: 650))
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let initial = appeared
        #expect(!initial.isEmpty)
        #expect(initial.count < 32, "Offscreen tracks must not instantiate every waveform row")
        let last = try #require(f.model.waveformTracks.last)
        try #require(scrollProxy).scrollTo(last.id, anchor: .bottom)
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutSubtreeIfNeeded()
        let final = visible
        #expect(!final.isEmpty)
        #expect(!final.isSubset(of: initial), "Scrolling materializes previously offscreen tracks")
        print("VERTICAL_VIRTUALIZATION tracks=32 initially_materialized=\(initial.count) after_scroll_visible=\(final.count)")
    }

    @Test func indexedViewportBenchmarkReportsEquivalentWorkAndBoundedSurfaces() async throws {
        try await Self.benchmarkViewport()
    }

    enum TimelineDragWorkload: String, CaseIterable { case pan, zoom, move }

    @Test(arguments: TimelineDragWorkload.allCases)
    func timelineDragUpdateBenchmarkIncludesNavigationAndHostedLayout(_ workload: TimelineDragWorkload) async throws {
        let f = try await fixture(durationSeconds: 40, extraSources: 4)
        defer { f.close() }
        f.model.listening.workspace.layout = .speaker
        if workload == .move {
            f.model.selectWaveform(try #require(f.model.waveformTracks.first { $0.id == f.target }))
        }
        let original = f.document.store.model
        let snapshot = f.model.waveformOverviewSnapshotID
        let host = HostedTimelineWindow(width: 1_200, height: 800,
            content: AlignmentWaveformView(model: f.model, showInspector: {}))
        defer { host.close() }
        host.window.setContentSize(NSSize(width: 1_200, height: 800))
        try await Task.sleep(for: .milliseconds(250))
        let clock = ContinuousClock()
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: clock.now).components
            return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        }
        var navigation: [Double] = []
        var updates: [Double] = []
        for frame in 0..<60 {
            let begin = clock.now
            let bounds = f.model.waveformViewingBounds
            let maximum = f.model.maximumWaveformDuration
            let fit = try #require(f.model.waveformFitRange)
            #expect(bounds.contains(fit.lowerBound) && maximum >= fit.upperBound - fit.lowerBound)
            navigation.append(milliseconds(since: begin))
            let update = clock.now
            switch workload {
            case .pan:
                #expect(f.model.previewWaveformWindow(start: 2 + Double(frame) / 60))
            case .zoom:
                #expect(f.model.previewWaveformViewport(start: 2, duration: 20 - Double(frame) / 10))
            case .move:
                f.model.groupDraftMilliseconds = Double(frame + 1) * 5
            }
            try await Task.sleep(for: .milliseconds(1))
            host.view.layoutSubtreeIfNeeded()
            host.view.displayIfNeeded()
            updates.append(milliseconds(since: update))
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * fraction))]
        }
        print("TIMELINE_DRAG_BENCHMARK workload=\(workload.rawValue) frames=60 tracks=6 bins=\(f.model.waveformOverviewIndices.values.reduce(0) { $0 + $1.count }) "
            + "navigation_p50_ms=\(percentile(navigation, 0.5)) navigation_p95_ms=\(percentile(navigation, 0.95)) "
            + "layout_p50_ms=\(percentile(updates, 0.5)) layout_p95_ms=\(percentile(updates, 0.95))")
        #expect(f.model.waveformOverviewSnapshotID == snapshot)
        #expect(f.document.store.model == original)
    }

    @concurrent
    private static func benchmarkViewport() async throws {
        let epoch = RecordingEpochID()
        func bins(count: Int, duration: Double) -> [AlignmentWaveformStroke] {
            (0..<count).map {
                let start = Double($0) / Double(count) * duration
                let end = Double($0 + 1) / Double(count) * duration
                return AlignmentWaveformStroke(sourceSeconds: start, groupSeconds: start, displaySeconds: start,
                    low: -0.5, high: 0.5, mapped: true, epoch: epoch,
                    displayRange: start...end, groupRange: start...end)
            }
        }
        let overview = bins(count: 120_000, duration: 1_200)
        let index = AlignmentWaveformStrokeIndex(strokes: overview)
        let clock = ContinuousClock()
        func measure(_ draw: (Double) -> Int) -> (seconds: Double, count: Int) {
            let begin = clock.now
            var count = 0
            for frame in 0..<60 { count += draw(600.125 + Double(frame) / 100) }
            let elapsed = begin.duration(to: clock.now).components
            return (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, count)
        }
        let scan = measure {
            AlignmentWaveformProjection.displayColumns(strokes: overview, start: $0, duration: 0.5,
                width: 960, pixelsPerPoint: 2).count
        }
        let indexed = measure {
            AlignmentWaveformProjection.displayColumns(strokes: index.visible(start: $0, duration: 0.5),
                start: $0, duration: 0.5, width: 960, pixelsPerPoint: 2).count
        }
        #expect(scan.count == indexed.count && indexed.count == 60 * 1_920)
        let tile = bins(count: 2_048, duration: 30)
        let tileIndex = AlignmentWaveformStrokeIndex(strokes: tile)
        let fullTile = measure { _ in
            AlignmentWaveformProjection.displayColumns(strokes: tile, start: 0, duration: 30,
                width: 960 * 60, pixelsPerPoint: 2).count
        }
        let viewport = measure { _ in
            AlignmentWaveformProjection.displayColumns(strokes: tileIndex.visible(start: 10, duration: 0.5),
                start: 10, duration: 0.5, width: 960, pixelsPerPoint: 2).count
        }
        #expect(fullTile.count == 60 * 115_200 && viewport.count == 60 * 1_920)
        print("VIEWPORT_BENCHMARK frames=60 bins=120000 scan_seconds=\(scan.seconds) indexed_seconds=\(indexed.seconds) "
            + "tile_seconds=\(fullTile.seconds) viewport_seconds=\(viewport.seconds) "
            + "tile_width=57600 viewport_width=960 scale=2 visible_bins=\(index.visible(start: 600.125, duration: 0.5).count)")
        try Task.checkCancellation()
    }

    private static func wave(target: Bool, durationSeconds: Int = 40,
                             pauses: [Range<Double>] = [], stepSeconds: Double = 0) -> Data {
        let rate = 8000, frames = rate * durationSeconds
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        put(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8)
        put(UInt32(frames * 2))
        func noise(_ index: Int64) -> Double {
            var z = UInt64(81) &+ UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) - 0.5
        }
        for frame in 0..<frames {
            let u = Double(frame) / Double(rate)
            let t = target ? 1.00012 * u + 0.18 + (u >= Double(durationSeconds) / 2 ? stepSeconds : 0) : u
            let x = t * 2000, index = Int64(floor(x)), fraction = x - floor(x)
            let value = pauses.contains { $0.contains(u) } ? 0 : noise(index) * (1 - fraction) + noise(index + 1) * fraction
            put(Int16((value * 20_000).rounded()))
        }
        return data
    }
}
