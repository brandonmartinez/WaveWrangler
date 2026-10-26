import Foundation
import Testing

@MainActor
@Suite("Mixer transaction ordering", .serialized)
struct MixerOperationQueueTests {
    @MainActor private final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func suspendedCaptureDrainsBeforeCloseAndReplacement() async throws {
        let queue = MixerOperationQueue()
        let gate = Gate()
        var writes: [String] = []
        let capture = Task {
            try await queue.run {
                await gate.wait()
                writes.append("capture")
            }
        }
        while !gate.entered { await Task.yield() }
        let close = Task { try await queue.run { writes.append("close") } }
        let replacement = Task { try await queue.run { writes.append("replacement") } }
        await Task.yield()
        #expect(writes.isEmpty)
        capture.cancel()
        gate.release()
        try await capture.value
        try await close.value
        try await replacement.value
        #expect(writes == ["capture", "close", "replacement"])
        #expect(queue.pending == 0)
    }

    @Test func refusedOperationDoesNotPoisonFollowingBarrier() async throws {
        enum Refusal: Error { case refused }
        let queue = MixerOperationQueue()
        do {
            try await queue.run { throw Refusal.refused }
            Issue.record("Refusal should propagate")
        } catch Refusal.refused {}
        let result = try await queue.run { 42 }
        #expect(result == 42 && queue.pending == 0)
    }
}
