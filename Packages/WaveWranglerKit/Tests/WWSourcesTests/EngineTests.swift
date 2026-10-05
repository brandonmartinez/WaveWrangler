import Darwin
import Foundation
import Testing
import WWCore
@testable import WWSources

struct InjectedError: Error {}

@Suite("Security scope ledger")
struct ScopeLedgerTests {
    @Test func balancesOnReturnThrowAndCancel() async throws {
        let tree = try SyntheticTree(label: "ledger")
        var rng = SplitMix64(seed: 1)
        let url = try tree.file("a.wav", bytes: 16, rng: &rng)
        let io = HarnessIO()
        let ledger = SecurityScopeLedger()

        _ = ledger.withScopedAccess(to: url, using: io) { _ in 1 }
        #expect(throws: InjectedError.self) {
            try ledger.withScopedAccess(to: url, using: io) { _ in throw InjectedError() }
        }
        let task = Task {
            try await ledger.withScopedAccess(to: url, using: io) { _ in
                try await Task.sleep(for: .seconds(30))
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        io.faults.scopeStartFails = true
        _ = ledger.withScopedAccess(to: url, using: io) { _ in 2 }

        let snapshot = ledger.snapshot
        #expect(snapshot.openScopes == 0)
        #expect(snapshot.starts == snapshot.stops)
        #expect(snapshot.unavailableStarts == 1)
        #expect(io.leakedScopes == 0)
        #expect(io.count(.scopeStart) == io.count(.scopeStop) + 1)
    }
}

@Suite("Source availability evaluator")
struct EvaluatorTests {
    @Test func noAccessRecordMeansRelinkRequired() {
        let io = HarnessIO()
        let evaluation = SourceAvailabilityEvaluator(context: makeContext(io)).evaluate(sourceID: SourceID(), record: nil, setting: .on)
        #expect(evaluation.observation.access == .needsRegrant)
        #expect(evaluation.observation.location == .unknown)
        #expect(evaluation.observation.identity == .unverified(.noRecordedEvidence))
        #expect(evaluation.observation.remedies.contains(.regrantAccess))
        #expect(io.allCounts.isEmpty)
    }

    @Test func bookmarkReplacementCounterexampleIsAMismatchNotARefresh() async throws {
        let tree = try SyntheticTree(label: "counterexample")
        var rng = SplitMix64(seed: 2)
        let original = try tree.file("take.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let plan = try await SourceImporter(context: context).plan(selection: [original])
        let record = try #require(plan.items.first?.accessRecord)
        try FileManager.default.moveItem(at: original, to: tree.sources.appendingPathComponent("moved.wav"))
        try tree.file("take.wav", bytes: 64, rng: &rng)

        let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(sourceID: record.sourceID, record: record, setting: .on)
        #expect(evaluation.refreshedRecord == nil)
        guard case .mismatch = evaluation.observation.identity else {
            Issue.record("expected mismatch, got \(evaluation.observation.identity)")
            return
        }
        #expect(evaluation.observation.access != .granted || evaluation.observation.identity != .matchesRecorded)
        #expect(evaluation.observation.remedies.contains(.reviewIdentityChange))
        #expect(context.ledger.snapshot.openScopes == 0)
    }

    @Test func denialIsNeverReportedAsMissing() async throws {
        let tree = try SyntheticTree(label: "denied")
        var rng = SplitMix64(seed: 3)
        let file = try tree.file("rec/a.wav", bytes: 32, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file]).items.first?.accessRecord)

        chmod(file.deletingLastPathComponent().path, 0)
        let dirDenied = SourceAvailabilityEvaluator(context: context).evaluate(sourceID: record.sourceID, record: record, setting: .on)
        chmod(file.deletingLastPathComponent().path, 0o755)
        #expect(dirDenied.observation.access == .denied)
        #expect(dirDenied.observation.location == .unknown)

        chmod(file.path, 0)
        let fileDenied = SourceAvailabilityEvaluator(context: context).evaluate(sourceID: record.sourceID, record: record, setting: .on)
        chmod(file.path, 0o644)
        #expect(fileDenied.observation.access == .denied)
        #expect(fileDenied.observation.location == .present)
    }
}

@Suite("Importer")
struct ImporterTests {
    @Test func largeMessyFolderImportsAudioOnlyAndNeverQueriesOtherFiles() async throws {
        let tree = try SyntheticTree(label: "messy")
        var rng = SplitMix64(seed: 4)
        var audio = 0
        var project = 0
        var documents = 0
        var other = 0
        var hidden = 0
        for folder in 0..<20 {
            for index in 0..<15 {
                try tree.file("Recorder \(folder % 4)/ZOOM\(String(format: "%04d", folder))/ZOOM\(String(format: "%04d", folder))_Tr\(index % 4 + 1)-\(index).WAV", bytes: 32, rng: &rng)
                audio += 1
            }
            try tree.file("Recorder \(folder % 4)/notes \(folder).txt", bytes: 8, rng: &rng); documents += 1
            try tree.file("Recorder \(folder % 4)/transcript \(folder).srt", bytes: 8, rng: &rng); documents += 1
            try tree.file("Recorder \(folder % 4)/session \(folder).rpp", bytes: 8, rng: &rng); project += 1
            try tree.file("Recorder \(folder % 4)/Episode \(folder).logicx/Alternatives/000/ProjectData", bytes: 8, rng: &rng); project += 1
            try tree.file("Recorder \(folder % 4)/peaks \(folder).reapeaks", bytes: 8, rng: &rng); other += 1
            try tree.file("Recorder \(folder % 4)/.DS_Store_\(folder)", bytes: 8, rng: &rng); hidden += 1
            // Not a declared package type anywhere: must still be treated as one opaque project.
            try tree.file("Recorder \(folder % 4)/Mix \(folder).dawproject/audio/stem.wav", bytes: 8, rng: &rng); project += 1
            try tree.file("Recorder \(folder % 4)/.cache \(folder)/hidden.wav", bytes: 8, rng: &rng); hidden += 1
        }
        let io = HarnessIO()
        let context = makeContext(io)
        let before = TreeSnapshot.take(tree.sources)
        let clock = ContinuousClock()
        let start = clock.now
        let plan = try await SourceImporter(context: context).plan(selection: [tree.sources])
        let elapsed = clock.now - start
        #expect(TreeSnapshot.take(tree.sources).differences(from: before) == 0)
        #expect(plan.items.count == audio)
        #expect(plan.skipped.byCategory[.projectOrSession] == project)
        #expect(plan.skipped.byCategory[.transcriptOrDocument] == documents)
        #expect(plan.skipped.byCategory[.otherFile] == other)
        #expect(plan.skipped.byCategory[.hidden] == hidden)
        #expect(plan.failures.isEmpty)
        // Metadata queried only for the root and audio files: never for project/transcript/other files.
        #expect(io.count(.metadata) == audio + 1)
        #expect(io.count(.downloadRequest) == 0)
        #expect(io.count(.bookmarkCreate) == audio)
        #expect(context.ledger.snapshot.openScopes == 0)
        for item in plan.items {
            #expect(item.sourceRecord.observations == SourceObservations())
            #expect(item.sourceRecord.roleConfirmation == .provisional)
            #expect(item.accessRecord.recordedIdentity?.confirmation == .provisional)
        }
        #expect(plan.suggestions.recorderGroups.count == 4)
        #expect(plan.suggestions.recorderGroups.allSatisfy { $0.confirmation == .provisional && $0.epochs.count == 5 })
        print("WW-IMPORT-TIMING audio=\(audio) ignored=\(plan.skipped.totalIgnoredFiles) elapsed=\(elapsed)")
    }

    @Test func duplicateSelectionsAndExistingSourcesAreFlaggedNotMerged() async throws {
        let tree = try SyntheticTree(label: "dupes")
        var rng = SplitMix64(seed: 5)
        let file = try tree.file("a.wav", bytes: 16, rng: &rng)
        let context = makeContext(HarnessIO())
        let first = try await SourceImporter(context: context).plan(selection: [file])
        let second = try await SourceImporter(context: context).plan(selection: [file, tree.sources], existingRecords: first.accessRecords)
        #expect(second.items.count == 1)
        #expect(second.skipped.duplicateSelections == 1)
        #expect(second.items[0].possibleDuplicateOf == first.items[0].sourceRecord.id)
        #expect(second.items[0].sourceRecord.id != first.items[0].sourceRecord.id)
    }

    @Test func cancellationStopsImportWithBalancedScopes() async throws {
        let tree = try SyntheticTree(label: "cancel")
        var rng = SplitMix64(seed: 6)
        for index in 0..<200 { try tree.file("f\(index).wav", bytes: 8, rng: &rng) }
        let context = makeContext(HarnessIO())
        let task = Task { try await SourceImporter(context: context).plan(selection: [tree.sources]) }
        task.cancel()
        _ = try? await task.value
        #expect(context.ledger.snapshot.openScopes == 0)
    }
}

@Suite("Organization suggestions")
struct OrganizationSuggesterTests {
    @Test func parsesCommonRecorderAndPersonPatterns() {
        #expect(OrganizationSuggester.parse(fileName: "ZOOM0001_Tr1.WAV") == .init(take: "ZOOM0001", recorderPrefix: "ZOOM", track: "Tr1", speaker: nil, role: .unassigned))
        #expect(OrganizationSuggester.parse(fileName: "220101_001_Tr2.WAV").take == "220101_001")
        #expect(OrganizationSuggester.parse(fileName: "Brandon.wav").speaker == "Brandon")
        #expect(OrganizationSuggester.parse(fileName: "riverside_alex_raw-audio.m4a").speaker == "Alex")
        #expect(OrganizationSuggester.parse(fileName: "Guest 2.wav").speaker == "Guest 2")
        #expect(OrganizationSuggester.parse(fileName: "Host Mic backup.wav").role == .backup)
        #expect(OrganizationSuggester.parse(fileName: "Host Mic backup.wav").speaker == "Host")
    }

    @Test func groupsByFolderAndTakeAllProvisional() {
        let a = SourceID(), b = SourceID(), c = SourceID(), d = SourceID()
        let result = OrganizationSuggester.suggest(for: [
            .init(sourceID: a, relativePathComponents: ["Zoom H6", "ZOOM0001", "ZOOM0001_Tr1.WAV"]),
            .init(sourceID: b, relativePathComponents: ["Zoom H6", "ZOOM0002", "ZOOM0002_Tr1.WAV"]),
            .init(sourceID: c, relativePathComponents: ["Brandon.wav"]),
            .init(sourceID: d, relativePathComponents: ["Alex.wav"]),
        ])
        #expect(result.recorderGroups.map(\.name) == ["Zoom H6", "Selected files"])
        #expect(result.recorderGroups[0].epochs.map(\.label) == ["ZOOM0001", "ZOOM0002"])
        #expect(result.speakers.map(\.name) == ["Brandon", "Alex"])
        #expect(result.speakers.allSatisfy { $0.confirmation == .provisional })
        #expect(result.sourceHints[a]?.trackLabel == "Tr1")
    }
}

@Suite("Relink")
struct RelinkTests {
    @Test func onlyExactMatchesApplyWithoutConfirmation() async throws {
        let tree = try SyntheticTree(label: "relink")
        var rng = SplitMix64(seed: 7)
        let file = try tree.file("a.wav", bytes: 16, rng: &rng)
        let context = makeContext(HarnessIO())
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file]).items.first?.accessRecord)
        let relink = RelinkEvaluator(context: context)

        let moved = tree.sources.appendingPathComponent("sub/a-renamed.wav")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: moved)
        let exact = relink.evaluate(candidate: moved, for: record.sourceID, record: record)
        #expect(exact.comparison == .matches)
        #expect(!exact.requiresConfirmation)
        let applied = try relink.apply(exact, to: record, userConfirmed: false)
        #expect(applied.recordedIdentity == record.recordedIdentity)

        let copy = tree.sources.appendingPathComponent("copy.wav")
        try FileManager.default.copyItem(at: moved, to: copy)
        let copied = relink.evaluate(candidate: copy, for: record.sourceID, record: applied)
        #expect(copied.requiresConfirmation)
        #expect(throws: RelinkError.self) { try relink.apply(copied, to: applied, userConfirmed: false) }
        let confirmed = try relink.apply(copied, to: applied, userConfirmed: true)
        #expect(confirmed.recordedIdentity?.confirmation == .userConfirmed)
        #expect(confirmed.relinkHistory.count == 2)

        let crossMachine = relink.evaluate(candidate: copy, for: SourceID(), record: nil)
        #expect(crossMachine.comparison == .unknown(FingerprintField.allCases))
        #expect(crossMachine.requiresConfirmation)

        let linkedTwice = relink.evaluate(candidate: copy, for: SourceID(), record: nil, otherRecords: [confirmed])
        #expect(linkedTwice.alreadyLinkedTo == record.sourceID)
        #expect(context.ledger.snapshot.openScopes == 0)
    }
}

@Suite("Transfer controller (simulated provider)")
struct TransferControllerTests {
    @Test func offNeverRequestsButExplicitMakeAvailableDoes() async throws {
        let tree = try SyntheticTree(label: "transfer-off")
        var rng = SplitMix64(seed: 8)
        let file = try tree.file("a.wav", bytes: 16, rng: &rng)
        let io = HarnessIO()
        io.simulate(file, SimulatedCloudItem(script: [.progress(0.5), .complete]))
        let controller = SourceTransferController(context: makeContext(io), policy: TransferPolicy(pollInterval: .milliseconds(1), stallTimeout: .seconds(5)))
        let id = SourceID()
        #expect(await controller.makeAvailable(id, at: file, setting: .off) == .notRequested(.availabilityOff))
        #expect(io.count(.downloadRequest) == 0)
        #expect(await controller.makeAvailable(id, at: file, setting: .off, userRequested: true) == .requested)
        #expect(await controller.waitUntilSettled(id) == .idle)
        #expect(io.count(.downloadRequest) == 1)
        #expect(io.leakedScopes == 0)
    }
}

@Suite("Device access store")
struct DeviceAccessStoreTests {
    @Test func roundTripsAndRefusesNewerSchemaWithoutOverwriting() async throws {
        let tree = try SyntheticTree(label: "store")
        let url = tree.root.appendingPathComponent("store/records.json")
        let store = FileDeviceAccessStore(fileURL: url)
        let record = DeviceAccessRecord(sourceID: SourceID(), bookmark: Data([1]), lastKnownPath: "/x", createdAt: Date(timeIntervalSince1970: 0))
        try await store.save(record)
        #expect(try await FileDeviceAccessStore(fileURL: url).record(for: record.sourceID) == record)

        let newer = Data(#"{"schemaVersion":99,"records":[],"future":true}"#.utf8)
        try newer.write(to: url)
        let refusing = FileDeviceAccessStore(fileURL: url)
        await #expect(throws: DeviceAccessStoreError.unsupportedNewerSchema(99)) { try await refusing.save(record) }
        #expect(try Data(contentsOf: url) == newer)
    }
}

@Suite("Source availability monitor")
@MainActor
struct MonitorTests {
    @Test func monitorRequestsOnlyPlaceholdersWhenOnAndNothingWhenOff() async throws {
        let tree = try SyntheticTree(label: "monitor")
        var rng = SplitMix64(seed: 9)
        let local = try tree.file("local.wav", bytes: 16, rng: &rng)
        let cloud = try tree.file("cloud.wav", bytes: 16, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let plan = try await SourceImporter(context: context).plan(selection: [local, cloud])
        io.simulate(cloud, SimulatedCloudItem(script: [.progress(0.3), .progress(0.9), .complete]))
        let store = InMemoryDeviceAccessStore()
        let monitor = SourceAvailabilityMonitor(store: store, context: context, setting: .off, transferPolicy: TransferPolicy(pollInterval: .milliseconds(1), stallTimeout: .seconds(5)))
        monitor.start()
        try await monitor.adopt(plan.accessRecords)
        let cloudID = plan.items[1].sourceRecord.id
        #expect(monitor.observations[cloudID]?.residency == .cloudPlaceholder)
        #expect(monitor.observations[cloudID]?.transfer == .notRequested(.availabilityOff))
        #expect(monitor.observations[cloudID]?.provenance == .simulated)
        #expect(io.count(.downloadRequest) == 0)

        await monitor.setAvailabilitySetting(.on)
        #expect(io.count(.downloadRequest) == 1)
        #expect(await monitor.transfers.waitUntilSettled(cloudID) == .idle)
        await monitor.refresh([cloudID])
        #expect(monitor.observations[cloudID]?.residency == .local)
        #expect(io.count(.downloadRequest) == 1)
        monitor.stop()
        #expect(context.ledger.snapshot.openScopes == 0)
    }
}

@Suite("Read-only gateway enforcement")
struct ForbiddenAPITests {
    /// Content-capable or mutating APIs. Only listed files may use the noted exceptions.
    static let forbidden = [
        "Data(contentsOf", "FileHandle", "InputStream", "fopen(", "open(", "read(", "mmap",
        ".write(to", "write(", "moveItem", "removeItem", "trashItem", "copyItem", "replaceItem", "linkItem",
        "setAttributes", "setResourceValue", "createFile", "createDirectory", "evictUbiquitousItem",
        "startDownloadingUbiquitousItem", "NSFileCoordinator", "AVAsset", "AVAudioFile", "AudioFileOpen",
        "ExtAudioFile", "QLThumbnail", "QuickLook", "CryptoKit", "SHA256", "CC_SHA", "Insecure.",
        "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", ".resourceValues(",
    ]

    static let exceptions: [String: Set<String>] = [
        "SystemSourceIO.swift": ["startDownloadingUbiquitousItem", "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", ".resourceValues("],
        "DeviceAccessRecord.swift": ["Data(contentsOf", ".write(to", "write(", "createDirectory", "FileManager"],
    ]

    static func violations(in source: String, fileName: String) -> [String] {
        let allowed = exceptions[fileName] ?? []
        let code = source
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return forbidden.filter { !allowed.contains($0) && code.contains($0) }.map { "\(fileName): \($0)" }
    }

    @Test func scannerDetectsForbiddenCalls() {
        #expect(Self.violations(in: "let d = try Data(contentsOf: url)", fileName: "SourceImporter.swift") == ["SourceImporter.swift: Data(contentsOf"])
        #expect(Self.violations(in: "try FileManager.default.moveItem(at: a, to: b)", fileName: "RelinkEvaluator.swift").contains("RelinkEvaluator.swift: moveItem"))
        #expect(Self.violations(in: "// FileHandle in a comment", fileName: "X.swift").isEmpty)
        #expect(Self.violations(in: "try FileManager.default.evictUbiquitousItem(at: u)", fileName: "SystemSourceIO.swift") == ["SystemSourceIO.swift: evictUbiquitousItem"])
    }

    @Test func wwSourcesHasNoContentOrMutationAPIsOutsideTheGateway() throws {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WWSources")
        let files = try FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 10)
        var violations: [String] = []
        for file in files {
            violations += Self.violations(in: try String(contentsOf: file, encoding: .utf8), fileName: file.lastPathComponent)
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func gatewayProtocolHasNoContentOrMutationRequirements() {
        // SourceIO requirements: metadata, listing, read-only bookmarks, scopes, download request/progress.
        let mirror = HarnessIO.Op.allCases.map(\.rawValue)
        #expect(Set(mirror) == ["metadata", "list", "bookmarkCreate", "bookmarkResolve", "scopeStart", "scopeStop", "downloadRequest", "downloadFraction"])
    }
}
