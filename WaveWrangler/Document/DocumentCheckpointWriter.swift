import Dispatch
import Foundation
import WWPersistence

/// Captures immutable snapshots on the main actor, with file I/O on a private serial queue.
@MainActor
final class DocumentCheckpointWriter {
    struct Request: Sendable {
        let snapshot: Data
        let base: RevisionFingerprint?
        let schemaVersion: Int
        let key: DocumentKey
        let capturedAt: Date
    }

    typealias Write = @Sendable (Request) async throws -> EditCheckpointRecord
    typealias Completion = @MainActor (Result<EditCheckpointRecord, Error>) -> Void

    private let write: Write
    private var generation = 0
    private var pending: (request: Request, completion: Completion)?
    private var active: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(recovery: RecoveryStore, gate: AutosaveGate? = nil) {
        let queue = DispatchQueue(label: "ww.document.recovery", qos: .userInitiated)
        write = { request in
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        guard gate?.isEnabled ?? true else { throw CocoaError(.userCancelled) }
                        return try recovery.writeEditCheckpoint(
                            snapshot: request.snapshot, base: request.base, schemaVersion: request.schemaVersion,
                            for: request.key, at: request.capturedAt
                        )
                    })
                }
            }
        }
    }

    init(write: @escaping Write) { self.write = write }

    var isBusy: Bool { active != nil || pending != nil }

    /// At most one write and one latest queued snapshot. Superseded callbacks cannot certify current edits.
    func enqueue(_ request: Request, completion: @escaping Completion) {
        generation += 1
        pending = (request, completion)
        if active == nil { startNext() }
    }

    func invalidatePending() {
        generation += 1
        pending = nil
    }

    /// Saves and close/discard wait without blocking the main actor, so a late write cannot recreate a
    /// checkpoint after those operations have retired it.
    func waitUntilIdle() async {
        guard isBusy else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func startNext() {
        guard let next = pending else { return }
        pending = nil
        let token = generation
        active = Task {
            if token == generation {
                let result: Result<EditCheckpointRecord, Error>
                do { result = .success(try await write(next.request)) }
                catch { result = .failure(error) }
                if token == generation { next.completion(result) }
            }
            active = nil
            if pending != nil {
                startNext()
            } else {
                let finished = waiters
                waiters.removeAll()
                for waiter in finished { waiter.resume() }
            }
        }
    }
}
