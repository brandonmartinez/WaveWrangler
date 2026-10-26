import Foundation

/// Main-actor tasks still interleave at awaits. AU capture and document barriers must not.
@MainActor
final class MixerOperationQueue {
    private var tail: Task<Void, Never>?
    private(set) var pending = 0

    func run<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let previous = tail
        pending += 1
        let task = Task {
            await previous?.value
            defer { pending -= 1 }
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
}
