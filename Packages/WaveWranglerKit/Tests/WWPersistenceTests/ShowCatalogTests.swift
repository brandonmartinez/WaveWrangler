import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Indexed show catalogs", .serialized)
struct ShowCatalogTests {
    let coder = ShowCatalogCoder()

    @Test func catalogRoundTripAndExplicitEpisodeLoadsPreserveTheCompleteModel() throws {
        let model = try ShowPackageTests.richShow()
        let catalog = try ShowCatalog(model)
        let data = try coder.encode(catalog, revision: 3)
        let decoded = try coder.decode(data)
        #expect(try ShowPackage.storageVersion(of: data) == 2)
        #expect(decoded.payload == catalog)
        #expect(decoded.payload.episodes.map(\.summary.id) == model.episodes.map(\.id))
        let loaded = try decoded.payload.materializedModel()
        let matches = loaded == model
        #expect(matches)
        let compatibilityMatches = try ShowPackageCoder().decode(data).payload == model
        #expect(compatibilityMatches)
    }

    @Test func savingCatalogAndOneEpisodePreservesUnvisitedStoredComponentsExactly() throws {
        let model = try ShowPackageTests.richShow()
        var catalog = try ShowCatalog(model)
        let unvisited = try #require(catalog.episodes.first)
        let originalFiles = try unvisited.files.mapValues { try $0.read() }
        catalog.header.show.title = "Catalog-only edit"
        var edited = try #require(catalog.episodes.last).load(in: catalog.header)
        edited.title = "One edited episode"
        catalog = try catalog.replacingEpisode(edited)
        let retained = try #require(catalog.episode(unvisited.id))
        #expect(retained == unvisited)
        #expect(retained.files.allSatisfy { unvisited.files[$0.key] === $0.value })
        let reloaded = try coder.decode(coder.encode(catalog, revision: 4)).payload
        let actualFiles = try #require(reloaded.episode(unvisited.id)).files.mapValues { try $0.read() }
        #expect(actualFiles == originalFiles)
        var expected = model
        expected.show.title = catalog.header.show.title
        expected.episodes[1].title = edited.title
        let matches = try reloaded.materializedModel() == expected
        #expect(matches)
    }

    @Test func unloadedIsAnExplicitStoredRecordAndPayloadFailuresOccurAtExplicitLoad() throws {
        let model = Fixtures.show(seed: 817)
        let storage = try CatalogComponentStorage()
        var bytes: [String: Data] = [:]
        let component = try ShowPackage.component(Data("not episode JSON".utf8), files: &bytes)
        let stored = try StoredCatalogEpisode(summary: CatalogEpisodeSummary(model.episodes[0]),
            content: component, artwork: nil, files: bytes.mapValues { try storage.store($0) })
        let catalog = ShowCatalog(header: ShowCatalogHeader(model), episodes: [stored], storage: storage)
        let decoded = try coder.decode(coder.encode(catalog, revision: 2)).payload
        let unloaded = try #require(decoded.episode(stored.id))
        #expect(unloaded.summary == stored.summary)
        #expect(decoded.episode(EpisodeID()) == nil)
        #expect(throws: (any Error).self) { try unloaded.load(in: decoded.header) }
        // An unrelated catalog edit must preserve, not silently empty, that uninterpreted component.
        var renamed = decoded
        renamed.header.show.title = "Still preserved"
        let preserved = try coder.decode(coder.encode(renamed, revision: 3)).payload
        #expect(preserved.episode(stored.id) == stored)
    }

    @Test func deletionReorderAndOldSnapshotsDoNotLoseStoredEpisodes() throws {
        let model = try ShowPackageTests.richShow()
        let before = try ShowCatalog(model)
        let oldRecord = try #require(before.episodes.first)
        let after = try before.retainingEpisodes(in: [before.episodes[1].id])
        #expect(after.episode(oldRecord.id) == nil)
        let restored = try coder.decode(coder.encode(before, revision: 4)).payload
        let matches = try restored.materializedModel() == model
        #expect(matches)
        let reversed = try before.retainingEpisodes(in: before.episodes.reversed().map(\.id))
        #expect(reversed.episodes.map(\.id) == before.episodes.reversed().map(\.id))
        #expect(throws: PersistenceError.self) { try before.retainingEpisodes(in: [oldRecord.id, oldRecord.id]) }
        #expect(throws: PersistenceError.self) { try before.retainingEpisodes(in: [EpisodeID()]) }
    }

    @Test func versionOnePackagesRequireAnExplicitUpgrade() throws {
        let model = Fixtures.show(seed: 819)
        let bytes = try ShowPackageCoder().encode(model, revision: 2)
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 1, minimum: 2)) {
            try coder.decode(bytes)
        }
    }

    @Test func immutableBackingSurvivesPublicationAndDetectsDamageBeforeSaving() throws {
        let model = Fixtures.show(seed: 820)
        let catalog = try ShowCatalog(model)
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Generated.wwshow")
        let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(),
            recovery: RecoveryStore(root: directory.sub("recovery")))
        let first = try publisher.publish(catalog, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        var edited = catalog
        edited.header.show.title = "Changed"
        _ = try publisher.publish(edited, revision: 2, key: .show(model.show.id), to: url,
            target: .inPlace(expectedBase: first.fingerprint))
        let previousMatches = try catalog.materializedModel() == model
        #expect(previousMatches)
        let file = try #require(catalog.episodes.first?.files.values.first)
        try Data("damaged local backing".utf8).write(to: file.url)
        #expect(throws: PersistenceError.self) { try coder.encode(catalog, revision: 3) }
    }

    @Test func episodePackageUpgradeIsExplicitAndExact() throws {
        let model = try ShowPackageTests.richShow()
        try checkUpgrade(ShowPackageCoder().encode(model, revision: 7), expected: model)
    }

    @Test(arguments: [1, 13, 14, 15])
    func preContainerEnvelopesAreRefusedWithoutMigrationOrWrites(_ schema: Int) throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Retired.wwshow")
        let original = Data("""
        {"format":"com.brandonmartinez.wavewrangler.show","schemaVersion":\(schema),"payload":{"future":"not interpreted"}}
        """.utf8)
        try original.write(to: url)
        let key = DocumentKey.show(ShowID())
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        let packageCoder = ShowPackageCoder()
        #expect(throws: PersistenceError.self) { try packageCoder.decode(original) }
        #expect(throws: PersistenceError.self) { try coder.decode(original) }
        let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        #expect(throws: PublicationError.self) {
            try DocumentMigrator.show(publisher: publisher).migrate(url, key: key, expectedOriginal: original)
        }
        #expect(try recovery.migrationBackups(for: key).isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    private func checkUpgrade(_ original: Data, expected: ShowDocumentModel) throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Generated.wwshow")
        try LocalFileOperations().writeNew(original, to: url)
        let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(),
            recovery: RecoveryStore(root: directory.sub("recovery")))
        let receipt = try DocumentMigrator.show(publisher: publisher).migrate(url,
            key: .show(expected.show.id), expectedOriginal: original)
        #expect(try LocalFileOperations().read(receipt.backup) == original)
        let data = try LocalFileOperations().read(url)
        #expect(try ShowPackage.storageVersion(of: data) == 2)
        let matches = try coder.decode(data).payload.materializedModel() == expected
        #expect(matches)
    }
}
