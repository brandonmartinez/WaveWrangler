import Foundation
import WWCore
import WWSources

struct AlignmentSourceAccess: Sendable {
    let store: any DeviceAccessStore

    func record(for key: DeviceAccessKey) async throws -> DeviceAccessRecord? {
        do {
            try Task.checkCancellation()
            let record = try await store.record(for: key)
            try Task.checkCancellation()
            return record
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AlignmentSourceAccessFailure(
                source: key.sourceID, operation: .readRecord, underlying: error
            )
        }
    }

    func refresh(_ record: DeviceAccessRecord) async throws {
        do {
            try Task.checkCancellation()
            try await store.save(record)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AlignmentSourceAccessFailure(
                source: record.sourceID, operation: .refreshRecord, underlying: error
            )
        }
    }
}

struct AlignmentSourceAccessFailure: LocalizedError {
    enum Operation: Sendable, Equatable {
        case readRecord
        case refreshRecord
    }

    let source: SourceID
    let operation: Operation
    let underlying: any Error

    var errorDescription: String? {
        switch operation {
        case .readRecord:
            "Saved source access could not be read: \(underlying.localizedDescription)"
        case .refreshRecord:
            "Refreshed source access could not be saved: \(underlying.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        "Restore source access in Setup and try again. No substitute audio was used."
    }
}
