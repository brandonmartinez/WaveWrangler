import Foundation
import Synchronization
import Testing
@testable import WWExport

@Suite("In-flight export remux cancellation", .serialized)
struct ExportCancellationTests {
    @Test(arguments: [false, true])
    func taskAndExplicitJobCancellationInterruptRemuxAndJoinBeforeCleanup(explicit: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ww-remux-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = PendingRemux()
        defer { framework.release() }
        let job = ExportJob(temporaryDirectory: root, remuxFactory: { _, output, _ in
            ExportRemuxOperation(run: { try await framework.run(output: output) },
                                 cancel: { framework.cancel() })
        })
        let request = try ExportJobRequest(userSelectedDirectory: root, protectedLocations: [],
            productionFrames: 0..<4_096, deliveries: [
                ExportDelivery(filename: "out.m4a", settings: .init(codec: .aacLC(bitrate: 128_000)),
                               metadata: .init(title: "Metadata requires remux"))
            ])
        let task = Task {
            try await job.run(request, isCurrent: { true }, render: { sink in
                try await sink(0, [[Float](repeating: 0.1, count: 4_096), [Float](repeating: 0.2, count: 4_096)])
            })
        }
        defer { task.cancel() }
        try #require(await event(framework.started))
        let staging = try #require(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first)
        let encoder = try #require(FileManager.default.contentsOfDirectory(at: staging,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("ww-export-") })
        if explicit { await job.cancel() } else { task.cancel() }
        #expect(await event(framework.canceled))
        // The fake framework deliberately remains in flight after cancellation until acknowledged.
        // Both the raw PCM and encoded input must remain present while it may still be writing.
        #expect(await job.progress.phase == .verifying(delivery: 0))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("production.f32").path))
        #expect(FileManager.default.fileExists(atPath: encoder.appendingPathComponent("encoded.m4a").path))
        framework.release()
        let result = try await task.value
        #expect(result.problem?.kind == .canceled && result.published.isEmpty)
        #expect(!result.cleanupErrors.isEmpty)
        #expect(try Data(contentsOf: encoder.appendingPathComponent("tagged.m4a")) == PendingRemux.partial)
        #expect(!FileManager.default.fileExists(atPath: encoder.appendingPathComponent("encoded.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("production.f32").path))
    }

    private func event(_ stream: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return false }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

/// Models framework cancellation acknowledgement independently of task cancellation.
private final class PendingRemux: Sendable {
    private static let initial = Data("unconfirmed framework partial".utf8)
    private static let acknowledgement = Data("; late framework write before cancellation acknowledgement".utf8)
    static var partial: Data { initial + acknowledgement }
    let started: AsyncStream<Void>
    let canceled: AsyncStream<Void>
    private let startSignal: AsyncStream<Void>.Continuation
    private let cancelSignal: AsyncStream<Void>.Continuation
    private struct State {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    init() {
        (started, startSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (canceled, cancelSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func run(output: URL) async throws {
        try Self.initial.write(to: output, options: .withoutOverwriting)
        startSignal.yield()
        await withCheckedContinuation { waiter in
            let resume = state.withLock {
                if $0.released { return true }
                $0.waiter = waiter
                return false
            }
            if resume { waiter.resume() }
        }
        let file = try FileHandle(forWritingTo: output)
        try file.seekToEnd()
        try file.write(contentsOf: Self.acknowledgement)
        try file.close()
        throw CancellationError()
    }

    func cancel() { cancelSignal.yield() }

    func release() {
        let waiter = state.withLock {
            $0.released = true
            let waiter = $0.waiter
            $0.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}
