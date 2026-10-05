import Darwin
import Foundation
import Testing
import WWCore
@testable import WWSources

// OBSERVED iCloud Drive trial (M1-SRC-ON-PROV-001 subset). Opt-in only: runs when WW_ICLOUD_TRIAL=1.
// Consent scope (user-granted 2026-10-04): generated random-byte files only, only inside
// ~/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/sources/, `brctl evict`
// allowed there, the `sources/` subfolder is deleted afterwards. No other provider, device, network or
// OS setting is touched. Results describe this host/account only and say nothing about OneDrive,
// Dropbox or other File Provider domains.

struct TrialEvent: Codable {
    var t: Double
    var phase: String
    var file: String
    var note: String
}

final class TrialLog: @unchecked Sendable {
    let start = Date()
    private let lock = NSLock()
    private(set) var events: [TrialEvent] = []

    func add(_ phase: String, _ file: String, _ note: String) {
        let event = TrialEvent(t: (Date().timeIntervalSince(start) * 1000).rounded() / 1000, phase: phase, file: file, note: note)
        lock.withLock { events.append(event) }
        print("WW-ICLOUD-TRIAL t=\(event.t) [\(phase)] \(file): \(note)")
    }
}

func describe(_ metadata: MetadataResult) -> String {
    switch metadata {
    case let .failure(failure): return "metadata failure \(failure)"
    case let .success(value):
        let u = value.ubiquitous
        return "ubiquitous=\(String(describing: u.isUbiquitousItem.value)) status=\(String(describing: u.downloadingStatus.value?.rawValue)) downloading=\(String(describing: u.isDownloading.value)) requested=\(String(describing: u.downloadRequested.value)) error=\(String(describing: u.downloadingError)) dataless=\(String(describing: value.isDataless.value)) size=\(String(describing: value.fingerprint.fileSize.value)) residency=\(value.residency.0.rawValue)"
    }
}

@Suite("iCloud Drive provider trial (opt-in, observed)", .serialized)
struct ProviderTrialTests {
    static let enabled = ProcessInfo.processInfo.environment["WW_ICLOUD_TRIAL"] == "1"
    static let trialRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial", isDirectory: true)

    static func brctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Harness-only metadata (no content access): lstat fields.
    static func lstatSignature(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "absent" }
        return "ino=\(info.st_ino) size=\(info.st_size) mtime=\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) mode=\(info.st_mode) dataless=\(info.st_flags & UInt32(SF_DATALESS) != 0)"
    }

    static func waitFor(_ timeout: TimeInterval, interval: TimeInterval = 1, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .seconds(interval))
        }
        return condition()
    }

    static func uploaded(_ url: URL) -> Bool {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]).ubiquitousItemIsUploaded) == true
    }

    static func status(_ io: SystemSourceIO, _ url: URL) -> UbiquitousDownloadingStatus? {
        if case let .success(metadata) = io.metadata(at: url) { return metadata.ubiquitous.downloadingStatus.value }
        return nil
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func observedICloudTrial() async throws {
        let log = TrialLog()
        let sources = Self.trialRoot.appendingPathComponent("sources", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        defer {
            // Delete only the consented sources/ subfolder.
            try? fm.removeItem(at: sources)
        }

        // 1. Generate synthetic random-byte files (not audio content).
        let sizes = [256 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024]
        var rng = SplitMix64(seed: FixtureSeed.derive(fixtureID: "M1-SRC-ON-PROV-001", split: "trial", caseIndex: 0))
        var generated: [URL: Data] = [:]
        for (index, size) in sizes.enumerated() {
            let url = sources.appendingPathComponent("synthetic-\(index + 1).wav")
            var data = Data(count: size)
            data.withUnsafeMutableBytes { buffer in
                for offset in buffer.indices { buffer[offset] = UInt8.random(in: 0...255, using: &rng) }
            }
            try data.write(to: url)
            generated[url] = data
            log.add("generate", url.lastPathComponent, "\(size) random bytes")
        }
        let urls = generated.keys.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // 2. Wait for upload so eviction is possible.
        for url in urls {
            let ok = await Self.waitFor(240) { Self.uploaded(url) }
            log.add("upload", url.lastPathComponent, ok ? "uploaded" : "NOT uploaded within 240 s")
            #expect(ok)
        }

        // 3. Import (metadata only) while local.
        let io = HarnessIOObserved()
        let context = SourceAccessContext(io: io, ledger: SecurityScopeLedger())
        let show = ShowID()
        let plan = try await SourceImporter(context: context).plan(selection: [sources], showID: show)
        log.add("import", "*", "items=\(plan.items.count) provenance=\(plan.provenance.rawValue)")
        #expect(plan.items.count == urls.count)
        let records = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.sourceRecord.displayNameHint, $0.accessRecord) })

        // 4. Evict.
        let system = SystemSourceIO()
        for url in urls {
            let (code, output) = Self.brctl(["evict", url.path])
            log.add("evict", url.lastPathComponent, "brctl exit=\(code) \(output)")
            let evicted = await Self.waitFor(120) { Self.status(system, url) == .notDownloaded }
            log.add("evict", url.lastPathComponent, "\(evicted ? "evicted" : "NOT evicted"); \(describe(system.metadata(at: url))); lstat \(Self.lstatSignature(url))")
            #expect(evicted)
        }
        let afterEvict = Dictionary(uniqueKeysWithValues: urls.map { ($0, Self.lstatSignature($0)) })

        // 5. OFF / metadata-only phase: evaluate, controller and monitor; zero download requests.
        let offController = SourceTransferController(context: context, policy: TransferPolicy(pollInterval: .milliseconds(200), stallTimeout: .seconds(60)), setting: .off)
        for url in urls {
            guard let record = records[url.lastPathComponent] else { continue }
            let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(key: record.key, record: record, setting: .off)
            let o = evaluation.observation
            log.add("off", url.lastPathComponent, "location=\(o.location) access=\(o.access.rawValue) residency=\(o.residency.rawValue)/\(o.residencyEvidence.rawValue) transfer=\(o.transfer) identity=\(o.identity) provenance=\(o.provenance.rawValue)")
            #expect(o.residency == .cloudPlaceholder)
            #expect(o.transfer == .notRequested(.availabilityOff))
            let state = await offController.makeAvailable(record.key, at: url)
            #expect(state == .notRequested(.availabilityOff))
        }
        try await Self.runOffMonitor(show: show, records: Array(records.values), context: context)
        try await Task.sleep(for: .seconds(15))
        for url in urls {
            let still = Self.status(system, url) == .notDownloaded
            log.add("off", url.lastPathComponent, "after 15 s: \(still ? "still evicted" : "NOT evicted") lstat \(Self.lstatSignature(url))")
            #expect(still)
            #expect(Self.lstatSignature(url) == afterEvict[url])
        }
        log.add("off", "*", "downloadRequests=\(io.count(.downloadRequest)) downloadFraction=\(io.count(.downloadFraction)) metadata=\(io.count(.metadata)) bookmarkResolve=\(io.count(.bookmarkResolve))")
        #expect(io.count(.downloadRequest) == 0)
        #expect(io.count(.downloadFraction) == 0)

        // 6. ON: download file 3 (largest) and record the observed progress timeline.
        let onController = SourceTransferController(context: context, policy: TransferPolicy(pollInterval: .milliseconds(100), stallTimeout: .seconds(90)), setting: .on)
        let stream = await onController.events()
        let collector = Task {
            for await event in stream {
                log.add("on-event", event.key.sourceID.description.prefix(8).description, "\(event.state) provenance=\(event.provenance.rawValue)")
            }
        }
        let big = urls[2]
        let bigRecord = try #require(records[big.lastPathComponent])
        let requested = await onController.makeAvailable(bigRecord.key, at: big)
        log.add("on", big.lastPathComponent, "makeAvailable -> \(requested)")
        let bigFinal = await onController.waitUntilSettled(bigRecord.key)
        log.add("on", big.lastPathComponent, "final \(bigFinal); \(describe(system.metadata(at: big)))")
        #expect(bigFinal == .idle)

        // 7. Cancel: request file 2 then cancel quickly; observe whether the provider continues.
        let mid = urls[1]
        let midRecord = try #require(records[mid.lastPathComponent])
        let midRequested = await onController.makeAvailable(midRecord.key, at: mid)
        log.add("cancel", mid.lastPathComponent, "makeAvailable -> \(midRequested)")
        try await Task.sleep(for: .milliseconds(50))
        await onController.cancel(midRecord.key)
        log.add("cancel", mid.lastPathComponent, "state after cancel \(await onController.state(of: midRecord.key)); \(describe(system.metadata(at: mid)))")
        for second in [1, 3, 10] {
            try await Task.sleep(for: .seconds(second == 1 ? 1 : second == 3 ? 2 : 7))
            log.add("cancel", mid.lastPathComponent, "+\(second) s after cancel: \(describe(system.metadata(at: mid)))")
        }

        // 8. Retry: evict file 2 again if the provider finished it, then retry.
        if Self.status(system, mid) != .notDownloaded {
            let (code, output) = Self.brctl(["evict", mid.path])
            let evicted = await Self.waitFor(120) { Self.status(system, mid) == .notDownloaded }
            log.add("retry", mid.lastPathComponent, "re-evict brctl exit=\(code) \(output) -> \(evicted ? "evicted" : "NOT evicted")")
        }
        let retried = await onController.retry(midRecord.key, at: mid)
        log.add("retry", mid.lastPathComponent, "retry -> \(retried)")
        let midFinal = await onController.waitUntilSettled(midRecord.key)
        log.add("retry", mid.lastPathComponent, "final \(midFinal)")
        #expect(midFinal == .idle)

        // 9. Explicit per-item Make Available while OFF (user request) for file 1.
        let small = urls[0]
        let smallRecord = try #require(records[small.lastPathComponent])
        await onController.availabilitySettingChanged(to: .off)
        let explicit = await onController.makeAvailable(smallRecord.key, at: small, userRequested: true)
        let smallFinal = await onController.waitUntilSettled(smallRecord.key)
        log.add("explicit-off", small.lastPathComponent, "\(explicit) -> \(smallFinal)")
        collector.cancel()

        // 10. Immutability: all downloaded now; compare bytes with what the harness generated.
        var unchanged = 0
        for url in urls where (try? Data(contentsOf: url)) == generated[url] { unchanged += 1 }
        log.add("audit", "*", "bytesUnchanged=\(unchanged)/\(urls.count) totalDownloadRequests=\(io.count(.downloadRequest)) downloadFractionQueries=\(io.count(.downloadFraction)) ledger=\(context.ledger.snapshot)")
        #expect(unchanged == urls.count)
        #expect(context.ledger.snapshot.openScopes == 0)

        let report = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/evidence/ww-006-icloud-trial.json")
        try? fm.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(log.events).write(to: report)
    }

    @MainActor
    static func runOffMonitor(show: ShowID, records: [DeviceAccessRecord], context: SourceAccessContext) async throws {
        let monitor = SourceAvailabilityMonitor(showID: show, store: InMemoryDeviceAccessStore(), context: context, setting: .off)
        monitor.start()
        try await monitor.adopt(records)
        monitor.stop()
    }
}

/// Counting wrapper around the real gateway (observed provenance).
final class HarnessIOObserved: SourceIO, @unchecked Sendable {
    private let base = SystemSourceIO(progressQueryTimeout: .seconds(1))
    private let lock = NSLock()
    private var counts: [HarnessIO.Op: Int] = [:]
    var provenance: ObservationProvenance { .observed }

    func count(_ op: HarnessIO.Op) -> Int { lock.withLock { counts[op, default: 0] } }
    private func bump(_ op: HarnessIO.Op) { lock.withLock { counts[op, default: 0] += 1 } }

    func metadata(at url: URL) -> MetadataResult { bump(.metadata); return base.metadata(at: url) }
    func listItems(under directory: URL) -> DirectoryListing { bump(.list); return base.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { bump(.bookmarkCreate); return try base.makeReadOnlyBookmark(for: url) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { bump(.bookmarkResolve); return base.resolveBookmark(data) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { bump(.scopeStart); return base.startAccessingSecurityScope(url) }
    func stopAccessingSecurityScope(_ url: URL) { bump(.scopeStop); base.stopAccessingSecurityScope(url) }
    func requestDownload(of url: URL) throws { bump(.downloadRequest); try base.requestDownload(of: url) }
    func downloadFraction(of url: URL) async -> Knowledge<Double> { bump(.downloadFraction); return await base.downloadFraction(of: url) }
}
