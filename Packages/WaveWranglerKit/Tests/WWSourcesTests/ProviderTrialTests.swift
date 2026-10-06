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
    /// Live-provider tests (real iCloud Drive, `brctl`): opt-in only, WW_LIVE_PROVIDER_TESTS=1 (#146).
    static let enabled = ProcessInfo.processInfo.environment["WW_LIVE_PROVIDER_TESTS"] == "1"
    static let skipMessage: Comment = "Live iCloud/two-device test: skipped by default; set WW_LIVE_PROVIDER_TESTS=1 to opt in (#146)"
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

    @Test(.enabled(if: enabled, skipMessage), .timeLimit(.minutes(20)))
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
        await monitor.stop()
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

// MARK: - Frozen holdout: M1-SRC-ON-PROV-001 (m1-freeze-1), 50 OFF + 50 ON evict/availability cycles

struct ProviderCycleRecord: Codable, Sendable {
    var set: String            // "OFF" (default-OFF metadata-only) or "ON" (default-ON source availability)
    var index: Int
    var seed: String
    var bytes: Int
    var variant: String
    var evictedBefore: Bool
    var passed: Bool
    var failures: [String]
    /// OFF: whether the item was still a placeholder at the end of the hold window.
    var stillEvictedAfterHold: Bool?
    var holdSeconds: Double?
    var downloadRequests: Int
    var progressQueries: Int
    var knownProgressReports: Int
    var transferStates: [String]
    var finalState: String
    var secondsToLocal: Double?
    var providerAfterCancel: [String]
    var bytesUnchanged: Bool?
    var inodeSizeMtimeUnchanged: Bool?
    /// Which lstat fields differ from the pre-evict baseline (provider rematerialization, observed).
    var lstatFieldsChanged: [String]?
    /// The app's metadata-only identity verdict for the source after the cycle.
    var identityAfter: String?
    /// Seconds between the identity baseline recorded at import and the value after the cycle.
    var creationDateDelta: Double?
    var modificationDateDelta: Double?
    var scopeStarts: Int
    var scopeStops: Int
}

extension ProviderTrialTests {
    static let holdoutEnabled = enabled
        && ProcessInfo.processInfo.environment["WW_ICLOUD_HOLDOUT"] == "1"
    static let provFixtureID = "M1-SRC-ON-PROV-001"
    static let frozenOffCycles = 50
    static let frozenOnCycles = 50
    /// Frozen calibration is 5 cycles; this lane runs 5 OFF + 5 ON calibration cycles (more, never fewer).
    static let calibrationCycles = 5
    /// `WW_ICLOUD_SPLIT=calibration` runs the calibration split (separate seeds, reported separately).
    /// `WW_ICLOUD_SPLIT=recheck-78` runs 50 ON-only regression cycles for #78 on their own seeds
    /// (not holdout) and requires the identity verdict after download to be unchanged.
    static let provSplit: String = {
        switch ProcessInfo.processInfo.environment["WW_ICLOUD_SPLIT"] {
        case "calibration": "calibration"
        case "recheck-78": "recheck-78"
        default: "holdout"
        }
    }()
    static var runOffCycles: Bool { provSplit != "recheck-78" }

    struct LStat: Equatable {
        var ino: UInt64
        var size: Int64
        var mtimeSec: Int
        var mtimeNsec: Int
        var dataless: Bool

        func changedFields(from other: LStat?) -> [String] {
            guard let other else { return ["absent"] }
            var fields: [String] = []
            if ino != other.ino { fields.append("inode") }
            if size != other.size { fields.append("size") }
            if mtimeSec != other.mtimeSec || mtimeNsec != other.mtimeNsec { fields.append("mtime") }
            if dataless != other.dataless { fields.append("dataless") }
            return fields
        }
    }

    static func lstatValues(_ url: URL) -> LStat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return LStat(ino: UInt64(info.st_ino), size: Int64(info.st_size), mtimeSec: info.st_mtimespec.tv_sec, mtimeNsec: info.st_mtimespec.tv_nsec, dataless: info.st_flags & UInt32(SF_DATALESS) != 0)
    }

    static func evict(_ url: URL, log: TrialLog) async -> Bool {
        let (code, output) = brctl(["evict", url.path])
        let ok = await waitFor(120, interval: 0.25) { status(SystemSourceIO(), url) == .notDownloaded }
        if !ok { log.add("evict", url.lastPathComponent, "NOT evicted (brctl exit=\(code) \(output))") }
        return ok
    }

    /// Waits for a transfer to settle; cancels and reports a timeout instead of hanging the trial.
    static func settle(_ controller: SourceTransferController, _ key: DeviceAccessKey, limit: Duration) async -> (TransferState, timedOut: Bool) {
        await withTaskGroup(of: (TransferState, Bool)?.self) { group in
            group.addTask { (await controller.waitUntilSettled(key), false) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
                await controller.cancel(key)
                group.cancelAll()
                return (await controller.state(of: key), true)
            }
            return (.unknown, true)
        }
    }

    @Test(.enabled(if: holdoutEnabled, skipMessage), .timeLimit(.minutes(60)))
    func frozenHoldoutCycles() async throws {
        let log = TrialLog()
        let fm = FileManager.default
        let rootExisted = fm.fileExists(atPath: Self.trialRoot.path)
        let rootEntriesBefore = (try? fm.contentsOfDirectory(atPath: Self.trialRoot.path)) ?? []
        let sources = Self.trialRoot.appendingPathComponent("sources", isDirectory: true)
        if fm.fileExists(atPath: sources.path) {
            try fm.removeItem(at: sources)
            log.add("setup", "sources/", "removed a stale sources/ subfolder left by an earlier run of this lane")
        }
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        log.add("setup", "sources/", "created (trial root existed before: \(rootExisted); root entries before: \(rootEntriesBefore.sorted()))")
        var records: [ProviderCycleRecord] = []
        var cleanupNote = ""
        defer {
            try? fm.removeItem(at: sources)
            let sourcesGone = !fm.fileExists(atPath: sources.path)
            let remaining = (try? fm.contentsOfDirectory(atPath: Self.trialRoot.path)) ?? []
            if !rootExisted && remaining.isEmpty { try? fm.removeItem(at: Self.trialRoot) }
            cleanupNote = "sources/ deleted=\(sourcesGone); trial root existed before=\(rootExisted); root entries after=\(((try? fm.contentsOfDirectory(atPath: Self.trialRoot.path)) ?? []).sorted()); root present after=\(fm.fileExists(atPath: Self.trialRoot.path))"
            log.add("cleanup", "sources/", cleanupNote)
            Self.writeProviderEvidence(records: records, log: log, split: Self.provSplit)
        }

        // 1. Generate one random-byte file per holdout index (seeded per the registry derivation).
        let split = Self.provSplit
        let cycles = split == "calibration" ? Self.calibrationCycles : max(Self.frozenOffCycles, Self.frozenOnCycles)
        log.add("setup", "*", "split=\(split) cycles per set=\(cycles)")
        var generated: [(url: URL, data: Data, seed: UInt64)] = []
        for index in 0..<cycles {
            let seed = FixtureSeed.derive(fixtureID: Self.provFixtureID, split: split, caseIndex: index)
            var rng = SplitMix64(seed: seed)
            let size = Int.random(in: (32 * 1024)...(1024 * 1024), using: &rng)
            var data = Data(count: size)
            data.withUnsafeMutableBytes { buffer in
                for offset in buffer.indices { buffer[offset] = UInt8.random(in: 0...255, using: &rng) }
            }
            let url = sources.appendingPathComponent(String(format: "prov-\(split)-%02d.wav", index))
            try data.write(to: url)
            generated.append((url, data, seed))
        }
        log.add("generate", "*", "\(generated.count) files, \(generated.map(\.data.count).reduce(0, +)) bytes")
        for item in generated {
            let ok = await Self.waitFor(600, interval: 0.5) { Self.uploaded(item.url) }
            if !ok { log.add("upload", item.url.lastPathComponent, "NOT uploaded within 600 s") }
        }
        log.add("upload", "*", "upload wait finished")
        let baseline = Dictionary(uniqueKeysWithValues: generated.map { ($0.url, Self.lstatValues($0.url)) })

        // 2. OFF cycles, in batches of 10 with a 15 s hold window.
        let show = ShowID()
        var offRecords: [Int: ProviderCycleRecord] = [:]
        var offContexts: [Int: (SourceAccessContext, HarnessIOObserved)] = [:]
        var offAccess: [Int: DeviceAccessRecord] = [:]
        for batchStart in stride(from: 0, to: Self.runOffCycles ? cycles : 0, by: 10) {
            let batch = Array(batchStart..<min(batchStart + 10, cycles))
            for index in batch {
                let item = generated[index]
                let evicted = await Self.evict(item.url, log: log)
                let io = HarnessIOObserved()
                let context = SourceAccessContext(io: io, ledger: SecurityScopeLedger())
                offContexts[index] = (context, io)
                var record = ProviderCycleRecord(set: "OFF", index: index, seed: String(format: "%016llx", item.seed), bytes: item.data.count, variant: "evaluate+controller+monitor", evictedBefore: evicted, passed: false, failures: [], stillEvictedAfterHold: nil, holdSeconds: nil, downloadRequests: 0, progressQueries: 0, knownProgressReports: 0, transferStates: [], finalState: "", secondsToLocal: nil, providerAfterCancel: [], bytesUnchanged: nil, inodeSizeMtimeUnchanged: nil, scopeStarts: 0, scopeStops: 0)
                if !evicted { record.failures.append("could not create placeholder") }
                guard let accessRecord = try await SourceImporter(context: context).plan(selection: [item.url], showID: show).items.first?.accessRecord else {
                    record.failures.append("import failed")
                    offRecords[index] = record
                    continue
                }
                let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(key: accessRecord.key, record: accessRecord, setting: .off)
                if evaluation.observation.residency != .cloudPlaceholder { record.failures.append("residency \(evaluation.observation.residency)") }
                if evaluation.observation.transfer != .notRequested(.availabilityOff) { record.failures.append("transfer \(evaluation.observation.transfer)") }
                let controller = SourceTransferController(context: context, setting: .off)
                let state = await controller.makeAvailable(accessRecord.key, at: item.url)
                if state != .notRequested(.availabilityOff) { record.failures.append("controller \(state)") }
                record.transferStates = ["\(evaluation.observation.transfer)", "\(state)"]
                try await Self.runOffMonitor(show: show, records: [accessRecord], context: context)
                offAccess[index] = accessRecord
                offRecords[index] = record
            }
            let holdStart = Date()
            try await Task.sleep(for: .seconds(15))
            let held = Date().timeIntervalSince(holdStart)
            for index in batch {
                guard var record = offRecords[index], let (context, io) = offContexts[index] else { continue }
                let item = generated[index]
                let still = Self.status(SystemSourceIO(), item.url) == .notDownloaded
                let after = Self.lstatValues(item.url)
                record.stillEvictedAfterHold = still
                record.holdSeconds = (held * 10).rounded() / 10
                record.downloadRequests = io.count(.downloadRequest)
                record.progressQueries = io.count(.downloadFraction)
                record.scopeStarts = context.ledger.snapshot.starts
                record.scopeStops = context.ledger.snapshot.stops
                var expectedAfterEvict = baseline[item.url] ?? nil
                expectedAfterEvict?.dataless = true
                record.inodeSizeMtimeUnchanged = after == expectedAfterEvict
                record.lstatFieldsChanged = after?.changedFields(from: baseline[item.url] ?? nil) ?? ["absent"]
                record.finalState = still ? "placeholder" : "downloaded"
                if let accessRecord = offAccess[index] {
                    let identity = SourceAvailabilityEvaluator(context: context).evaluate(key: accessRecord.key, record: accessRecord, setting: .off)
                    record.identityAfter = "\(identity.observation.identity)"
                }
                if !still { record.failures.append("no longer a placeholder after the hold window") }
                if record.downloadRequests != 0 || record.progressQueries != 0 { record.failures.append("OFF made \(record.downloadRequests) download / \(record.progressQueries) progress requests") }
                if context.ledger.snapshot.openScopes != 0 { record.failures.append("open scopes") }
                if record.inodeSizeMtimeUnchanged != true { record.failures.append("lstat changed: \(String(describing: after)) vs \(String(describing: expectedAfterEvict))") }
                record.passed = record.failures.isEmpty
                records.append(record)
                log.add("off", item.url.lastPathComponent, "passed=\(record.passed) stillEvicted=\(still) requests=\(record.downloadRequests)/\(record.progressQueries) \(record.failures)")
            }
        }

        // 3. ON cycles on the same (still evicted) files: 0 automatic, 1 cancel then retry, 2 explicit request with the setting OFF.
        for index in 0..<cycles {
            let item = generated[index]
            var evicted = Self.status(SystemSourceIO(), item.url) == .notDownloaded
            if !evicted { evicted = await Self.evict(item.url, log: log) }
            let io = HarnessIOObserved()
            let context = SourceAccessContext(io: io, ledger: SecurityScopeLedger())
            let variant = ["automatic", "cancel-then-retry", "explicit-with-setting-off"][index % 3]
            var record = ProviderCycleRecord(set: "ON", index: index, seed: String(format: "%016llx", item.seed), bytes: item.data.count, variant: variant, evictedBefore: evicted, passed: false, failures: [], stillEvictedAfterHold: nil, holdSeconds: nil, downloadRequests: 0, progressQueries: 0, knownProgressReports: 0, transferStates: [], finalState: "", secondsToLocal: nil, providerAfterCancel: [], bytesUnchanged: nil, inodeSizeMtimeUnchanged: nil, scopeStarts: 0, scopeStops: 0)
            if !evicted { record.failures.append("could not create placeholder") }
            guard let accessRecord = try await SourceImporter(context: context).plan(selection: [item.url], showID: show).items.first?.accessRecord else {
                record.failures.append("import failed")
                records.append(record)
                continue
            }
            let controller = SourceTransferController(context: context, policy: TransferPolicy(pollInterval: .milliseconds(100)), setting: variant == "explicit-with-setting-off" ? .off : .on)
            let states = StateLog()
            let stream = await controller.events()
            let collector = Task { for await event in stream where event.key == accessRecord.key { states.append(event.state) } }
            let start = Date()
            switch variant {
            case "cancel-then-retry":
                _ = await controller.makeAvailable(accessRecord.key, at: item.url)
                try await Task.sleep(for: .milliseconds(50))
                await controller.cancel(accessRecord.key)
                for delay in [1.0, 3.0] {
                    try await Task.sleep(for: .seconds(delay == 1.0 ? 1.0 : 2.0))
                    let status = Self.status(SystemSourceIO(), item.url)
                    record.providerAfterCancel.append("+\(Int(delay)) s: \(status?.rawValue ?? "unknown")")
                }
                if Self.status(SystemSourceIO(), item.url) != .notDownloaded {
                    let reEvicted = await Self.evict(item.url, log: log)
                    record.providerAfterCancel.append("re-evicted=\(reEvicted)")
                }
                _ = await controller.retry(accessRecord.key, at: item.url)
            case "explicit-with-setting-off":
                _ = await controller.makeAvailable(accessRecord.key, at: item.url, userRequested: true)
            default:
                _ = await controller.makeAvailable(accessRecord.key, at: item.url)
            }
            let (final, timedOut) = await Self.settle(controller, accessRecord.key, limit: .seconds(180))
            await controller.shutdown()
            collector.cancel()
            record.secondsToLocal = final == .idle ? (Date().timeIntervalSince(start) * 1000).rounded() / 1000 : nil
            record.transferStates = states.states.map { "\($0)" }
            record.knownProgressReports = states.states.compactMap(\.reportedFraction).count
            record.finalState = "\(final)"
            record.downloadRequests = io.count(.downloadRequest)
            record.progressQueries = io.count(.downloadFraction)
            record.scopeStarts = context.ledger.snapshot.starts
            record.scopeStops = context.ledger.snapshot.stops
            let bytes = try? Data(contentsOf: item.url)
            record.bytesUnchanged = bytes == item.data
            let after = Self.lstatValues(item.url)
            record.lstatFieldsChanged = after?.changedFields(from: baseline[item.url] ?? nil) ?? ["absent"]
            let identity = SourceAvailabilityEvaluator(context: context).evaluate(key: accessRecord.key, record: accessRecord, setting: .on)
            record.identityAfter = "\(identity.observation.identity)"
            if case let .success(now) = SystemSourceIO().metadata(at: item.url), let baselineFingerprint = accessRecord.recordedIdentity?.fingerprint {
                if let a = baselineFingerprint.creationDate.value, let b = now.fingerprint.creationDate.value { record.creationDateDelta = b.timeIntervalSince(a) }
                if let a = baselineFingerprint.contentModificationDate.value, let b = now.fingerprint.contentModificationDate.value { record.modificationDateDelta = b.timeIntervalSince(a) }
            }
            record.inodeSizeMtimeUnchanged = after.map { LStat(ino: $0.ino, size: $0.size, mtimeSec: $0.mtimeSec, mtimeNsec: $0.mtimeNsec, dataless: false) } == baseline[item.url]?.map { LStat(ino: $0.ino, size: $0.size, mtimeSec: $0.mtimeSec, mtimeNsec: $0.mtimeNsec, dataless: false) }
            if timedOut { record.failures.append("did not settle within 180 s") }
            if split == "recheck-78", identity.observation.identity != .unverified(.baselineNotUserConfirmed) {
                record.failures.append("#78: identity after download \(identity.observation.identity)")
            }
            if final != .idle { record.failures.append("final \(final)") }
            if record.bytesUnchanged != true { record.failures.append("bytes differ from generated") }
            if context.ledger.snapshot.openScopes != 0 { record.failures.append("open scopes") }
            let expectedRequests = variant == "cancel-then-retry" ? 2 : 1
            if record.downloadRequests != expectedRequests { record.failures.append("download requests \(record.downloadRequests) != \(expectedRequests)") }
            record.passed = record.failures.isEmpty
            records.append(record)
            log.add("on", item.url.lastPathComponent, "\(variant) passed=\(record.passed) lstatChanged=\(record.lstatFieldsChanged ?? []) identity=\(record.identityAfter ?? "-") final=\(final) t=\(String(describing: record.secondsToLocal)) states=\(record.transferStates) knownProgress=\(record.knownProgressReports) \(record.providerAfterCancel) \(record.failures)")
        }

        let off = records.filter { $0.set == "OFF" }
        let on = records.filter { $0.set == "ON" }
        print("M1-SRC-ON-PROV-001 split=\(split) OFF cycles=\(off.count) passed=\(off.filter(\.passed).count) downloadRequests=\(off.map(\.downloadRequests).reduce(0, +)) progressQueries=\(off.map(\.progressQueries).reduce(0, +)) stillEvicted=\(off.filter { $0.stillEvictedAfterHold == true }.count)")
        print("M1-SRC-ON-PROV-001 split=\(split) ON cycles=\(on.count) passed=\(on.filter(\.passed).count) idle=\(on.filter { $0.finalState == "idle" }.count) bytesUnchanged=\(on.filter { $0.bytesUnchanged == true }.count) knownProgressReports=\(on.map(\.knownProgressReports).reduce(0, +)) downloadRequests=\(on.map(\.downloadRequests).reduce(0, +))")
        #expect(off.count >= (Self.runOffCycles ? cycles : 0))
        #expect(on.count >= cycles)
        let failedCycles = records.filter { !$0.passed }.count
        #expect(failedCycles == 0)
    }

    static func writeProviderEvidence(records: [ProviderCycleRecord], log: TrialLog, split: String) {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = records.compactMap { try? String(decoding: encoder.encode($0), as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("m1-src-on-prov-001-\(split)-cycles.jsonl"), atomically: true, encoding: .utf8)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(log.events).write(to: dir.appendingPathComponent("m1-src-on-prov-001-\(split)-log.json"))
    }
}
