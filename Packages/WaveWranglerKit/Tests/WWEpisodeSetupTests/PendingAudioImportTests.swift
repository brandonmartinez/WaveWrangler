import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
@testable import WWEpisodeSetup

@MainActor @Suite("Verified supplemental audio reuse", .serialized)
struct PendingAudioImportTests {
    @MainActor private final class Fixture {
        let root: URL
        let file: URL
        let store: InMemoryDeviceAccessStore
        let ledger: InterceptingAudioLedger
        let engine: WWSourcesSetupEngine
        var model: ShowDocumentModel
        var generation = 0
        var expectedGeneration = 0

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-f6-reuse-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("synthetic.wav")
            try PendingAudioImportTests.wave().write(to: file)
            model = ShowDocumentModel(show: Show(title: "Synthetic reuse"),
                episodes: [Episode(title: "First"), Episode(title: "Second"), Episode(title: "Third")])
            store = InMemoryDeviceAccessStore()
            ledger = InterceptingAudioLedger(base: store)
            let context = SourceAccessContext(io: SystemSourceIO())
            engine = WWSourcesSetupEngine(showID: model.show.id, store: ledger, context: context,
                preference: FixedPreference(false), captureRawIdentity: { url, fingerprint in
                    try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
                })
            engine.activeSourceIDs = { [weak self] in self.map { Set($0.model.episodes.flatMap(\.sources).map(\.id)) } }
        }

        func scan(_ files: [URL]? = nil, episode index: Int = 0) async throws -> AudioImportScan {
            expectedGeneration = generation
            return try await engine.scanForAudioImport(files ?? [file], in: model.episodes[index].id) { [self] in
                guard generation == expectedGeneration else { throw SourceEngineError.failed(reason: "stale generation") }
                return model
            }
        }

        func publish(_ tokens: [PendingAudioImport], episode index: Int = 0) async throws {
            let episode = model.episodes[index]
            var sources = episode.sources, arrangement = episode.audioArrangement ?? AudioArrangement()
            let track = arrangement.tracks.first ?? AudioTrack(name: "Audio")
            if arrangement.tracks.isEmpty { arrangement.tracks.append(track) }
            for token in tokens {
                let read = try await engine.validatePendingAudioImport(token)
                let asset = read.existingAsset ?? AudioAsset(source: token.source, frameCount: 480,
                                                            sampleRate: 48_000, channelCount: 1)
                if token.addsSource {
                    var source = read.source
                    source.purpose = .supplementalAudio
                    source.observations = .init(durationSeconds: .known(Double(asset.frameCount) / Double(asset.sampleRate)),
                        channelCount: .known(asset.channelCount), sampleRate: .known(Double(asset.sampleRate)))
                    sources.append(source)
                    arrangement.assets.append(asset)
                }
                arrangement.clips.append(.init(track: track.id, source: token.source,
                    trim: .init(startFrame: 0, endFrame: asset.frameCount), anchor: .programOrigin(frame: 0)))
            }
            model = try model.settingAudioState(arrangement, mix: episode.mix, sources: sources, in: episode.id)
            generation += 1
            expectedGeneration = generation
        }

        func add(episode index: Int = 0) async throws -> SourceID {
            let scan = try await scan(episode: index)
            let token = try await engine.preparePendingAudioImport(
                candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token)
            try await publish([token], episode: index)
            try await engine.adoptPendingAudioImports([token]) { [self] in model }
            await engine.discardScan(scan.scan.token)
            return token.source
        }

        func close() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func newReuseCopyAndDestinationPreferenceNeverDuplicateAnEpisodeAsset() async throws {
        let f = try Fixture()
        let bytes = try Data(contentsOf: f.file)
        let first = try await f.add()
        let originalRecord = try #require(await f.store.record(for: .init(showID: f.model.show.id, sourceID: first)))
        let scan = try await f.scan()
        let id = try #require(scan.scan.candidates.first?.id)
        #expect(scan.choices[id] == .reuse(source: first))
        let reuse = try await f.engine.preparePendingAudioImport(candidate: id, fromScan: scan.scan.token)
        #expect(!reuse.addsSource && reuse.source == first && reuse.disposition == .reuse(source: first))
        try await f.publish([reuse])
        try await f.engine.adoptPendingAudioImports([reuse]) { f.model }
        #expect(await f.store.allRecords().count == 1)
        #expect(f.model.episodes[0].sources.count == 1)
        #expect(f.model.episodes[0].audioArrangement?.clips.map(\.source) == [first, first])
        await #expect(throws: (any Error).self) { try await f.engine.validatePendingAudioImport(reuse) }
        let second = try await f.add(episode: 1)
        #expect(second != first)
        #expect(await f.store.allRecords().count == 2)
        #expect(await f.store.record(for: originalRecord.key) == originalRecord)
        let preferred = try await f.scan(episode: 1)
        let candidate = try #require(preferred.scan.candidates.first?.id)
        #expect(preferred.choices[candidate] == .reuse(source: second),
                "The first physical match can belong to another episode.")
        let thirdScan = try await f.scan(episode: 2)
        guard case .copy = thirdScan.choices[try #require(thirdScan.scan.candidates.first?.id)] else {
            Issue.record("Another episode must explicitly review an episode-owned copy, not reuse its logical ID.")
            await f.close()
            return
        }
        #expect(try Data(contentsOf: f.file) == bytes)
        await f.close()
    }

    @Test func mixedNewReuseAndCopyAdoptOnlyNewOwnedRecords() async throws {
        let f = try Fixture()
        let copied = try await f.add(episode: 1)
        let other = f.root.appendingPathComponent("other.wav")
        try Self.wave(value: 4).write(to: other)
        let localScan = try await f.scan([other])
        let local = try await f.engine.preparePendingAudioImport(
            candidate: #require(localScan.scan.candidates.first).id, fromScan: localScan.scan.token)
        try await f.publish([local])
        try await f.engine.adoptPendingAudioImports([local]) { f.model }
        let fresh = f.root.appendingPathComponent("fresh.wav")
        try Self.wave(value: 5).write(to: fresh)
        let batch = try await f.scan([other, fresh, f.file])
        let tokens = try await prepare(batch, engine: f.engine)
        #expect(tokens.map(\.addsSource) == [false, true, true])
        #expect(tokens[0].source == local.source && tokens[2].source != copied)
        try await f.publish(tokens)
        try await f.engine.adoptPendingAudioImports(tokens) { f.model }
        #expect(await f.store.allRecords().count == 4)
        #expect(f.model.episodes[0].sources.count == 3)
        #expect(f.model.episodes[0].audioArrangement?.clips.count == 4)
        await f.close()
    }

    @Test func recordingAmongEveryPhysicalMatchBlocksEvenWithDestinationAsset() async throws {
        let f = try Fixture()
        let first = try await f.add()
        _ = try await f.add(episode: 1)
        let original = try #require(await f.store.record(for: .init(showID: f.model.show.id, sourceID: first)))
        let recording = SourceRecord(displayNameHint: "recording.wav")
        f.model.episodes[2].sources.append(recording)
        var record = original
        record.sourceID = recording.id
        await f.store.save(record)
        let scan = try await f.scan(episode: 1)
        guard case .blocked = scan.choices[try #require(scan.scan.candidates.first?.id)] else {
            Issue.record("A recording match must block every supplemental exception.")
            await f.close()
            return
        }
        await #expect(throws: (any Error).self) { try await f.engine.preparePendingAudioImport(
            candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token) }
        f.model.episodes[2].sources = []
        let withoutInactiveBlocker = try await f.scan(episode: 1)
        #expect(withoutInactiveBlocker.choices.values.allSatisfy { $0.canImport })
        await f.close()
    }

    @Test func provisionalMissingGeometryAndChangedOriginalRequireRepair() async throws {
        for scenario in 0..<4 {
            let f = try Fixture()
            let id = try await f.add()
            let key = DeviceAccessKey(showID: f.model.show.id, sourceID: id)
            if scenario == 0 {
                var record = try #require(await f.store.record(for: key))
                record.recordedIdentity?.confirmation = .provisional
                await f.store.save(record)
            } else if scenario == 1 {
                f.model.episodes[0].audioArrangement?.assets = []
            } else if scenario == 2 {
                try Self.wave(value: 9).write(to: f.file)
            } else {
                var record = try #require(await f.store.record(for: key))
                record.bookmark = nil
                await f.store.save(record)
            }
            let scan = try await f.scan()
            await #expect(throws: (any Error).self) { try await f.engine.preparePendingAudioImport(
                candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token) }
            #expect(await f.store.allRecords().count == 1)
            await f.close()
        }
    }

    @Test func accessABAStaleCanonicalAndClosedScanRevokeReuseAuthority() async throws {
        for scenario in 0..<4 {
            let f = try Fixture()
            let id = try await f.add()
            let scan = try await f.scan()
            let token = try await f.engine.preparePendingAudioImport(
                candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token)
            if scenario == 0 {
                let key = DeviceAccessKey(showID: f.model.show.id, sourceID: id)
                let record = try #require(await f.store.record(for: key))
                await f.store.removeRecord(for: key)
                await f.store.save(record)
            } else if scenario == 1 {
                f.generation += 2
            } else if scenario == 2 {
                await f.engine.discardScan(scan.scan.token)
            } else {
                await f.engine.shutdown()
            }
            await #expect(throws: (any Error).self) { try await f.engine.validatePendingAudioImport(token) }
            #expect(await f.store.allRecords().count == 1)
            await f.close()
        }
    }

    @Test func postpublicationStalenessPreservesOriginalAndCleansOnlyCopiedGrant() async throws {
        let f = try Fixture()
        let original = try await f.add()
        let scan = try await f.scan(episode: 1)
        let tokens = try await prepare(scan, engine: f.engine)
        try await f.publish(tokens, episode: 1)
        let publication = f.model
        var changed = false
        await #expect(throws: (any Error).self) {
            try await f.engine.adoptPendingAudioImports(tokens) {
                if !changed {
                    changed = true
                    return publication
                }
                throw SourceEngineError.failed(reason: "restored destination")
            }
        }
        #expect(await f.store.allRecords().map(\.sourceID) == [original])
        #expect(f.model.episodes[1].sources.count == 1, "Postpublication failure leaves an explicit blocked reference.")
        await f.close()
    }

    @Test func foldersSymlinksRemoteAndNonAudioAreExplicitMetadataOnlySkips() async throws {
        let f = try Fixture()
        let folder = f.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.wave().write(to: folder.appendingPathComponent("must-not-enumerate.wav"))
        let link = f.root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
        let text = f.root.appendingPathComponent("not-audio.txt")
        try Data("Synthetic text".utf8).write(to: text)
        let scan = try await f.scan([folder, link, text, #require(URL(string: "https://example.invalid/audio.wav"))])
        #expect(scan.scan.candidates.isEmpty)
        #expect(scan.scan.uncountedSkips.folders == 1 && scan.scan.uncountedSkips.symbolicLinks == 1)
        #expect(scan.scan.uncountedSkips.notRecordings == 2)
        #expect(await f.store.allRecords().isEmpty)
        await f.close()
    }

    @Test func failingLedgerAndPartialCanonicalRosterNeverBecomeNewImportAuthority() async throws {
        let f = try Fixture()
        let failing = WWSourcesSetupEngine(showID: f.model.show.id, store: FailingAudioLedger())
        await #expect(throws: (any Error).self) {
            try await failing.scanForAudioImport([f.file], in: f.model.episodes[0].id) { f.model }
        }
        await failing.shutdown()
        f.model.episodes[1].sources.append(.init(displayNameHint: "unavailable.wav", purpose: .supplementalAudio))
        let partial = try await f.scan()
        let candidate = try #require(partial.scan.candidates.first)
        #expect(partial.choices[candidate.id]?.canImport == false)
        await #expect(throws: (any Error).self) {
            try await f.engine.preparePendingAudioImport(candidate: candidate.id, fromScan: partial.scan.token)
        }
        #expect(await f.store.allRecords().isEmpty)
        await f.close()
    }

    @Test func concurrentCanonicalRecordingImportInvalidatesTheAudioReview() async throws {
        let f = try Fixture()
        _ = try await f.add()
        let scan = try await f.scan(episode: 1)
        f.model.episodes[2].sources.append(.init(displayNameHint: "concurrent recording"))
        await #expect(throws: (any Error).self) {
            try await f.engine.preparePendingAudioImport(
                candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token)
        }
        #expect(await f.store.allRecords().count == 1)
        await f.close()
    }

    @Test func partialLegacyActiveHintCannotHideAnActiveRecordingRelink() async throws {
        let f = try Fixture()
        let original = try await f.add()
        let source = SourceRecord(displayNameHint: "active recording")
        var access = try #require(await f.store.record(for: .init(showID: f.model.show.id, sourceID: original)))
        f.model.episodes[0].sources = [source]
        f.model.episodes[0].audioArrangement = nil
        access.sourceID = source.id
        await f.store.save(access)
        let fresh = f.root.appendingPathComponent("fresh.wav")
        try Self.wave(value: 6).write(to: fresh)
        let scan = try await f.scan([fresh], episode: 1)
        #expect(scan.choices.values.first == .newSource)
        let plan = try await SourceImporter(context: .init(io: SystemSourceIO()))
            .plan(selection: [fresh], showID: f.model.show.id)
        let changed = try #require(plan.items.first?.accessRecord)
        access.bookmark = changed.bookmark
        access.lastKnownPath = changed.lastKnownPath
        access.recordedIdentity = changed.recordedIdentity
        await f.store.save(access)
        f.engine.activeSourceIDs = { [] }
        await #expect(throws: (any Error).self) {
            try await f.engine.preparePendingAudioImport(
                candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token)
        }
        #expect(f.model.episodes[1].sources.isEmpty)
        await f.close()
    }

    @Test func persistentIdentitySurvivesMountFieldsButNeverContentChanges() async throws {
        let f = try Fixture()
        let id = try await f.add()
        let key = DeviceAccessKey(showID: f.model.show.id, sourceID: id)
        var record = try #require(await f.store.record(for: key))
        let raw = try #require(record.recordedIdentity?.rawWitness)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
        object["device"] = raw.device + 1
        object["fileSystemID0"] = (raw.fileSystemID0 ?? 0) + 1
        record.recordedIdentity?.rawWitness = try JSONDecoder().decode(RawSourceIdentity.self,
            from: JSONSerialization.data(withJSONObject: object))
        await f.store.save(record)
        let scan = try await f.scan()
        let token = try await f.engine.preparePendingAudioImport(
            candidate: #require(scan.scan.candidates.first).id, fromScan: scan.scan.token)
        let read = try await f.engine.validatePendingAudioImport(token)
        #expect(read.witness == raw)
        #expect(read.witness != record.recordedIdentity?.rawWitness)
        try Self.wave(value: 22).write(to: f.file)
        await #expect(throws: (any Error).self) { try await f.engine.validatePendingAudioImport(token) }
        await f.close()
    }

    @Test func stalenessAfterActualInsertionRemovesOnlyTheOwnedCopy() async throws {
        let f = try Fixture()
        let original = try await f.add()
        let scan = try await f.scan(episode: 1)
        let tokens = try await prepare(scan, engine: f.engine)
        try await f.publish(tokens, episode: 1)
        let publication = f.model
        await f.ledger.afterInsert { @MainActor in f.generation += 1 }
        await #expect(throws: (any Error).self) {
            try await f.engine.adoptPendingAudioImports(tokens) {
                guard f.generation == f.expectedGeneration else { throw SourceEngineError.failed(reason: "restored") }
                return f.model
            }
        }
        #expect(await f.store.allRecords().map(\.sourceID) == [original])
        #expect(f.model == publication, "No canonical rollback occurs after publication.")
        await f.close()
    }

    @Test func laterRegrantOfCopiedRecordIsNeverRemovedByFailedAdoption() async throws {
        let f = try Fixture()
        let original = try await f.add()
        let scan = try await f.scan(episode: 1)
        let tokens = try await prepare(scan, engine: f.engine)
        try await f.publish(tokens, episode: 1)
        let copy = try #require(tokens.first)
        let base = f.store, show = f.model.show.id
        await f.ledger.afterInsert {
            let key = DeviceAccessKey(showID: show, sourceID: copy.source)
            if var record = await base.record(for: key) {
                record.lastKnownPath = "/synthetic/later-regrant"
                await base.save(record)
            }
        }
        await #expect(throws: (any Error).self) {
            try await f.engine.adoptPendingAudioImports(tokens) { f.model }
        }
        #expect(await f.store.allRecords().count == 2)
        #expect(await f.store.record(for: .init(showID: show, sourceID: original)) != nil)
        #expect(await f.store.record(for: .init(showID: show, sourceID: copy.source))?.lastKnownPath == "/synthetic/later-regrant")
        await f.close()
    }

    @Test func remoteCloudAndUnknownLocalityNeverCaptureContentOrRequestDownloads() async throws {
        let f = try Fixture()
        for mode in AudioLocalityIO.Mode.allCases {
            let io = AudioLocalityIO(mode: mode), context = SourceAccessContext(io: io)
            let engine = WWSourcesSetupEngine(showID: f.model.show.id, store: f.store, context: context,
                captureRawIdentity: { _, _ in
                    Issue.record("Metadata-only locality refusal must not enter the content gateway.")
                    throw SourceEngineError.failed(reason: "unexpected content capture")
                })
            let scan = try await engine.scanForAudioImport([f.file], in: f.model.episodes[0].id) { f.model }
            let candidate = try #require(scan.scan.candidates.first)
            #expect(scan.choices[candidate.id]?.canImport == false)
            await #expect(throws: (any Error).self) {
                try await engine.preparePendingAudioImport(candidate: candidate.id, fromScan: scan.scan.token)
            }
            #expect(io.downloads == 0 && io.listings == 0)
            await engine.shutdown()
        }
        await f.close()
    }

    private func prepare(_ scan: AudioImportScan, engine: WWSourcesSetupEngine) async throws -> [PendingAudioImport] {
        var result: [PendingAudioImport] = []
        for candidate in scan.scan.candidates {
            result.append(try await engine.preparePendingAudioImport(candidate: candidate.id, fromScan: scan.scan.token))
        }

        return result
    }

    private static func wave(value: Int16 = 3) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + 960))
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(48_000)); put(UInt32(96_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(UInt32(960))
        for _ in 0..<480 { put(value) }
        return data
    }
}

private actor FailingAudioLedger: DeviceAccessSnapshotStore {
    private func failure() -> SourceEngineError { .failed(reason: "synthetic ledger schema/read failure") }
    func record(for key: DeviceAccessKey) throws -> DeviceAccessRecord? { throw failure() }
    func records(in showID: ShowID) throws -> [DeviceAccessRecord] { throw failure() }
    func allRecords() throws -> [DeviceAccessRecord] { throw failure() }
    func snapshot(for key: DeviceAccessKey) throws -> DeviceAccessSnapshot? { throw failure() }
    func save(_ record: DeviceAccessRecord) throws { throw failure() }
    func save(_ records: [DeviceAccessRecord]) throws { throw failure() }
    func removeRecord(for key: DeviceAccessKey) throws { throw failure() }
    func removeRecords(in showID: ShowID) throws { throw failure() }
}

private actor InterceptingAudioLedger: DeviceAccessImportStore {
    let base: InMemoryDeviceAccessStore
    private var hook: (@Sendable () async -> Void)?
    init(base: InMemoryDeviceAccessStore) { self.base = base }
    func afterInsert(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }
    func record(for key: DeviceAccessKey) async -> DeviceAccessRecord? { await base.record(for: key) }
    func records(in showID: ShowID) async -> [DeviceAccessRecord] { await base.records(in: showID) }
    func allRecords() async -> [DeviceAccessRecord] { await base.allRecords() }
    func snapshot(for key: DeviceAccessKey) async -> DeviceAccessSnapshot? { await base.snapshot(for: key) }
    func save(_ record: DeviceAccessRecord) async { await base.save(record) }
    func save(_ records: [DeviceAccessRecord]) async { await base.save(records) }
    func removeRecord(for key: DeviceAccessKey) async { await base.removeRecord(for: key) }
    func removeRecords(in showID: ShowID) async { await base.removeRecords(in: showID) }
    func insertNew(_ records: [DeviceAccessRecord]) async throws -> [DeviceAccessSnapshot] {
        let inserted = try await base.insertNew(records)
        await hook?()
        return inserted
    }
    func discardImported(_ snapshots: [DeviceAccessSnapshot]) async -> [DeviceAccessKey] {
        await base.discardImported(snapshots)
    }
}

private final class AudioLocalityIO: SourceIO, @unchecked Sendable {
    enum Mode: CaseIterable { case remote, cloud, unknown }
    let mode: Mode
    private let base = SystemSourceIO()
    private let lock = NSLock()
    private var counts = (downloads: 0, listings: 0)
    init(mode: Mode) { self.mode = mode }
    var downloads: Int { lock.withLock { counts.downloads } }
    var listings: Int { lock.withLock { counts.listings } }
    var provenance: ObservationProvenance { base.provenance }
    func metadata(at url: URL) -> MetadataResult {
        guard case var .success(value) = base.metadata(at: url) else { return base.metadata(at: url) }
        switch mode {
        case .remote: value.volumeIsLocal = .known(false)
        case .cloud: value.isDataless = .known(true)
        case .unknown: value.volumeIsLocal = .unknown
        }
        return .success(value)
    }
    func listItems(under directory: URL) -> DirectoryListing {
        lock.withLock { counts.listings += 1 }
        return base.listItems(under: directory)
    }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { try base.makeReadOnlyBookmark(for: url) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { base.resolveBookmark(data) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { base.startAccessingSecurityScope(url) }
    func stopAccessingSecurityScope(_ url: URL) { base.stopAccessingSecurityScope(url) }
    func requestDownload(of url: URL) throws { lock.withLock { counts.downloads += 1 } }
    func downloadFraction(of url: URL) async -> Knowledge<Double> { .unknown }
}
