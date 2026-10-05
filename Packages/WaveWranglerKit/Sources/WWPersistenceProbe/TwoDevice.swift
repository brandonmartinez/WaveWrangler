import Darwin
import Foundation
import WWCore
import WWPersistence

// M1-DUR-025 two-device iCloud trial commands (headless; synthetic documents only).
//
//   await         --file F (--publication UUID | --title T | --exists 0|1) [--timeout S]   (triggers download, polls)
//   inspect       --file F            (current file + NSFileVersion conflict versions + sibling copies, decoded)
//   lib           --file SETTINGS --container DIR --recovery DIR --cache FILE [--move-to F | --use F]
//                 [--add-collection NAME [--at-epoch-ms T]] [--combine 1] [--reload 1]
//   lib-inspect   --file LIBRARY.wwlibrary [--level-settings S --level-recovery DIR]   (read-only level sample)
//   fixture-state --file F            (setup diagnostics: presence, size, dataless, upload/download state, digest)
//   request-download --file F         (FileManager.startDownloadingUbiquitousItem; the setup retry)
//   corrupt       --file F            (external damaged writer: truncates the file in place)
//   save ... --at-epoch-ms T          (see Probe.save: waits until T, then edits and saves)

func epochMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

func sleepUntil(epochMs target: Int64?) {
    guard let target else { return }
    let remaining = target - epochMs()
    if remaining > 0 { usleep(useconds_t(min(remaining, 600_000) * 1_000)) }
    while epochMs() < target { usleep(500) }
}

/// m1-freeze-3: evidence names hosts only by pseudonym ("host A" / "host B", from WW_HOST_PSEUDONYM); no hostname,
/// computer name or account identifier is recorded.
func hostLabel() -> String { ProcessInfo.processInfo.environment["WW_HOST_PSEUDONYM"].map { "host \($0)" } ?? "unlabelled host" }

/// An NSFileVersion's saving computer, pseudonymized: "this host" or "other host" (never the computer name).
func savingComputerLabel(_ name: String?) -> String {
    guard let name, !name.isEmpty else { return "" }
    return name == (Host.current().localizedName ?? "") ? "this host" : "other host"
}

extension Probe {
    var plainOpener: DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>> { DocumentOpener(coder: coder, recovery: nil) }

    /// Waits until the file (after asking iCloud to download it) decodes with the expected publication/title,
    /// or exists/doesn't. Reports when it was observed, in this Mac's wall clock.
    func awaitFile() -> Int32 {
        let timeout = Double(args["timeout"] ?? "180") ?? 180
        let start = epochMs()
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        var last: [String: Any] = [:]
        while Date() < deadline {
            polls += 1
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            let exists = FileManager.default.fileExists(atPath: file.path)
            if let wanted = args["exists"] {
                if exists == (wanted == "1") {
                    emit(["result": "observed", "observedEpochMs": epochMs(), "waitedMs": epochMs() - start, "polls": polls, "host": hostLabel()])
                    return 0
                }
            } else if exists {
                last = describe(plainOpener.open(file))
                let matches = (args["publication"].map { last["publicationID"] as? String == $0 } ?? true)
                    && (args["title"].map { last["title"] as? String == $0 } ?? true)
                if matches, last["outcome"] as? String == "editable" {
                    emit(["result": "observed", "observedEpochMs": epochMs(), "waitedMs": epochMs() - start, "polls": polls,
                          "host": hostLabel()].merging(last) { $1 })
                    return 0
                }
            }
            usleep(250_000)
        }
        emit(["result": "timeout", "waitedMs": epochMs() - start, "polls": polls, "host": hostLabel(), "last": last])
        return 1
    }

    /// Everything that could hold either device's work: the current file, provider conflict versions
    /// (`NSFileVersion`, decoded) and sibling copies a provider may create ("Name 2.wwshow").
    func inspect() -> Int32 {
        var object: [String: Any] = ["host": hostLabel(), "epochMs": epochMs()]
        object["current"] = FileManager.default.fileExists(atPath: file.path) ? describe(plainOpener.open(file)) : ["outcome": "absent"]
        let current = NSFileVersion.currentVersionOfItem(at: file)
        object["currentSavingComputer"] = savingComputerLabel(current?.localizedNameOfSavingComputer)
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        object["unresolvedConflictVersions"] = conflicts.map { version -> [String: Any] in
            var entry: [String: Any] = ["savingComputer": savingComputerLabel(version.localizedNameOfSavingComputer),
                                        "modified": version.modificationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? -1]
            if let data = try? Data(contentsOf: version.url) {
                switch Result(catching: { () throws(PersistenceError) -> DecodedDocument<ShowDocumentModel> in try coder.decode(data) }) {
                case let .success(document):
                    entry["title"] = document.payload.show.title
                    entry["revision"] = document.revision
                    entry["publicationID"] = document.publication.publicationID.uuidString
                case let .failure(error): entry["decodeError"] = "\(error)"
                }
            } else {
                entry["decodeError"] = "unreadable"
            }
            return entry
        }
        object["otherVersions"] = (NSFileVersion.otherVersionsOfItem(at: file) ?? []).count
        // What the show's status shows (C4): the product's own report, including zero.
        object["statusProviderConflicts"] = ProviderConflictReport.inspect(file).unresolvedVersionCount
        object["sha256"] = (try? Data(contentsOf: file)).map(sha256Hex) ?? ""
        let stem = file.deletingPathExtension().lastPathComponent
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == file.pathExtension && $0.lastPathComponent != file.lastPathComponent
                && $0.deletingPathExtension().lastPathComponent.hasPrefix(stem) }
        object["siblings"] = siblings.map { url -> [String: Any] in
            ["name": url.lastPathComponent].merging(describe(plainOpener.open(url))) { $1 }
        }
        let values = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey])
        object["downloadingStatus"] = values?.ubiquitousItemDownloadingStatus?.rawValue ?? "unknown"
        object["isUploaded"] = values?.ubiquitousItemIsUploaded ?? false
        object["hasUnresolvedConflicts"] = values?.ubiquitousItemHasUnresolvedConflicts ?? false
        emit(object)
        return 0
    }

    /// External damaged writer (simulates a provider or another app leaving a truncated file). Never used on
    /// anything but the synthetic trial file named on the command line.
    func corrupt() -> Int32 {
        guard let data = try? Data(contentsOf: file), data.count > 8 else { emit(["result": "unreadable"]); return 1 }
        do {
            try data.prefix(data.count / 2).write(to: file)
            emit(["result": "corrupted", "bytes": data.count / 2, "epochMs": epochMs()])
            return 0
        } catch {
            emit(["result": "error", "detail": "\(error)"])
            return 1
        }
    }

    func libraryOp() async -> Int32 {
        guard let container = args.url("container"), let recovery, let cache = args.url("cache") else {
            emit(["error": "lib needs --container --recovery --cache"])
            return 2
        }
        let store = LibraryStore(containerFolder: container, settings: FileLibrarySettings(url: file), bookmarks: PathBookmarks(),
                                 recovery: recovery, indexCache: LibraryIndexCache(url: cache))
        var object: [String: Any] = ["host": hostLabel(), "loadStartedEpochMs": epochMs()]
        object["load"] = "\(await store.load())"
        object["loadFinishedEpochMs"] = epochMs()
        object["levelAfterLoad"] = "\(await store.levelState)"
        object["providerConflictsAfterLoad"] = await store.providerConflicts.count
        object["unusableAfterLoad"] = await store.unusableProviderConflicts.count
        object["rawUnresolvedAfterLoad"] = await store.currentLibraryURL().map { (NSFileVersion.unresolvedConflictVersionsOfItem(at: $0) ?? []).count } ?? -1
        if args["seed-fixture"] == "1" {
            // DUR-025 library fixture: 4 shows, collections Alpha [0,1,2] and Beta [1,2,3], recents [0]; no aliases.
            let result = try? await store.update { library in
                var library = library
                let ids = (0..<4).map { _ in ShowID() }
                for (index, id) in ids.enumerated() {
                    library = LibraryReconciler.registering(id, title: "Synthetic Show \(index)", publication: nil, in: library)
                }
                library.collections.append(LibraryCollection(name: "Alpha", showIDs: Array(ids[0...2])))
                library.collections.append(LibraryCollection(name: "Beta", showIDs: Array(ids[1...3])))
                library.recentShowIDs = [ids[0]]
                return library
            }
            object["seeded"] = result.map { "\($0)" } ?? "threw"
        }
        if let folder = args.url("move-to") { object["move"] = "\(await store.moveLibrary(to: folder))" }
        if let folder = args.url("use") { object["use"] = "\(await store.useLibrary(in: folder))" }
        if args["reload"] == "1" { object["reload"] = "\(await store.reload())" }
        if let kind = args["edit"] ?? args["add-collection"].map({ _ in "collection" }) {
            let value = args["edit-arg"] ?? args["add-collection"] ?? ""
            let at = args["at-epoch-ms"].flatMap(Int64.init)
            sleepUntil(epochMs: at)
            object["startedEpochMs"] = epochMs()
            do {
                // Seeded organizing edits (m1-freeze-2 library-conflict cell): collection, alias, order or recents.
                let result = try await store.update { library in
                    var library = library
                    switch kind {
                    case "collection":
                        library.collections.append(LibraryCollection(name: value))
                    case "alias":
                        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                        if let index = Int(parts[0]), library.entries.indices.contains(index) {
                            library.entries[index].alias = parts.count > 1 ? parts[1] : "Alias"
                        }
                    case "order":
                        if let index = library.collections.firstIndex(where: { $0.name == value }) {
                            library.collections[index].showIDs.reverse()
                        }
                    case "recent":
                        if let index = Int(value), library.entries.indices.contains(index) {
                            library = LibraryReconciler.recordingRecent(library.entries[index].showID, in: library)
                        }
                    default:
                        break
                    }
                    return library
                }
                object["update"] = switch result {
                case let .published(receipt): "published r\(receipt.revision)"
                case let .queued(count): "queued \(count)"
                case .unchanged: "unchanged"
                case let .failed(error): "failed \(describe(error)["result"] ?? "")"
                }
            } catch {
                object["update"] = "threw \(error)"
            }
            object["finishedEpochMs"] = epochMs()
        }
        if args["combine"] == "1", args["edit"] == nil, args["add-collection"] == nil {
            sleepUntil(epochMs: args["at-epoch-ms"].flatMap(Int64.init))   // concurrentCombine: shared trigger
        }
        if args["combine"] == "1", case .changedElsewhere = await store.levelState {
            object["combineStartedEpochMs"] = epochMs()
            if let url = await store.currentLibraryURL() {
                object["combineBeforeModel"] = (decodeLibrary(try? Data(contentsOf: url))["model"]) ?? [:]
            }
            switch await store.resolveConflictByCombining() {
            case let .success(summary):
                object["combine"] = summary.message
                object["combineSummary"] = ["entryChangesNotCarried": summary.entryChangesNotCarried,
                                            "queuedChangesNotCarried": summary.queuedChangesNotCarried,
                                            "collectionsKeptAsCopies": summary.collectionsKeptAsCopies,
                                            "collectionsAdded": summary.collectionsAdded, "showsAdded": summary.showsAdded,
                                            "recentItemsAdded": summary.recentItemsAdded]
                if let combined = await store.library { object["combineAfterModel"] = libraryModelDict(combined) }
            case let .failure(error): object["combine"] = "failed \(describe(error)["result"] ?? "")"
            }
        }
        object["levelState"] = "\(await store.levelState)"
        object["providerConflicts"] = await store.providerConflicts.count
        object["unusableProviderConflicts"] = await store.unusableProviderConflicts.count
        object["conflictBackups"] = ((try? recovery.conflictCandidates(for: .library)) ?? []).count
        object["pendingEdits"] = await store.pendingEditCount
        let library = await store.library
        object["collections"] = library?.collections.map(\.name) ?? []
        object["libraryID"] = library.map { "\($0.libraryID)" } ?? ""
        object["finishedEpochMs"] = epochMs()
        if let url = await store.currentLibraryURL() { object["libraryURL"] = url.path }
        emit(object)
        return 0
    }

    func libraryInspect() async -> Int32 {
        func decode(_ url: URL) -> [String: Any] { decodeLibrary(try? Data(contentsOf: url)) }
        var object: [String: Any] = ["host": hostLabel(), "epochMs": epochMs()]
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        return await libraryInspectBody(&object, decode: decode)
    }

    func libraryModelDict(_ model: LibraryModel) -> [String: Any] {
        ["entries": model.entries.map { ["showID": $0.showID.rawValue.uuidString, "alias": $0.alias ?? ""] },
         "collections": model.collections.map { ["name": $0.name, "showIDs": $0.showIDs.map(\.rawValue.uuidString)] },
         "recents": model.recentShowIDs.map(\.rawValue.uuidString)]
    }

    func decodeLibrary(_ bytes: Data?) -> [String: Any] {
            guard let data = bytes else { return ["outcome": "unreadable"] }
            switch Result(catching: { () throws(PersistenceError) -> DecodedDocument<LibraryModel> in try LibraryCoder.library.decode(data) }) {
            case let .success(document):
                let model = document.payload
                return ["outcome": "valid", "revision": document.revision, "collections": model.collections.map(\.name),
                        "publicationID": document.publication.publicationID.uuidString, "libraryID": "\(model.libraryID)",
                        "sha256": sha256Hex(data), "model": libraryModelDict(model)]
            case let .failure(error):
                return ["outcome": "invalid", "detail": "\(error)"]
            }
    }

    func libraryInspectBody(_ object: inout [String: Any], decode: (URL) -> [String: Any]) async -> Int32 {
        object["current"] = FileManager.default.fileExists(atPath: file.path) ? decode(file) : ["outcome": "absent"]
        object["currentSavingComputer"] = savingComputerLabel(NSFileVersion.currentVersionOfItem(at: file)?.localizedNameOfSavingComputer)
        object["unresolvedConflictVersions"] = (NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).map { version in
            ["savingComputer": savingComputerLabel(version.localizedNameOfSavingComputer)].merging(decode(version.url)) { $1 }
        }
        let stem = file.deletingPathExtension().lastPathComponent
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == file.pathExtension && $0.lastPathComponent != file.lastPathComponent
                && $0.deletingPathExtension().lastPathComponent.hasPrefix(stem) }
        object["siblings"] = siblings.map { ["name": $0.lastPathComponent].merging(decode($0)) { $1 } }
        object["otherVersions"] = (NSFileVersion.otherVersionsOfItem(at: file) ?? []).count
        if let settings = args.url("level-settings"), let recoveryRoot = args.url("level-recovery") {
            object["level"] = await readOnlyLevel(settings: settings, recovery: recoveryRoot)
            object["unresolvedAfterLevel"] = (NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).count
        }
        emit(object)
        return 0
    }

    /// m1-freeze-3 level sampling: the level a product load would show now, without its side effects. The load
    /// runs against scratch copies of this host's library settings and recovery store, with provider versions
    /// that are never marked resolved; versions the load would have backed up and resolved (already included)
    /// are counted, not resolved. Refuses (unsampled) if queued library edits exist, since loading would publish them.
    func readOnlyLevel(settings: URL, recovery recoveryRoot: URL) async -> [String: Any] {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "ww-level-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch) }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let settingsCopy = scratch.appending(path: "settings.json")
            try fm.copyItem(at: settings, to: settingsCopy)
            let recoveryCopy = scratch.appending(path: "recovery", directoryHint: .isDirectory)
            if fm.fileExists(atPath: recoveryRoot.path) { try fm.copyItem(at: recoveryRoot, to: recoveryCopy) }
            else { try fm.createDirectory(at: recoveryCopy, withIntermediateDirectories: true) }
            let store = RecoveryStore(root: recoveryCopy)
            if store.pendingLibraryEdits() != nil { return ["level": "unsampled", "reason": "queued library edits present"] }
            let versions = NonResolvingVersions()
            let library = LibraryStore(containerFolder: scratch.appending(path: "container", directoryHint: .isDirectory),
                                       settings: FileLibrarySettings(url: settingsCopy), bookmarks: PathBookmarks(), recovery: store,
                                       indexCache: LibraryIndexCache(url: scratch.appending(path: "index.json")), providerVersions: versions)
            let started = epochMs()
            let load = await library.load()
            let asked = versions.asked
            let unusable = await library.unusableProviderConflicts.map(\.id).filter { !asked.contains($0) }
            let notIncluded = Set(await library.providerConflicts.map(\.id))
            let current = await library.library
            // m1-freeze-4 per-version record. The product's verdict comes from this load itself; the fork bases are
            // listed the way the store selects them (retained checkpoints of this library at revision − 1).
            let candidates = DocumentOpener(coder: LibraryCoder.library, recovery: store).candidates(url: nil, key: .library)
            let perVersion: [[String: Any]] = versions.versions.map { version in
                var entry = decodeLibrary(version.bytes)
                entry["savingComputer"] = savingComputerLabel(version.savingComputer)
                let decoded = version.bytes.flatMap { try? LibraryCoder.library.decode($0) }
                if let decoded, let current {
                    entry["sameLibraryID"] = "\(decoded.payload.libraryID)" == "\(current.libraryID)"
                    entry["forkBases"] = candidates.filter { $0.document.revision == decoded.revision - 1
                        && ("\($0.document.payload.libraryID)" == "\(current.libraryID)" || LibraryCoder.isProvisional($0.document.payload.libraryID)) }
                        .map { ["revision": $0.document.revision, "sha256": $0.checkpoint.fingerprint.byteDigest] }
                }
                entry["productVerdict"] = asked.contains(version.id) ? "included" : notIncluded.contains(version.id) ? "notIncluded"
                    : unusable.contains(version.id) ? "unusable" : "notSeen"
                // The #119 notice is driven by the store's unusable list.
                entry["noticeShown"] = unusable.contains(version.id)
                return entry
            }
            return ["level": "\(await library.levelState)", "load": "\(load)", "startedEpochMs": started, "finishedEpochMs": epochMs(),
                    "notIncluded": await library.providerConflicts.count, "wouldResolveAsIncluded": asked.count, "unusable": unusable.count,
                    "seenByLoad": versions.seen, "versions": perVersion]
        } catch {
            return ["level": "unsampled", "reason": "\((error as NSError).domain) \((error as NSError).code)"]
        }
    }

    /// Setup diagnostics (m1-freeze-3): never reads a dataless placeholder (that would download it).
    func fixtureState() -> Int32 {
        var object: [String: Any] = ["host": hostLabel(), "epochMs": epochMs()]
        var info = stat()
        let present = lstat(file.path, &info) == 0
        object["present"] = present
        var dataless = false
        if present {
            object["size"] = Int64(info.st_size)
            dataless = (info.st_flags & 0x4000_0000) != 0   // SF_DATALESS
            object["dataless"] = dataless
        }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                         .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey]
        if let values = try? file.resourceValues(forKeys: keys) {
            object["isUbiquitous"] = values.isUbiquitousItem ?? false
            object["isUploaded"] = values.ubiquitousItemIsUploaded.map { $0 as Any } ?? NSNull()
            object["isUploading"] = values.ubiquitousItemIsUploading.map { $0 as Any } ?? NSNull()
            object["downloadingStatus"] = values.ubiquitousItemDownloadingStatus?.rawValue ?? NSNull()
            object["downloadingError"] = values.ubiquitousItemDownloadingError.map { "\($0.domain) \($0.code)" } ?? NSNull()
            object["uploadingError"] = values.ubiquitousItemUploadingError.map { "\($0.domain) \($0.code)" } ?? NSNull()
        }
        if present, !dataless, let data = try? Data(contentsOf: file) {
            object["sha256"] = sha256Hex(data)
            if let show = try? coder.decode(data) { object["publicationID"] = show.publication.publicationID.uuidString }
            else if let library = try? LibraryCoder.library.decode(data) { object["publicationID"] = library.publication.publicationID.uuidString }
        }
        emit(object)
        return 0
    }

    func requestDownload() -> Int32 {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: file)
            emit(["result": "requested", "epochMs": epochMs(), "host": hostLabel()])
        } catch {
            emit(["result": "error", "error": "\((error as NSError).domain) \((error as NSError).code)", "epochMs": epochMs(), "host": hostLabel()])
        }
        return 0
    }
}

/// Provider versions for the read-only level sample: passes through what NSFileVersion reports and never marks
/// anything resolved (records which versions the load would have resolved instead).
final class NonResolvingVersions: ProviderVersionInspecting, @unchecked Sendable {
    private let inner = FileVersionInspector()
    private let lock = NSLock()
    private var askedIDs: Set<String> = []
    private var lastSeen: [ProviderConflictVersion] = []
    var asked: Set<String> { lock.withLock { askedIDs } }
    var seen: Int { lock.withLock { lastSeen.count } }
    var versions: [ProviderConflictVersion] { lock.withLock { lastSeen } }

    func unresolvedConflictVersions(of url: URL) -> [ProviderConflictVersion] {
        let versions = inner.unresolvedConflictVersions(of: url)
        lock.withLock { lastSeen = versions }
        return versions
    }

    func markResolved(_ ids: Set<String>, of url: URL) throws {
        lock.withLock { askedIDs.formUnion(ids) }
        throw CocoaError(.fileWriteNoPermission)
    }
}
