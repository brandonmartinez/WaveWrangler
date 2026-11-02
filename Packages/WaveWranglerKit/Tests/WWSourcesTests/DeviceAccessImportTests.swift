import Foundation
import Testing
import WWCore
@testable import WWSources

@Suite("Conditional import access publication", .serialized)
struct DeviceAccessImportTests {
    private func record() -> DeviceAccessRecord {
        .init(showID: ShowID(), sourceID: SourceID(), createdAt: Date(timeIntervalSince1970: 100))
    }

    @Test func occupiedAndDuplicateBatchesNeverPartiallyPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-import-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let stores: [any DeviceAccessImportStore] = [
            InMemoryDeviceAccessStore(), FileDeviceAccessStore(fileURL: root.appendingPathComponent("access.json"))
        ]
        for store in stores {
            let a = record(), b = record()
            let initial = try await store.insertNew([a])
            await #expect(throws: DeviceAccessImportError.occupiedKey(a.key)) { try await store.insertNew([b, a]) }
            #expect(try await store.record(for: b.key) == nil)
            #expect(try await store.snapshot(for: a.key) == initial.first)
            await #expect(throws: DeviceAccessImportError.duplicateKey(b.key)) { try await store.insertNew([b, b]) }
            #expect(try await store.record(for: b.key) == nil)
        }
    }

    @Test func concurrentImportsHaveExactlyOneOwnerAndNoOverwrite() async throws {
        let store = InMemoryDeviceAccessStore(), a = record()
        let first = Task { try await store.insertNew([a]) }
        let second = Task { try await store.insertNew([a]) }
        let outcomes = await [first.result, second.result]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(await store.allRecords() == [a])
    }

    @Test func conditionalDiscardPreservesABAAndForeignStoreGrants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-import-aba-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for store: any DeviceAccessImportStore in [
            InMemoryDeviceAccessStore(), FileDeviceAccessStore(fileURL: root.appendingPathComponent("access.json"))
        ] {
            let a = record(), b = record()
            let ownership = try await store.insertNew([a, b])
            var changed = a
            changed.lastKnownPath = "/different"
            try await store.save(changed)
            try await store.save(a)
            #expect(try await store.discardImported(ownership) == [a.key])
            #expect(try await store.record(for: a.key) == a)
            #expect(try await store.record(for: b.key) == nil)
            let other = InMemoryDeviceAccessStore()
            let foreign = try await other.insertNew([a])
            #expect(try await store.discardImported(foreign) == [a.key])
            #expect(try await store.record(for: a.key) == a)
        }
    }

    @Test func failedDurablePublicationReloadsOnlyThePriorRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-import-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("access.json")
        let store = FileDeviceAccessStore(fileURL: url), a = record(), b = record()
        let inserted = try await store.insertNew([a])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) { try await store.insertNew([b]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let reloaded = FileDeviceAccessStore(fileURL: url)
        #expect(try await reloaded.allRecords() == [a])
        #expect(try await reloaded.snapshot(for: a.key)?.mutationGeneration == inserted.first?.mutationGeneration)
        #expect(try await reloaded.discardImported(inserted) == [a.key], "A different store instance does not inherit cleanup ownership.")
    }
}
