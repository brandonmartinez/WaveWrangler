import AppKit
import CoreTransferable
import Foundation

@MainActor
enum AudioFileLocationLoader {
    static func load(from provider: NSItemProvider) async throws -> SetupFileDrop {
        let request = AudioFileLocationRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                let progress = provider.loadTransferable(type: SetupFileDrop.self) { request.finish($0) }
                request.install(progress)
            }
        } onCancel: { request.cancel() }
    }
}

/// One location request; the callback and cancellation may race on different executors.
private final class AudioFileLocationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SetupFileDrop, any Error>?
    private var progress: Progress?
    private var result: Result<SetupFileDrop, any Error>?

    func install(_ continuation: CheckedContinuation<SetupFileDrop, any Error>) -> Bool {
        let completed: Result<SetupFileDrop, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed); return false }
        return true
    }

    func install(_ progress: Progress) {
        let canceled = lock.withLock {
            if case let .failure(error) = result { return error is CancellationError }
            if result == nil { self.progress = progress }
            return false
        }
        if canceled { progress.cancel() }
    }

    func finish(_ result: Result<SetupFileDrop, any Error>) {
        let waiting = lock.withLock {
            guard self.result == nil else { return Optional<CheckedContinuation<SetupFileDrop, any Error>>.none }
            self.result = result
            defer { continuation = nil; progress = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func cancel() {
        let pending = lock.withLock {
            guard result == nil else { return (Optional<CheckedContinuation<SetupFileDrop, any Error>>.none, Optional<Progress>.none) }
            result = .failure(CancellationError())
            defer { continuation = nil; progress = nil }
            return (continuation, progress)
        }
        pending.0?.resume(throwing: CancellationError())
        pending.1?.cancel()
    }
}
