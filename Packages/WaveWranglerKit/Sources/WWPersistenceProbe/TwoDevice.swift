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
//   lib-inspect   --file LIBRARY.wwlibrary
//   corrupt       --file F            (external damaged writer: truncates the file in place)
//   save ... --at-epoch-ms T          (see Probe.save: waits until T, then edits and saves)

func epochMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

func sleepUntil(epochMs target: Int64?) {
    guard let target else { return }
    let remaining = target - epochMs()
    if remaining > 0 { usleep(useconds_t(min(remaining, 600_000) * 1_000)) }
    while epochMs() < target { usleep(500) }
}

func hostLabel() -> String { ProcessInfo.processInfo.hostName }

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
        object["currentSavingComputer"] = current?.localizedNameOfSavingComputer ?? ""
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        object["unresolvedConflictVersions"] = conflicts.map { version -> [String: Any] in
            var entry: [String: Any] = ["savingComputer": version.localizedNameOfSavingComputer ?? "",
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
        var object: [String: Any] = ["host": hostLabel(), "load": "\(await store.load())"]
        if let folder = args.url("move-to") { object["move"] = "\(await store.moveLibrary(to: folder))" }
        if let folder = args.url("use") { object["use"] = "\(await store.useLibrary(in: folder))" }
        if args["reload"] == "1" { object["reload"] = "\(await store.reload())" }
        if let name = args["add-collection"] {
            let at = args["at-epoch-ms"].flatMap(Int64.init)
            sleepUntil(epochMs: at)
            object["startedEpochMs"] = epochMs()
            do {
                let result = try await store.update { library in
                    var library = library
                    library.collections.append(LibraryCollection(name: name))
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
        if args["combine"] == "1", case .changedElsewhere = await store.levelState {
            switch await store.resolveConflictByCombining() {
            case let .success(summary): object["combine"] = summary.message
            case let .failure(error): object["combine"] = "failed \(describe(error)["result"] ?? "")"
            }
        }
        object["levelState"] = "\(await store.levelState)"
        object["pendingEdits"] = await store.pendingEditCount
        let library = await store.library
        object["collections"] = library?.collections.map(\.name) ?? []
        object["libraryID"] = library.map { "\($0.libraryID)" } ?? ""
        if let url = await store.currentLibraryURL() { object["libraryURL"] = url.path }
        emit(object)
        return 0
    }

    func libraryInspect() -> Int32 {
        func decode(_ url: URL) -> [String: Any] {
            guard let data = try? Data(contentsOf: url) else { return ["outcome": "unreadable"] }
            switch Result(catching: { () throws(PersistenceError) -> DecodedDocument<LibraryModel> in try LibraryCoder.library.decode(data) }) {
            case let .success(document):
                return ["outcome": "valid", "revision": document.revision, "collections": document.payload.collections.map(\.name),
                        "publicationID": document.publication.publicationID.uuidString, "libraryID": "\(document.payload.libraryID)"]
            case let .failure(error):
                return ["outcome": "invalid", "detail": "\(error)"]
            }
        }
        var object: [String: Any] = ["host": hostLabel(), "epochMs": epochMs()]
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        object["current"] = FileManager.default.fileExists(atPath: file.path) ? decode(file) : ["outcome": "absent"]
        object["currentSavingComputer"] = NSFileVersion.currentVersionOfItem(at: file)?.localizedNameOfSavingComputer ?? ""
        object["unresolvedConflictVersions"] = (NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).map { version in
            ["savingComputer": version.localizedNameOfSavingComputer ?? ""].merging(decode(version.url)) { $1 }
        }
        let stem = file.deletingPathExtension().lastPathComponent
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == file.pathExtension && $0.lastPathComponent != file.lastPathComponent
                && $0.deletingPathExtension().lastPathComponent.hasPrefix(stem) }
        object["siblings"] = siblings.map { ["name": $0.lastPathComponent].merging(decode($0)) { $1 } }
        emit(object)
        return 0
    }
}
