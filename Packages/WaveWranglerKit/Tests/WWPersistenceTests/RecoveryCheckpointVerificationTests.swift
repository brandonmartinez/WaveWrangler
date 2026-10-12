import Foundation
import Synchronization
import Testing
import WWCore
@testable import WWPersistence

@Suite("Retained prior read-back verification")
struct RecoveryCheckpointVerificationTests {
    @Test(arguments: CheckpointReadFault.allCases)
    func refusesPublicationBeforePruningWhenNewPriorCannotBeVerified(_ fault: CheckpointReadFault) throws {
        let ops = CheckpointReadOperations()
        let rig = Rig(label: "prior-read-back", ops: ops)
        var model = Fixtures.show(seed: 45_101)
        let key = DocumentKey.show(model.show.id)
        let url = rig.url()
        var base = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation).fingerprint
        for revision in 2...4 {
            model = try model.renamingShow(to: "Verified revision \(revision)")
            base = try rig.publisher.publish(
                model, revision: revision, key: key, to: url, target: .inPlace(expectedBase: base)
            ).fingerprint
        }
        let before = try ops.read(url)
        let existing = try rig.recovery.checkpoints(for: key)
        #expect(existing.count == 3)
        let retained = try Dictionary(uniqueKeysWithValues: existing.map { ($0.url, try ops.read($0.url)) })
        let changed = try JSONEnvelopeCoder<ShowDocumentModel>.show.encode(
            model.renamingShow(to: "Different checkpoint bytes"), revision: 4
        )
        ops.arm(fault, known: Set(retained.keys), changed: changed)

        do {
            _ = try rig.publisher.publish(
                model.renamingShow(to: "Must remain unsaved"), revision: 5, key: key, to: url,
                target: .inPlace(expectedBase: base)
            )
            Issue.record("An unreadable or changed retained prior must refuse the canonical overwrite")
        } catch let error as PublicationError {
            guard case .failed(stage: .candidateValidated, kind: .other, _) = error else {
                Issue.record("Unexpected publication error: \(error)")
                return
            }
        }
        #expect(ops.checkpointReadCount == 4, "Reuse the existing independent checkpoint reads")
        #expect(ops.listingCount == 1, "Do not add another directory enumeration")
        ops.disarm()
        #expect(try ops.read(url) == before, "Refusal must happen before canonical publication")
        for (checkpoint, bytes) in retained {
            #expect(ops.exists(checkpoint), "A failed prior verification must not prune a validated older record")
            if ops.exists(checkpoint) { #expect(try ops.read(checkpoint) == bytes) }
        }
    }

    @Test func verifiedPriorUsesExistingReadBackPass() throws {
        let ops = CheckpointReadOperations()
        let rig = Rig(label: "verified-prior", ops: ops)
        let model = Fixtures.show(seed: 45_102)
        let key = DocumentKey.show(model.show.id)
        let url = rig.url()
        let first = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
        ops.resetCounts()
        let second = try rig.publisher.publish(
            model.renamingShow(to: "Verified edit"), revision: 2, key: key, to: url,
            target: .inPlace(expectedBase: first.fingerprint)
        )
        #expect(second.priorCheckpoint?.fingerprint == first.fingerprint)
        #expect(ops.checkpointReadCount == 1)
        #expect(ops.listingCount == 1)
        let checkpoint = try #require(second.priorCheckpoint)
        #expect(try rig.recovery.bytes(of: checkpoint) == JSONEnvelopeCoder<ShowDocumentModel>.show.encode(
            model, revision: 1, publicationID: first.publication.publicationID
        ))
    }
}

enum CheckpointReadFault: Sendable, CaseIterable {
    case unreadable
    case changed
}

private final class CheckpointReadOperations: FileOperations {
    private struct State {
        var fault: CheckpointReadFault?
        var known: Set<URL> = []
        var changed = Data()
        var checkpointReads = 0
        var listings = 0
    }

    private let state = Mutex(State())
    private let base = LocalFileOperations()

    var checkpointReadCount: Int { state.withLock { $0.checkpointReads } }
    var listingCount: Int { state.withLock { $0.listings } }

    func arm(_ fault: CheckpointReadFault, known: Set<URL>, changed: Data) {
        state.withLock {
            $0 = State(fault: fault, known: known, changed: changed)
        }
    }

    func disarm() { state.withLock { $0.fault = nil } }
    func resetCounts() {
        state.withLock {
            $0.checkpointReads = 0
            $0.listings = 0
        }
    }

    func read(_ url: URL) throws -> Data {
        let (fault, changed) = state.withLock { state in
            if url.pathExtension == "wwcheckpoint" {
                state.checkpointReads += 1
                return (state.known.contains(url) ? nil : state.fault, state.changed)
            }
            return (nil, Data())
        }
        switch fault {
        case .unreadable: throw POSIXError(.EIO)
        case .changed: return changed
        case nil: return try base.read(url)
        }
    }

    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws { try base.writeNew(data, to: url) }
    func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
    func moveNew(_ source: URL, to destination: URL) throws { try base.moveNew(source, to: destination) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        try base.makeStagingDirectory(appropriateFor: destination)
    }
    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        state.withLock { $0.listings += 1 }
        return try base.contentsOfDirectory(url)
    }
}
