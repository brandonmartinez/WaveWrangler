import Foundation
import Testing
import WWCore
@testable import WWSources

/// T30 (WW-012): automatic retry on reconnect. With availability ON, downloads that failed with an observed
/// connectivity error are requested again when the network comes back; nothing else is. With OFF nothing
/// is requested automatically.
@Suite("Reconnect retry (T30)", .timeLimit(.minutes(1)))
@MainActor
struct ReconnectRetryTests {
    static let offline = SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    static let other = SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)

    @Test func decision() {
        #expect(ReconnectRetry.shouldRetry(.offlineOrUnknown(Self.offline), setting: .on, userCancelled: false))
        #expect(!ReconnectRetry.shouldRetry(.offlineOrUnknown(Self.offline), setting: .off, userCancelled: false), "OFF never retries")
        #expect(!ReconnectRetry.shouldRetry(.offlineOrUnknown(Self.offline), setting: .on, userCancelled: true), "a user cancel waits for Retry")
        #expect(!ReconnectRetry.shouldRetry(.offlineOrUnknown(nil), setting: .on, userCancelled: false), "a stall is not an observed connection failure")
        #expect(!ReconnectRetry.shouldRetry(.failed(Self.other), setting: .on, userCancelled: false))
        #expect(!ReconnectRetry.shouldRetry(.cancelled, setting: .on, userCancelled: false))
        #expect(!ReconnectRetry.shouldRetry(.idle, setting: .on, userCancelled: false))
        #expect(!ReconnectRetry.shouldRetry(nil, setting: .on, userCancelled: false))
    }

    private struct Env {
        let tree: SyntheticTree
        let io: HarnessIO
        let monitor: SourceAvailabilityMonitor
        let files: [URL]
        let records: [DeviceAccessRecord]
    }

    private func makeEnv(_ label: String, scripts: [[SimulatedCloudItem.Step]], setting: SourceAvailabilitySetting) async throws -> Env {
        let tree = try SyntheticTree(label: label)
        var rng = SplitMix64(seed: 30)
        let files = try scripts.indices.map { try tree.file("source\($0).wav", bytes: 64, rng: &rng) }
        let io = HarnessIO()
        let context = makeContext(io)
        let records = try await SourceImporter(context: context).plan(selection: files, showID: testShow).items.compactMap(\.accessRecord)
        try #require(records.count == files.count)
        for (file, script) in zip(files, scripts) { io.simulate(file, SimulatedCloudItem(script: script)) }
        let monitor = SourceAvailabilityMonitor(showID: testShow, store: InMemoryDeviceAccessStore(), context: context, setting: setting, transferPolicy: StallFollowUpTests.policy)
        monitor.start()
        return Env(tree: tree, io: io, monitor: monitor, files: files, records: records)
    }

    /// Waits (without blocking a thread) until the monitor's observation of `id` satisfies `condition`.
    private func waitFor(_ monitor: SourceAvailabilityMonitor, _ id: SourceID, _ condition: (TransferState?) -> Bool) async throws -> Bool {
        for _ in 0..<2_000 {
            if condition(monitor.observations[id]?.transfer) { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return condition(monitor.observations[id]?.transfer)
    }

    private static func isConnectionFailure(_ state: TransferState?) -> Bool {
        if case .offlineOrUnknown(.some)? = state { return true }
        return false
    }

    @Test func onRetriesOnlyObservedConnectionFailures() async throws {
        let env = try await makeEnv("t30-on", scripts: [[.progress(0.2), .error(Self.offline)], [.error(Self.other)]], setting: .on)
        let (noConnection, otherFailure) = (env.records[0].sourceID, env.records[1].sourceID)
        try await env.monitor.adopt(env.records)
        #expect(try await waitFor(env.monitor, noConnection, Self.isConnectionFailure))
        #expect(try await waitFor(env.monitor, otherFailure) { if case .failed? = $0 { true } else { false } })
        #expect(env.io.count(.downloadRequest) == 2, "both requested automatically once")

        // Still offline: refreshing doesn't retry by itself.
        await env.monitor.refreshAll()
        #expect(env.io.count(.downloadRequest) == 2)

        // Network back: the provider can download again; only the "No connection" source is requested.
        env.io.simulated(env.files[0])?.evictAgain(script: [.progress(0.5), .complete])
        env.io.simulated(env.files[1])?.evictAgain(script: [.complete])
        let requested = await env.monitor.connectivityRestored()
        #expect(requested == [noConnection])
        #expect(env.io.count(.downloadRequest) == 3)
        #expect(try await waitFor(env.monitor, noConnection) { $0 == .idle }, "Waiting → Downloading → Ready with no user action")
        #expect(env.monitor.observations[noConnection]?.residency == .local)
        if case .failed? = env.monitor.observations[otherFailure]?.transfer {} else { Issue.record("other failures wait for Retry") }
        await env.monitor.stop()
    }

    @Test func userCancelledIsNotRetried() async throws {
        let env = try await makeEnv("t30-cancel", scripts: [[.progress(0.2), .error(Self.offline)]], setting: .on)
        let id = env.records[0].sourceID
        try await env.monitor.adopt(env.records)
        #expect(try await waitFor(env.monitor, id, Self.isConnectionFailure))
        await env.monitor.cancelTransfer(id)
        env.io.simulated(env.files[0])?.evictAgain(script: [.complete])
        #expect(await env.monitor.connectivityRestored().isEmpty)
        #expect(env.io.count(.downloadRequest) == 1)
        await env.monitor.stop()
    }

    @Test func offRetriesNothingAndRequestsNothingElse() async throws {
        let env = try await makeEnv("t30-off", scripts: [[.progress(0.2), .error(Self.offline)], [.complete]], setting: .off)
        let (explicit, untouched) = (env.records[0].sourceID, env.records[1].sourceID)
        try await env.monitor.adopt(env.records)
        #expect(env.io.count(.downloadRequest) == 0, "OFF requests nothing on its own")
        await env.monitor.makeAvailable(explicit)
        #expect(try await waitFor(env.monitor, explicit, Self.isConnectionFailure))
        #expect(env.io.count(.downloadRequest) == 1)

        env.io.simulated(env.files[0])?.evictAgain(script: [.complete])
        #expect(await env.monitor.connectivityRestored().isEmpty)
        await env.monitor.refreshAll()
        #expect(env.io.count(.downloadRequest) == 1, "the failed explicit download is not retried; no other source is requested")
        #expect(Self.isConnectionFailure(env.monitor.observations[explicit]?.transfer), "stays No connection until Retry")
        #expect(env.monitor.observations[untouched]?.transfer == .notRequested(.availabilityOff))

        // Retry is the user's path back.
        await env.monitor.retryTransfer(explicit)
        #expect(env.io.count(.downloadRequest) == 2)
        #expect(try await waitFor(env.monitor, explicit) { $0 == .idle })
        await env.monitor.stop()
    }

    @Test func stoppedMonitorRetriesNothing() async throws {
        let env = try await makeEnv("t30-stop", scripts: [[.error(Self.offline)]], setting: .on)
        let id = env.records[0].sourceID
        try await env.monitor.adopt(env.records)
        #expect(try await waitFor(env.monitor, id, Self.isConnectionFailure))
        await env.monitor.stop()
        env.io.simulated(env.files[0])?.evictAgain(script: [.complete])
        #expect(await env.monitor.connectivityRestored().isEmpty)
        #expect(env.io.count(.downloadRequest) == 1)
    }
}
