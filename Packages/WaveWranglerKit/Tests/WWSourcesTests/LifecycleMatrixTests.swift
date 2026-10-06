import Darwin
import Foundation
import Testing
import WWCore
@testable import WWSources

// WW-006 lifecycle/error/cancel matrix (fixture registry M1-REF-001…017, M1-SRC-OFF-001, M1-SRC-ON-001/002).
// Every case runs on generated random-byte files in a private temp directory. Invariants checked for
// every case: zero leaked scopes, zero source writes (bytes + mtime + file id + mode of every file before
// vs after each app phase), zero silent substitutions, and zero download requests on OFF paths. Content,
// hash, header, preview and decode requests are structurally impossible (SourceIO has no such API and a
// source scan forbids them), so they are reported as 0 by construction.

enum MatrixFamily: String, CaseIterable, Sendable {
    case ref001 = "M1-REF-001", ref002 = "M1-REF-002", ref003 = "M1-REF-003", ref004 = "M1-REF-004"
    case ref005 = "M1-REF-005", ref006 = "M1-REF-006", ref007 = "M1-REF-007", ref008 = "M1-REF-008"
    case ref009 = "M1-REF-009", ref010 = "M1-REF-010", ref011 = "M1-REF-011", ref012 = "M1-REF-012"
    case ref013 = "M1-REF-013", ref014 = "M1-REF-014", ref015 = "M1-REF-015", ref016 = "M1-REF-016"
    case ref017 = "M1-REF-017"
    case srcOff001 = "M1-SRC-OFF-001", srcOn001 = "M1-SRC-ON-001", srcOn002 = "M1-SRC-ON-002"
    /// Added after review (not in the frozen registry): OFF toggled during an off-main refresh, explicit
    /// requests during automatic transfers, and stale terminal transfer states vs fresh evidence.
    case srcToggleRefresh = "M1-SRC-ON-002-REVIEW"

    /// Frozen registry splits.
    var holdout: Int {
        switch self {
        case .ref016: 150
        case .srcOff001, .srcOn001: 200
        case .srcOn002, .srcToggleRefresh: 100
        default: 60
        }
    }

    var calibration: Int { 10 }
    var isOffPath: Bool { self == .srcOff001 }
}

struct FamilyTally: Sendable, Codable {
    var family: String
    var calibrationCases = 0
    var holdoutCases = 0
    var failedAssertions = 0
    var leakedScopes = 0
    var sourceWrites = 0
    var substitutions = 0
    var downloadRequests = 0
    var offPathDownloadRequests = 0
    var scopeStarts = 0
    var simulatedCases = 0
    var observedCases = 0
    var failures: [String] = []
    /// Every case, including failures (post-freeze reporting: every case, actual counts).
    var cases: [CaseRecord] = []
}

/// One executed case. `seed` is the registry derivation for (fixtureID, split, index).
struct CaseRecord: Sendable, Codable {
    var family: String
    var split: String
    var index: Int
    var seed: String
    var passed: Bool
    var failures: [String]
    var leakedScopes: Int
    var sourceWrites: Int
    var substitutions: Int
    var downloadRequests: Int
    var progressQueries: Int
    var scopeStarts: Int
    var provenance: String
}

/// Frozen holdout/calibration counts from the WW-003 registry freeze `m1-freeze-1` (2026-10-05). The
/// harness may run more, never fewer.
enum FrozenCounts {
    static let freezeID = "m1-freeze-1"
    static let holdout: [String: Int] = [
        "M1-REF-001": 60, "M1-REF-002": 60, "M1-REF-003": 60, "M1-REF-004": 60, "M1-REF-005": 60,
        "M1-REF-006": 60, "M1-REF-007": 60, "M1-REF-008": 60, "M1-REF-009": 60, "M1-REF-010": 60,
        "M1-REF-011": 60, "M1-REF-012": 60, "M1-REF-013": 60, "M1-REF-014": 60, "M1-REF-015": 60,
        "M1-REF-016": 150, "M1-REF-017": 60,
        "M1-SRC-OFF-001": 200, "M1-SRC-ON-001": 200, "M1-SRC-ON-002": 100, "M1-SRC-ON-002-REVIEW": 100,
    ]
    static let calibration = 10
}

final class CaseEnv: @unchecked Sendable {
    let family: MatrixFamily
    let label: String
    let tree: SyntheticTree
    let io = HarnessIO()
    let context: SourceAccessContext
    let showID = ShowID()
    var rng: SplitMix64
    var writes = 0
    var substitutions = 0
    var failures: [String] = []
    /// Stall detection by unchanged polls, never wall-clock time, so results do not depend on host load.
    /// No non-stall script has more than 10 consecutive unchanged polls.
    let transferPolicy = TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 500, stalledPollInterval: .milliseconds(1), maxStalledPollInterval: .milliseconds(2))
    /// Only for the dedicated REF-015 stall cases.
    let stallPolicy = TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 5, stalledPollInterval: .milliseconds(1), maxStalledPollInterval: .milliseconds(2))

    init(family: MatrixFamily, split: String, index: Int) throws {
        self.family = family
        label = "\(family.rawValue)/\(split)/\(index)"
        rng = SplitMix64(seed: FixtureSeed.derive(fixtureID: family.rawValue, split: split, caseIndex: index))
        tree = try SyntheticTree(label: family.rawValue)
        context = SourceAccessContext(io: io, ledger: SecurityScopeLedger())
    }

    var importer: SourceImporter { SourceImporter(context: context) }
    var evaluator: SourceAvailabilityEvaluator { SourceAvailabilityEvaluator(context: context) }
    var relink: RelinkEvaluator { RelinkEvaluator(context: context) }

    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append("\(label): \(message())") }
    }

    /// Runs app code and counts any change to the source tree it caused.
    func app<T>(_ body: () async throws -> T) async rethrows -> T {
        let before = TreeSnapshot.take(tree.sources)
        do {
            let result = try await body()
            writes += TreeSnapshot.take(tree.sources).differences(from: before)
            return result
        } catch {
            writes += TreeSnapshot.take(tree.sources).differences(from: before)
            throw error
        }
    }

    static let names = [
        "ZOOM0001_Tr1.WAV", "Brandon.wav", "Guest 1.aif", "Host Mic.m4a", "220101_001_Tr2.WAV",
        "riverside_alex_raw-audio.flac", "Track 3.mp3", "take.caf", "Interview backup.wav",
    ]

    func pick<T>(_ values: [T]) -> T { values[Int.random(in: 0..<values.count, using: &rng)] }
    func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &rng) < percent }
    func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }

    func sourcePath() -> String {
        let folder = chance(50) ? "" : pick(["Recorder A/", "Zoom H6/ZOOM0001/", "Remote/Guests/"])
        return folder + pick(Self.names)
    }

    /// Generates and imports one source file.
    func importOne(path: String? = nil) async throws -> (url: URL, record: DeviceAccessRecord, inode: UInt64) {
        let url = try tree.file(path ?? sourcePath(), bytes: int(64...4096), rng: &rng)
        let plan = try await app { try await importer.plan(selection: [url], showID: showID) }
        guard let record = plan.items.first?.accessRecord else { throw MatrixError.importFailed }
        check(record.recordedIdentity?.confirmation == .provisional, "import baseline must be provisional")
        return (url, record, inode(of: url) ?? 0)
    }

    func evaluate(_ record: DeviceAccessRecord?, key: DeviceAccessKey? = nil, setting: SourceAvailabilitySetting = .on, transfer: TransferState? = nil) async -> SourceEvaluation {
        let key = key ?? record!.key
        return await app { evaluator.evaluate(key: key, record: record, setting: setting, transfer: transfer) }
    }

    /// An unconfirmed update may refresh the bookmark onto the *same* file object only; it may never
    /// change the identity baseline or location hint.
    func checkNoSubstitution(original: DeviceAccessRecord, updated: DeviceAccessRecord?, originalInode: UInt64) {
        guard let updated else { return }
        var substituted = false
        if updated.recordedIdentity != original.recordedIdentity { substituted = true }
        if updated.lastKnownPath != original.lastKnownPath { substituted = true }
        if updated.bookmark != original.bookmark, let data = updated.bookmark {
            if case let .resolved(url, _) = SystemSourceIO().resolveBookmark(data), inode(of: url) != originalInode {
                substituted = true
            }
        }
        if substituted {
            substitutions += 1
            failures.append("\(label): silent substitution")
        }
    }

    func transferController(setting: SourceAvailabilitySetting = .on) -> SourceTransferController {
        SourceTransferController(context: context, policy: transferPolicy, setting: setting)
    }

    func key(_ record: DeviceAccessRecord) -> DeviceAccessKey { record.key }
}

enum MatrixError: Error { case importFailed }

extension IdentityState {
    var isMismatch: Bool { if case .mismatch = self { true } else { false } }
    var isChanged: Bool { if case .changed = self { true } else { false } }
    var changedFields: [FingerprintField] {
        switch self {
        case let .changed(fields), let .mismatch(fields): fields
        default: []
        }
    }
}

extension LocationState {
    var isMoved: Bool { if case .moved = self { true } else { false } }
    var isMissing: Bool { if case .missing = self { true } else { false } }
}

extension TransferState {
    var isTerminal: Bool {
        switch self {
        case .idle, .cancelled, .failed, .offlineOrUnknown, .notRequested: true
        default: false
        }
    }
}

// MARK: - Families

enum MatrixScenarios {
    static func run(_ env: CaseEnv, index: Int) async throws {
        switch env.family {
        case .ref001: try await add(env)
        case .ref002: try await staleRefresh(env)
        case .ref003: try await regrant(env, variant: index % 4)
        case .ref004: try await moved(env, withReplacement: index % 2 == 1)
        case .ref005: try await copied(env, deleteOriginal: index % 2 == 1)
        case .ref006: try await renamed(env)
        case .ref007: try await sameNameSubstitute(env, variant: index % 3)
        case .ref008: try await denied(env, variant: index % 3)
        case .ref009: try await missing(env, deleteFolder: index % 2 == 1)
        case .ref010: try await changed(env, variant: index % 3)
        case .ref011: try await placeholder(env, variant: index % 6)
        case .ref012: try await progress(env, variant: index % 3)
        case .ref013: try await cancel(env)
        case .ref014: try await retry(env, variant: index % 3)
        case .ref015: try await offline(env, variant: index % 4)
        case .ref016: try await scopeInjection(env, op: index % 6, injection: (index / 6) % 5)
        case .ref017: try await crossMachine(env, variant: index % 3)
        case .srcOff001: try await offWorkflow(env, useMonitor: index % 3 == 0)
        case .srcOn001: try await onWorkflow(env, useMonitor: index % 4 == 0)
        case .srcOn002: try await toggle(env, keepUserRequested: index % 3 == 0)
        case .srcToggleRefresh: try await toggleDuringRefresh(env, variant: index % 4)
        }
    }

    // M1-REF-001
    static func add(_ env: CaseEnv) async throws {
        let audioCount = env.int(1...6)
        var noise = 0
        for index in 0..<audioCount {
            try env.tree.file("Recorder \(index % 2)/\(index)-\(env.pick(CaseEnv.names))", bytes: env.int(64...2048), rng: &env.rng)
        }
        for index in 0..<env.int(0...5) {
            try env.tree.file("Recorder \(index % 2)/\(env.pick(["notes.txt", "show.srt", "session.rpp", "peaks.reapeaks", ".hidden"]))-\(index).\(env.pick(["txt", "srt", "rpp", "reapeaks"]))", bytes: 16, rng: &env.rng)
            noise += 1
        }
        let plan = try await env.app { try await env.importer.plan(selection: [env.tree.sources], showID: env.showID) }
        env.check(plan.items.count == audioCount, "imported \(plan.items.count) of \(audioCount)")
        env.check(plan.skipped.totalIgnoredFiles == noise, "ignored \(plan.skipped.totalIgnoredFiles) of \(noise)")
        env.check(env.io.count(.metadata) == audioCount + 1, "metadata calls for non-audio files")
        for item in plan.items {
            env.check(item.sourceRecord.observations == SourceObservations(), "duration/channels must stay unknown")
            env.check(item.accessRecord.bookmark != nil, "bookmark missing")
            let evaluation = await env.evaluate(item.accessRecord)
            let observation = evaluation.observation
            env.check(observation.location == .present, "location \(observation.location)")
            env.check(observation.access == .granted, "access \(observation.access)")
            env.check(observation.identity == .unverified(.baselineNotUserConfirmed), "identity \(observation.identity)")
            env.check(observation.residency == .local, "residency \(observation.residency)")
            env.check(observation.transfer == .idle, "transfer \(observation.transfer)")
        }
    }

    // M1-REF-002
    static func staleRefresh(_ env: CaseEnv) async throws {
        var (url, record, originalInode) = try await env.importOne()
        let confirmed = env.chance(50)
        if confirmed { record = env.relink.confirmIdentity(of: record) }
        let destination = env.chance(50)
            ? url.deletingLastPathComponent().appendingPathComponent("renamed-\(env.int(1...999)).\(url.pathExtension)")
            : try env.tree.directory("Moved/\(env.int(1...9))").appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)

        let first = await env.evaluate(record)
        env.check(first.observation.location.isMoved, "location \(first.observation.location)")
        env.check(first.observation.access == .granted, "access \(first.observation.access)")
        env.check(first.observation.identity == (confirmed ? .matchesRecorded : .unverified(.baselineNotUserConfirmed)), "identity \(first.observation.identity)")
        env.checkNoSubstitution(original: record, updated: first.refreshedRecord, originalInode: originalInode)
        let current = first.refreshedRecord ?? record
        let second = await env.evaluate(current)
        env.check(second.observation.access == .granted && second.observation.location.isMoved, "after refresh \(second.observation.access) \(second.observation.location)")

        let proposal = await env.app { env.relink.evaluate(candidate: destination, for: record.key, record: current) }
        env.check(!proposal.requiresConfirmation, "moved original must be an exact match")
        let accepted = try env.relink.apply(proposal, to: current, userConfirmed: false)
        let third = await env.evaluate(accepted)
        env.check(third.observation.location == .present, "after accept \(third.observation.location)")
    }

    // M1-REF-003
    static func regrant(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne()
        var broken = record
        switch variant {
        case 0: broken.bookmark = Data((0..<env.int(8...64)).map { _ in UInt8.random(in: 0...255, using: &env.rng) })
        case 1: broken.bookmark = Data()
        case 2: broken.bookmark = nil
        default:
            broken.bookmark = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &env.rng) })
            try FileManager.default.removeItem(at: url)
        }
        let evaluation = await env.evaluate(broken)
        let observation = evaluation.observation
        env.check(observation.access == .needsRegrant, "access \(observation.access)")
        env.check(evaluation.refreshedRecord == nil, "must not refresh without a usable grant")
        env.check(observation.remedies.contains(.regrantAccess), "remedies \(observation.remedies)")
        switch variant {
        case 2: env.check(observation.location == .unknown, "location \(observation.location)")
        case 3: env.check(observation.location == .missing(lastKnownPathOccupied: .known(false)), "location \(observation.location)")
        default: env.check(observation.location == .present, "location \(observation.location)")
        }
        env.check(observation.access != .denied, "regrant is not denial")
    }

    // M1-REF-004
    static func moved(_ env: CaseEnv, withReplacement: Bool) async throws {
        let (url, record, originalInode) = try await env.importOne()
        let destination = try env.tree.directory("Elsewhere/\(env.int(1...5))/\(env.int(1...5))").appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        if withReplacement {
            try env.tree.file(url.path.replacingOccurrences(of: env.tree.sources.path + "/", with: ""), bytes: env.int(64...4096), rng: &env.rng)
        }
        let evaluation = await env.evaluate(record)
        let observation = evaluation.observation
        env.checkNoSubstitution(original: record, updated: evaluation.refreshedRecord, originalInode: originalInode)
        if observation.identity.isMismatch {
            env.check(evaluation.refreshedRecord == nil, "mismatch must not refresh")
            env.check(observation.remedies.contains(.reviewIdentityChange), "remedies \(observation.remedies)")
        } else {
            env.check(observation.location.isMoved, "location \(observation.location)")
            env.check(observation.identity == .unverified(.baselineNotUserConfirmed), "identity \(observation.identity)")
        }
        env.check(!(observation.location == .present && !observation.identity.isMismatch), "replacement reported as the original")
        let proposal = await env.app { env.relink.evaluate(candidate: destination, for: record.key, record: record) }
        env.check(proposal.comparison == .matches, "moved original comparison \(proposal.comparison)")
        if withReplacement {
            let replacement = await env.app { env.relink.evaluate(candidate: url, for: record.key, record: record) }
            env.check(replacement.requiresConfirmation, "replacement must require confirmation")
        }
    }

    // M1-REF-005
    static func copied(_ env: CaseEnv, deleteOriginal: Bool) async throws {
        let (url, record, originalInode) = try await env.importOne()
        let copy = url.deletingLastPathComponent().appendingPathComponent("copy-\(env.int(1...999))-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: copy)
        if deleteOriginal { try FileManager.default.removeItem(at: url) }
        let evaluation = await env.evaluate(record)
        env.checkNoSubstitution(original: record, updated: evaluation.refreshedRecord, originalInode: originalInode)
        if deleteOriginal {
            env.check(evaluation.observation.location == .missing(lastKnownPathOccupied: .known(false)), "location \(evaluation.observation.location)")
        } else {
            env.check(evaluation.observation.location == .present && evaluation.observation.access == .granted, "original \(evaluation.observation.location)")
        }
        let proposal = await env.app { env.relink.evaluate(candidate: copy, for: record.key, record: record) }
        env.check(proposal.requiresConfirmation, "copy must require confirmation")
        env.check(proposal.comparison != .matches, "copy compared as exact match")
        do {
            _ = try env.relink.apply(proposal, to: record, userConfirmed: false)
            env.check(false, "unconfirmed copy relink applied")
        } catch {}
        let confirmed = try env.relink.apply(proposal, to: record, userConfirmed: true)
        let after = await env.evaluate(confirmed)
        env.check(after.observation.identity == .matchesRecorded && after.observation.location == .present, "after confirm \(after.observation.identity)")
    }

    // M1-REF-006
    static func renamed(_ env: CaseEnv) async throws {
        let (url, record, originalInode) = try await env.importOne()
        let ext = env.chance(50) ? url.pathExtension.uppercased() : url.pathExtension.lowercased()
        let renamed = url.deletingLastPathComponent().appendingPathComponent("Renamed \(env.int(1...999)).\(ext)")
        try FileManager.default.moveItem(at: url, to: renamed)
        let evaluation = await env.evaluate(record)
        env.check(evaluation.observation.location.isMoved, "location \(evaluation.observation.location)")
        env.check(evaluation.observation.identity == .unverified(.baselineNotUserConfirmed), "identity \(evaluation.observation.identity)")
        env.checkNoSubstitution(original: record, updated: evaluation.refreshedRecord, originalInode: originalInode)
        env.check(evaluation.refreshedRecord?.lastKnownPath ?? record.lastKnownPath == record.lastKnownPath, "hint changed without confirmation")
    }

    // M1-REF-007
    static func sameNameSubstitute(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, originalInode) = try await env.importOne()
        let size = Int(record.recordedIdentity?.fingerprint.fileSize.value ?? 64)
        if variant == 1 {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("archived-\(url.lastPathComponent)"))
        } else {
            try FileManager.default.removeItem(at: url)
        }
        let relative = String(url.standardizedFileURL.path.dropFirst(env.tree.sources.standardizedFileURL.path.count + 1))
        try env.tree.file(relative, bytes: variant == 2 ? size : env.int(64...4096), rng: &env.rng)
        if variant == 2 {
            try setDates(url, modification: record.recordedIdentity?.fingerprint.contentModificationDate.value, creation: record.recordedIdentity?.fingerprint.creationDate.value)
        }
        let evaluation = await env.evaluate(record)
        env.check(evaluation.observation.identity.isMismatch, "identity \(evaluation.observation.identity)")
        env.check(evaluation.refreshedRecord == nil, "substitute must not refresh the bookmark")
        env.check(evaluation.observation.access != .granted || evaluation.observation.identity.isMismatch, "substitute granted as original")
        env.checkNoSubstitution(original: record, updated: evaluation.refreshedRecord, originalInode: originalInode)
        let proposal = await env.app { env.relink.evaluate(candidate: url, for: record.key, record: record) }
        env.check(proposal.requiresConfirmation, "same-name candidate must require confirmation")
        env.check(proposal.comparison.isExactMatch == false, "same-name compared equal")
        if variant == 2, case let .differs(fields, _) = proposal.comparison {
            env.check(fields.contains(.fileIdentifier), "file identity must differ")
        }
    }

    // M1-REF-008
    static func denied(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne(path: "Locked/\(env.pick(CaseEnv.names))")
        let before = TreeSnapshot.take(env.tree.sources)
        let target = variant == 1 ? url.deletingLastPathComponent() : url
        chmod(target.path, variant == 2 ? 0o200 : 0)
        let evaluation = env.evaluator.evaluate(key: record.key, record: record, setting: .on)
        let proposal = env.relink.evaluate(candidate: url, for: record.key, record: record)
        chmod(target.path, variant == 1 ? 0o755 : 0o644)
        env.writes += TreeSnapshot.take(env.tree.sources).differences(from: before) > 0 ? 1 : 0
        env.check(evaluation.observation.access == .denied, "access \(evaluation.observation.access)")
        env.check(!evaluation.observation.location.isMissing, "denied reported as missing")
        env.check(evaluation.observation.remedies.contains(.checkPermissions), "remedies \(evaluation.observation.remedies)")
        env.check(!proposal.canApply || variant != 1, "denied candidate must not apply")
    }

    // M1-REF-009
    static func missing(_ env: CaseEnv, deleteFolder: Bool) async throws {
        let (url, record, _) = try await env.importOne(path: "Gone/\(env.int(1...9))/\(env.pick(CaseEnv.names))")
        try FileManager.default.removeItem(at: deleteFolder ? url.deletingLastPathComponent() : url)
        let evaluation = await env.evaluate(record)
        env.check(evaluation.observation.location == .missing(lastKnownPathOccupied: .known(false)), "location \(evaluation.observation.location)")
        env.check(evaluation.observation.access != .denied, "missing reported as denied")
        env.check(evaluation.observation.remedies.contains(.relink), "remedies \(evaluation.observation.remedies)")
        let proposal = await env.app { env.relink.evaluate(candidate: url, for: record.key, record: record) }
        env.check(proposal.availability == .notFound && !proposal.canApply, "missing candidate \(proposal.availability)")
    }

    // M1-REF-010
    static func changed(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, originalInode) = try await env.importOne()
        if variant != 1 { try appendBytes(url, count: env.int(1...64)) }
        if variant != 0 {
            try setDates(url, modification: Date().addingTimeInterval(TimeInterval(env.int(5...5000))), creation: nil)
        }
        let evaluation = await env.evaluate(record)
        env.check(evaluation.observation.identity.isChanged, "identity \(evaluation.observation.identity)")
        let fields = Set(evaluation.observation.identity.changedFields)
        env.check(!fields.isEmpty && fields.isSubset(of: [.fileSize, .contentModificationDate]), "fields \(fields)")
        env.check(evaluation.observation.remedies.contains(.reviewIdentityChange), "remedies")
        env.checkNoSubstitution(original: record, updated: evaluation.refreshedRecord, originalInode: originalInode)
        let proposal = await env.app { env.relink.evaluate(candidate: url, for: record.key, record: record) }
        env.check(proposal.requiresConfirmation, "changed file must require confirmation")
    }

    // M1-REF-011
    static func placeholder(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne()
        let setting: SourceAvailabilitySetting = variant % 2 == 0 ? .off : .on
        let kind: SimulatedCloudItem.Kind = [.iCloud, .datalessUnknownProvider, .unreported][variant / 2]
        env.io.simulate(url, SimulatedCloudItem(kind: kind, script: [.progress(0.5), .complete]))
        let evaluation = await env.evaluate(record, setting: setting)
        let observation = evaluation.observation
        env.check(observation.provenance == .simulated, "provenance must be simulated")
        switch kind {
        case .iCloud:
            env.check(observation.residency == .cloudPlaceholder && observation.residencyEvidence == .ubiquitousResourceValues, "residency \(observation.residency)")
            env.check(observation.transfer == (setting == .off ? .notRequested(.availabilityOff) : .unknown), "transfer \(observation.transfer)")
        case .datalessUnknownProvider:
            env.check(observation.residency == .cloudPlaceholder && observation.residencyEvidence == .fileSystemDatalessFlag, "residency \(observation.residency)")
            env.check(observation.transfer == .notRequested(.unsupportedLocation), "transfer \(observation.transfer)")
        case .unreported:
            env.check(observation.residency == .unknown, "residency \(observation.residency)")
        }
        let controller = env.transferController(setting: setting)
        let state = await env.app { await controller.makeAvailable(record.key, at: url) }
        let expectedRequests = kind == .iCloud && setting == .on ? 1 : 0
        env.check(env.io.count(.downloadRequest) == expectedRequests, "requests \(env.io.count(.downloadRequest))")
        if expectedRequests == 1 {
            env.check(state == .requested, "state \(state)")
            _ = await controller.waitUntilSettled(record.key)
        }
    }

    static func collectEvents(_ controller: SourceTransferController, key: DeviceAccessKey) async -> Task<[TransferState], Never> {
        let stream = await controller.events()
        return Task {
            var states: [TransferState] = []
            for await event in stream where event.key == key {
                states.append(event.state)
                if event.state.isTerminal { break }
            }
            return states
        }
    }

    // M1-REF-012
    static func progress(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne()
        var script: [SimulatedCloudItem.Step] = []
        var reported: Set<Double> = []
        switch variant {
        case 0:
            var value = 0.0
            for _ in 0..<env.int(1...8) {
                value = min(0.99, value + Double(env.int(1...30)) / 100)
                reported.insert(value)
                script.append(.progress(value))
            }
        case 1:
            script = Array(repeating: .progress(nil), count: env.int(1...6))
        default:
            break
        }
        script.append(.complete)
        env.io.simulate(url, SimulatedCloudItem(script: script))
        let controller = env.transferController()
        let collector = await collectEvents(controller, key: record.key)
        _ = await env.app { await controller.makeAvailable(record.key, at: url) }
        let final = await controller.waitUntilSettled(record.key)
        let states = await collector.value
        env.check(final == .idle, "final \(final)")
        for state in states {
            if let fraction = state.reportedFraction {
                env.check(reported.contains(fraction), "invented fraction \(fraction)")
            }
        }
        if variant != 0 {
            env.check(states.allSatisfy { $0.reportedFraction == nil }, "determinate progress without a report")
        }
        let after = await env.evaluate(record)
        env.check(after.observation.residency == .local, "residency after \(after.observation.residency)")
    }

    // M1-REF-013
    static func cancel(_ env: CaseEnv) async throws {
        let (url, record, _) = try await env.importOne()
        let item = SimulatedCloudItem(script: (1...40).map { .progress(Double($0) / 50) } + [.complete])
        env.io.simulate(url, item)
        let controller = env.transferController()
        _ = await env.app { await controller.makeAvailable(record.key, at: url) }
        try await Task.sleep(for: .milliseconds(env.int(0...6)))
        await controller.cancel(record.key)
        let settled = await controller.waitUntilSettled(record.key)
        env.check(settled == .cancelled || settled == .idle, "after cancel \(settled)")
        try await Task.sleep(for: .milliseconds(5))
        env.check(await controller.state(of: record.key) == settled, "state changed after cancel")
        env.check(await controller.activeCount == 0, "active after cancel")
        env.check(env.io.count(.downloadRequest) == 1, "requests \(env.io.count(.downloadRequest))")
        if settled == .cancelled {
            let evaluation = await env.evaluate(record, transfer: settled)
            env.check(evaluation.observation.remedies.contains(.retryTransfer), "cancel must offer retry")
            env.check(evaluation.observation.residency != .local || item.status != .notDownloaded, "cancelled shown as available")
        }
    }

    // M1-REF-014
    static func retry(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne()
        let offline = SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let failure = SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        let item: SimulatedCloudItem
        switch variant {
        case 0: item = SimulatedCloudItem(script: [.progress(0.2), .error(offline)])
        case 1: item = SimulatedCloudItem(script: [.error(failure)])
        default: item = SimulatedCloudItem(script: [], requestError: offline)
        }
        env.io.simulate(url, item)
        let controller = env.transferController()
        // Hold the first attempt's first observation poll so the duplicate request deterministically
        // lands while it is in flight (variant 2 fails at request time and never starts a transfer).
        await env.io.fractionGate.arm()
        _ = await env.app { await controller.makeAvailable(record.key, at: url) }
        if variant != 2 {
            env.check(await env.io.fractionGate.waitUntilEntered(), "first attempt never polled")
            env.check(await controller.isActive(record.key), "first attempt not active while held")
        }
        _ = await controller.retry(record.key, at: url)
        env.check(await controller.activeCount <= 1, "more than one active request")
        // Variants 0/1: the duplicate is a no-op while active. Variant 2: there was nothing active, so the
        // call is a genuine retry after the request-time failure.
        env.check(env.io.count(.downloadRequest) == (variant == 2 ? 2 : 1), "requests after duplicate call (\(env.io.count(.downloadRequest)))")
        await env.io.fractionGate.release()
        let first = await controller.waitUntilSettled(record.key)
        if variant == 2 {
            // The duplicate call was itself a retry after the immediate request failure.
            env.check(first.isOfflineOrUnknown, "request-time failure \(first)")
        } else {
            env.check(first.isOfflineOrUnknown || first.isFailed, "first attempt \(first)")
        }
        let firstRequests = env.io.count(.downloadRequest)
        // Harness: the provider is idle and still not downloaded, so a retry must issue a new request.
        item.evictAgain(script: [.progress(0.6), .complete])
        item.requestError = nil
        _ = await env.app { await controller.retry(record.key, at: url) }
        env.check(await controller.activeCount <= 1, "more than one active request")
        let second = await controller.waitUntilSettled(record.key)
        env.check(second == .idle, "after retry \(second)")
        env.check(env.io.count(.downloadRequest) == firstRequests + 1, "retry requests \(env.io.count(.downloadRequest))")
    }

    // M1-REF-015
    /// Variants: 0 offline at request time, 1 provider-reported unavailable, 2 stall then user cancel,
    /// 3 stall then the provider completes (observation continues with backoff and flips to idle).
    static func offline(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne()
        switch variant {
        case 0: env.io.simulate(url, SimulatedCloudItem(script: [], requestError: SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        case 1: env.io.simulate(url, SimulatedCloudItem(script: [.progress(nil), .error(SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUnavailableError))]))
        // Stall variants start with a harness-controlled `.hold`: the provider stays stalled until the
        // harness has observed and evaluated the published stall, so completion can never race the
        // checks (#85). Recipe, truth, seeds and counts are unchanged (the RNG draw is kept).
        case 2: env.io.simulate(url, SimulatedCloudItem(script: [.hold]))
        default: env.io.simulate(url, SimulatedCloudItem(script: [.hold] + Array(repeating: .stall, count: env.int(8...40)) + [.complete]))
        }
        let controller = SourceTransferController(context: env.context, policy: variant >= 2 ? env.stallPolicy : env.transferPolicy, setting: .on)
        let collector = await eventCollector(controller, key: record.key) { $0.isOfflineOrUnknown || $0 == .idle || $0.isFailed }
        _ = await env.app { await controller.makeAvailable(record.key, at: url) }
        let firstTerminal = (await collector.value).last
        env.check(firstTerminal?.isOfflineOrUnknown == true, "first terminal \(String(describing: firstTerminal))")
        if variant >= 2 {
            env.check(await controller.isActive(record.key), "stalled transfer stopped observing")
        }
        let reported = await controller.reportableState(of: record.key)
        let evaluation = await env.evaluate(record, transfer: reported)
        env.check(evaluation.observation.residency == .cloudPlaceholder || evaluation.observation.residency == .downloading, "residency \(evaluation.observation.residency)")
        env.check(evaluation.observation.transfer.isOfflineOrUnknown, "transfer \(evaluation.observation.transfer)")
        env.check(evaluation.observation.remedies.contains(.retryTransfer), "remedies \(evaluation.observation.remedies)")
        switch variant {
        case 2:
            await controller.cancel(record.key)
            let afterCancel = await controller.state(of: record.key)
            env.check(afterCancel == .cancelled, "after cancel \(afterCancel)")
            env.check(env.context.ledger.snapshot.openScopes == 0, "scope open after cancel returned")
            env.check(await controller.activeCount == 0, "still observing after cancel")
        case 3:
            // The provider resumes only now, after the stall was observed and evaluated.
            env.io.releaseHold(url)
            let final = await controller.waitUntilSettled(record.key)
            env.check(final == .idle, "stall then complete \(final)")
            let after = await env.evaluate(record, transfer: await controller.reportableState(of: record.key))
            env.check(after.observation.residency == .local && after.observation.transfer == .idle, "after completion \(after.observation.residency) \(after.observation.transfer)")
        default:
            break
        }
        env.check(env.io.count(.downloadRequest) == 1, "requests \(env.io.count(.downloadRequest))")
    }

    // M1-REF-016
    static func scopeInjection(_ env: CaseEnv, op: Int, injection: Int) async throws {
        let (url, record, originalInode) = try await env.importOne()
        switch injection {
        case 0: env.io.faults.scopeStartFails = true
        case 1: env.io.faults.metadataFailures[HarnessIO.key(url)] = env.chance(50) ? .permissionDenied : .other(SourceErrorDescriptor(domain: "WWInjected", code: 1))
        case 2: env.io.faults.bookmarkCreateFails = true
        case 3: env.io.simulate(url, SimulatedCloudItem(script: (1...30).map { .progress(Double($0) / 40) } + [.complete]))
        default: break
        }
        let cancelEarly = injection == 3 || env.chance(30)
        switch op {
        case 0:
            for index in 0..<env.int(5...40) { try env.tree.file("bulk/\(index).wav", bytes: 32, rng: &env.rng) }
            let task = Task { try await env.importer.plan(selection: [env.tree.sources], showID: env.showID) }
            if cancelEarly { task.cancel() }
            _ = try? await task.value
        case 1:
            let evaluation = await env.evaluate(record)
            env.checkNoSubstitution(original: record, updated: evaluation.refreshedRecord, originalInode: originalInode)
        case 2:
            let proposal = await env.app { env.relink.evaluate(candidate: url, for: record.key, record: record) }
            if injection == 2 { env.check(!proposal.canApply, "bookmark failure must block apply") }
        case 3:
            let other = try env.tree.file("other.wav", bytes: 48, rng: &env.rng)
            let proposal = await env.app { env.relink.evaluate(candidate: other, for: record.key, record: record) }
            do {
                _ = try env.relink.apply(proposal, to: record, userConfirmed: false)
                env.check(false, "unconfirmed relink applied")
            } catch {}
        case 4:
            if injection != 3 { env.io.simulate(url, SimulatedCloudItem(script: (1...20).map { .progress(Double($0) / 25) } + [.complete])) }
            let controller = env.transferController()
            _ = await controller.makeAvailable(record.key, at: url)
            if cancelEarly { await controller.cancel(record.key) }
            _ = await controller.waitUntilSettled(record.key)
        default:
            let task = Task { () -> SourceEvaluation in
                try await Task.sleep(for: .milliseconds(env.int(0...2)))
                return env.evaluator.evaluate(key: record.key, record: record, setting: .on)
            }
            if cancelEarly { task.cancel() }
            _ = try? await task.value
        }
        let snapshot = env.context.ledger.snapshot
        env.check(snapshot.openScopes == 0 && snapshot.starts == snapshot.stops, "ledger \(snapshot)")
    }

    // M1-REF-017
    static func crossMachine(_ env: CaseEnv, variant: Int) async throws {
        let url = try env.tree.file(env.sourcePath(), bytes: env.int(64...4096), rng: &env.rng)
        let key = DeviceAccessKey(showID: env.showID, sourceID: SourceID())
        let record: DeviceAccessRecord? = switch variant {
        case 0: nil
        case 1: DeviceAccessRecord(showID: env.showID, sourceID: key.sourceID, bookmark: Data((0..<48).map { _ in UInt8.random(in: 0...255, using: &env.rng) }), lastKnownPath: "/Volumes/WW-Other-Mac-\(env.int(1...99))/Shows/\(url.lastPathComponent)", createdAt: Date())
        default: DeviceAccessRecord(showID: env.showID, sourceID: key.sourceID, createdAt: Date())
        }
        let evaluation = await env.evaluate(record, key: key)
        env.check(evaluation.observation.access == .needsRegrant, "access \(evaluation.observation.access)")
        env.check(evaluation.observation.remedies.contains(.regrantAccess), "remedies")
        if variant == 1 {
            env.check(evaluation.observation.location == .missing(lastKnownPathOccupied: .known(false)), "location \(evaluation.observation.location)")
        } else {
            env.check(evaluation.observation.location == .unknown, "location \(evaluation.observation.location)")
            env.check(evaluation.observation.identity == .unverified(.noRecordedEvidence), "identity \(evaluation.observation.identity)")
        }
        let proposal = await env.app { env.relink.evaluate(candidate: url, for: key, record: record) }
        env.check(proposal.requiresConfirmation && proposal.comparison == .unknown(FingerprintField.allCases), "comparison \(proposal.comparison)")
        do {
            _ = try env.relink.apply(proposal, to: record, userConfirmed: false)
            env.check(false, "cross-machine relink applied without confirmation")
        } catch {}
        let linked = try env.relink.apply(proposal, to: record, userConfirmed: true)
        let after = await env.evaluate(linked)
        env.check(after.observation.identity == .matchesRecorded && after.observation.access == .granted && after.observation.location == .present, "after relink \(after.observation)")
    }

    // MARK: Source availability families

    static func makeMixedSources(_ env: CaseEnv) async throws -> [(url: URL, record: DeviceAccessRecord, kind: SimulatedCloudItem.Kind?, script: [SimulatedCloudItem.Step])] {
        var result: [(URL, DeviceAccessRecord, SimulatedCloudItem.Kind?, [SimulatedCloudItem.Step])] = []
        for index in 0..<env.int(2...6) {
            let url = try env.tree.file("Episode/\(index)-\(env.pick(CaseEnv.names))", bytes: env.int(64...1024), rng: &env.rng)
            let plan = try await env.app { try await env.importer.plan(selection: [url], showID: env.showID) }
            guard let record = plan.items.first?.accessRecord else { throw MatrixError.importFailed }
            let kind: SimulatedCloudItem.Kind? = env.pick([nil, .iCloud, .iCloud, .datalessUnknownProvider, .unreported])
            var script: [SimulatedCloudItem.Step] = []
            if let kind {
                script = env.pick([
                    [.complete],
                    [.progress(0.25), .progress(0.75), .complete],
                    [.progress(nil), .progress(nil), .complete],
                    [.progress(0.1), .error(SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))],
                    [.error(SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError))],
                ])
                env.io.simulate(url, SimulatedCloudItem(kind: kind, script: script))
            }
            result.append((url, record, kind, script))
        }
        return result
    }

    static func expectedFinal(_ script: [SimulatedCloudItem.Step]) -> (TransferState) -> Bool {
        switch script.last {
        case let .error(error)?:
            let expected = TransferErrorClassifier.state(for: error)
            return { $0 == expected }
        default:
            return { $0 == .idle }
        }
    }

    // M1-SRC-OFF-001
    static func offWorkflow(_ env: CaseEnv, useMonitor: Bool) async throws {
        let sources = try await makeMixedSources(env)
        let storeURL = env.tree.root.appendingPathComponent("device-access/records.json")
        try await FileDeviceAccessStore(fileURL: storeURL).save(sources.map(\.record))
        let reloaded = try await FileDeviceAccessStore(fileURL: storeURL).allRecords()
        env.check(reloaded.count == sources.count, "store rebuild lost records")
        let controller = env.transferController(setting: .off)
        for source in sources {
            let evaluation = await env.evaluate(source.record, setting: .off)
            if source.kind == .iCloud {
                env.check(evaluation.observation.transfer == .notRequested(.availabilityOff), "OFF transfer \(evaluation.observation.transfer)")
                env.check(evaluation.observation.remedies.contains(.makeAvailable), "OFF must offer explicit Make Available")
            }
            _ = await env.app { await controller.makeAvailable(source.record.key, at: source.url) }
        }
        if let first = sources.first {
            let proposal = await env.app { env.relink.evaluate(candidate: first.url, for: first.record.key, record: first.record) }
            _ = try env.relink.apply(proposal, to: first.record, userConfirmed: true)
        }
        if useMonitor {
            try await runMonitor(env, records: sources.map(\.record), setting: .off)
        }
        env.check(env.io.count(.downloadRequest) == 0, "OFF download requests \(env.io.count(.downloadRequest))")
        env.check(env.io.count(.downloadFraction) == 0, "OFF progress queries \(env.io.count(.downloadFraction))")
    }

    @MainActor
    static func runMonitor(_ env: CaseEnv, records: [DeviceAccessRecord], setting: SourceAvailabilitySetting) async throws {
        let monitor = SourceAvailabilityMonitor(showID: env.showID, store: InMemoryDeviceAccessStore(), context: env.context, setting: setting, transferPolicy: env.transferPolicy)
        monitor.start()
        let before = TreeSnapshot.take(env.tree.sources)
        try await monitor.adopt(records)
        for record in records { _ = await monitor.transfers.waitUntilSettled(record.key) }
        env.writes += TreeSnapshot.take(env.tree.sources).differences(from: before)
        await monitor.stop()
        env.check(monitor.observations.count == records.count, "monitor observations")
    }

    // M1-SRC-ON-001
    static func onWorkflow(_ env: CaseEnv, useMonitor: Bool) async throws {
        let sources = try await makeMixedSources(env)
        let placeholders = sources.filter { $0.kind == .iCloud }
        if useMonitor {
            try await runMonitor(env, records: sources.map(\.record), setting: .on)
            env.check(env.io.count(.downloadRequest) == placeholders.count, "monitor requests \(env.io.count(.downloadRequest)) for \(placeholders.count) placeholders")
            return
        }
        let controller = env.transferController()
        for source in sources {
            let evaluation = await env.evaluate(source.record, setting: .on)
            if evaluation.observation.residency == .cloudPlaceholder, evaluation.supportsDownloadRequest {
                _ = await env.app { await controller.makeAvailable(source.record.key, at: source.url) }
            } else if source.kind == .datalessUnknownProvider {
                env.check(evaluation.observation.transfer == .notRequested(.unsupportedLocation), "unsupported \(evaluation.observation.transfer)")
            }
        }
        env.check(env.io.count(.downloadRequest) == placeholders.count, "requests \(env.io.count(.downloadRequest)) for \(placeholders.count) placeholders")
        for source in placeholders {
            let final = await controller.waitUntilSettled(source.record.key)
            env.check(expectedFinal(source.script)(final), "final \(final) for \(source.script)")
        }
    }

    // M1-SRC-ON-002
    static func toggle(_ env: CaseEnv, keepUserRequested: Bool) async throws {
        var placeholders: [(URL, DeviceAccessRecord)] = []
        for index in 0..<env.int(1...4) {
            let url = try env.tree.file("Toggle/\(index).wav", bytes: 128, rng: &env.rng)
            let plan = try await env.app { try await env.importer.plan(selection: [url], showID: env.showID) }
            guard let record = plan.items.first?.accessRecord else { throw MatrixError.importFailed }
            env.io.simulate(url, SimulatedCloudItem(script: (1...25).map { .progress(Double($0) / 30) } + [.complete]))
            placeholders.append((url, record))
        }
        let controller = env.transferController()
        for (offset, (url, record)) in placeholders.enumerated() {
            _ = await env.app { await controller.makeAvailable(record.key, at: url, userRequested: keepUserRequested && offset == 0) }
        }
        let initialRequests = env.io.count(.downloadRequest)
        env.check(initialRequests == placeholders.count, "initial requests")
        try await Task.sleep(for: .milliseconds(env.int(0...5)))
        await controller.availabilitySettingChanged(to: .off)
        for (offset, (_, record)) in placeholders.enumerated() {
            let state = await controller.state(of: record.key)
            if keepUserRequested && offset == 0 {
                env.check(state != .cancelled, "user-requested transfer cancelled by OFF")
            } else {
                env.check(state == .cancelled || state == .idle, "after OFF \(state)")
            }
        }
        // OFF: re-evaluation and automatic requests issue nothing.
        for (url, record) in placeholders.dropFirst(keepUserRequested ? 1 : 0) {
            _ = await env.app { await controller.makeAvailable(record.key, at: url) }
        }
        env.check(env.io.count(.downloadRequest) == initialRequests, "OFF issued requests")
        // ON again: resume only items that are still not local (observe-only when the provider is still busy).
        await controller.availabilitySettingChanged(to: .on)
        for (url, record) in placeholders {
            _ = await env.app { await controller.makeAvailable(record.key, at: url) }
        }
        for (_, record) in placeholders {
            let final = await controller.waitUntilSettled(record.key)
            env.check(final == .idle, "after ON \(final)")
        }
        env.check(env.io.count(.downloadRequest) <= initialRequests * 2, "duplicate requests")
    }
}

extension MatrixScenarios {
    static let longScript: [SimulatedCloudItem.Step] = (1...60).map { .progress(Double($0) / 70) } + [.complete]

    /// M1-SRC-ON-002-REVIEW. Variants:
    /// 0 OFF while a refresh's evaluation is in flight ⇒ zero requests.
    /// 1 explicit Make Available during an automatic transfer, then OFF ⇒ the transfer survives.
    /// 2 ON download completes, OFF, provider evicts ⇒ fresh `notRequested(.availabilityOff)`, not stale idle.
    /// 3 stale `notRequested(.awaitingAccess)` ⇒ replaced by fresh evidence once access works.
    @MainActor
    static func toggleDuringRefresh(_ env: CaseEnv, variant: Int) async throws {
        let (url, record, _) = try await env.importOne()
        let item = SimulatedCloudItem(script: variant == 2 ? [.progress(0.5), .complete] : longScript)
        env.io.simulate(url, item)
        let store = InMemoryDeviceAccessStore([record])
        let monitor = SourceAvailabilityMonitor(showID: env.showID, store: store, context: env.context, setting: .on, transferPolicy: env.transferPolicy)
        monitor.start()
        let id = record.sourceID
        let before = TreeSnapshot.take(env.tree.sources)
        defer { env.writes += TreeSnapshot.take(env.tree.sources).differences(from: before) }

        switch variant {
        case 0:
            let evaluationGate = AsyncGate()
            await evaluationGate.arm()
            monitor.evaluatorTaskDidStart = { await evaluationGate.pass() }
            let refresh = Task { await monitor.refresh([id]) }
            env.check(await evaluationGate.waitUntilEntered(), "detached evaluator task never started")
            await monitor.setAvailabilitySetting(.off)
            await evaluationGate.release()
            await refresh.value
            env.check(env.io.count(.downloadRequest) == 0, "requests after OFF \(env.io.count(.downloadRequest))")
            env.check(await monitor.transfers.activeCount == 0, "active transfer after OFF")
            env.check(monitor.observations[id]?.transfer == .notRequested(.availabilityOff), "observation \(String(describing: monitor.observations[id]?.transfer))")
        case 1:
            // Hold the automatic transfer's first poll so the explicit request lands while it is in flight.
            await env.io.fractionGate.arm()
            await monitor.refresh([id])
            env.check(env.io.count(.downloadRequest) == 1, "automatic request")
            env.check(await env.io.fractionGate.waitUntilEntered(), "automatic transfer never polled")
            await monitor.makeAvailable(id)
            env.check(await monitor.transfers.isUserRequested(record.key), "explicit request did not upgrade the transfer")
            await monitor.setAvailabilitySetting(.off)
            await env.io.fractionGate.release()
            let final = await monitor.transfers.waitUntilSettled(record.key)
            env.check(final == .idle, "user-requested transfer after OFF \(final)")
            env.check(env.io.count(.downloadRequest) == 1, "requests \(env.io.count(.downloadRequest))")
        case 2:
            await monitor.refresh([id])
            let downloaded = await monitor.transfers.waitUntilSettled(record.key)
            env.check(downloaded == .idle, "download \(downloaded)")
            await monitor.setAvailabilitySetting(.off)
            item.evictAgain(script: [.complete])
            await monitor.refresh([id])
            let observation = monitor.observations[id]
            env.check(observation?.residency == .cloudPlaceholder, "residency \(String(describing: observation?.residency))")
            env.check(observation?.transfer == .notRequested(.availabilityOff), "stale transfer \(String(describing: observation?.transfer))")
            env.check(observation?.remedies.contains(.makeAvailable) == true, "missing Make Available remedy")
            env.check(env.io.count(.downloadRequest) == 1, "requests \(env.io.count(.downloadRequest))")
        default:
            env.io.faults.metadataFailures[HarnessIO.key(url)] = .permissionDenied
            let held = await monitor.transfers.makeAvailable(record.key, at: url)
            env.check(held == .notRequested(.awaitingAccess), "held \(held)")
            env.io.faults.metadataFailures = [:]
            await monitor.setAvailabilitySetting(.off)
            await monitor.refresh([id])
            env.check(monitor.observations[id]?.transfer == .notRequested(.availabilityOff), "stale awaitingAccess \(String(describing: monitor.observations[id]?.transfer))")
            await monitor.setAvailabilitySetting(.on)
            let final = await monitor.transfers.waitUntilSettled(record.key)
            env.check(final == .idle, "after access restored \(final)")
            env.check(env.io.count(.downloadRequest) == 1, "requests \(env.io.count(.downloadRequest))")
        }
        await monitor.stop()
    }
}

// MARK: - Runner

@Suite("WW-006 lifecycle matrix", .serialized)
struct LifecycleMatrixTests {
    @Test @MainActor func offSwitchWaitsForEvaluatorTaskEntry() async throws {
        let env = try CaseEnv(family: .srcToggleRefresh, split: "calibration", index: 0)
        defer { env.tree.cleanUp() }
        try await MatrixScenarios.toggleDuringRefresh(env, variant: 0)
        #expect(env.failures.isEmpty, "\(env.failures)")
    }

    static func runFamily(_ family: MatrixFamily) async -> FamilyTally {
        var tally = FamilyTally(family: family.rawValue)
        for (split, count) in [("calibration", family.calibration), ("holdout", family.holdout)] {
            for index in 0..<count {
                let env: CaseEnv
                do {
                    env = try CaseEnv(family: family, split: split, index: index)
                } catch {
                    tally.failedAssertions += 1
                    tally.failures.append("\(family.rawValue)/\(split)/\(index): setup \(error)")
                    continue
                }
                do {
                    try await MatrixScenarios.run(env, index: index)
                } catch {
                    env.failures.append("\(env.label): threw \(error)")
                }
                let ledger = env.context.ledger.snapshot
                let leaked = ledger.openScopes + env.io.leakedScopes + abs(ledger.starts - ledger.stops)
                if leaked != 0 { env.failures.append("\(env.label): leaked scopes \(leaked)") }
                if env.writes != 0 { env.failures.append("\(env.label): source writes \(env.writes)") }
                if split == "calibration" { tally.calibrationCases += 1 } else { tally.holdoutCases += 1 }
                tally.cases.append(CaseRecord(
                    family: family.rawValue,
                    split: split,
                    index: index,
                    seed: String(format: "%016llx", FixtureSeed.derive(fixtureID: family.rawValue, split: split, caseIndex: index)),
                    passed: env.failures.isEmpty,
                    failures: env.failures,
                    leakedScopes: leaked,
                    sourceWrites: env.writes,
                    substitutions: env.substitutions,
                    downloadRequests: env.io.count(.downloadRequest),
                    progressQueries: env.io.count(.downloadFraction),
                    scopeStarts: ledger.starts,
                    provenance: env.io.provenance.rawValue
                ))
                tally.failedAssertions += env.failures.count
                tally.failures += env.failures.prefix(3)
                tally.leakedScopes += leaked
                tally.sourceWrites += env.writes
                tally.substitutions += env.substitutions
                tally.downloadRequests += env.io.count(.downloadRequest)
                if family.isOffPath { tally.offPathDownloadRequests += env.io.count(.downloadRequest) + env.io.count(.downloadFraction) }
                tally.scopeStarts += ledger.starts
                if env.io.provenance == .simulated { tally.simulatedCases += 1 } else { tally.observedCases += 1 }
                env.tree.cleanUp()
            }
        }
        return tally
    }

    @Test func lifecycleMatrix() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let tallies = await withTaskGroup(of: FamilyTally.self) { group in
            var pending = MatrixFamily.allCases[...]
            var results: [FamilyTally] = []
            for _ in 0..<4 {
                if let family = pending.popFirst() { group.addTask { await Self.runFamily(family) } }
            }
            while let result = await group.next() {
                results.append(result)
                if let family = pending.popFirst() { group.addTask { await Self.runFamily(family) } }
            }
            return results.sorted { $0.family < $1.family }
        }
        let elapsed = clock.now - start

        let holdout = tallies.reduce(0) { $0 + $1.holdoutCases }
        let calibration = tallies.reduce(0) { $0 + $1.calibrationCases }
        let referenceHoldout = tallies.filter { $0.family.hasPrefix("M1-REF") }.reduce(0) { $0 + $1.holdoutCases }
        let registryHoldout = tallies.filter { $0.family != MatrixFamily.srcToggleRefresh.rawValue }.reduce(0) { $0 + $1.holdoutCases }
        let failures = tallies.reduce(0) { $0 + $1.failedAssertions }
        let leaked = tallies.reduce(0) { $0 + $1.leakedScopes }
        let writes = tallies.reduce(0) { $0 + $1.sourceWrites }
        let substitutions = tallies.reduce(0) { $0 + $1.substitutions }
        let offRequests = tallies.reduce(0) { $0 + $1.offPathDownloadRequests }

        for tally in tallies {
            print("WW-006-MATRIX \(tally.family) calibration=\(tally.calibrationCases) holdout=\(tally.holdoutCases) failed=\(tally.failedAssertions) leakedScopes=\(tally.leakedScopes) sourceWrites=\(tally.sourceWrites) substitutions=\(tally.substitutions) downloadRequests=\(tally.downloadRequests) offPathRequests=\(tally.offPathDownloadRequests) scopeStarts=\(tally.scopeStarts) simulated=\(tally.simulatedCases) observed=\(tally.observedCases)")
            for failure in tally.failures.prefix(5) { print("WW-006-MATRIX-FAILURE \(failure)") }
        }
        print("WW-006-MATRIX TOTAL holdout=\(holdout) (registry=\(registryHoldout), reference=\(referenceHoldout)) calibration=\(calibration) failedAssertions=\(failures) leakedScopes=\(leaked) sourceWrites=\(writes) substitutions=\(substitutions) offPathDownloadRequests=\(offRequests) contentHashHeaderPreviewDecodeRequests=0(structural) elapsed=\(elapsed)")

        let report = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/evidence/ww-006-lifecycle-matrix.json")
        try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var summaries = tallies
        for index in summaries.indices { summaries[index].cases = [] }
        try? encoder.encode(summaries).write(to: report)
        // One line per case (every case, including failures) for the evidence record.
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys]
        let lines = tallies.flatMap(\.cases).compactMap { try? String(decoding: lineEncoder.encode($0), as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: report.deletingLastPathComponent().appendingPathComponent("ww-006-lifecycle-matrix-cases.jsonl"),
            atomically: true, encoding: .utf8)

        #expect(holdout == MatrixFamily.allCases.reduce(0) { $0 + $1.holdout })
        for tally in tallies {
            #expect(tally.holdoutCases >= FrozenCounts.holdout[tally.family, default: .max], "\(tally.family) below frozen holdout")
            #expect(tally.cases.count == tally.holdoutCases + tally.calibrationCases)
        }
        #expect(Set(tallies.map(\.family)) == Set(FrozenCounts.holdout.keys))
        #expect(referenceHoldout >= 1_000)
        #expect(failures == 0)
        #expect(leaked == 0)
        #expect(writes == 0)
        #expect(substitutions == 0)
        #expect(offRequests == 0)
    }
}
