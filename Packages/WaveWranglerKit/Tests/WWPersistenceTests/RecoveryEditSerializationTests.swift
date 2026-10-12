import Dispatch
import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Recovery edit-record serialization")
struct RecoveryEditSerializationTests {
    @Test func storeCopiesSerializeSequenceVerificationAndPruning() async throws {
        let rig = Rig()
        let model = Fixtures.show(seed: 853)
        let key = DocumentKey.show(model.show.id)
        let snapshot = try rig.publisher.coder.encode(model, revision: 1)
        let copy = rig.recovery
        let queue = DispatchQueue(label: "ww.test.recovery.serialized-copies", attributes: .concurrent)
        var sequences: [Int] = []
        for _ in 0..<4 {
            async let first = write(rig.recovery, snapshot: snapshot, key: key, queue: queue)
            async let second = write(copy, snapshot: snapshot, key: key, queue: queue)
            let pair = try await (first, second)
            sequences.append(contentsOf: [pair.0.checkpointSequence, pair.1.checkpointSequence])
        }
        #expect(sequences.sorted() == Array(1...8))
        #expect(copy.editCheckpoints(for: key).count == 1)
        let latest = try #require(copy.latestEditCheckpoint(for: key))
        #expect(latest.checkpointSequence == 8 && latest.snapshot == snapshot)
        try rig.recovery.setAsideEditCheckpoints(for: key)
        #expect(copy.editCheckpoints(for: key).isEmpty)
        #expect(copy.offeredEditCheckpoints(for: key).count == 1)
    }

    private func write(
        _ recovery: RecoveryStore, snapshot: Data, key: DocumentKey, queue: DispatchQueue
    ) async throws -> EditCheckpointRecord {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try recovery.writeEditCheckpoint(
                        snapshot: snapshot, base: nil, schemaVersion: SchemaVersion.show, for: key
                    )
                })
            }
        }
    }
}
