import Foundation
import Synchronization
import Testing
import WWCore
import WWPersistence

@MainActor
@Suite("Native recovery checkpoint worker", .serialized)
struct DocumentCheckpointWriterTests {
    @Test func productionWritesAndIndependentReadBackRunOffMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WWCheckpointWorker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = CheckpointThreadOperations()
        let recovery = RecoveryStore(root: root, ops: ops)
        let writer = DocumentCheckpointWriter(recovery: recovery)
        let request = try makeRequest("Protected snapshot")
        var result: Result<EditCheckpointRecord, Error>?
        writer.enqueue(request) { result = $0 }
        #expect(writer.isBusy)
        await writer.waitUntilIdle()
        guard case let .success(record) = try #require(result) else {
            Issue.record("Recovery write failed")
            return
        }
        #expect(record.snapshot == request.snapshot)
        #expect(record.unpublished)
        #expect(ops.observedThreads.count >= 3, "Stage write, staged read and final independent read-back")
        #expect(ops.observedThreads.allSatisfy { !$0 })
        #expect(!writer.isBusy)
    }

    @Test func aSuspendedWriteDoesNotBlockMainActorAndObsoleteCompletionIsIgnored() async throws {
        let gate = CheckpointWriteGate()
        let root = FileManager.default.temporaryDirectory.appending(path: "WWCheckpointGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let writer = DocumentCheckpointWriter { request in
            await gate.block()
            return try recovery.writeEditCheckpoint(
                snapshot: request.snapshot, base: request.base, schemaVersion: request.schemaVersion,
                for: request.key, at: request.capturedAt
            )
        }
        var completionRan = false
        writer.enqueue(try makeRequest("Earlier edit")) { _ in completionRan = true }
        await gate.waitForEntry()
        // Reaching this line on the main actor while I/O is suspended is the responsiveness assertion.
        #expect(writer.isBusy)
        writer.invalidatePending()
        var drained = false
        let waiter = Task { await writer.waitUntilIdle(); drained = true }
        await Task.yield()
        #expect(!drained)
        await gate.release()
        await waiter.value
        #expect(drained)
        #expect(!completionRan, "A superseded snapshot must never mark current edits protected")
    }

    @Test func coalescesQueuedSnapshotsAndDrainsBeforeSaveOrDiscard() async throws {
        let gate = CheckpointWriteGate()
        let root = FileManager.default.temporaryDirectory.appending(path: "WWCheckpointLatest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let requests = Mutex<[Data]>([])
        let writer = DocumentCheckpointWriter { request in
            let first = requests.withLock { values in
                values.append(request.snapshot)
                return values.count == 1
            }
            if first { await gate.block() }
            return try recovery.writeEditCheckpoint(
                snapshot: request.snapshot, base: request.base, schemaVersion: request.schemaVersion,
                for: request.key, at: request.capturedAt
            )
        }
        let first = try makeRequest("First")
        let second = try makeRequest("Second", key: first.key)
        let latest = try makeRequest("Latest", key: first.key)
        var callbacks: [String] = []
        writer.enqueue(first) { _ in callbacks.append("first") }
        await gate.waitForEntry()
        writer.enqueue(second) { _ in callbacks.append("second") }
        writer.enqueue(latest) { _ in callbacks.append("latest") }
        await gate.release()
        await writer.waitUntilIdle()
        #expect(requests.withLock { $0 } == [first.snapshot, latest.snapshot])
        #expect(callbacks == ["latest"])
        #expect(recovery.latestEditCheckpoint(for: latest.key)?.snapshot == latest.snapshot)
        try recovery.discardEditCheckpoints(for: latest.key)
        #expect(recovery.latestEditCheckpoint(for: latest.key) == nil, "No late queued write can recreate it")
    }

    @Test func failureIsDeliveredWithoutSuccessfulProtection() async throws {
        let writer = DocumentCheckpointWriter { _ in throw POSIXError(.ENOSPC) }
        var result: Result<EditCheckpointRecord, Error>?
        writer.enqueue(try makeRequest("Unsaved")) { result = $0 }
        await writer.waitUntilIdle()
        guard case let .failure(error) = try #require(result) else {
            Issue.record("A failed recovery write must not look protected")
            return
        }
        #expect(WriteFailureKind(classifying: error) == .diskFull)
    }

    @Test func invalidationBeforeAdmissionWritesNothing() async throws {
        let calls = Mutex(0)
        let writer = DocumentCheckpointWriter { _ in
            calls.withLock { $0 += 1 }
            throw POSIXError(.ENOSPC)
        }
        var completionRan = false
        writer.enqueue(try makeRequest("Cancelled before admission")) { _ in completionRan = true }
        writer.invalidatePending()
        await writer.waitUntilIdle()
        #expect(calls.withLock { $0 } == 0)
        #expect(!completionRan)
    }

    @Test func offGateRefusesFileIOAtWorkerAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WWCheckpointOff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = CheckpointThreadOperations()
        let gate = AutosaveGate(AutosavePreference(enabled: false))
        let writer = DocumentCheckpointWriter(recovery: RecoveryStore(root: root, ops: ops), gate: gate)
        var result: Result<EditCheckpointRecord, Error>?
        writer.enqueue(try makeRequest("Not automatically written")) { result = $0 }
        await writer.waitUntilIdle()
        guard case let .failure(error) = try #require(result) else {
            Issue.record("OFF must refuse the automatic write")
            return
        }
        #expect(WriteFailureKind(classifying: error) == .cancelled)
        #expect(ops.observedThreads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func makeRequest(_ title: String, key: DocumentKey? = nil) throws -> DocumentCheckpointWriter.Request {
        let model = try ShowDocumentModel.untitled().renamingShow(to: title)
        return DocumentCheckpointWriter.Request(
            snapshot: try JSONEnvelopeCoder<ShowDocumentModel>.show.encode(model, revision: 1),
            base: nil, schemaVersion: SchemaVersion.show, key: key ?? .show(model.show.id), capturedAt: Date()
        )
    }
}

private actor CheckpointWriteGate {
    private var entered = false
    private var waitingForEntry: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?

    func block() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            entered = true
            for observer in waitingForEntry { observer.resume() }
            waitingForEntry.removeAll()
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { waitingForEntry.append($0) }
    }

    func release() { blocked?.resume(); blocked = nil }
}

private final class CheckpointThreadOperations: FileOperations {
    private let state = Mutex<[Bool]>([])
    private let base = LocalFileOperations()
    var observedThreads: [Bool] { state.withLock { $0 } }
    private func noteThread() { state.withLock { $0.append(Thread.isMainThread) } }
    func read(_ url: URL) throws -> Data { noteThread(); return try base.read(url) }
    func writeNew(_ data: Data, to url: URL) throws { noteThread(); try base.writeNew(data, to: url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func replace(_ destination: URL, withStaged staged: URL) throws { try base.replace(destination, withStaged: staged) }
    func moveNew(_ source: URL, to destination: URL) throws { try base.moveNew(source, to: destination) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        try base.makeStagingDirectory(appropriateFor: destination)
    }
}
