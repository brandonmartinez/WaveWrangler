import AppKit
import Foundation
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
                 pauses: [Range<Double>] = []) async throws -> Fixture {
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
        for (index, source) in [reference, target].enumerated() {
            let file = folder.appendingPathComponent(source.displayNameHint)
            try Self.wave(target: index == 1, durationSeconds: durationSeconds, pauses: pauses).write(to: file)
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
        try await wait { model.rows.count == 2 && model.waveformTracks.count == 2 && !model.isLoadingWaveforms }
        model.ensureWaveformOverview()
        try await wait { !model.isLoadingOverview && model.waveformOverviewTracks.count == 2 }
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

    private static func wave(target: Bool, durationSeconds: Int = 40, pauses: [Range<Double>] = []) -> Data {
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
            let t = target ? 1.00012 * u + 0.18 : u
            let x = t * 2000, index = Int64(floor(x)), fraction = x - floor(x)
            let value = pauses.contains { $0.contains(u) } ? 0 : noise(index) * (1 - fraction) + noise(index + 1) * fraction
            put(Int16((value * 20_000).rounded()))
        }
        return data
    }
}
