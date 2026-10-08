import Darwin
import CryptoKit
import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWSources
import WWTimeMap
@testable import WWSpeech

private struct SpeechFixtureIO: SourceIO {
    let url: URL
    private let system = SystemSourceIO()

    var provenance: ObservationProvenance { .simulated }
    func metadata(at url: URL) -> MetadataResult { system.metadata(at: url) }
    func listItems(under directory: URL) -> DirectoryListing { system.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution {
        .resolved(data == Data("fixture".utf8) ? url : URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
                  isStale: false)
    }
    func startAccessingSecurityScope(_ url: URL) -> Bool { false }
    func stopAccessingSecurityScope(_ url: URL) {}
    func requestDownload(of url: URL) throws {}
    func downloadFraction(of url: URL) async -> Knowledge<Double> { .unknown }
}

private struct SpeechUnavailableIO: SourceIO {
    enum Failure: Sendable { case permission, dataless }
    let base: SpeechFixtureIO
    let failure: Failure

    var provenance: ObservationProvenance { .simulated }
    func metadata(at url: URL) -> MetadataResult {
        switch failure {
        case .permission: return .failure(.permissionDenied)
        case .dataless:
            guard case var .success(metadata) = base.metadata(at: url) else { return .failure(.notFound) }
            metadata.isDataless = .known(true)
            return .success(metadata)
        }
    }
    func listItems(under directory: URL) -> DirectoryListing { base.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { try base.makeReadOnlyBookmark(for: url) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { base.resolveBookmark(data) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { base.startAccessingSecurityScope(url) }
    func stopAccessingSecurityScope(_ url: URL) { base.stopAccessingSecurityScope(url) }
    func requestDownload(of url: URL) throws { try base.requestDownload(of: url) }
    func downloadFraction(of url: URL) async -> Knowledge<Double> { await base.downloadFraction(of: url) }
}

private actor SpeechSnapshot {
    var value: PrimarySpeechInputState
    var replacement: PrimarySpeechInputState?
    var calls = 0

    init(_ value: PrimarySpeechInputState) { self.value = value }
    func read() -> PrimarySpeechInputState {
        calls += 1
        return calls > 1 ? replacement ?? value : value
    }
    func change(_ next: PrimarySpeechInputState) { replacement = next }
}

private actor SpeechSwapSnapshot {
    let value: PrimarySpeechInputState
    let url: URL
    var calls = 0

    init(_ value: PrimarySpeechInputState, url: URL) { self.value = value; self.url = url }
    func read() throws -> PrimarySpeechInputState {
        calls += 1
        if calls == 2 {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("old.wav"))
            try Data(repeating: 0, count: 300).write(to: url)
        }
        return value
    }
}

private actor SpeechLateSnapshot {
    let initial: PrimarySpeechInputState
    let changed: PrimarySpeechInputState
    private(set) var calls = 0

    init(initial: PrimarySpeechInputState, changed: PrimarySpeechInputState) {
        self.initial = initial
        self.changed = changed
    }

    func read() -> PrimarySpeechInputState {
        calls += 1
        return calls == 3 ? changed : initial
    }
}

private actor SpeechAfterWorkerSnapshot {
    let initial: PrimarySpeechInputState
    let changed: PrimarySpeechInputState
    private(set) var calls = 0

    init(initial: PrimarySpeechInputState, changed: PrimarySpeechInputState) {
        self.initial = initial
        self.changed = changed
    }

    func read() -> PrimarySpeechInputState {
        calls += 1
        return calls >= 4 ? changed : initial
    }
}

private final class CapturedSpeechFD: @unchecked Sendable {
    var descriptor: Int32 = -1
}

private struct SpeechMidReadContentIO: SourceContentIO {
    let url: URL

    func openForDecoding(_ url: URL) throws(DecodeFailure) -> any DecodingContentReader {
        let reader = try SystemSourceContentIO().openForDecoding(url)
        return SpeechMidReadReader(reader: reader, url: self.url)
    }
}

private final class SpeechMidReadReader: DecodingContentReader {
    let reader: any DecodingContentReader
    let url: URL
    var reads = 0
    var facts: EncodedStreamFacts { reader.facts }

    init(reader: any DecodingContentReader, url: URL) {
        self.reader = reader
        self.url = url
    }

    func readRawFrames(into buffer: RawDecodeBuffer) throws(DecodeFailure) -> Int {
        let count = try reader.readRawFrames(into: buffer)
        reads += 1
        if reads == 1 {
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seek(toOffset: 46)
                try handle.write(contentsOf: Data([0x11, 0x22]))
                try handle.close()
            } catch {
                throw .readFailed(errno: EIO)
            }
        }
        return count
    }

    func currentOpenedFileState() throws(DecodeFailure) -> OpenedFileState {
        try reader.currentOpenedFileState()
    }

    func close() { reader.close() }
}

@Suite("Selected primary source bytes")
struct PrimarySpeechInputTests {
    private func wav(channel0: Int16 = 100, channel1: Int16 = -200, frames: Int = 64,
                     rate: Int = 16_000, selectedSamples: [Int16]? = nil) -> Data {
        precondition(selectedSamples == nil || selectedSamples?.count == frames)
        var data = Data()
        func ascii(_ text: String) { data.append(Data(text.utf8)) }
        func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        ascii("RIFF"); u32(UInt32(36 + frames * 4)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        ascii("data"); u32(UInt32(frames * 4))
        for frame in 0..<frames {
            u16(UInt16(bitPattern: channel0))
            u16(UInt16(bitPattern: selectedSamples?[frame] ?? channel1))
        }
        return data
    }

    private func fixture(rate: Int = 16_000, frames: Int = 64, selectedSamples: [Int16]? = nil)
        throws -> (URL, URL, SourceAccessContext, PrimarySpeechInputState, EpisodeID, SpeakerID)
    {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ww-speech-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.wav")
        try wav(frames: frames, rate: rate, selectedSamples: selectedSamples).write(to: url)
        let io = SpeechFixtureIO(url: url)
        guard case let .success(metadata) = io.metadata(at: url) else {
            throw SpeechAdmissionRefusal.sourceIdentityNotConfirmed
        }
        let source = SourceRecord(displayNameHint: "synthetic", observations: SourceObservations(channelCount: .known(2)),
                                  placement: SourcePlacement(channelLabels: [ChannelLabel(channel: 1, label: "speech")]),
                                  role: .primary, roleConfirmation: .userConfirmed)
        let speaker = SpeakerID()
        let episode = Episode(title: "synthetic", sources: [source], speakerAssignments: [
            SpeakerAssignment(speakerID: speaker,
                              primary: ChannelReference(sourceID: source.id, statedChannel: 1),
                              primaryConfirmation: .userConfirmed)
        ])
        let show = ShowDocumentModel(show: Show(title: "synthetic"), speakers: [Speaker(id: speaker, name: "speaker")],
                                      episodes: [episode])
        let record = DeviceAccessRecord(
            showID: show.show.id, sourceID: source.id, bookmark: Data("fixture".utf8),
            lastKnownPath: url.path, recordedIdentity: RecordedIdentity(
                fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
            ), createdAt: Date()
        )
        let snapshot = PrimarySpeechInputState(
            show: show, showRevision: 1, accessRecords: [record],
            sourceRevision: SourceRevision.metadata(source.id, fingerprint: metadata.fingerprint),
            inputAssetRevision: PrimarySpeechInputAdapter.inputAssetRevision
        )
        return (directory, url, SourceAccessContext(io: io), snapshot, episode.id, speaker)
    }

    @Test func onlySelectedChannelDecodesAndCannotLaunchCallerWAV() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try await PrimarySpeechInputAdapter(access: access).prepare(
            episodeID: episode, speakerID: speaker,
            authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
            availability: .on, current: { snapshot }
        )
        #expect(input.selection.channel == 1)
        #expect(input.frameCount == 64)
        #expect(input.interpretation.channelCount == 2)
        #expect(input.samples.allSatisfy { abs($0 - Float(-200) / 32768) < 0.000_01 })
        #expect(input.samples.allSatisfy { abs($0 - Float(100) / 32768) > 0.001 })
        #expect(throws: SpeechAdmissionRefusal.primaryProxyNotProven) {
            try input.offlinePlan(stage: directory, scratch: directory)
        }
    }

    @Test func selectedPrimaryProxyTracksExactSourceAndChunkCoordinates() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture(
            rate: 48_000, frames: 48_003)
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
            episodeID: episode, speakerID: speaker,
            authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
            availability: .on, current: { snapshot }
        )
        #expect(proxy.selection.channel == 1)
        #expect(proxy.sourceRevision == snapshot.sourceRevision)
        #expect(proxy.selectedSourcePCMHash.hasPrefix("selected-pcm-sha256:"))
        #expect(proxy.selectedSourcePCMHash.count == "selected-pcm-sha256:".count + 64)
        #expect(proxy.inputAssetRevision == PrimarySpeechInputAdapter.inputAssetRevision)
        #expect(proxy.proxyAssetRevision == SelectedPrimaryPCMProxy.proxyAsset.revision)
        #expect(proxy.interpretation.sourceSampleRate == 48_000)
        #expect(
            proxy.interpretation.sourceFingerprint
                == snapshot.accessRecords[0].recordedIdentity?.fingerprint)
        #expect(proxy.sourceFramesPerOutputFrame == 3)
        #expect(proxy.frameCount == 16_001)
        #expect(proxy.chunks.count == 2)
        #expect(proxy.chunks[0].outputFrames == 0..<16_000)
        #expect(proxy.chunks[0].sourceFrames == 0..<48_000)
        #expect(proxy.chunks[0].filterSourceFrames == 0..<48_003)
        #expect(proxy.chunks[1].outputFrames == 16_000..<16_001)
        #expect(proxy.chunks[1].sourceFrames == 48_000..<48_003)
        #expect(proxy.chunks[1].filterSourceFrames == 47_976..<48_003)
        #expect(abs(proxy.samples[100] - Float(-200) / 32768) < 0.000_1)
        #expect(abs(proxy.samples[100] - Float(100) / 32768) > 0.001)
        #expect(throws: SpeechAdmissionRefusal.primaryProxyNotProven) {
            try proxy.offlinePlan(stage: directory, scratch: directory)
        }
    }

    @Test func proxyPassthroughPreservesSelectedChannel() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
            episodeID: episode, speakerID: speaker,
            authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
            availability: .on, current: { snapshot }
        )
        #expect(proxy.frameCount == 64)
        #expect(proxy.chunks.map(\.outputFrames) == [0..<64])
        #expect(proxy.chunks[0].sourceFrames == 0..<64)
        #expect(proxy.samples.allSatisfy { $0 == Float(-200) / 32768 })
    }

    @Test func sealedWorkerBorrowsOnlySelectedPCMAndScrubsAfterReturn() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workerURL = directory.appendingPathComponent("stub")
        try Data("abc".utf8).write(to: workerURL)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        var sourceHasher = SHA256()
        sourceHasher.update(data: Data("WWSelectedPrimaryPCM1".utf8))
        for number in [Int64(1), 16_000] {
            withUnsafeBytes(of: number.littleEndian) { sourceHasher.update(bufferPointer: $0) }
        }
        let selectedBits = [UInt32](repeating: (Float(-200) / 32768).bitPattern.littleEndian, count: 64)
        selectedBits.withUnsafeBytes { sourceHasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: Int64(64).littleEndian) { sourceHasher.update(bufferPointer: $0) }
        let selectedHash = "selected-pcm-sha256:" +
            sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let duplicate = try await PrimarySpeechInputAdapter(access: access)
            .withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { snapshot }, workerURL: workerURL, workerPin: pin
            ) { input throws(SpeechAdmissionRefusal) in
                guard input.selection.episodeID == episode, input.selection.speakerID == speaker,
                      input.declaredAuthorization
                        == .explicitUserRequest(episodeID: episode, speakerID: speaker),
                      input.showRevision == snapshot.showRevision,
                      input.selection.channel == 1, input.interpretation.channelCount == 2,
                      input.interpretation.sourceFingerprint
                        == snapshot.accessRecords[0].recordedIdentity?.fingerprint,
                      input.sourceRevision == snapshot.sourceRevision,
                      input.selectedSourcePCMHash == selectedHash,
                      input.inputAssetRevision == PrimarySpeechInputAdapter.inputAssetRevision,
                      input.proxyAssetRevision == SelectedPrimaryPCMProxy.proxyAsset.revision,
                      input.sampleRate == 16_000, input.channelCount == 1,
                      input.format == "f32le", input.frameCount == 64,
                      input.sourceFramesPerOutputFrame == 1,
                      input.chunks.map(\.outputFrames) == [0..<64]
                else { throw .workerInputChanged }
                var info = stat()
                guard fstat(input.descriptor, &info) == 0, info.st_nlink == 0,
                      info.st_size == 64 * 4,
                      fcntl(input.descriptor, F_GETFL) & O_ACCMODE == O_RDONLY
                else { throw .workerInputChanged }
                var bytes = [UInt8](repeating: 0, count: 64 * 4)
                let readCount = bytes.withUnsafeMutableBytes {
                    pread(input.descriptor, $0.baseAddress, $0.count, 0)
                }
                guard readCount == bytes.count,
                      SHA256.hash(data: Data(bytes)).map({ String(format: "%02x", $0) }).joined()
                        == input.sha256
                else { throw .workerInputChanged }
                let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                    | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                guard Float(bitPattern: bits) == Float(-200) / 32768 else {
                    throw .workerInputChanged
                }
                return dup(input.descriptor)
            }
        defer { _ = close(duplicate) }
        var after = stat()
        #expect(fstat(duplicate, &after) == 0)
        #expect(after.st_size == 0)
        #expect(after.st_nlink == 0)
    }

    @Test func sealedWorkerRefusesUnpinnedOrModifiedWorkerWithoutDelivery() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workerURL = directory.appendingPathComponent("stub")
        try Data("abd".utf8).write(to: workerURL)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        let adapter = PrimarySpeechInputAdapter(access: access)
        let grant = PrimarySpeechAuthorization.explicitUserRequest(
            episodeID: episode, speakerID: speaker)
        do {
            _ = try await adapter.withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker, authorization: grant,
                availability: .on, current: { snapshot }, workerURL: workerURL, workerPin: pin
            ) { _ in Issue.record("unverified worker received PCM"); return 1 }
            Issue.record("unverified worker was admitted")
        } catch { #expect(error == .runtimeDependencyMismatch) }
        try Data("abc".utf8).write(to: workerURL)
        let correct = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        do {
            _ = try await adapter.withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker, authorization: grant,
                availability: .on, current: { snapshot }, workerURL: workerURL, workerPin: correct
            ) { _ in
                try? Data("abd".utf8).write(to: workerURL)
                return 1
            }
            Issue.record("modified worker was accepted")
        } catch { #expect(error == .runtimeDependencyMismatch) }
    }

    @Test func changedSealedBytesRefuseAndWorkerErrorsScrubAnonymousInput() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
            episodeID: episode, speakerID: speaker,
            authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
            availability: .on, current: { snapshot })
        let sealed = try SealedPrimaryPCMWorkerInput(proxy: proxy)
        let retained = try sealed.withBorrowedDescriptor { input throws(SpeechAdmissionRefusal) in
            let duplicate = dup(input.descriptor)
            guard duplicate >= 0 else { throw .workerInputNotSealed }
            return duplicate
        }
        defer { _ = close(retained) }
        sealed.overwriteForTesting()
        #expect(throws: SpeechAdmissionRefusal.workerInputChanged) {
            try sealed.withBorrowedDescriptor { _ in
                Issue.record("modified PCM reached worker"); return 0
            }
        }

        let workerURL = directory.appendingPathComponent("stub")
        try Data("abc".utf8).write(to: workerURL)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        let caught = CapturedSpeechFD()
        do {
            let _: Int = try await PrimarySpeechInputAdapter(access: access).withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { snapshot }, workerURL: workerURL, workerPin: pin
            ) { input throws(SpeechAdmissionRefusal) -> Int in
                caught.descriptor = dup(input.descriptor)
                throw .sandboxFailed
            }
            Issue.record("worker failure was swallowed")
        } catch { #expect(error == .sandboxFailed) }
        defer { if caught.descriptor >= 0 { _ = close(caught.descriptor) } }
        var after = stat()
        #expect(caught.descriptor >= 0)
        #expect(fstat(caught.descriptor, &after) == 0)
        #expect(after.st_size == 0)
        #expect(after.st_nlink == 0)
    }

    @Test func sealedWorkerRefusesLatePrimaryChangeAndWrongOccurrence() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workerURL = directory.appendingPathComponent("stub")
        try Data("abc".utf8).write(to: workerURL)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        let grant = PrimarySpeechAuthorization.explicitUserRequest(
            episodeID: episode, speakerID: speaker)
        let changed = PrimarySpeechInputState(
            show: snapshot.show, showRevision: 2, accessRecords: snapshot.accessRecords,
            sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision)
        let state = SpeechLateSnapshot(initial: snapshot, changed: changed)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { await state.read() }, workerURL: workerURL, workerPin: pin
            ) { _ in Issue.record("stale primary reached worker"); return 0 }
            Issue.record("late revision was admitted")
        } catch { #expect(error == .sourceRevisionChanged) }
        #expect(await state.calls == 3)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).withSealedSyntheticWorkerInput(
                episodeID: EpisodeID(), speakerID: speaker, authorization: grant, availability: .on,
                current: { snapshot }, workerURL: workerURL, workerPin: pin
            ) { _ in Issue.record("wrong episode reached worker"); return 0 }
            Issue.record("wrong episode was admitted")
        } catch { #expect(error == .sourceIdentityNotConfirmed) }
        let swapped = SpeechSwapSnapshot(snapshot, url: url)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { try await swapped.read() }, workerURL: workerURL, workerPin: pin
            ) { _ in Issue.record("relinked source reached worker"); return 0 }
            Issue.record("relinked source was admitted")
        } catch { #expect(error == .sourceAliasOrChanged) }
    }

    @Test func cancellationAfterHandoffScrubsBytesAndRefusesPublication() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("stub")
        try Data("abc".utf8).write(to: stub)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        let caught = CapturedSpeechFD()
        let task = Task { () throws -> Int in
            try await PrimarySpeechInputAdapter(access: access).withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { snapshot }, workerURL: stub, workerPin: pin
            ) { input in
                caught.descriptor = dup(input.descriptor)
                withUnsafeCurrentTask { $0?.cancel() }
                return 1
            }
        }
        do {
            _ = try await task.value
            Issue.record("cancelled handoff returned success")
        } catch { #expect(error as? SpeechAdmissionRefusal == .decode(.cancelled)) }
        defer { if caught.descriptor >= 0 { _ = close(caught.descriptor) } }
        var after = stat()
        #expect(caught.descriptor >= 0)
        #expect(fstat(caught.descriptor, &after) == 0)
        #expect(after.st_nlink == 0)
        #expect(after.st_size == 0)
    }

    @Test func workerResultRefusesOrganizerRevisionChangedDuringCallback() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("stub")
        try Data("abc".utf8).write(to: stub)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        let changed = PrimarySpeechInputState(
            show: snapshot.show, showRevision: 2, accessRecords: snapshot.accessRecords,
            sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision)
        let state = SpeechAfterWorkerSnapshot(initial: snapshot, changed: changed)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).withSealedSyntheticWorkerInput(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { await state.read() }, workerURL: stub, workerPin: pin
            ) { _ in 1 }
            Issue.record("stale post-worker result was published")
        } catch { #expect(error == .sourceRevisionChanged) }
        #expect(await state.calls == 4)
    }

        @Test func proxyFilterPreservesSpeechBandAndSuppressesOutOfBandTone() async throws {
            func tone(_ frequency: Int) -> [Int16] {
                (0..<4_800).map { frame in
                    Int16((10_000 * sin(2 * .pi * Double(frame * frequency) / 48_000)).rounded())
                }
            }
            func amplitude(_ frequency: Int) async throws -> Double {
                let (directory, _, access, snapshot, episode, speaker) = try fixture(
                    rate: 48_000, frames: 4_800, selectedSamples: tone(frequency))
                defer { try? FileManager.default.removeItem(at: directory) }
                let proxy = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                    episodeID: episode, speakerID: speaker,
                    authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                    availability: .on, current: { snapshot }
                )
                return sqrt(proxy.samples[100..<1_500].reduce(0.0) { $0 + Double($1 * $1) } / 1_400)
            }
            let speechBand = try await amplitude(1_000)
            let aliasedBand = try await amplitude(12_000)
            #expect(speechBand > 0.20)
            #expect(aliasedBand < 0.005)
        }

    @Test func proxyPlanRefusesUnsupportedRateBoundsAndChunkOverflow() throws {
        let passthrough = try PCMProxyPlan(
            sourceFrames: 16_001, sourceRate: 16_000, chunkFrames: 16_000)
        #expect(passthrough.chunks[0].filterSourceFrames == 0..<16_000)
        #expect(passthrough.chunks[1].filterSourceFrames == 16_000..<16_001)
        #expect(throws: SpeechAdmissionRefusal.proxyRateUnsupported) {
            try PCMProxyPlan(sourceFrames: 64, sourceRate: 44_100, chunkFrames: 16_000)
        }
        #expect(throws: SpeechAdmissionRefusal.proxyRateUnsupported) {
            try PCMProxyPlan(sourceFrames: 64, sourceRate: 0, chunkFrames: 16_000)
        }
        #expect(throws: SpeechAdmissionRefusal.proxyFrameOverflow) {
            try PCMProxyPlan(sourceFrames: Int64.max, sourceRate: 16_000, chunkFrames: 16_000)
        }
        #expect(throws: SpeechAdmissionRefusal.proxyFrameOverflow) {
            try PCMProxyPlan(sourceFrames: -1, sourceRate: 16_000, chunkFrames: 16_000)
        }
        #expect(throws: SpeechAdmissionRefusal.inputTooLarge) {
            try PCMProxyPlan(
                sourceFrames: Int64(PrimarySpeechInputAdapter.maximumFrames + 1),
                sourceRate: 16_000, chunkFrames: 16_000)
        }
        #expect(throws: SpeechAdmissionRefusal.proxyChunkOverflow) {
            try PCMProxyPlan(sourceFrames: 64, sourceRate: 16_000, chunkFrames: Int.max)
        }
        #expect(throws: SpeechAdmissionRefusal.proxyChunkOverflow) {
            try PCMProxyPlan(sourceFrames: 64, sourceRate: 16_000, chunkFrames: 0)
        }
    }

    @Test func proxyRefusesChannelCountMismatchAndUnsupportedResampling() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(
            episodeID: episode, speakerID: speaker)
        var show = snapshot.show
        show.episodes[0].sources[0].observations.channelCount = .known(3)
        let mismatchedShow = show
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: {
                    .init(
                        show: mismatchedShow, showRevision: snapshot.showRevision,
                        accessRecords: snapshot.accessRecords,
                        sourceRevision: snapshot.sourceRevision,
                        inputAssetRevision: snapshot.inputAssetRevision)
                }
            )
            Issue.record("channel mismatch yielded a proxy")
        } catch { #expect(error == .sourceRevisionChanged) }
        let (otherDirectory, _, otherAccess, otherState, otherEpisode, otherSpeaker) = try fixture(
            rate: 44_100)
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        do {
            _ = try await PrimarySpeechInputAdapter(access: otherAccess).preparePCMProxy(
                episodeID: otherEpisode, speakerID: otherSpeaker,
                authorization: .explicitUserRequest(
                    episodeID: otherEpisode, speakerID: otherSpeaker),
                availability: .on, current: { otherState }
            )
            Issue.record("unsupported rate yielded a proxy")
        } catch { #expect(error == .proxyRateUnsupported) }
    }

    @Test func proxyRefusesLateRevisionAndCancellation() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(
            episodeID: episode, speakerID: speaker)
        let changed = PrimarySpeechInputState(
            show: snapshot.show, showRevision: 2, accessRecords: snapshot.accessRecords,
            sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision
        )
        let state = SpeechLateSnapshot(initial: snapshot, changed: changed)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { await state.read() }
            )
            Issue.record("late revision yielded a proxy")
        } catch { #expect(error == .sourceRevisionChanged) }
        #expect(await state.calls == 3)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { snapshot }
            )
        }
        do {
            _ = try await cancelled.value
            Issue.record("cancelled decode yielded a proxy")
        } catch { #expect(error as? SpeechAdmissionRefusal == .decode(.cancelled)) }
    }

    @Test func proxyRefusesMidReadSourceChange() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture(frames: 20_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await PrimarySpeechInputAdapter(
                access: access, content: SpeechMidReadContentIO(url: url)
            ).preparePCMProxy(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { snapshot }
            )
            Issue.record("mid-read source mutation yielded a proxy")
        } catch {
            #expect(error == .decode(.sourceChangedDuringDecode))
        }
    }

    @Test(arguments: ["missing", "relink", "revoked"])
    func proxyRefusesLateSourceOrAccessChange(_ scenario: String) async throws {
            let (directory, _, access, snapshot, episode, speaker) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var show = snapshot.show
            var records = snapshot.accessRecords
            switch scenario {
            case "missing": show.episodes[0].sources.removeAll()
            case "relink": records[0].lastKnownPath = directory.appendingPathComponent("other.wav").path
            case "revoked": records.removeAll()
            default: Issue.record("unknown fixture scenario"); return
            }
            let changed = PrimarySpeechInputState(
                show: show, showRevision: 2, accessRecords: records,
                sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision
            )
            let state = SpeechLateSnapshot(initial: snapshot, changed: changed)
            do {
                _ = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                    episodeID: episode, speakerID: speaker,
                    authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                    availability: .on, current: { await state.read() }
                )
                Issue.record("late source or access change yielded a proxy")
            } catch { #expect(error == .sourceRevisionChanged) }
    }

    @Test(arguments: [SpeechUnavailableIO.Failure.permission, .dataless])
    private func proxyRefusesUnreadableOrDatalessSource(_ failure: SpeechUnavailableIO.Failure) async throws {
            let (directory, url, _, snapshot, episode, speaker) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let access = SourceAccessContext(io: SpeechUnavailableIO(base: SpeechFixtureIO(url: url),
                                                                     failure: failure))
            do {
                _ = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                    episodeID: episode, speakerID: speaker,
                    authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                    availability: .on, current: { snapshot }
                )
                Issue.record("unreadable or dataless source yielded a proxy")
            } catch { #expect(error == .sourceIdentityNotConfirmed) }
    }

    @Test func absentConsentBackupUnknownChannelAndRevisionRefuseBeforeDecode() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = PrimarySpeechInputAdapter(access: access)
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        func denied(_ value: PrimarySpeechInputState, authorization: PrimarySpeechAuthorization? = grant)
            async -> SpeechAdmissionRefusal?
        {
            do {
                _ = try await adapter.prepare(episodeID: episode, speakerID: speaker,
                                              authorization: authorization, availability: .on, current: { value })
                return nil
            } catch { return error }
        }
        #expect(await denied(snapshot, authorization: nil) == .sourceIdentityNotConfirmed)
        #expect(await denied(snapshot, authorization: .explicitUserRequest(
            episodeID: episode, speakerID: SpeakerID()
        )) == .sourceIdentityNotConfirmed)
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .off, current: { snapshot })
            Issue.record("unavailable source was decoded")
        } catch {
            #expect(error == .sourceIdentityNotConfirmed)
        }
        var show = snapshot.show
        show.episodes[0].sources[0].role = .backup
        #expect(await denied(.init(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .primaryNotConfirmed)
        show = snapshot.show
        show.episodes[0].speakerAssignments[0].primary?.channel = .unknown
        #expect(await denied(.init(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .primaryNotConfirmed)
        show = snapshot.show
        show.episodes[0].sources[0].placement.channelLabels[0].channel = 0
        #expect(await denied(.init(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .primaryNotConfirmed)
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: nil, inputAssetRevision: snapshot.inputAssetRevision))
                == .sourceRevisionChanged)
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: nil))
                == .sourceRevisionChanged)
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: [],
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .sourceIdentityNotConfirmed)
        var alias = snapshot.accessRecords[0]
        alias.sourceID = SourceID()
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: snapshot.accessRecords + [alias],
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .sourceAliasOrChanged)
    }

    @Test func stalePrimaryAndAliasesDoNotPublishDecodedInput() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        let adapter = PrimarySpeechInputAdapter(access: access)
        let state = SpeechSnapshot(snapshot)
        var changed = snapshot.show
        changed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        await state.change(.init(show: changed, showRevision: 2, accessRecords: snapshot.accessRecords,
                                 sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .on, current: { await state.read() })
            Issue.record("stale primary was published")
        } catch {
            #expect(error == .sourceRevisionChanged)
        }
        let restored = SpeechSnapshot(snapshot)
        await restored.change(.init(show: snapshot.show, showRevision: 2, accessRecords: snapshot.accessRecords,
                                    sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .on, current: { await restored.read() })
            Issue.record("primary switched away and back was published")
        } catch {
            #expect(error == .sourceRevisionChanged)
        }
        let alias = directory.appendingPathComponent("hardlink.wav")
        try FileManager.default.linkItem(at: url, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .on, current: { snapshot })
            Issue.record("hardlinked source was published")
        } catch {
            #expect(error == .sourceAliasOrChanged)
        }
    }

    @Test(arguments: ["source-deleted", "source-relinked", "revision-changed", "access-revoked"])
    func finalStateCheckRefusesLateMutation(_ scenario: String) async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var show = snapshot.show
        var records = snapshot.accessRecords
        var revision = snapshot.showRevision
        switch scenario {
        case "source-deleted":
            show.episodes[0].sources.removeAll()
        case "source-relinked":
            records[0].lastKnownPath = directory.appendingPathComponent("other.wav").path
        case "revision-changed":
            revision = 2
        case "access-revoked":
            records.removeAll()
        default:
            Issue.record("unknown scenario")
            return
        }
        let changed = PrimarySpeechInputState(
            show: show, showRevision: revision, accessRecords: records,
            sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision
        )
        let state = SpeechLateSnapshot(initial: snapshot, changed: changed)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { await state.read() }
            )
            Issue.record("state changed during validation was published")
        } catch {
            #expect(error == .sourceRevisionChanged)
        }
        #expect(await state.calls == 3)
    }

    @Test func truncatedContainerCannotBecomeSpeechInput() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var damaged = wav()
        damaged[40] = 0xFF
        try damaged.write(to: url)
        guard case let .success(metadata) = access.io.metadata(at: url) else {
            Issue.record("source metadata unavailable")
            return
        }
        var record = snapshot.accessRecords[0]
        record.recordedIdentity = RecordedIdentity(fingerprint: metadata.fingerprint,
                                                   confirmation: .userConfirmed, recordedAt: Date())
        let current = PrimarySpeechInputState(
            show: snapshot.show, showRevision: 1, accessRecords: [record],
            sourceRevision: SourceRevision.metadata(snapshot.show.episodes[0].sources[0].id, fingerprint: metadata.fingerprint),
            inputAssetRevision: PrimarySpeechInputAdapter.inputAssetRevision
        )
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { current }
            )
            Issue.record("truncated source was published")
        } catch {
            guard case .decode = error else { Issue.record("unexpected refusal: \(error)"); return }
        }
    }

    @Test func pathSwapAndSymlinkedParentRefuse() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        let swapped = SpeechSwapSnapshot(snapshot, url: url)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { try await swapped.read() }
            )
            Issue.record("replaced path was published")
        } catch {
            #expect(error == .sourceAliasOrChanged)
        }
        let parent = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ww-speech-link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: parent) }
        var record = snapshot.accessRecords[0]
        record.lastKnownPath = parent.appendingPathComponent("old.wav").path
        let symlinked = PrimarySpeechInputState(show: snapshot.show, showRevision: 1, accessRecords: [record],
                                                 sourceRevision: snapshot.sourceRevision,
                                                 inputAssetRevision: snapshot.inputAssetRevision)
        do {
            _ = try await PrimarySpeechInputAdapter(access: SourceAccessContext(
                io: SpeechFixtureIO(url: parent.appendingPathComponent("old.wav"))
            )).prepare(episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                       current: { symlinked })
            Issue.record("symlinked parent was published")
        } catch {
            #expect(error == .sourceAliasOrChanged)
        }
    }

    private func mappedFixture(_ scenario: String = "continuous") throws
        -> (directory: URL, access: SourceAccessContext, state: PrimarySpeechInputState,
            episode: EpisodeID, speaker: SpeakerID, occurrence: SourceOccurrenceID, referenceURL: URL)
    {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        let duplicate = scenario == "duplicate"
        let gap = scenario == "gap"
        func time(_ frames: Int64) throws -> ExactRational {
            try ExactRational(numerator: Int128(frames), denominator: Int128(16_000))
        }
        func segment(_ start: Int64, _ end: Int64) throws -> AffineClockSegment {
            try AffineClockSegment(groupClockStart: time(start), groupClockEnd: time(end),
                                   rateRatio: .one, alignedOffset: .zero)
        }
        let rate = try NominalRate(16_000)
        let referenceSource = SourceRecord(displayNameHint: "reference")
        let referenceURL = directory.appendingPathComponent("reference.wav")
        try wav(channel0: 300).write(to: referenceURL)
        guard case let .success(referenceMetadata) = access.io.metadata(at: referenceURL),
              let sourceRevision = snapshot.sourceRevision
        else { throw SpeechAdmissionRefusal.sourceIdentityNotConfirmed }
        let reference = try SourceOccurrence(source: referenceSource.id, nominalRate: rate, frameCount: 64)
        let refGroup = RecorderGroupID(), refEpoch = RecordingEpochID()
        let timeline = TimelineReference(group: refGroup, epoch: refEpoch, occurrence: reference.id)
        let refMap = try GroupTimeMap(
            group: refGroup, reference: timeline,
            epochs: [EpochClockMap(epoch: refEpoch,
                                   mapping: .mapped(segments: [segment(0, 64)], provenance: .timelineReference))],
            placements: [OccurrencePlacement(
                occurrence: reference, spans: [EpochSpan(startFrame: 0, endFrame: 64,
                                                          epoch: refEpoch, groupClockOffset: .zero)]
            )]
        )
        let source = snapshot.show.episodes[0].sources[0].id
        let chosen = try SourceOccurrence(source: source, nominalRate: rate, frameCount: 64)
        let first = RecordingEpochID(), second = RecordingEpochID()
        let spans = gap
            ? [EpochSpan(startFrame: 0, endFrame: 20, epoch: first, groupClockOffset: .zero),
               EpochSpan(startFrame: 40, endFrame: 64, epoch: second, groupClockOffset: try time(24))]
            : [EpochSpan(startFrame: 0, endFrame: 64, epoch: first, groupClockOffset: .zero)]
        let mapped = MapProvenance.manual(ManualCorrection(basis: .numericEntry))
        let targetGroupID = RecorderGroupID()
        let target = try GroupTimeMap(
            group: targetGroupID, reference: timeline,
            epochs: [EpochClockMap(epoch: first, mapping: .mapped(segments: [segment(0, 64)],
                                                                   provenance: mapped))]
                + (gap ? [EpochClockMap(epoch: second,
                                       mapping: .mapped(segments: [segment(64, 128)], provenance: mapped))] : []),
            placements: [OccurrencePlacement(occurrence: chosen, spans: spans)]
                + (duplicate ? [OccurrencePlacement(
                    occurrence: try SourceOccurrence(source: source, nominalRate: rate, frameCount: 64), spans: spans
                )] : [])
        )
        let map = try AlignedTimelineMap(reference: timeline, groups: [refMap, target])
        let embedded = try JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map))
        var show = snapshot.show
        var referenced = referenceSource
        referenced.placement.recorderGroupID = refGroup
        referenced.placement.epochID = refEpoch
        show.episodes[0].sources.append(referenced)
        show.episodes[0].recorderGroups = [
            RecorderGroup(id: refGroup, name: "reference", epochs: [RecordingEpoch(id: refEpoch, label: "reference")]),
            RecorderGroup(id: targetGroupID, name: "selected", epochs:
                [RecordingEpoch(id: first, label: "selected")] +
                (gap ? [RecordingEpoch(id: second, label: "restart")] : []))
        ]
        show.episodes[0].sources[0].placement.recorderGroupID = targetGroupID
        show.episodes[0].sources[0].placement.epochID = first
        let referenceRevision = SourceRevision.metadata(referenceSource.id, fingerprint: referenceMetadata.fingerprint)
        let recipe = AlignmentPipeline.fixtureDependencyRecipe(map: map, revisions: [sourceRevision, referenceRevision])
        show.episodes[0].alignment = EpisodeAlignment(maps: [
            TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: [
                TimeMapSourceInput(sourceID: source, formatInterpretationVersion: FormatRevision.current.interpretationVersion),
                TimeMapSourceInput(sourceID: referenceSource.id, formatInterpretationVersion: FormatRevision.current.interpretationVersion)
            ], recipe: recipe), map: embedded)
        ], acceptedRevision: 1)
        let referenceRecord = DeviceAccessRecord(
            showID: show.show.id, sourceID: referenceSource.id, bookmark: Data(referenceURL.path.utf8),
            lastKnownPath: referenceURL.path,
            recordedIdentity: RecordedIdentity(fingerprint: referenceMetadata.fingerprint,
                                               confirmation: .userConfirmed, recordedAt: Date()),
            createdAt: Date()
        )
        let state = PrimarySpeechInputState(show: show, showRevision: 1,
                                            accessRecords: snapshot.accessRecords + [referenceRecord],
                                            sourceRevision: snapshot.sourceRevision,
                                            inputAssetRevision: snapshot.inputAssetRevision)
        return (directory, access, state, episode, speaker, chosen.id, referenceURL)
    }

    private func refusal(_ fixture: (directory: URL, access: SourceAccessContext, state: PrimarySpeechInputState,
                                     episode: EpisodeID, speaker: SpeakerID, occurrence: SourceOccurrenceID, referenceURL: URL))
        async -> SpeechAdmissionRefusal?
    {
        do {
            _ = try await PrimarySpeechInputAdapter(access: fixture.access).prepare(
                episodeID: fixture.episode, speakerID: fixture.speaker,
                authorization: .explicitUserRequest(episodeID: fixture.episode, speakerID: fixture.speaker),
                availability: .on, current: { fixture.state }
            )
            return nil
        } catch { return error }
    }

    @Test(arguments: ["continuous", "gap", "duplicate"])
    func callerMintedMapsCannotAuthorizeOccurrence(_ scenario: String) async throws {
        let fixture = try mappedFixture(scenario)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await refusal(fixture) == .occurrenceNotContinuous)
    }

    @Test(arguments: ["continuous", "gap", "duplicate"])
    func repeatedOrMappedPlacementsCannotProducePCMProxy(_ scenario: String) async throws {
        let fixture = try mappedFixture(scenario)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await PrimarySpeechInputAdapter(access: fixture.access).preparePCMProxy(
                episodeID: fixture.episode, speakerID: fixture.speaker,
                authorization: .explicitUserRequest(episodeID: fixture.episode, speakerID: fixture.speaker),
                availability: .on, current: { fixture.state }
            )
            Issue.record("mapped or repeated placement yielded a proxy")
        } catch { #expect(error == .occurrenceNotContinuous) }
    }

    @Test(arguments: ["continuous", "gap", "duplicate"])
    func mappedOccurrencesCannotReachSealedWorker(_ scenario: String) async throws {
        let item = try mappedFixture(scenario)
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let stub = item.directory.appendingPathComponent("stub")
        try Data("abc".utf8).write(to: stub)
        let pin = LocalSpeechAssetPin(
            name: "synthetic-stub", version: "1", sizeBytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            license: "synthetic", source: "fixture")
        do {
            _ = try await PrimarySpeechInputAdapter(access: item.access).withSealedSyntheticWorkerInput(
                episodeID: item.episode, speakerID: item.speaker,
                authorization: .explicitUserRequest(episodeID: item.episode, speakerID: item.speaker),
                availability: .on, current: { item.state }, workerURL: stub, workerPin: pin
            ) { _ in Issue.record("mapped occurrence reached worker"); return 0 }
            Issue.record("mapped occurrence was admitted")
        } catch { #expect(error == .occurrenceNotContinuous) }
    }

    @Test func backupAndOfflineSourcesCannotProducePCMProxy() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        var show = snapshot.show
        show.episodes[0].sources[0].role = .backup
        let backup = PrimarySpeechInputState(
            show: show, showRevision: snapshot.showRevision, accessRecords: snapshot.accessRecords,
            sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision
        )
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { backup }
            )
            Issue.record("backup yielded a proxy")
        } catch { #expect(error == .primaryNotConfirmed) }
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).preparePCMProxy(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .off,
                current: { snapshot }
            )
            Issue.record("offline source yielded a proxy")
        } catch { #expect(error == .sourceIdentityNotConfirmed) }
    }

    @Test func mappedRefusalPrecedesDecode() async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let selected = fixture.directory.appendingPathComponent("source.wav")
        try Data(repeating: 0, count: 300).write(to: selected)
        #expect(await refusal(fixture) == .occurrenceNotContinuous)
    }

    @Test func unacceptedMapCannotBecomeAnUnmappedInput() async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var show = fixture.state.show
        show.episodes[0].alignment?.acceptedRevision = nil
        let state = PrimarySpeechInputState(
            show: show, showRevision: 2, accessRecords: fixture.state.accessRecords,
            sourceRevision: fixture.state.sourceRevision, inputAssetRevision: fixture.state.inputAssetRevision
        )
        #expect(await refusal((fixture.directory, fixture.access, state, fixture.episode, fixture.speaker,
                               fixture.occurrence, fixture.referenceURL)) == .occurrenceNotContinuous)
    }

    @Test(arguments: ["reference", "selected-primary"])
    func sameInodeSameLengthRewriteCannotAuthorizeMappedInput(_ source: String) async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let url = source == "reference" ? fixture.referenceURL
            : fixture.directory.appendingPathComponent("source.wav")
        let original = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = original[.modificationDate] as? Date,
              let inode = original[.systemFileNumber] as? NSNumber,
              case let .success(before) = fixture.access.io.metadata(at: url)
        else { Issue.record("source metadata unavailable"); return }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: wav(channel0: 800, channel1: -400))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let rewritten = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let rewrittenInode = rewritten[.systemFileNumber] as? NSNumber,
              case let .success(after) = fixture.access.io.metadata(at: url)
        else { Issue.record("rewritten source metadata unavailable"); return }
        #expect(inode == rewrittenInode)
        #expect(original[.size] as? NSNumber == rewritten[.size] as? NSNumber)
        #expect(before.fingerprint.compare(to: after.fingerprint) == .matches)
        #expect(await refusal(fixture) == .occurrenceNotContinuous)
    }

    @Test func confirmedSameLengthReferenceRelinkCannotAuthorizeMappedInput() async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let relinkedURL = fixture.directory.appendingPathComponent("relinked.wav")
        try wav(channel0: 500).write(to: relinkedURL)
        guard case let .success(metadata) = fixture.access.io.metadata(at: relinkedURL) else {
            Issue.record("relinked metadata unavailable")
            return
        }
        var records = fixture.state.accessRecords
        records[1].bookmark = Data(relinkedURL.path.utf8)
        records[1].lastKnownPath = relinkedURL.path
        records[1].recordedIdentity = RecordedIdentity(fingerprint: metadata.fingerprint,
                                                       confirmation: .userConfirmed, recordedAt: Date())
        let state = PrimarySpeechInputState(show: fixture.state.show, showRevision: 2, accessRecords: records,
                                            sourceRevision: fixture.state.sourceRevision,
                                            inputAssetRevision: fixture.state.inputAssetRevision)
        #expect(await refusal((fixture.directory, fixture.access, state, fixture.episode, fixture.speaker,
                               fixture.occurrence, fixture.referenceURL)) == .occurrenceNotContinuous)
    }

    @Test func confirmedSameLengthPrimaryRelinkCannotAuthorizeMappedInput() async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let relinkedURL = fixture.directory.appendingPathComponent("primary-relinked.wav")
        try wav(channel1: -400).write(to: relinkedURL)
        guard case let .success(metadata) = fixture.access.io.metadata(at: relinkedURL) else {
            Issue.record("relinked metadata unavailable")
            return
        }
        var records = fixture.state.accessRecords
        records[0].bookmark = Data(relinkedURL.path.utf8)
        records[0].lastKnownPath = relinkedURL.path
        records[0].recordedIdentity = RecordedIdentity(fingerprint: metadata.fingerprint,
                                                       confirmation: .userConfirmed, recordedAt: Date())
        let state = PrimarySpeechInputState(
            show: fixture.state.show, showRevision: 2, accessRecords: records,
            sourceRevision: SourceRevision.metadata(records[0].sourceID, fingerprint: metadata.fingerprint),
            inputAssetRevision: fixture.state.inputAssetRevision
        )
        #expect(await refusal((fixture.directory, fixture.access, state, fixture.episode, fixture.speaker,
                               fixture.occurrence, fixture.referenceURL)) == .occurrenceNotContinuous)
    }

    @Test func deletedReferencedSourceCannotAuthorizeMappedInput() async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var show = fixture.state.show
        show.episodes[0].sources.removeLast()
        let state = PrimarySpeechInputState(show: show, showRevision: 2, accessRecords: Array(fixture.state.accessRecords.prefix(1)),
                                            sourceRevision: fixture.state.sourceRevision,
                                            inputAssetRevision: fixture.state.inputAssetRevision)
        #expect(await refusal((fixture.directory, fixture.access, state, fixture.episode, fixture.speaker,
                               fixture.occurrence, fixture.referenceURL)) == .occurrenceNotContinuous)
    }

    @Test func missingReferencedFileCannotAuthorizeMappedInput() async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.referenceURL)
        #expect(await refusal(fixture) == .occurrenceNotContinuous)
    }

    @Test(arguments: ["missing-input", "stale-format", "unverified-content-digest", "stale-recipe",
                      "duplicate-revision", "missing-revision", "reordered-revision"])
    func callerAuthoredMapVariationsRemainRefused(_ scenario: String) async throws {
        let fixture = try mappedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var show = fixture.state.show
        switch scenario {
        case "missing-input":
            show.episodes[0].alignment!.maps[0].inputs.sources.removeLast()
        case "stale-format":
            show.episodes[0].alignment!.maps[0].inputs.sources[0].formatInterpretationVersion = 0
        case "unverified-content-digest":
            show.episodes[0].alignment!.maps[0].inputs.sources[0].contentDigest = "unverified"
        case "stale-recipe":
            show.episodes[0].alignment!.maps[0].inputs.recipe = RecipeReference(name: "stale", revision: 2)
        case "duplicate-revision":
            show.episodes[0].alignment!.maps.append(show.episodes[0].alignment!.maps[0])
        case "missing-revision":
            show.episodes[0].alignment!.acceptedRevision = 2
        case "reordered-revision":
            var older = show.episodes[0].alignment!.maps[0]
            older.revision = 0
            show.episodes[0].alignment!.maps.append(older)
        default:
            Issue.record("unknown scenario")
            return
        }
        let state = PrimarySpeechInputState(show: show, showRevision: 2, accessRecords: fixture.state.accessRecords,
                                            sourceRevision: fixture.state.sourceRevision,
                                            inputAssetRevision: fixture.state.inputAssetRevision)
        #expect(await refusal((fixture.directory, fixture.access, state, fixture.episode, fixture.speaker,
                               fixture.occurrence, fixture.referenceURL)) == .occurrenceNotContinuous)
    }
}
