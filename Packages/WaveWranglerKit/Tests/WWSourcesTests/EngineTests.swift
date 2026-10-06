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
        let evaluation = SourceAvailabilityEvaluator(context: makeContext(io)).evaluate(key: DeviceAccessKey(showID: testShow, sourceID: SourceID()), record: nil, setting: .on)
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
        let plan = try await SourceImporter(context: context).plan(selection: [original], showID: testShow)
        let record = try #require(plan.items.first?.accessRecord)
        try FileManager.default.moveItem(at: original, to: tree.sources.appendingPathComponent("moved.wav"))
        try tree.file("take.wav", bytes: 64, rng: &rng)

        let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(key: record.key, record: record, setting: .on)
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
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)

        chmod(file.deletingLastPathComponent().path, 0)
        let dirDenied = SourceAvailabilityEvaluator(context: context).evaluate(key: record.key, record: record, setting: .on)
        chmod(file.deletingLastPathComponent().path, 0o755)
        #expect(dirDenied.observation.access == .denied)
        #expect(dirDenied.observation.location == .unknown)

        chmod(file.path, 0)
        let fileDenied = SourceAvailabilityEvaluator(context: context).evaluate(key: record.key, record: record, setting: .on)
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
        let plan = try await SourceImporter(context: context).plan(selection: [tree.sources], showID: testShow)
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
        let first = try await SourceImporter(context: context).plan(selection: [file], showID: testShow)
        let second = try await SourceImporter(context: context).plan(selection: [file, tree.sources], showID: testShow, existingRecords: first.accessRecords)
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
        let task = Task { try await SourceImporter(context: context).plan(selection: [tree.sources], showID: testShow) }
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
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        let relink = RelinkEvaluator(context: context)

        let moved = tree.sources.appendingPathComponent("sub/a-renamed.wav")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: moved)
        let exact = relink.evaluate(candidate: moved, for: record.key, record: record)
        #expect(exact.comparison == .matches)
        #expect(!exact.requiresConfirmation)
        let applied = try relink.apply(exact, to: record, userConfirmed: false)
        #expect(applied.recordedIdentity == record.recordedIdentity)

        let copy = tree.sources.appendingPathComponent("copy.wav")
        try FileManager.default.copyItem(at: moved, to: copy)
        let copied = relink.evaluate(candidate: copy, for: record.key, record: applied)
        #expect(copied.requiresConfirmation)
        #expect(throws: RelinkError.self) { try relink.apply(copied, to: applied, userConfirmed: false) }
        let confirmed = try relink.apply(copied, to: applied, userConfirmed: true)
        #expect(confirmed.recordedIdentity?.confirmation == .userConfirmed)
        #expect(confirmed.relinkHistory.count == 2)

        let crossMachine = relink.evaluate(candidate: copy, for: DeviceAccessKey(showID: testShow, sourceID: SourceID()), record: nil)
        #expect(crossMachine.comparison == .unknown(FingerprintField.allCases))
        #expect(crossMachine.requiresConfirmation)

        let linkedTwice = relink.evaluate(candidate: copy, for: DeviceAccessKey(showID: testShow, sourceID: SourceID()), record: nil, otherRecords: [confirmed])
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
        let controller = SourceTransferController(context: makeContext(io), policy: TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 500), setting: .off)
        let id = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        #expect(await controller.makeAvailable(id, at: file) == .notRequested(.availabilityOff))
        #expect(io.count(.downloadRequest) == 0)
        #expect(await controller.makeAvailable(id, at: file, userRequested: true) == .requested)
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
        let record = DeviceAccessRecord(showID: testShow, sourceID: SourceID(), bookmark: Data([1]), lastKnownPath: "/x", createdAt: Date(timeIntervalSince1970: 0))
        try await store.save(record)
        #expect(try await FileDeviceAccessStore(fileURL: url).record(for: record.key) == record)

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
        let plan = try await SourceImporter(context: context).plan(selection: [local, cloud], showID: testShow)
        io.simulate(cloud, SimulatedCloudItem(script: [.progress(0.3), .progress(0.9), .complete]))
        let store = InMemoryDeviceAccessStore()
        let monitor = SourceAvailabilityMonitor(showID: testShow, store: store, context: context, setting: .off, transferPolicy: TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 500))
        monitor.start()
        try await monitor.adopt(plan.accessRecords)
        let cloudID = plan.items[1].sourceRecord.id
        #expect(monitor.observations[cloudID]?.residency == .cloudPlaceholder)
        #expect(monitor.observations[cloudID]?.transfer == .notRequested(.availabilityOff))
        #expect(monitor.observations[cloudID]?.provenance == .simulated)
        #expect(io.count(.downloadRequest) == 0)

        await monitor.setAvailabilitySetting(.on)
        #expect(io.count(.downloadRequest) == 1)
        #expect(await monitor.transfers.waitUntilSettled(DeviceAccessKey(showID: testShow, sourceID: cloudID)) == .idle)
        await monitor.refresh([cloudID])
        #expect(monitor.observations[cloudID]?.residency == .local)
        #expect(io.count(.downloadRequest) == 1)
        await monitor.stop()
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

    // MARK: - WWDecode: the read-only content gateway

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The one file allowed to open source content, and only through these read-only APIs. Matched by
    /// its path relative to Sources/WWDecode, so a same-named file in a subdirectory is not excepted.
    static let contentGatewayFile = "SystemSourceContentIO.swift"
    static let contentGatewayAllowed: Set<String> = ["open(", "read(", "AudioFileOpen", "ExtAudioFile"]
    /// The only flags the gateway's `open(` may pass. `O_RDONLY` is 0, so anything else (even a bare
    /// `2`) could make the descriptor writable; the gateway also checks `fcntl(F_GETFL)` at run time.
    static let readOnlyOpenFlags: Set<String> = ["O_RDONLY", "O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK"]

    /// Writing, creating, truncating, renaming, metadata-changing or materialising APIs: forbidden in
    /// WWDecode with no exception.
    static let decodeMutationTokens = [
        "AudioFileCreate", "AudioFileInitialize", "AudioFileWrite", "AudioFileOptimize", "AudioFileSetUserData",
        "AudioFileRemoveUserData", "AudioFileOpenURL", "ExtAudioFileCreate", "ExtAudioFileWrite", "ExtAudioFileOpenURL",
        "forWriting", "forUpdating", "writePermission", "readWritePermission", "kAudioFileReadWrite",
        "O_RDWR", "O_WRONLY", "O_CREAT", "O_TRUNC", "O_APPEND", "pwrite", "truncate(", "openat(", "unlink(", "unlinkat(",
        "remove(", "rename(", "renameat", "renamex_np", "exchangedata", "copyfile", "clonefile",
        "setxattr", "removexattr", "futimens", "utimes", "chmod", "chown", "chflags", "fchflags",
        "IOPOL_MATERIALIZE_DATALESS_FILES_ON",
    ]

    /// Decoding and playback APIs: only WWDecode's gateway may use them; every other module and the app are scanned.
    static let decodeTokens = [
        "AudioFileOpen", "ExtAudioFile", "AudioFileStream", "AudioConverter", "AVAudioFile", "AVAsset", "AVURLAsset",
        "AVAudioConverter", "AudioQueue", "AVPlayer", "AVAudioPlayer", "NSSound",
    ]
    /// WWDecode's package-access content gateway: no module but WWDecode may name it or its entry points.
    static let contentGatewayAPITokens = ["SystemSourceContentIO", "openForDecoding", "readRawFrames"]

    static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Every Swift file under `root`, recursively, with its path relative to `root`.
    static func swiftFiles(under root: URL) throws -> [(path: String, url: URL)] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(path: String, url: URL)] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath().path
            let path = String(resolved.dropFirst(root.path.count + 1))
            files.append((path, file))
        }
        return files
    }

    /// `fileName` is the path relative to Sources/WWDecode.
    static func decodeViolations(in source: String, fileName: String) -> [String] {
        let code = code(source)
        let isGateway = fileName == contentGatewayFile
        var found = (forbidden + decodeMutationTokens)
            .filter { !(isGateway && contentGatewayAllowed.contains($0)) && code.contains($0) }
        // ExtAudioFileSetProperty configures the reader; a raw AudioFileSetProperty could change the file.
        if !matches("(?<!Ext)AudioFileSetProperty", in: code).isEmpty { found.append("AudioFileSetProperty") }
        if isGateway {
            let opens = matches(#"\bopen\("#, in: code)
            let calls = matches(#"\bopen\([^,()]+,[^)]*\)"#, in: code)
            if opens.count != calls.count { found.append("open with unchecked arguments") }
            for call in calls {
                let flags = String(call.drop { $0 != "," }.dropFirst().dropLast())
                    .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !flags.contains("O_RDONLY") || !flags.allSatisfy(readOnlyOpenFlags.contains) {
                    found.append("open with flags other than read-only: \(call)")
                }
            }
            if calls.isEmpty { found.append("no read-only open found") }
            let audioOpens = matches(#"AudioFileOpen\w*\("#, in: code)
            let callbackOpens = matches(#"AudioFileOpenWithCallbacks\(\s*[^,]+,\s*\w+\s*,\s*nil\s*,\s*\w+\s*,\s*nil\s*,"#, in: code)
            if audioOpens.count != callbackOpens.count || audioOpens.isEmpty { found.append("AudioFileOpen without nil write and set-size callbacks") }
            let wraps = matches(#"ExtAudioFileWrapAudioFileID\("#, in: code)
            let readOnlyWraps = matches(#"ExtAudioFileWrapAudioFileID\(\s*\w+\s*,\s*false\s*,"#, in: code)
            if wraps.count != readOnlyWraps.count { found.append("ExtAudioFileWrapAudioFileID for writing") }
        }
        return found.map { "\(fileName): \($0)" }
    }

    /// `path` is relative to the package's Sources directory, or starts with `WaveWrangler/` for the app.
    static func otherModuleViolations(in source: String, path: String) -> [String] {
        if path == "WWDecode/\(contentGatewayFile)" { return [] }
        let code = code(source)
        var tokens = decodeTokens
        if !path.hasPrefix("WWDecode/") { tokens += contentGatewayAPITokens }
        return tokens.filter { code.contains($0) }.map { "\(path): \($0)" }
    }

    @Test func decodeScannerDetectsMutationsAndWritableOpens() {
        let gateway = Self.contentGatewayFile
        let readOnly = """
            result = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            AudioFileOpenWithCallbacks(retained.toOpaque(), readCallback, nil, sizeCallback, nil, 0, &file)
            ExtAudioFileWrapAudioFileID(audioFile, false, &wrapped)
            ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, size, &client)
            """
        #expect(Self.decodeViolations(in: readOnly, fileName: gateway).isEmpty)
        #expect(Self.decodeViolations(in: readOnly, fileName: "SourceDecoder.swift").count == 3)
        #expect(Self.decodeViolations(in: readOnly, fileName: "Internal/\(gateway)").count == 3, "a same-named file in a subdirectory is not the gateway")
        let mutations: [(String, String)] = [
            ("result = Darwin.open(path, O_RDWR)", "O_RDWR"),
            ("result = Darwin.open(path, O_CLOEXEC)", "open with flags other than read-only: open(path, O_CLOEXEC)"),
            ("result = Darwin.open(path, O_RDONLY | 2)", "open with flags other than read-only: open(path, O_RDONLY | 2)"),
            ("result = Darwin.open(path, O_RDONLY | O_EXLOCK)", "open with flags other than read-only: open(path, O_RDONLY | O_EXLOCK)"),
            ("result = Darwin.open(url.path, 2)", "open with flags other than read-only: open(url.path, 2)"),
            ("result = Darwin.open(url.path(percentEncoded: false), 2)", "open with unchecked arguments"),
            ("static func open(url: URL) { }", "open with unchecked arguments"),
            ("AudioFileOpenWithCallbacks(r.toOpaque(), readCallback, writeCallback, sizeCallback, nil, 0, &f)", "AudioFileOpen without nil write and set-size callbacks"),
            ("AudioFileOpenWithCallbacks(r.toOpaque(), readCallback, nil, sizeCallback, setSizeCallback, 0, &f)", "AudioFileOpen without nil write and set-size callbacks"),
            ("ExtAudioFileWrapAudioFileID(audioFile, true, &wrapped)", "ExtAudioFileWrapAudioFileID for writing"),
            ("AudioFileSetProperty(file, kAudioFilePropertyChannelLayout, size, &layout)", "AudioFileSetProperty"),
            ("ExtAudioFileWriteAsync(ext, frames, list)", "ExtAudioFileWrite"),
            ("let file = try AVAudioFile(forWriting: url, settings: [:])", "AVAudioFile"),
            ("pwrite(fd, buffer, count, 0)", "pwrite"),
            ("setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_ON)", "IOPOL_MATERIALIZE_DATALESS_FILES_ON"),
            ("try FileManager.default.removeItem(at: url)", "removeItem"),
        ]
        let tokenCalls: [(String, String)] = [
            ("ftruncate(fd, 0)", "truncate("), ("truncate(path, 0)", "truncate("), ("Darwin.remove(path)", "remove("),
            ("unlinkat(AT_FDCWD, path, 0)", "unlinkat("), ("renameat(AT_FDCWD, a, AT_FDCWD, b)", "renameat"),
            ("renamex_np(a, b, UInt32(RENAME_SWAP))", "renamex_np"), ("exchangedata(a, b, 0)", "exchangedata"),
            ("copyfile(a, b, nil, copyfile_flags_t(COPYFILE_ALL))", "copyfile"), ("clonefile(a, b, 0)", "clonefile"),
            ("setxattr(path, name, value, size, 0, 0)", "setxattr"), ("fsetxattr(fd, name, value, size, 0, 0)", "setxattr"),
            ("removexattr(path, name, 0)", "removexattr"), ("fremovexattr(fd, name, 0)", "removexattr"),
            ("futimens(fd, &times)", "futimens"), ("utimes(path, &times)", "utimes"), ("lutimes(path, &times)", "utimes"),
            ("chmod(path, 0o644)", "chmod"), ("fchmod(fd, 0o644)", "chmod"), ("fchown(fd, 0, 0)", "chown"),
            ("chflags(path, 0)", "chflags"), ("fchflags(fd, 0)", "fchflags"),
        ]
        for (line, expected) in mutations + tokenCalls {
            let violations = Self.decodeViolations(in: readOnly + "\n" + line, fileName: gateway)
            #expect(violations.contains("\(gateway): \(expected)"), "\(line) → \(violations)")
        }
        #expect(Self.decodeViolations(in: "/// AudioFileSetProperty in a doc comment", fileName: "SourceDecoder.swift").isEmpty)
    }

    @Test func otherModuleScannerDetectsDecodingPlaybackAndGatewayUse() {
        #expect(Self.otherModuleViolations(in: "let s = NSSound(contentsOf: url, byReference: true)", path: "WaveWrangler/App/Preview.swift") == ["WaveWrangler/App/Preview.swift: NSSound"])
        #expect(Self.otherModuleViolations(in: "let a = AVURLAsset(url: url)", path: "WWWaveform/Peaks.swift").contains("WWWaveform/Peaks.swift: AVURLAsset"))
        #expect(Self.otherModuleViolations(in: "let p = try AVAudioPlayer(contentsOf: url)", path: "WWDecode/Playback/Preview.swift").contains("WWDecode/Playback/Preview.swift: AVAudioPlayer"))
        #expect(Self.otherModuleViolations(in: "let r = try SystemSourceContentIO().openForDecoding(url)", path: "WWShow/Probe.swift") == ["WWShow/Probe.swift: SystemSourceContentIO", "WWShow/Probe.swift: openForDecoding"])
        #expect(Self.otherModuleViolations(in: "try reader.readRawFrames(into: list, frames: 4)", path: "WaveWrangler/Probe.swift") == ["WaveWrangler/Probe.swift: readRawFrames"])
        #expect(Self.otherModuleViolations(in: "content.openForDecoding(url)", path: "WWDecode/SourceDecoder.swift").isEmpty, "WWDecode itself may use its gateway")
        #expect(Self.otherModuleViolations(in: "ExtAudioFileRead(ext, &frames, list)", path: "WWDecode/\(Self.contentGatewayFile)").isEmpty)
        #expect(Self.otherModuleViolations(in: "ExtAudioFileRead(ext, &frames, list)", path: "WWDecode/Sub/\(Self.contentGatewayFile)") == ["WWDecode/Sub/\(Self.contentGatewayFile): ExtAudioFile"])
    }

    @Test func swiftFileEnumerationIsRecursiveAndRelative() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested/Deeper"), withIntermediateDirectories: true)
        for path in ["Top.swift", "Nested/\(Self.contentGatewayFile)", "Nested/Deeper/Leaf.swift", "Nested/notes.md"] {
            try Data("ExtAudioFileRead(x)".utf8).write(to: root.appendingPathComponent(path))
        }
        let paths = try Self.swiftFiles(under: root).map(\.path).sorted()
        #expect(paths == ["Nested/Deeper/Leaf.swift", "Nested/\(Self.contentGatewayFile)", "Top.swift"])
    }

    @Test func wwDecodeOpensContentOnlyThroughTheReadOnlyGateway() throws {
        let files = try Self.swiftFiles(under: Self.packageRoot.appendingPathComponent("Sources/WWDecode"))
        #expect(files.contains { $0.path == Self.contentGatewayFile })
        #expect(files.count >= 6)
        var violations: [String] = []
        for file in files {
            violations += Self.decodeViolations(in: try String(contentsOf: file.url, encoding: .utf8), fileName: file.path)
        }
        #expect(violations.isEmpty, "\(violations)")
        // Only the gateway may even mention the content APIs it is excepted for.
        for file in files where file.path != Self.contentGatewayFile {
            let code = Self.code(try String(contentsOf: file.url, encoding: .utf8))
            for token in Self.contentGatewayAllowed where code.contains(token) {
                Issue.record("\(file.path) uses \(token) outside the content gateway")
            }
        }
    }

    @Test func noOtherModuleOrTheAppDecodes() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources")
        var files = try Self.swiftFiles(under: sources)
        let app = Self.packageRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WaveWrangler")
        if FileManager.default.fileExists(atPath: app.path) {
            files += try Self.swiftFiles(under: app).map { ("WaveWrangler/\($0.path)", $0.url) }
        }
        #expect(Set(files.map { $0.path.split(separator: "/").first.map(String.init) ?? "" }).count >= 7)
        #expect(files.contains { $0.path == "WWDecode/\(Self.contentGatewayFile)" })
        #expect(files.count >= 30)
        var violations: [String] = []
        for file in files {
            violations += Self.otherModuleViolations(in: try String(contentsOf: file.url, encoding: .utf8), path: file.path)
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    // MARK: - WWDerived: derived assets and content digests

    /// File and staging operations: only the derived-asset store may use them, and only on its own cache.
    static let derivedStoreTokens = ["FileOperations", "writeNew", "moveNew", "replace(", "remove(", "read(", "createDirectory", "FileManager"]
    static let derivedExceptions: [String: Set<String>] = [
        // `.resourceValues(`: the cache root's own ubiquity metadata (cloud-storage refusal), never a source's.
        "DerivedAssetStore.swift": Set(derivedStoreTokens).union([".resourceValues("]),
        "DerivedAssetKey.swift": ["CryptoKit", "SHA256"],
        "ContentDigest.swift": ["CryptoKit", "SHA256"],
    ]
    /// The store may ask FileManager only for the caches folder and whether a path exists.
    static let derivedFileManagerCalls: Set<String> = ["url", "fileExists"]

    /// `fileName` is the path relative to Sources/WWDerived. WWDerived reaches source content only through
    /// `SourceDecoder` (the other-module scan forbids the gateway itself), hashes only in its two digest files,
    /// and mutates files only through the store.
    static func derivedViolations(in source: String, fileName: String) -> [String] {
        let code = code(source)
        let allowed = derivedExceptions[fileName] ?? []
        var found = Array(Set(forbidden + decodeMutationTokens + derivedStoreTokens))
            .filter { !allowed.contains($0) && code.contains($0) }
            .sorted()
        for call in matches(#"FileManager\.default\.\w+"#, in: code) {
            let method = String(call.split(separator: ".").last ?? "")
            if !derivedFileManagerCalls.contains(method) { found.append("FileManager.default.\(method)") }
        }
        return found.map { "\(fileName): \($0)" }
    }

    @Test func derivedScannerDetectsContentHashingAndMutation() {
        #expect(Self.derivedViolations(in: "let d = try Data(contentsOf: source)", fileName: "DerivedAssetStore.swift") == ["DerivedAssetStore.swift: Data(contentsOf"])
        #expect(Self.derivedViolations(in: "try files.writeNew(bytes, to: url)", fileName: "DerivedJobCoordinator.swift") == ["DerivedJobCoordinator.swift: writeNew"])
        #expect(Self.derivedViolations(in: "try files.writeNew(bytes, to: url)", fileName: "DerivedAssetStore.swift").isEmpty)
        #expect(Self.derivedViolations(in: "try files.writeNew(bytes, to: url)", fileName: "Sub/DerivedAssetStore.swift") == ["Sub/DerivedAssetStore.swift: writeNew"])
        #expect(Self.derivedViolations(in: "let h = SHA256.hash(data: bytes)", fileName: "MapHistory.swift") == ["MapHistory.swift: SHA256"])
        #expect(Self.derivedViolations(in: "let h = SHA256.hash(data: bytes)", fileName: "DerivedAssetStore.swift") == ["DerivedAssetStore.swift: SHA256"])
        #expect(Self.derivedViolations(in: "try FileManager.default.moveItem(at: a, to: b)", fileName: "DerivedAssetStore.swift")
            == ["DerivedAssetStore.swift: moveItem", "DerivedAssetStore.swift: FileManager.default.moveItem"])
        #expect(Self.derivedViolations(in: "_ = FileManager.default.contents(atPath: p)", fileName: "DerivedAssetStore.swift") == ["DerivedAssetStore.swift: FileManager.default.contents"])
        #expect(Self.derivedViolations(in: "let a = try AVAudioFile(forReading: url)", fileName: "ContentDigest.swift").contains("ContentDigest.swift: AVAudioFile"))
        #expect(Self.derivedViolations(in: "chmod(path, 0o644)", fileName: "DerivedAssetStore.swift") == ["DerivedAssetStore.swift: chmod"])
    }

    @Test func wwDerivedHasNoContentOrMutationAPIsOutsideItsStore() throws {
        let files = try Self.swiftFiles(under: Self.packageRoot.appendingPathComponent("Sources/WWDerived"))
        #expect(Set(files.map(\.path)).isSuperset(of: Self.derivedExceptions.keys))
        var violations: [String] = []
        for file in files {
            violations += Self.derivedViolations(in: try String(contentsOf: file.url, encoding: .utf8), fileName: file.path)
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}

@Suite("Duplicated shows keep separate device access")
struct DuplicatedShowTests {
    /// A File ▸ Duplicate copy keeps the source IDs but gets a new ShowID.
    func makeOriginalAndCopy(store: any DeviceAccessStore, tree: SyntheticTree, rng: inout SplitMix64) async throws -> (original: DeviceAccessRecord, copy: DeviceAccessRecord, context: SourceAccessContext) {
        let file = try tree.file("take.wav", bytes: 32, rng: &rng)
        let context = makeContext(HarnessIO())
        let original = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        var copy = original
        copy.showID = ShowID()
        try await store.save([original, copy])
        return (original, copy, context)
    }

    @Test(arguments: ["memory", "file"])
    func relinkingTheCopyLeavesTheOriginalUntouched(storeKind: String) async throws {
        let tree = try SyntheticTree(label: "dup-relink")
        var rng = SplitMix64(seed: 10)
        let store: any DeviceAccessStore = storeKind == "memory"
            ? InMemoryDeviceAccessStore()
            : FileDeviceAccessStore(fileURL: tree.root.appendingPathComponent("store.json"))
        let (original, copy, context) = try await makeOriginalAndCopy(store: store, tree: tree, rng: &rng)
        #expect(original.sourceID == copy.sourceID)
        #expect(original.key != copy.key)

        let other = try tree.file("other.wav", bytes: 48, rng: &rng)
        let relink = RelinkEvaluator(context: context)
        let proposal = relink.evaluate(candidate: other, for: copy.key, record: copy, otherRecords: try await store.allRecords())
        #expect(proposal.requiresConfirmation)
        #expect(proposal.alreadyLinkedTo == nil)
        let relinked = try relink.apply(proposal, to: copy, userConfirmed: true)
        try await store.save(relinked)

        // Reload from a fresh store instance for the file-backed variant.
        let reread: any DeviceAccessStore = storeKind == "memory" ? store : FileDeviceAccessStore(fileURL: tree.root.appendingPathComponent("store.json"))
        #expect(try await reread.record(for: original.key) == original)
        #expect(try await reread.record(for: copy.key) == relinked)
        #expect(try await reread.records(in: testShow) == [original])

        // Applying the copy's proposal to the original's record is refused.
        #expect(throws: RelinkError.sourceMismatch) { try relink.apply(proposal, to: original, userConfirmed: true) }

        // Forgetting the copy's grant keeps the original's grant.
        try await reread.removeRecord(for: copy.key)
        #expect(try await reread.record(for: original.key) == original)
        try await reread.removeRecords(in: copy.showID)
        #expect(try await reread.allRecords() == [original])

        // The original still observes as present and granted.
        let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(key: original.key, record: original, setting: .on)
        #expect(evaluation.observation.location == .present)
        #expect(evaluation.observation.access == .granted)
    }

    @Test func evaluatorIgnoresARecordFromAnotherShow() async throws {
        let tree = try SyntheticTree(label: "dup-eval")
        var rng = SplitMix64(seed: 11)
        let (original, copy, context) = try await makeOriginalAndCopy(store: InMemoryDeviceAccessStore(), tree: tree, rng: &rng)
        let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(key: copy.key, record: original, setting: .on)
        #expect(evaluation.observation.access == .needsRegrant)
        #expect(evaluation.observation.identity == .unverified(.noRecordedEvidence))
    }

    @Test @MainActor func monitorsOfTheTwoShowsDoNotCrossWrite() async throws {
        let tree = try SyntheticTree(label: "dup-monitor")
        var rng = SplitMix64(seed: 12)
        let store = InMemoryDeviceAccessStore()
        let (original, copy, context) = try await makeOriginalAndCopy(store: store, tree: tree, rng: &rng)
        // Make the original's bookmark stale so a refresh would rewrite it.
        let moved = tree.sources.appendingPathComponent("moved.wav")
        try FileManager.default.moveItem(at: tree.sources.appendingPathComponent("take.wav"), to: moved)

        let copyMonitor = SourceAvailabilityMonitor(showID: copy.showID, store: store, context: context, setting: .off)
        try await copyMonitor.adopt([original])  // a record from another show is not adopted
        await copyMonitor.refresh([copy.sourceID])
        #expect(try await store.record(for: original.key) == original)
        #expect(try await store.record(for: copy.key)?.bookmark != copy.bookmark)  // copy's own bookmark refreshed
        guard case .moved = copyMonitor.observations[copy.sourceID]?.location else {
            Issue.record("expected moved")
            return
        }
    }
}

@Suite("Harness self-checks")
struct HarnessSelfTests {
    @Test func snapshotDetectsEveryKindOfSourceChange() throws {
        let tree = try SyntheticTree(label: "snapshot")
        var rng = SplitMix64(seed: 13)
        let file = try tree.file("a.wav", bytes: 32, rng: &rng)
        let base = TreeSnapshot.take(tree.sources)
        #expect(TreeSnapshot.take(tree.sources).differences(from: base) == 0)
        try setDates(file, modification: Date(timeIntervalSince1970: 1_000), creation: nil)
        #expect(TreeSnapshot.take(tree.sources).differences(from: base) == 1)
        let touched = TreeSnapshot.take(tree.sources)
        try appendBytes(file, count: 1)
        #expect(TreeSnapshot.take(tree.sources).differences(from: touched) == 1)
        let appended = TreeSnapshot.take(tree.sources)
        try FileManager.default.moveItem(at: file, to: tree.sources.appendingPathComponent("b.wav"))
        #expect(TreeSnapshot.take(tree.sources).differences(from: appended) == 2)
        let renamed = TreeSnapshot.take(tree.sources)
        chmod(tree.sources.appendingPathComponent("b.wav").path, 0o600)
        #expect(TreeSnapshot.take(tree.sources).differences(from: renamed) == 1)
    }

    @Test func seedsFollowTheRegistryDerivation() {
        #expect(FixtureSeed.derive(fixtureID: "M1-REF-001", split: "holdout", caseIndex: 0) == FixtureSeed.derive(fixtureID: "M1-REF-001", split: "holdout", caseIndex: 0))
        #expect(FixtureSeed.derive(fixtureID: "M1-REF-001", split: "holdout", caseIndex: 0) != FixtureSeed.derive(fixtureID: "M1-REF-001", split: "calibration", caseIndex: 0))
    }
}


@Suite("Review regressions: setting races and stale transfer state")
struct ReviewRegressionTests {
    /// 0: OFF during an in-flight refresh ⇒ zero requests. 1: explicit request upgrades an automatic
    /// transfer so OFF does not cancel it. 2: stale idle after OFF+evict. 3: stale awaitingAccess.
    @Test(arguments: 0..<4)
    func scenario(variant: Int) async throws {
        let env = try CaseEnv(family: .srcToggleRefresh, split: "unit", index: variant)
        try await MatrixScenarios.toggleDuringRefresh(env, variant: variant)
        #expect(env.failures.isEmpty, "\(env.failures)")
        #expect(env.writes == 0)
        #expect(env.context.ledger.snapshot.openScopes == 0)
    }

    @Test func controllerRefusesAutomaticRequestsWhenItsSettingIsOff() async throws {
        let tree = try SyntheticTree(label: "controller-setting")
        var rng = SplitMix64(seed: 14)
        let file = try tree.file("a.wav", bytes: 16, rng: &rng)
        let io = HarnessIO()
        io.simulate(file, SimulatedCloudItem(script: MatrixScenarios.longScript))
        let controller = SourceTransferController(context: makeContext(io), policy: TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 500), setting: .on)
        let key = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        await controller.availabilitySettingChanged(to: .off)
        #expect(await controller.makeAvailable(key, at: file) == .notRequested(.availabilityOff))
        #expect(io.count(.downloadRequest) == 0)
        await controller.availabilitySettingChanged(to: .on)
        await io.fractionGate.arm()
        #expect(await controller.makeAvailable(key, at: file) == .requested)
        #expect(await io.fractionGate.waitUntilEntered())
        _ = await controller.makeAvailable(key, at: file, userRequested: true)
        #expect(await controller.isUserRequested(key))
        await controller.availabilitySettingChanged(to: .off)
        #expect(await controller.isActive(key))
        await io.fractionGate.release()
        #expect(await controller.waitUntilSettled(key) == .idle)
        #expect(await controller.reportableState(of: key) == nil)
    }

    @Test func evaluatorIgnoresTerminalHistoryButKeepsActiveAndFailedStates() {
        let error = SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(!SourceAvailabilityEvaluator.transferStillApplies(.idle, residency: .cloudPlaceholder))
        #expect(!SourceAvailabilityEvaluator.transferStillApplies(.notRequested(.awaitingAccess), residency: .cloudPlaceholder))
        #expect(SourceAvailabilityEvaluator.transferStillApplies(.inProgress(fractionCompleted: .unknown), residency: .cloudPlaceholder))
        #expect(SourceAvailabilityEvaluator.transferStillApplies(.offlineOrUnknown(error), residency: .cloudPlaceholder))
        #expect(!SourceAvailabilityEvaluator.transferStillApplies(.offlineOrUnknown(error), residency: .local))
        #expect(!SourceAvailabilityEvaluator.transferStillApplies(.cancelled, residency: .local))
    }
}

@Suite("Stall follow-up: keep observing after offlineOrUnknown", .timeLimit(.minutes(1)))
struct StallFollowUpTests {
    static let policy = TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 5, stalledPollInterval: .milliseconds(1), maxStalledPollInterval: .milliseconds(2))

    func setUp(script: [SimulatedCloudItem.Step], setting: SourceAvailabilitySetting = .on) throws -> (SyntheticTree, URL, HarnessIO, SourceTransferController, DeviceAccessKey) {
        let tree = try SyntheticTree(label: "stall")
        var rng = SplitMix64(seed: 15)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        io.simulate(file, SimulatedCloudItem(script: script))
        let controller = SourceTransferController(context: makeContext(io), policy: Self.policy, setting: setting)
        return (tree, file, io, controller, DeviceAccessKey(showID: testShow, sourceID: SourceID()))
    }

    @Test(arguments: [false, true])
    func stallThenCompleteFlipsToIdle(progressResumes: Bool) async throws {
        let resume: [SimulatedCloudItem.Step] = progressResumes ? [.progress(0.4), .progress(0.8)] : []
        let (tree, file, io, controller, key) = try setUp(script: Array(repeating: .stall, count: 20) + resume + [.complete])
        _ = tree
        let collector = await eventCollector(controller, key: key) { $0 == .idle || $0.isFailed || $0 == .cancelled }
        #expect(await controller.makeAvailable(key, at: file) == .requested)
        let states = await collector.value
        let stallIndex = try #require(states.firstIndex { $0.isOfflineOrUnknown })
        #expect(states.last == .idle)
        #expect(stallIndex < states.count - 1)
        if progressResumes {
            #expect(states[stallIndex...].contains(.inProgress(fractionCompleted: .known(0.4))))
        }
        #expect(await controller.activeCount == 0)
        #expect(io.count(.downloadRequest) == 1)
        #expect(io.leakedScopes == 0)
    }

    @Test func stallThenCancelStopsObserving() async throws {
        let (tree, file, io, controller, key) = try setUp(script: Array(repeating: .stall, count: 100_000))
        _ = tree
        let collector = await eventCollector(controller, key: key) { $0.isOfflineOrUnknown }
        _ = await controller.makeAvailable(key, at: file)
        _ = await collector.value
        #expect(await controller.isActive(key))
        await controller.cancel(key)
        // cancel returns only after the observer finished: no open scope, no further polls.
        #expect(controller.context.ledger.snapshot.openScopes == 0)
        #expect(io.leakedScopes == 0)
        #expect(await controller.state(of: key) == .cancelled)
        #expect(await controller.activeCount == 0)
        #expect(await controller.waitUntilSettled(key) == .cancelled)
        let polls = io.count(.metadata)
        try await Task.sleep(for: .milliseconds(20))
        #expect(io.count(.metadata) == polls)
        #expect(await controller.state(of: key) == .cancelled)
        #expect(io.count(.downloadRequest) == 1)
    }

    @Test func explicitRetryOfAStalledTransferIssuesAFreshRequest() async throws {
        let (tree, file, io, controller, key) = try setUp(script: Array(repeating: .stall, count: 100_000))
        _ = tree
        let collector = await eventCollector(controller, key: key) { $0.isOfflineOrUnknown }
        _ = await controller.makeAvailable(key, at: file)
        _ = await collector.value
        // An automatic call while stalled does nothing new.
        _ = await controller.makeAvailable(key, at: file)
        #expect(io.count(.downloadRequest) == 1)
        // Freeze the stalled observer mid-poll so the provider change and the retry cannot interleave with
        // it (#85): otherwise it can observe the change first and publish inProgress, and an explicit
        // Retry during inProgress is currently a no-op (tracked separately).
        await io.fractionGate.arm()
        #expect(await io.fractionGate.waitUntilEntered())
        io.mutateSimulated(file) { $0.evictAgain(script: [.progress(0.5), .complete]) }
        #expect(await controller.retry(key, at: file) == .requested)
        #expect(io.count(.downloadRequest) == 2)
        await io.fractionGate.release()
        #expect(await settled(controller, key) == .idle)
    }

    @Test func offCancelsAStalledAutomaticTransfer() async throws {
        let (tree, file, io, controller, key) = try setUp(script: Array(repeating: .stall, count: 100_000))
        _ = tree
        let collector = await eventCollector(controller, key: key) { $0.isOfflineOrUnknown }
        _ = await controller.makeAvailable(key, at: file)
        _ = await collector.value
        await controller.availabilitySettingChanged(to: .off)
        #expect(await controller.state(of: key) == .cancelled)
        #expect(await controller.activeCount == 0)
        #expect(io.count(.downloadRequest) == 1)
    }

    @Test func stalledBackoffDoublesToTheCap() {
        let policy = TransferPolicy()
        #expect(policy.stalledPollInterval == .seconds(5))
        #expect(policy.nextStalledInterval(after: .seconds(5)) == .seconds(10))
        #expect(policy.nextStalledInterval(after: .seconds(20)) == .seconds(30))
        #expect(policy.nextStalledInterval(after: .seconds(30)) == .seconds(30))
        #expect(policy.stallDetection == .elapsed(.seconds(60)))
    }

    @Test @MainActor func monitorShowsStallThenAvailable() async throws {
        let tree = try SyntheticTree(label: "stall-monitor")
        var rng = SplitMix64(seed: 16)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        io.simulate(file, SimulatedCloudItem(script: Array(repeating: .stall, count: 30) + [.complete]))
        let monitor = SourceAvailabilityMonitor(showID: testShow, store: InMemoryDeviceAccessStore(), context: context, setting: .on, transferPolicy: Self.policy)
        let collector = await eventCollector(monitor.transfers, key: record.key) { $0 == .idle }
        monitor.start()
        try await monitor.adopt([record])
        let states = await collector.value
        #expect(states.contains { $0.isOfflineOrUnknown }, "stall was never observed: \(states)")
        // The monitor's event consumer runs on the main actor; give it a turn.
        for _ in 0..<100 where monitor.observations[record.sourceID]?.transfer != .idle { await Task.yield() }
        #expect(monitor.observations[record.sourceID]?.transfer == .idle)
        #expect(monitor.observations[record.sourceID]?.residency == .local)
        #expect(io.count(.downloadRequest) == 1)
        await monitor.stop()
    }
}


/// A sleeper driven by the test: each `sleep` publishes its duration on `requests` and suspends (on a
/// continuation, not a thread) until `step()`; task cancellation resumes it with `CancellationError`.
final class SteppedSleeper: @unchecked Sendable {
    let requests: AsyncStream<Duration>
    private let requestContinuation: AsyncStream<Duration>.Continuation
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, any Error>?
    private var cancelled = false

    init() {
        (requests, requestContinuation) = AsyncStream<Duration>.makeStream()
    }

    func sleep(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if cancelled { return true }
                    pending = continuation
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requestContinuation.yield(duration)
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                cancelled = true
                defer { pending = nil }
                return pending
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Lets the currently suspended sleep return.
    func step() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume()
    }
}

/// Polling has stopped once the metadata call count stays unchanged for 40 ms (a live test observer
/// polls every 1–2 ms). Waits up to 5 s for that, so one late in-flight poll under load is tolerated.
func pollingStopped(_ io: HarnessIO) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while clock.now < deadline {
        let before = io.count(.metadata)
        try await Task.sleep(for: .milliseconds(40))
        if io.count(.metadata) == before { return true }
    }
    return false
}

/// Polling continues if the metadata call count increases within 5 s (liveness, not a timing window).
func pollingContinues(_ io: HarnessIO) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    let before = io.count(.metadata)
    while clock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
        if io.count(.metadata) > before { return true }
    }
    return false
}

@Suite("Stall follow-up: observer lifetime and backoff schedule", .timeLimit(.minutes(1)))
struct StallLifetimeTests {
    static let stallForever: [SimulatedCloudItem.Step] = Array(repeating: .stall, count: 1_000_000)

    @Test @MainActor func stoppingTheMonitorStopsStalledObservers() async throws {
        let tree = try SyntheticTree(label: "stall-stop")
        var rng = SplitMix64(seed: 17)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        io.simulate(file, SimulatedCloudItem(script: Self.stallForever))
        let monitor = SourceAvailabilityMonitor(showID: testShow, store: InMemoryDeviceAccessStore(), context: context, setting: .on, transferPolicy: StallFollowUpTests.policy)
        let collector = await eventCollector(monitor.transfers, key: record.key) { $0.isOfflineOrUnknown }
        monitor.start()
        try await monitor.adopt([record])
        #expect((await collector.value).last?.isOfflineOrUnknown == true)
        #expect(try await pollingContinues(io))
        await monitor.stop()
        #expect(try await pollingStopped(io))
        #expect(await monitor.transfers.activeCount == 0)
        // Teardown is not a user decision.
        #expect(await monitor.transfers.reportableState(of: record.key) == nil)
        #expect(context.ledger.snapshot.openScopes == 0)
    }

    /// A refresh already in flight when the monitor stops must not request a download afterwards. The
    /// refresh is held by an async (non-blocking) store gate, so no cooperative thread is ever parked.
    @Test @MainActor func stoppedMonitorNeverRequestsFromInFlightRefresh() async throws {
        let tree = try SyntheticTree(label: "stop-inflight")
        var rng = SplitMix64(seed: 18)
        let file = try tree.file("late.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        io.simulate(file, SimulatedCloudItem(script: [.complete]))
        let store = GatedDeviceAccessStore([record])
        let monitor = SourceAvailabilityMonitor(showID: testShow, store: store, context: context, setting: .on, transferPolicy: StallFollowUpTests.policy)
        monitor.start()
        await store.arm()
        let refresh = Task { await monitor.refresh([record.sourceID]) }
        while await !store.entered { await Task.yield() }
        await monitor.stop()
        await store.release()
        await refresh.value
        await monitor.makeAvailable(record.sourceID)
        #expect(monitor.isStopped)
        #expect(io.count(.downloadRequest) == 0, "no transfer after stop()")
        #expect(await monitor.transfers.activeCount == 0)
        #expect(context.ledger.snapshot.openScopes == 0)
    }

    /// Direct-caller race: a request decided before a shutdown began is refused even if it reaches the
    /// controller afterwards; a decision made after the shutdown began is honored.
    @Test func controllerRefusesRequestsDecidedBeforeShutdownBegan() async throws {
        let tree = try SyntheticTree(label: "decided-before-stop")
        var rng = SplitMix64(seed: 19)
        let file = try tree.file("raced.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        io.simulate(file, SimulatedCloudItem(script: [.complete]))
        let controller = SourceTransferController(context: context, policy: StallFollowUpTests.policy, setting: .on)

        let decided = controller.shutdownTicket()
        let ticket = controller.beginShutdown()
        let refused = await controller.makeAvailable(record.key, at: file, userRequested: true, decidedAt: decided)
        #expect(refused == .unknown)
        #expect(io.count(.downloadRequest) == 0, "request decided before the shutdown began")
        #expect(await controller.activeCount == 0)
        await controller.shutdown(through: ticket)

        let fresh = controller.shutdownTicket()
        await controller.makeAvailable(record.key, at: file, userRequested: true, decidedAt: fresh)
        #expect(io.count(.downloadRequest) == 1, "a decision after the shutdown began is honored")
        #expect(await controller.waitUntilSettled(record.key) == .idle)
        #expect(context.ledger.snapshot.openScopes == 0)
    }

    /// Reviewer's interleaving: `beginShutdown()` runs while `makeAvailable` is doing its I/O. Inside
    /// `requestDownload` (request already out): no observer survives, the transfer is reported cancelled
    /// and counted. During the metadata read: nothing is requested at all.
    @Test(arguments: [InterleavePoint.requestDownload, .metadata])
    func shutdownBeginningDuringMakeAvailableLeavesNoTransfer(_ point: InterleavePoint) async throws {
        let tree = try SyntheticTree(label: "interleave-\(point)")
        var rng = SplitMix64(seed: 20)
        let file = try tree.file("raced.wav", bytes: 64, rng: &rng)
        let base = HarnessIO()
        let io = InterleavingIO(base: base, point: point)
        let context = SourceAccessContext(io: io, ledger: SecurityScopeLedger())
        let record = try #require(try await SourceImporter(context: makeContext(base)).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        base.simulate(file, SimulatedCloudItem(script: [.complete]))
        let controller = SourceTransferController(context: context, policy: StallFollowUpTests.policy, setting: .on)
        io.onPoint = { _ = controller.beginShutdown() }

        let decided = controller.shutdownTicket()
        let state = await controller.makeAvailable(record.key, at: file, userRequested: true, decidedAt: decided)
        await controller.shutdown(through: controller.shutdownTicket())
        #expect(await controller.activeCount == 0)
        switch point {
        case .requestDownload:
            #expect(base.count(.downloadRequest) == 1, "the request had already gone out")
            #expect(await controller.downloadRequestCount == 1, "counted")
            #expect(state == .cancelled)
            #expect(await controller.state(of: record.key) == .cancelled)
        case .metadata:
            #expect(base.count(.downloadRequest) == 0, "refused before any request")
        }
        #expect(context.ledger.snapshot.openScopes == 0)
    }

    @Test @MainActor func droppingTheMonitorStopsStalledObservers() async throws {
        let tree = try SyntheticTree(label: "stall-drop-monitor")
        var rng = SplitMix64(seed: 18)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        io.simulate(file, SimulatedCloudItem(script: Self.stallForever))
        var monitor: SourceAvailabilityMonitor? = SourceAvailabilityMonitor(showID: testShow, store: InMemoryDeviceAccessStore(), context: context, setting: .on, transferPolicy: StallFollowUpTests.policy)
        weak var weakController = monitor?.transfers
        let collector = await eventCollector(monitor!.transfers, key: record.key) { $0.isOfflineOrUnknown }
        monitor?.start()
        try await monitor?.adopt([record])
        #expect((await collector.value).last?.isOfflineOrUnknown == true)
        monitor = nil
        #expect(try await pollingStopped(io))
        #expect(weakController == nil)
        #expect(context.ledger.snapshot.openScopes == 0)
    }

    @Test func droppingTheControllerStopsItsObservers() async throws {
        let tree = try SyntheticTree(label: "stall-drop-controller")
        var rng = SplitMix64(seed: 19)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        io.simulate(file, SimulatedCloudItem(script: Self.stallForever))
        let key = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        var controller: SourceTransferController? = SourceTransferController(context: makeContext(io), policy: StallFollowUpTests.policy, setting: .on)
        let collector = await eventCollector(controller!, key: key) { $0.isOfflineOrUnknown }
        _ = await controller?.makeAvailable(key, at: file)
        #expect((await collector.value).last?.isOfflineOrUnknown == true)
        #expect(try await pollingContinues(io))
        controller = nil
        #expect(try await pollingStopped(io))
    }

    @Test func waitUntilSettledFollowsARetryThatReplacesTheTransfer() async throws {
        let tree = try SyntheticTree(label: "stall-wait-retry")
        var rng = SplitMix64(seed: 20)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        io.simulate(file, SimulatedCloudItem(script: Self.stallForever))
        let key = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        let controller = SourceTransferController(context: makeContext(io), policy: StallFollowUpTests.policy, setting: .on)
        let collector = await eventCollector(controller, key: key) { $0.isOfflineOrUnknown }
        _ = await controller.makeAvailable(key, at: file)
        _ = await collector.value
        let waiter = Task { await settled(controller, key) }
        // Freeze the stalled observer before changing the provider and retrying (see above).
        await io.fractionGate.arm()
        #expect(await io.fractionGate.waitUntilEntered())
        io.mutateSimulated(file) { $0.evictAgain(script: [.progress(0.5), .complete]) }
        #expect(await controller.retry(key, at: file) == .requested)
        await io.fractionGate.release()
        #expect(await waiter.value == .idle)
    }

    /// Event-driven (#85 follow-up): the injected sleeper hands each requested duration to the test and
    /// suspends on a continuation until the test steps it — no wall clock, no parked threads.
    @Test func stalledBackoffScheduleInsideTheObservationLoop() async throws {
        let tree = try SyntheticTree(label: "stall-backoff")
        var rng = SplitMix64(seed: 21)
        let file = try tree.file("long.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        io.simulate(file, SimulatedCloudItem(script: Self.stallForever))
        let sleeper = SteppedSleeper()
        let policy = TransferPolicy(pollInterval: .milliseconds(1), stallAfterUnchangedPolls: 3, stalledPollInterval: .milliseconds(4), maxStalledPollInterval: .milliseconds(16))
        let controller = SourceTransferController(context: makeContext(io), policy: policy, setting: .on) { duration in
            try await sleeper.sleep(duration)
        }
        let key = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        _ = await controller.makeAvailable(key, at: file)
        var durations: [Duration] = []
        for await duration in sleeper.requests {
            durations.append(duration)
            if durations.count == 10 { break }
            sleeper.step()
        }
        await controller.cancel(key)
        // 1 poll establishes the signature, 3 unchanged polls trigger the stall, then 4 → 8 → 16 (cap).
        #expect(durations == [.milliseconds(1), .milliseconds(1), .milliseconds(1), .milliseconds(1),
                              .milliseconds(4), .milliseconds(8), .milliseconds(16), .milliseconds(16),
                              .milliseconds(16), .milliseconds(16)])
        #expect(await controller.state(of: key) == .cancelled)
        #expect(await controller.activeCount == 0)
        #expect(io.count(.downloadRequest) == 1)
        #expect(io.leakedScopes == 0)
    }
}


@Suite("Teardown never swallows later requests", .timeLimit(.minutes(1)))
struct TeardownOrderingTests {
    /// Mirrors the review probe: stop(); start(); makeAvailable back-to-back. A teardown that lands
    /// after the new request must not cancel it.
    @Test(arguments: [false, true]) @MainActor
    func stopThenStartThenMakeAvailableReachesIdle(transferRunningAtStop: Bool) async throws {
        let tree = try SyntheticTree(label: "stop-start")
        var rng = SplitMix64(seed: 22)
        let file = try tree.file("take.wav", bytes: 64, rng: &rng)
        let other = try tree.file("other.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        let context = makeContext(io)
        let plan = try await SourceImporter(context: context).plan(selection: [file, other], showID: testShow)
        let record = try #require(plan.items.first { $0.sourceRecord.displayNameHint == "take.wav" }?.accessRecord)
        let otherRecord = try #require(plan.items.first { $0.sourceRecord.displayNameHint == "other.wav" }?.accessRecord)
        io.simulate(file, SimulatedCloudItem(script: (1...30).map { .progress(Double($0) / 40) } + [.complete]))
        io.simulate(other, SimulatedCloudItem(script: StallLifetimeTests.stallForever))
        let monitor = SourceAvailabilityMonitor(showID: testShow, store: InMemoryDeviceAccessStore(), context: context, setting: .off, transferPolicy: StallFollowUpTests.policy)
        monitor.start()
        try await monitor.adopt(plan.accessRecords)
        if transferRunningAtStop {
            await monitor.makeAvailable(otherRecord.sourceID)
            #expect(await monitor.transfers.isActive(otherRecord.key))
        }

        await monitor.stop()
        monitor.start()
        await monitor.makeAvailable(record.sourceID)

        #expect(await monitor.transfers.waitUntilSettled(record.key) == .idle)
        for _ in 0..<500 where monitor.observations[record.sourceID]?.transfer != .idle { await Task.yield() }
        #expect(monitor.observations[record.sourceID]?.transfer == .idle)
        #expect(monitor.observations[record.sourceID]?.residency == .local)
        #expect(await !monitor.transfers.isActive(otherRecord.key))
        #expect(io.count(.downloadRequest) == (transferRunningAtStop ? 2 : 1))
        await monitor.stop()
    }

    @Test func lateShutdownOnlyAffectsWhatExistedAtTheTicket() async throws {
        let tree = try SyntheticTree(label: "ticket")
        var rng = SplitMix64(seed: 23)
        let old = try tree.file("old.wav", bytes: 64, rng: &rng)
        let new = try tree.file("new.wav", bytes: 64, rng: &rng)
        let io = HarnessIO()
        io.simulate(old, SimulatedCloudItem(script: StallLifetimeTests.stallForever))
        io.simulate(new, SimulatedCloudItem(script: StallLifetimeTests.stallForever))
        let controller = SourceTransferController(context: makeContext(io), policy: StallFollowUpTests.policy, setting: .on)
        let oldKey = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        let newKey = DeviceAccessKey(showID: testShow, sourceID: SourceID())
        let oldEvents = await eventCollector(controller, key: oldKey) { $0 == .cancelled }
        _ = await controller.makeAvailable(oldKey, at: old)
        let ticket = controller.shutdownTicket()
        // Created after the ticket: must survive the late shutdown.
        let newEvents = await eventCollector(controller, key: newKey, limit: .milliseconds(300)) { $0 == .cancelled }
        _ = await controller.makeAvailable(newKey, at: new)
        await controller.shutdown(through: ticket)
        #expect(await !controller.isActive(oldKey))
        #expect(await controller.isActive(newKey))
        #expect((await oldEvents.value).last == .cancelled)
        let laterStates = await newEvents.value
        #expect(!laterStates.contains(.cancelled))
        #expect(!laterStates.isEmpty)
        await controller.cancel(newKey)
    }
}


enum InterleavePoint: String, Sendable, CustomTestStringConvertible {
    case requestDownload
    case metadata
    var testDescription: String { rawValue }
}

/// Delegates to `HarnessIO` and runs `onPoint` once, synchronously, at the chosen I/O call (as a
/// nonisolated `beginShutdown()` on another thread would interleave).
final class InterleavingIO: SourceIO, @unchecked Sendable {
    let base: HarnessIO
    let point: InterleavePoint
    private let lock = NSLock()
    private var _onPoint: (@Sendable () -> Void)?
    var onPoint: (@Sendable () -> Void)? {
        get { lock.withLock { _onPoint } }
        set { lock.withLock { _onPoint = newValue } }
    }

    init(base: HarnessIO, point: InterleavePoint) {
        self.base = base
        self.point = point
    }

    private func fire(_ at: InterleavePoint) {
        guard at == point else { return }
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { _onPoint = nil }
            return _onPoint
        }
        hook?()
    }

    var provenance: ObservationProvenance { base.provenance }
    func metadata(at url: URL) -> MetadataResult {
        let result = base.metadata(at: url)
        fire(.metadata)
        return result
    }
    func listItems(under directory: URL) -> DirectoryListing { base.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { try base.makeReadOnlyBookmark(for: url) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { base.resolveBookmark(data) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { base.startAccessingSecurityScope(url) }
    func stopAccessingSecurityScope(_ url: URL) { base.stopAccessingSecurityScope(url) }
    func requestDownload(of url: URL) throws {
        try base.requestDownload(of: url)
        fire(.requestDownload)
    }
    func downloadFraction(of url: URL) async -> Knowledge<Double> { await base.downloadFraction(of: url) }
}
