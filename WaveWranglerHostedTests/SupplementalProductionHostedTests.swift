import AppKit
import AudioToolbox
import Foundation
import Synchronization
import Testing
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWSources
import WWMix
@testable import WaveWrangler

/// Synthetic media only. Run under the coordinated macOS VM GUI lease, never on the desktop.
@MainActor
@Suite("Supplemental production adapters", .serialized)
struct SupplementalProductionHostedTests {
    private struct Fixture {
        let folder: URL
        let url: URL
        let document: ShowDocument
        let runtime: AlignmentRuntime
        let access: InMemoryDeviceAccessStore
        let source: SourceRecord
        let track: AudioTrack
        let episode: EpisodeID

        func close() {
            NSDocumentController.shared.removeDocument(document)
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func fixture(codec: UInt32 = kAudioFormatLinearPCM, storage: Int64 = 1 << 30) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ww-f4-hosted-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = folder.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent("generated.caf")
        try Self.writeAudio(url, codec: codec)
        let source = SourceRecord(displayNameHint: "Generated stereo", purpose: .supplementalAudio)
        let track = AudioTrack(name: "Supplemental")
        let clip = AudioClip(track: track.id, source: source.id,
            trim: .init(startFrame: 0, endFrame: 4800), anchor: .absolute(frame: 0))
        let episode = Episode(title: "Audio only", sources: [source], audioArrangement: .init(
            assets: [.init(source: source.id, frameCount: 4800, sampleRate: 48_000, channelCount: 2)],
            tracks: [track], clips: [clip]))
        let model = ShowDocumentModel(show: Show(title: "Synthetic production"), episodes: [episode])
        let io = SystemSourceIO(), context = SourceAccessContext(io: SystemSourceIO())
        guard case .success(let metadata) = io.metadata(at: url) else { throw DecodeFailure.notFound }
        let witness = try await SourceDecoder(access: context).captureRawIdentity(url, matching: metadata.fingerprint)
        let record = DeviceAccessRecord(showID: model.show.id, sourceID: source.id,
            bookmark: try io.makeReadOnlyBookmark(for: url), lastKnownPath: url.path,
            recordedIdentity: .init(fingerprint: metadata.fingerprint, confirmation: .userConfirmed,
                                    recordedAt: Date(), rawWitness: witness), createdAt: Date())
        let access = InMemoryDeviceAccessStore([record])
        let showURL = folder.appendingPathComponent("synthetic.wwshow")
        try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(model, revision: 1, publicationID: UUID()).data.write(to: showURL)
        let raw = try NSDocumentController.shared.makeDocument(withContentsOf: showURL, ofType: DocumentTypes.show)
        let document = try #require(raw as? ShowDocument)
        NSDocumentController.shared.addDocument(document)
        let runtime = try await AlignmentRuntime.make(showID: model.show.id, accessStore: access, access: context,
            nativeConfiguration: .init(maximumStorageBytes: storage))
        return .init(folder: folder, url: url, document: document, runtime: runtime, access: access,
                     source: source, track: track, episode: episode.id)
    }

    private static func writeAudio(_ url: URL, codec: UInt32 = kAudioFormatLinearPCM) throws {
        var client = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format = codec == kAudioFormatLinearPCM ? client : AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: codec, mFormatFlags: 1, mBytesPerPacket: 0,
            mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var created: ExtAudioFileRef?
        try #require(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, nil, 0, &created) == noErr)
        let file = try #require(created)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        try #require(ExtAudioFileSetProperty(file, kExtAudioFileProperty_FileChannelLayout,
            UInt32(MemoryLayout.size(ofValue: layout)), &layout) == noErr)
        try #require(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
        var samples = (0..<4800).flatMap { frame -> [Int16] in [Int16(frame % 1000), -Int16(frame % 2000)] }
        let result = samples.withUnsafeMutableBytes { bytes in
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: .init(
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return ExtAudioFileWrite(file, 4800, &buffer)
        }
        let closed = ExtAudioFileDispose(file)
        try #require(result == noErr && closed == noErr)
    }

    private func joining(_ first: Fixture, _ second: Fixture) async throws -> ShowDocumentModel {
        let secondModel = second.document.store.model
        let candidate = await second.access.record(for: .init(showID: secondModel.show.id, sourceID: second.source.id))
        var record = try #require(candidate)
        record.showID = first.document.store.model.show.id
        await first.access.save(record)
        let candidateEpisode = secondModel.episode(second.episode)
        let episode = try #require(candidateEpisode)
        return try first.document.store.model.addingEpisode(episode)
    }

    @Test func retirementCancelsBeforePublicationAndRefusesSelfJoinWithoutWaitingForActiveWork() async throws {
        let reached = SupplementalHostedConsumerGate(), resume = SupplementalHostedConsumerGate()
        let activeGate = SupplementalHostedConsumerGate()
        let attemptedJoin = Mutex(false), canceledAdmission = Mutex(false)
        let retirements = ProductionPlaybackRetirements(beforeSnapshotForTesting: {
            reached.open()
            await resume.wait()
        }, beforeJoiningForTesting: {
            attemptedJoin.withLock { $0 = true }
            // Trap a regression before it actually awaits its own task handle.
            throw CancellationError()
        })
        let active = Task { await activeGate.wait() }
        let retiring = Task {
            do {
                try await retirements.wait()
                Issue.record("A self-retired admission returned successfully.")
            } catch is CancellationError {
                canceledAdmission.withLock { $0 = true }
            } catch {
                Issue.record("Unexpected retirement failure: \(error)")
            }
        }
        await reached.wait()
        retirements.retire(retiring)
        let canceledBeforeResuming = retiring.isCancelled
        resume.open()
        await retiring.value
        let joined = attemptedJoin.withLock { $0 }
        let refused = canceledAdmission.withLock { $0 }
        let activeCanceled = active.isCancelled
        activeGate.open()
        await active.value
        #expect(canceledBeforeResuming && refused && !joined)
        #expect(!activeCanceled)
    }

    @Test func completedOfflineConsumerAllowsEpisodeSwitchAndCachedReadmission() async throws {
        let first = try await fixture(codec: kAudioFormatAppleLossless, storage: 80_000)
        let second = try await fixture(codec: kAudioFormatAppleLossless)
        defer { first.close(); second.close() }
        let model = try await joining(first, second)
        let a = try await first.runtime.mixerRecipe(model: model, episode: first.episode, programFrames: 0..<4800)
        let b = try await first.runtime.mixerRecipe(model: model, episode: second.episode, programFrames: 0..<4800)
        try await first.runtime.renderProductionOffline(recipe: a, model: model, isCurrent: { true }, sink: { _ in })
        let other = try await first.runtime.productionPCM(recipe: b, model: model, frames: 0..<16)
        let readmitted = try await first.runtime.productionPCM(recipe: a, model: model, frames: 0..<16)
        let otherFrames = other.audioTracks[second.track.id]?.first?.count
        let readmittedFrames = readmitted.audioTracks[first.track.id]?.first?.count
        #expect(otherFrames == 16 && readmittedFrames == 16)
    }

    @Test func canceledConsumerPreservesIndependentOwnerUntilItsOwnCompletion() async throws {
        let first = try await fixture(codec: kAudioFormatAppleLossless, storage: 80_000)
        let second = try await fixture(codec: kAudioFormatAppleLossless)
        defer { first.close(); second.close() }
        let model = try await joining(first, second)
        let runtime = first.runtime, track = first.track.id
        let a = try await runtime.mixerRecipe(model: model, episode: first.episode, programFrames: 0..<4800)
        let b = try await runtime.mixerRecipe(model: model, episode: second.episode, programFrames: 0..<4800)
        try await runtime.withProductionConsumer(recipe: a, model: model) { survivor in
            let started = SupplementalHostedConsumerGate(), finish = SupplementalHostedConsumerGate()
            let pending = Task {
                do {
                    try await runtime.withProductionConsumer(recipe: a, model: model) { consumer in
                        _ = try await runtime.productionPCM(recipe: a, model: model, frames: 0..<16, consumer: consumer)
                        started.open()
                        await finish.wait()
                        try Task.checkCancellation()
                    }
                } catch {
                    started.open()
                    throw error
                }
            }
            await started.wait()
            pending.cancel()
            finish.open()
            await #expect(throws: CancellationError.self) { try await pending.value }
            await #expect(throws: NativeSourcePreparationFailure.storageBudgetExceeded) {
                try await runtime.productionPCM(recipe: b, model: model, frames: 0..<16)
            }
            let live = try await runtime.productionPCM(recipe: a, model: model, frames: 0..<16, consumer: survivor)
            let count = live.audioTracks[track]?.first?.count
            #expect(count == 16)
        }
        let other = try await runtime.productionPCM(recipe: b, model: model, frames: 0..<16)
        let count = other.audioTracks[second.track.id]?.first?.count
        #expect(count == 16)
    }

    @Test func stoppedProductionReleasesBeforeEpisodeAndImportReadmission() async throws {
        let first = try await fixture(codec: kAudioFormatAppleLossless, storage: 80_000)
        let second = try await fixture(codec: kAudioFormatAppleLossless)
        defer { first.close(); second.close() }
        let snapshot = try await joining(first, second)
        let b = try await first.runtime.mixerRecipe(model: snapshot, episode: second.episode, programFrames: 0..<4800)
        let gate = SupplementalHostedConsumerGate()
        let model = EpisodeAlignmentModel(document: first.document, episodeID: first.episode, runtime: first.runtime)
        defer { model.suspend(); gate.open() }
        model.load()
        try await MixerHostedTests().wait {
            model.audioEditor.composition != nil && !model.audioEditor.isPreparingWaveforms
        }
        await first.runtime.setProductionValidationHookForTesting { await gate.wait() }
        model.playProductionMix(interval: 0...0.1)
        try await MixerHostedTests().wait { gate.isEntered || model.lastError != nil }
        let entered = gate.isEntered
        try #require(entered)
        model.stopAudition()
        gate.open()
        let other = try await first.runtime.productionPCM(recipe: b, model: snapshot, frames: 0..<16)
        let count = other.audioTracks[second.track.id]?.first?.count
        #expect(count == 16)
        let candidateAsset = snapshot.episode(first.episode)?.audioArrangement?.assets.first
        let asset = try #require(candidateAsset)
        _ = try await first.runtime.audioAssetWaveform(asset, model: snapshot, episode: first.episode) { _ in }
        await first.runtime.setProductionValidationHookForTesting(nil)
        model.playProductionMix(interval: 0...0.1)
        try await MixerHostedTests().wait { !model.canStopAudition }
        let label = model.auditionLabel
        #expect(label == "Production mix reached the end of the selected program.")
    }

    @Test func audioOnlyPreparationAndOfflineUseIdenticalPlanPCMAndDSPWithoutAcceptedTiming() async throws {
        let f = try await fixture()
        defer { f.close() }
        let model = f.document.store.model
        let composition = try await f.runtime.programComposition(model: model, episode: f.episode)
        #expect(composition.programFrames == 0..<4800 && composition.timeline.dialogueFrames == nil)
        let recipe = try await f.runtime.mixerRecipe(model: model, episode: f.episode, programFrames: 0..<4800)
        let raw = try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 0..<4800)
        #expect(raw.channels.isEmpty && raw.audioTracks[f.track.id]?.count == 2)
        let liveGraph = try await MixerProcessor.load(recipe: recipe)
        let expected = try await liveGraph.process(raw)
        let collector = SupplementalOutputCollector()
        try await f.runtime.renderProductionOffline(recipe: recipe, model: model, isCurrent: { true },
            sink: { await collector.append($0) })
        #expect(await collector.channels == expected.channels)
        #expect(model.episode(f.episode)?.alignment == nil)
    }

    @Test func adapterCacheReuseStillRefusesRevokedDeviceRecordAndChangedOriginal() async throws {
        let f = try await fixture()
        defer { f.close() }
        let model = f.document.store.model
        let recipe = try await f.runtime.mixerRecipe(model: model, episode: f.episode, programFrames: 0..<4800)
        _ = try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 0..<1024)
        await f.access.removeRecord(for: .init(showID: model.show.id, sourceID: f.source.id))
        await #expect(throws: (any Error).self) {
            try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 1024..<2048)
        }
        await #expect(throws: (any Error).self) { try await f.runtime.validateProduction(recipe: recipe, model: model) }
        let other = try await fixture()
        defer { other.close() }
        let snapshot = other.document.store.model
        let otherRecipe = try await other.runtime.mixerRecipe(model: snapshot, episode: other.episode, programFrames: 0..<4800)
        _ = try await other.runtime.productionPCM(recipe: otherRecipe, model: snapshot, frames: 0..<1024)
        var bytes = try Data(contentsOf: other.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: other.url)
        await #expect(throws: (any Error).self) {
            try await other.runtime.validateProduction(recipe: otherRecipe, model: snapshot)
        }
    }

    @Test func liveTrackControlsKeepInstanceButArrangementEditsInvalidateIt() async throws {
        let f = try await fixture()
        defer { f.close() }
        let controller = EpisodeMixerController(document: f.document, episodeID: f.episode, runtime: f.runtime)
        _ = try await controller.prepare(programFrames: 0..<4800)
        let revision = controller.instanceRevision
        try #require(f.document.store.apply("Track level") { model throws(DomainError) in
            try model.settingAudioTrackMix(.init(track: f.track.id, gainDB: -6, balance: 0.5), in: f.episode)
        })
        try await controller.synchronizeControls()
        #expect(controller.instanceRevision == revision && controller.preparedInstanceIsCurrent)
        let block = try await controller.preparePCM(0..<512)
        let output = try await controller.renderPrepared(block)
        #expect(output.audioTrackMeters[f.track.id]?.count == 2)
        try #require(f.document.store.apply("Move audio") { model throws(DomainError) in
            var clip = model.episode(f.episode)!.audioArrangement!.clips[0]
            clip.anchor = .absolute(frame: 480)
            return try model.replacingAudioClip(clip, in: f.episode)
        })
        #expect(!controller.preparedInstanceIsCurrent)
        await #expect(throws: MixerFailure.staleDependencies) { try await controller.preparePCM(512..<1024) }
    }

    @Test func audioTrackNativeStateCaptureUsesTheExistingSaveUndoBarrier() async throws {
        let f = try await fixture()
        defer { f.close() }
        let slot = try MixerHostedTests().appleSlot()
        try #require(f.document.store.apply("Track effect") { model throws(DomainError) in
            try model.settingAudioTrackMix(.init(track: f.track.id, inserts: [slot]), in: f.episode)
        })
        let controller = EpisodeMixerController(document: f.document, episodeID: f.episode, runtime: f.runtime)
        _ = try await controller.prepare(programFrames: 0..<4800)
        try await controller.beginEditorObservation(coalescing: "f4.track.editor")
        let processor = try #require(controller.processor)
        let parameters = try await processor.parameters(slot: slot.id)
        let parameter = try #require(parameters.first { $0.writable && $0.minimum < $0.maximum })
        let value = parameter.value == parameter.minimum ? parameter.maximum : parameter.minimum
        try await processor.setParameter(slot: slot.id, address: parameter.address, value: value)
        try await controller.endEditorObservation()
        #expect(controller.unitStatuses.count == 1)
        #expect(f.document.store.model.episode(f.episode)?.mix?.audioTracks?.first?.inserts.first?.documentState != nil)
        try await f.document.mixerTransactions.barrier(replacingInstances: true, episode: f.episode) {}
        #expect(controller.processor == nil)
    }

    @Test func insertedIntroAndOutroUseProgramCoordinatesWhileRealDialogueKeepsAcceptedSupport() async throws {
        let helper = MixerHostedTests(), f = try await helper.ready()
        defer { f.close() }
        let url = f.folder.appendingPathComponent("supplemental.caf")
        try Self.writeAudio(url)
        let source = SourceRecord(displayNameHint: "Supplemental", purpose: .supplementalAudio)
        let io = SystemSourceIO()
        guard case .success(let metadata) = io.metadata(at: url) else { throw DecodeFailure.notFound }
        let witness = try await SourceDecoder(access: .init(io: io)).captureRawIdentity(url, matching: metadata.fingerprint)
        let show = f.document.store.model.show.id
        try await FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json")).save(.init(
            showID: show, sourceID: source.id, bookmark: try io.makeReadOnlyBookmark(for: url), lastKnownPath: url.path,
            recordedIdentity: .init(fingerprint: metadata.fingerprint, confirmation: .userConfirmed,
                                    recordedAt: Date(), rawWitness: witness), createdAt: Date()))
        let episode = try #require(f.document.store.model.episode(f.model.episodeID))
        let accepted = try #require(episode.alignment?.acceptedMap)
        let track = AudioTrack(name: "Intro and outro")
        let region = try AudioInsertionRegion(anchor: .dialogue(.init(map: accepted, frame: 0)), durationFrames: 4800)
        let intro = AudioClip(track: track.id, source: source.id, trim: .init(startFrame: 0, endFrame: 4800),
                              anchor: .insertion(region: region.id, offsetFrames: 0))
        let outro = AudioClip(track: track.id, source: source.id, trim: intro.trim, anchor: .absolute(frame: 210_000))
        let arrangement = AudioArrangement(assets: [.init(source: source.id, frameCount: 4800, sampleRate: 48_000, channelCount: 2)],
            tracks: [track], clips: [intro, outro], insertionRegions: [region])
        try #require(f.document.store.apply("Generated intro and outro") { model throws(DomainError) in
            try model.settingAudioState(arrangement, mix: episode.mix, sources: episode.sources + [source], in: episode.id)
        })
        try await helper.save(f.document)
        let model = f.document.store.model
        let recipe = try await f.runtime.mixerRecipe(model: model, episode: episode.id, programFrames: 0..<214_800)
        #expect(recipe.composition?.timeline.dialogueFrames == 0..<192_000)
        #expect(recipe.composition?.programFrames == 0..<214_800)
        let first = try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 0..<512)
        #expect(first.channels.values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(first.audioTracks[track.id]?[0].contains { $0 != 0 } == true)
        let dialogue = try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 4800..<5312)
        let route = try #require(recipe.routes.first)
        let original = try await f.runtime.sourceAuditions(model: model, episode: episode.id,
            sources: [route.reference.sourceID], outputFrames: 0..<512, applyingCuts: false,
            decodedChannels: [route.reference.sourceID: 0], applyingInputGain: false)
        #expect(dialogue.channels[route.reference] == original[route.reference.sourceID]?.samples)
        let gap = try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 200_000..<200_512)
        #expect(gap.channels.values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(gap.audioTracks[track.id]?.allSatisfy { $0.allSatisfy { $0 == 0 } } == true)
        let last = try await f.runtime.productionPCM(recipe: recipe, model: model, frames: 210_000..<210_512)
        #expect(last.audioTracks[track.id] == first.audioTracks[track.id])
        #expect(model.episode(episode.id)?.alignment?.acceptedMap == accepted)
    }

    @Test func productionPlayAcceptsAudioOnlyWithoutSourceTimePreviewOrFakeAlignment() async throws {
        let f = try await fixture()
        defer { f.close() }
        let model = EpisodeAlignmentModel(document: f.document, episodeID: f.episode, runtime: f.runtime)
        model.playProductionMix(interval: 0...0.1)
        try await MixerHostedTests().wait { !model.canStopAudition }
        #expect(model.listeningMode == .productionMix)
        #expect(model.auditionLabel == "Production mix reached the end of the selected program.")
        #expect(model.productionPlayheadSeconds == 0.1)
        #expect(f.document.store.model.episode(f.episode)?.alignment == nil)
        model.suspend()
    }

    @Test func discardedRuntimeReleasesCachedAdmissionsAndItsExclusiveNativeStore() async throws {
        let f = try await fixture()
        defer { f.close() }
        let model = f.document.store.model
        var runtime: AlignmentRuntime? = try await AlignmentRuntime.make(
            showID: model.show.id, accessStore: f.access, access: .init(io: SystemSourceIO()))
        let root = try #require(runtime).nativeCacheRootForTesting
        let recipe = try await #require(runtime).mixerRecipe(model: model, episode: f.episode, programFrames: 0..<4800)
        _ = try await #require(runtime).productionPCM(recipe: recipe, model: model, frames: 0..<512)
        #expect(FileManager.default.fileExists(atPath: root.path))
        weak var released = runtime
        runtime = nil
        try await MixerHostedTests().wait { released == nil && !FileManager.default.fileExists(atPath: root.path) }
        #expect(released == nil, "Cached source callbacks must not form a Runtime -> Scheduler -> Runtime cycle.")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

private actor SupplementalOutputCollector {
    var channels = [[Float](), [Float]()]
    func append(_ output: MixerPCMOutput) {
        for channel in 0..<2 { channels[channel] += output.channels[channel] }
    }
}

private final class SupplementalHostedConsumerGate: Sendable {
    private struct State {
        var entered = false
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    var isEntered: Bool { state.withLock { $0.entered } }
    func wait() async {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.entered = true
                if $0.opened { continuation.resume() }
                else { $0.waiters.append(continuation) }
            }
        }
    }
    func open() {
        state.withLock {
            $0.opened = true
            for waiter in $0.waiters { waiter.resume() }
            $0.waiters = []
        }
    }
}
