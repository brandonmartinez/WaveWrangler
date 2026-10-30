import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
@testable import WWEpisodeSetup

@MainActor @Suite("Scoped pending audio imports", .serialized)
struct PendingSourceImportTests {
    private struct Fixture {
        let root: URL
        let file: URL
        let store: InMemoryDeviceAccessStore
        let engine: WWSourcesSetupEngine
        func close() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-pending-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("synthetic.wav")
        try Data(repeating: 3, count: 96).write(to: file)
        let context = SourceAccessContext(io: SystemSourceIO()), store = InMemoryDeviceAccessStore()
        let engine = WWSourcesSetupEngine(showID: ShowID(), store: store, context: context,
            preference: FixedPreference(false), captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        return .init(root: root, file: file, store: store, engine: engine)
    }
    private func prepare(_ f: Fixture) async throws -> (ImportScan, PendingSourceImport) {
        let scan = try await f.engine.scanForImport([f.file], episodeSourceIDs: [])
        let candidate = try #require(scan.candidates.first)
        return (scan, try await f.engine.preparePendingImport(candidate: candidate.id, fromScan: scan.token))
    }

    @Test func reviewIsMetadataOnlyAndExplicitPreparationDoesNotPublishAccess() async throws {
        let f = try fixture()
        let bytes = try Data(contentsOf: f.file)
        let (scan, token) = try await prepare(f)
        #expect(await f.store.allRecords().isEmpty)
        let read = try await f.engine.validatePendingImport(token)
        #expect(read.source.id == token.source && read.witness.isUsable)
        #expect(try Data(contentsOf: f.file) == bytes)
        await f.engine.discardScan(scan.token)
        await #expect(throws: (any Error).self) { try await f.engine.validatePendingImport(token) }
        #expect(await f.store.allRecords().isEmpty)
        await f.close()
    }

    @Test func tokensAreEngineBoundConsumedOnceAndShutdownRevokesThem() async throws {
        let f = try fixture(), other = try fixture()
        let (_, token) = try await prepare(f)
        await #expect(throws: (any Error).self) { try await other.engine.validatePendingImport(token) }
        f.engine.activeSourceIDs = { [token] in [token.source] }
        try await f.engine.adoptPendingImports([token], validatingPublication: {})
        #expect(await f.store.allRecords().map(\.sourceID) == [token.source])
        await #expect(throws: (any Error).self) { try await f.engine.adoptPendingImports([token], validatingPublication: {}) }
        let (_, second) = try await prepare(other)
        await other.engine.shutdown()
        await #expect(throws: (any Error).self) { try await other.engine.validatePendingImport(second) }
        await f.close(); await other.close()
    }

    @Test func changedOriginalDiscardCancellationAndPartialBatchFailureNeverPublish() async throws {
        let f = try fixture()
        let (_, token) = try await prepare(f)
        try Data(repeating: 5, count: 100).write(to: f.file)
        await #expect(throws: (any Error).self) { try await f.engine.validatePendingImport(token) }
        await #expect(throws: (any Error).self) { try await f.engine.adoptPendingImports([token], validatingPublication: {}) }
        #expect(await f.store.allRecords().isEmpty)
        f.engine.discardPendingImport(token)
        let (_, next) = try await prepare(f)
        let task = Task {
            try Task.checkCancellation()
            return try await f.engine.validatePendingImport(next)
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        f.engine.discardPendingImport(next)
        #expect(await f.store.allRecords().isEmpty)
        await f.close()
    }

    @Test func stalePublicationAfterInsertCleansOnlyOwnedAccessAndNeverRetriesToken() async throws {
        let f = try fixture()
        let (_, token) = try await prepare(f)
        f.engine.activeSourceIDs = { [token] in [token.source] }
        var checks = 0
        await #expect(throws: (any Error).self) {
            try await f.engine.adoptPendingImports([token]) {
                checks += 1
                if checks == 4 { throw SourceEngineError.failed(reason: "destination restored") }
            }
        }
        #expect(checks == 4)
        #expect(await f.store.allRecords().isEmpty)
        await #expect(throws: (any Error).self) { try await f.engine.adoptPendingImports([token], validatingPublication: {}) }
        await f.close()
    }

    @Test func revokedThenRegrantedPendingSourceCannotOverwriteTheNewGrant() async throws {
        let f = try fixture()
        let (_, token) = try await prepare(f)
        let record = DeviceAccessRecord(showID: f.engine.showID, sourceID: token.source, createdAt: Date())
        await f.store.save(record)
        await f.store.removeRecord(for: record.key)
        await f.store.save(record)
        await #expect(throws: (any Error).self) { try await f.engine.validatePendingImport(token) }
        #expect(await f.store.record(for: record.key) == record)
        await f.close()
    }

    @Test func explicitStereoWAVFixtureCarriesQualifiedLeftRightLayout() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let frames = 441, rate = 44_100
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(60 + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(40)); append(UInt16(0xfffe)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
        append(UInt16(22)); append(UInt16(16)); append(UInt32(3))
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
        data.append(contentsOf: "data".utf8); append(UInt32(frames * 4))
        data.append(Data(repeating: 0, count: frames * 4))
        try data.write(to: f.file)
        let format = try await SourceDecoder(access: .init(io: SystemSourceIO()))
            .withDecodingCursor(f.file, source: SourceID()) { $0.interpretation }
        #expect(format.channelLayout.channelLabels == [1, 2])
        #expect(format.sourceSampleRate == rate && format.frames.validFrames == frames)
        await f.engine.shutdown()
    }
}
