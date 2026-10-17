import AppKit
import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDecode
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Alignment waveform retention (synthetic only)", .serialized)
struct AlignmentWaveformRetentionHostedTests {
    @MainActor private struct Fixture {
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

    private func fixture() async throws -> Fixture {
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
        let episode = Episode(title: "Synthetic", recorderGroups: [referenceGroup, targetGroup],
            sources: [reference, target], speakerAssignments: [
                SpeakerAssignment(speakerID: speaker.id,
                    primary: ChannelReference(sourceID: reference.id, statedChannel: 0),
                    backups: [ChannelReference(sourceID: target.id, statedChannel: 0)])
            ])
        let initial = ShowDocumentModel(show: Show(title: "Retention fixture"), speakers: [speaker], episodes: [episode])
        let accessStore = FileDeviceAccessStore(fileURL: folder.appendingPathComponent("access.json"))
        let io = SystemSourceIO()
        let decoder = SourceDecoder(access: SourceAccessContext(io: io))
        var files: [URL] = []
        for (index, source) in [reference, target].enumerated() {
            let file = folder.appendingPathComponent(source.displayNameHint)
            try Self.wave(target: index == 1).write(to: file)
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
        f.model.analyse()
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

    private static func wave(target: Bool) -> Data {
        let rate = 8000, frames = rate * 40
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
            let value = noise(index) * (1 - fraction) + noise(index + 1) * fraction
            put(Int16((value * 20_000).rounded()))
        }
        return data
    }
}
