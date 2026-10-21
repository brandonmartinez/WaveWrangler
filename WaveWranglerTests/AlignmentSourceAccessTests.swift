import Foundation
import Testing
import WWCore
import WWSources

@Suite("Alignment source access failures")
struct AlignmentSourceAccessTests {
    @Test func missingRecordsRemainDistinctFromReadFailures() async throws {
        let store = Store()
        let access = AlignmentSourceAccess(store: store)
        let key = DeviceAccessKey(showID: ShowID(), sourceID: SourceID())
        #expect(try await access.record(for: key) == nil)
        await store.failReads(with: .storage)
        do {
            _ = try await access.record(for: key)
            Issue.record("An unreadable access store must not look like a missing record")
        } catch let error as AlignmentSourceAccessFailure {
            #expect(error.source == key.sourceID)
            #expect(error.operation == .readRecord)
            #expect(error.underlying as? Failure == .storage)
            #expect(error.localizedDescription.contains("could not be read"))
        }
        #expect(await store.saveCount == 0)
    }

    @Test func refreshFailuresAreReportedWithoutReplacingTheSavedRecord() async throws {
        let store = Store()
        let access = AlignmentSourceAccess(store: store)
        let original = DeviceAccessRecord(showID: ShowID(), sourceID: SourceID(), createdAt: Date())
        try await access.refresh(original)
        await store.failSaves(with: .storage)
        var refreshed = original
        refreshed.lastKnownPath = "/synthetic/refresh"
        do {
            try await access.refresh(refreshed)
            Issue.record("A failed bookmark refresh must not look successful")
        } catch let error as AlignmentSourceAccessFailure {
            #expect(error.source == original.sourceID)
            #expect(error.operation == .refreshRecord)
            #expect(error.underlying as? Failure == .storage)
            #expect(error.localizedDescription.contains("could not be saved"))
        }
        #expect(try await access.record(for: original.key) == original)
    }

    @Test func cancellationRemainsCancellationForReadsAndRefreshes() async throws {
        let store = Store()
        let access = AlignmentSourceAccess(store: store)
        let record = DeviceAccessRecord(showID: ShowID(), sourceID: SourceID(), createdAt: Date())
        await store.failReads(with: .canceled)
        await store.failSaves(with: .canceled)
        await #expect(throws: CancellationError.self) { try await access.record(for: record.key) }
        await #expect(throws: CancellationError.self) { try await access.refresh(record) }
    }

    private enum Failure: Error {
        case storage, canceled
    }

    private actor Store: DeviceAccessStore {
        var saved: [DeviceAccessKey: DeviceAccessRecord] = [:]
        var saveCount = 0
        var readFailure: Failure?
        var saveFailure: Failure?

        func failReads(with failure: Failure) { readFailure = failure }
        func failSaves(with failure: Failure) { saveFailure = failure }
        func record(for key: DeviceAccessKey) throws -> DeviceAccessRecord? {
            if readFailure == .canceled { throw CancellationError() }
            if let readFailure { throw readFailure }
            return saved[key]
        }
        func records(in showID: ShowID) -> [DeviceAccessRecord] {
            saved.values.filter { $0.showID == showID }
        }
        func allRecords() -> [DeviceAccessRecord] { Array(saved.values) }
        func save(_ record: DeviceAccessRecord) throws {
            if saveFailure == .canceled { throw CancellationError() }
            if let saveFailure { throw saveFailure }
            saved[record.key] = record
            saveCount += 1
        }
        func save(_ records: [DeviceAccessRecord]) throws {
            for record in records { try save(record) }
        }
        func removeRecord(for key: DeviceAccessKey) { saved[key] = nil }
        func removeRecords(in showID: ShowID) { saved = saved.filter { $0.key.showID != showID } }
    }
}
