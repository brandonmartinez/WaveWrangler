import Darwin
import Foundation
import WWCore
import WWPersistence

// Headless persistence probe. Operates only on the synthetic documents named on the command line.
// Every command prints one JSON object on stdout.
//
//   create    --file F [--seed N] [--recovery DIR]
//   save      --file F --title T [--recovery DIR] [--ready FILE --go FILE]
//   open      --file F [--recovery DIR]
//   versions  --file F
//   autosave  --file F --enabled 0|1 [--delay S] [--recovery DIR]
//   kill-at   --file F --boundary P1..P7 [--recovery DIR] [--library LIB --index IDX] [--marker FILE] (SIGKILL at that boundary;
//             P7 needs --library: the show save acknowledges into that library file, then updates IDX)
//   library-kill-at --file SETTINGS.json --container DIR --recovery DIR --cache FILE --boundary P1..P6 --collection NAME
//   record-location --file LOCATIONS_DIR --show UUID --doc SHOW.wwshow
//   reopen-save --file LOCATIONS_DIR --show UUID --title T --recovery DIR [--library-settings S --container DIR --cache FILE]
//   library   --file SETTINGS.json --container DIR --recovery DIR --cache FILE [--move-to FOLDER] [--add N]

struct Arguments {
    let command: String
    private let values: [String: String]

    init(_ arguments: [String]) {
        command = arguments.dropFirst().first ?? "help"
        var values: [String: String] = [:]
        var iterator = arguments.dropFirst(2).makeIterator()
        while let key = iterator.next() {
            if key.hasPrefix("--") { values[String(key.dropFirst(2))] = iterator.next() ?? "" }
        }
        self.values = values
    }

    subscript(_ key: String) -> String? { values[key] }

    func url(_ key: String) -> URL? { values[key].map { URL(fileURLWithPath: $0) } }
}

func emit(_ object: [String: Any]) {
    var object = object
    object["pid"] = Int(getpid())
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func describe(_ error: PublicationError) -> [String: Any] {
    switch error {
    case let .conflict(conflict):
        return ["result": "conflict", "onDiskRevision": conflict.onDisk?.revision ?? -1, "preservedCandidate": conflict.preservedCandidate?.path ?? ""]
    case let .failed(stage, kind, detail): return ["result": "failed", "stage": stage.rawValue, "kind": kind.rawValue, "detail": detail]
    case .cancelled: return ["result": "cancelled"]
    case let .acknowledgementUncertain(detail): return ["result": "acknowledgementUncertain", "detail": detail]
    case let .readOnly(reason): return ["result": "readOnly", "detail": reason]
    case let .invalidCandidate(error): return ["result": "invalidCandidate", "detail": "\(error)"]
    }
}

func describe(_ outcome: OpenOutcome<ShowDocumentModel>) -> [String: Any] {
    switch outcome {
    case let .editable(document, fingerprint):
        return ["outcome": "editable", "revision": document.revision, "title": document.payload.show.title,
                "publicationID": document.publication.publicationID.uuidString, "digest": fingerprint.byteDigest]
    case let .refusedNewerFormat(found, supported, _): return ["outcome": "refusedNewerFormat", "found": found, "supported": supported]
    case let .needsMigration(schema, _): return ["outcome": "needsMigration", "schema": schema]
    case let .damaged(error, candidates):
        return ["outcome": "damaged", "detail": "\(error)", "candidateRevisions": candidates.map(\.document.revision),
                "candidateTitles": candidates.map(\.document.payload.show.title)]
    case let .unreadable(kind, detail, candidates):
        return ["outcome": "unreadable", "kind": kind.rawValue, "detail": detail, "candidateRevisions": candidates.map(\.document.revision)]
    }
}

func waitFor(_ url: URL, timeout: Double = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        usleep(2_000)
    }
    return false
}

/// Kills the process with SIGKILL (no cleanup, no handlers) when the chosen boundary is reached. With a
/// `marker` file, the boundary name is written and flushed first, so the parent can tell a kill *at* the
/// boundary from any other termination (#82).
struct ExitAtBoundary: PublicationHooks {
    let boundary: PublicationBoundary
    var marker: URL?
    func reached(_ reached: PublicationBoundary) throws {
        if reached == boundary {
            if let marker {
                let fd = open(marker.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 {
                    _ = boundary.rawValue.withCString { write(fd, $0, strlen($0)) }
                    fsync(fd)
                    close(fd)
                }
            }
            kill(getpid(), SIGKILL)
            // Delivery can lag the syscall's return: wait for it, so the process only ever ends by SIGKILL.
            while true { pause() }
        }
    }
}

typealias ShowSession = CanonicalDocumentSession<JSONEnvelopeCoder<ShowDocumentModel>>

struct Probe {
    let args: Arguments
    let file: URL
    let recovery: RecoveryStore?
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    var publisher: DocumentPublisher<JSONEnvelopeCoder<ShowDocumentModel>> { DocumentPublisher(coder: coder, recovery: recovery) }
    var opener: DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>> { DocumentOpener(coder: coder, recovery: recovery) }

    func openSession(gate: AutosaveGate? = nil, hooks: any PublicationHooks = NoPublicationHooks()) -> ShowSession? {
        let hooked = DocumentPublisher(coder: coder, recovery: recovery, hooks: hooks)
        switch ShowSession.open(file, key: nil, opener: opener, publisher: hooked, gate: gate, keyFor: { .show($0.show.id) }) {
        case let .success(session): return session
        case let .failure(failure):
            emit(["result": "openFailed"].merging(describe(failure.outcome)) { $1 })
            return nil
        }
    }

    func run() async -> Int32 {
        switch args.command {
        case "create": return create()
        case "save": return await save()
        case "open": return open()
        case "profile-open": return profileOpen()
        case "versions": return versions()
        case "autosave": return await autosave()
        case "kill-at": return await killAt()
        case "library": return await library()
        case "library-kill-at": return await libraryKillAt()
        case "reopen-save": return await reopenSave()
        case "record-location": return recordLocation()
        default:
            emit(["error": "unknown command \(args.command)"])
            return 2
        }
    }

    func create() -> Int32 {
        let seed = UInt64(args["seed"] ?? "1") ?? 1
        var model = ShowDocumentModel.untitled(title: "Synthetic Trial Show \(seed)")
        for index in 0..<3 {
            model = (try? model.addingEpisode(Episode(title: "Synthetic Episode \(index + 1)",
                                                      sources: [SourceRecord(displayNameHint: "synthetic-\(index).wav")]))) ?? model
        }
        do {
            let receipt = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: file, target: .newLocation)
            emit(["result": "saved", "revision": receipt.revision, "publicationID": receipt.publication.publicationID.uuidString])
            return 0
        } catch let error as PublicationError {
            emit(describe(error))
        } catch {
            emit(["result": "error", "detail": "\(error)"])
        }
        return 1
    }

    func save() async -> Int32 {
        guard let session = openSession() else { return 1 }
        if let ready = args.url("ready"), let go = args.url("go") {
            FileManager.default.createFile(atPath: ready.path, contents: Data())
            guard waitFor(go) else { emit(["result": "timeout"]); return 1 }
        }
        let title = args["title"] ?? "Edited by \(getpid())"
        _ = try? await session.edit { try $0.renamingShow(to: title) }
        if let delay = Int(args["delay-ms"] ?? "") { usleep(useconds_t(delay * 1_000)) }   // seeded race schedule
        let start = ContinuousClock.now
        switch await session.save() {
        case let .success(receipt):
            emit(["result": "saved", "revision": receipt.revision, "title": title,
                  "publicationID": receipt.publication.publicationID.uuidString, "seconds": seconds(.now - start)])
        case let .failure(error):
            emit(describe(error).merging(["title": title]) { $1 })
        }
        return 0
    }

    /// Cold-process timing of the non-UI stages of opening a show (SCALE-001 investigation): file read,
    /// decode + checksum, NSFileVersion conflict inspection, edit-checkpoint set-aside + offer scan.
    func profileOpen() -> Int32 {
        func ms(_ start: ContinuousClock.Instant) -> Double { seconds(.now - start) * 1000 }
        var out: [String: Any] = [:]
        var t = ContinuousClock.now
        guard let data = try? Data(contentsOf: file) else { emit(["error": "read"]); return 1 }
        out["readMs"] = ms(t)
        t = .now
        let opener = DocumentOpener(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        let outcome = opener.outcome(for: data, url: file)
        out["decodeMs"] = ms(t)
        guard case let .editable(document, fingerprint) = outcome else { emit(["error": "not editable"]); return 1 }
        t = .now
        _ = ProviderConflictReport.inspect(file)
        out["fileVersionMs"] = ms(t)
        if let recovery {
            let key = DocumentKey.show(document.payload.show.id)
            t = .now
            try? recovery.setAsideEditCheckpoints(for: key)
            out["setAsideMs"] = ms(t)
            t = .now
            let showID = document.payload.show.id
            _ = EditCheckpointOffer.assess(recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue, onDisk: fingerprint,
                                           coder: coder, belongsToDocument: { $0.show.id == showID })
            out["offerScanMs"] = ms(t)
        }
        // The persistent library path (PersistentLibraryEntryObserver.openShow): resolve the read-write
        // bookmark and start its scope, then verify the show identity with a coordinated open, before NSDocument
        // reads the file again. The first run records the bookmark (same executable, as the app does).
        if let root = args.url("locations") {
            let showID = document.payload.show.id
            t = .now
            let locations = LibraryShowLocations(root: root)
            out["locationsInitMs"] = ms(t)
            if args["record"] != nil {
                try? locations.record(showID, at: file)
                out["recorded"] = true
            } else {
                t = .now
                guard let grant = try? locations.beginAccess(showID) else { emit(["error": "beginAccess"]); return 1 }
                out["beginAccessMs"] = ms(t)
                t = .now
                _ = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: nil).open(grant.url, key: .show(showID))
                out["verifyOpenMs"] = ms(t)
                locations.endAccess(grant)
            }
        }
        out["bytes"] = data.count
        emit(out)
        return 0
    }

    func open() -> Int32 {
        let start = ContinuousClock.now
        var object = describe(opener.open(file))
        object["seconds"] = seconds(.now - start)
        object["unresolvedConflictVersions"] = ProviderConflictReport.inspect(file).unresolvedVersionCount
        emit(object)
        return 0
    }

    func versions() -> Int32 {
        let report = ProviderConflictReport.inspect(file)
        let others = NSFileVersion.otherVersionsOfItem(at: file) ?? []
        let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
                                                        .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey])
        emit([
            "unresolvedConflictVersions": report.unresolvedVersionCount,
            "hasUnresolvedConflicts": report.hasUnresolvedConflicts,
            "otherVersions": others.count,
            "isUbiquitous": values?.isUbiquitousItem ?? false,
            "downloadingStatus": values?.ubiquitousItemDownloadingStatus?.rawValue ?? "unknown",
            "isUploaded": values?.ubiquitousItemIsUploaded ?? false,
            "isUploading": values?.ubiquitousItemIsUploading ?? false,
        ])
        return 0
    }

    func autosave() async -> Int32 {
        let enabled = args["enabled"] == "1"
        let gate = AutosaveGate(AutosavePreference(enabled: enabled, delaySeconds: Double(args["delay"] ?? "1") ?? 1))
        guard let session = openSession(gate: gate) else { return 1 }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let scheduler = QuiescenceScheduler(gate: gate, queue: .global(), onSkipped: { continuation.yield("skipped") }) { kind in
            Task {
                switch kind {
                case .publish:
                    if case .success = await session.save(automatic: true) { continuation.yield("published") } else { continuation.yield("failed") }
                case .editCheckpoint:
                    if await session.writeEditCheckpoint() { continuation.yield("editCheckpoint") }
                }
            }
        }
        _ = try? await session.edit { try $0.renamingShow(to: "Autosave \(enabled ? "ON" : "OFF") \(getpid())") }
        let lastEdit = ContinuousClock.now
        guard scheduler.noteEdit() else {
            try? await Task.sleep(for: .seconds(2.5))
            let skipped: Bool = if case .failure(.cancelled) = await session.save(automatic: true) { true } else { false }
            emit(["result": "off", "scheduled": false, "automaticSaveSkipped": skipped, "dirty": await session.isDirty])
            return 0
        }
        var iterator = stream.makeAsyncIterator()
        var events: [String] = []
        while let event = await iterator.next() {
            events.append(event)
            if event != "editCheckpoint" { break }
        }
        emit(["result": events.last ?? "none", "events": events, "scheduled": true, "dirty": await session.isDirty,
              "secondsFromLastEdit": seconds(.now - lastEdit)])
        return 0
    }

    func killAt() async -> Int32 {
        guard let raw = args["boundary"], let boundary = PublicationBoundary(rawValue: raw) else { emit(["error": "boundary"]); return 2 }
        guard let session = openSession(hooks: ExitAtBoundary(boundary: boundary, marker: args.url("marker"))) else { return 1 }
        do {
            try await session.edit { try $0.renamingShow(to: "Killed at \(raw)") }
        } catch {
            // Fatal: saving an unedited model would republish the old payload as revision 3.
            emit(["error": "edit failed: \(error)"])
            return 3
        }
        var followUp = PublicationFollowUp.none
        if let libraryURL = args.url("library") {
            let showID = await session.payload.show.id
            let indexURL = args.url("index")
            let libraryPublisher = DocumentPublisher(coder: LibraryCoder.library, recovery: recovery)
            followUp = PublicationFollowUp(
                acknowledgeLibrary: { receipt in
                    // C3 step 8: acknowledge the verified show publication into the library (whole publication).
                    let bytes = try Data(contentsOf: libraryURL)
                    let current = try LibraryCoder.library.decode(bytes)
                    let updated = LibraryReconciler.acknowledging(showID, title: "Killed at \(raw)", publication: receipt.publication, in: current.payload)
                    _ = try libraryPublisher.publish(updated, revision: current.revision + 1, key: .library, to: libraryURL,
                                                     target: .inPlace(expectedBase: RevisionFingerprint(of: bytes)))
                },
                updateIndex: { _ in
                    guard let indexURL else { return }
                    let bytes = try Data(contentsOf: libraryURL)
                    try LibraryIndexCache(url: indexURL).store(LibraryIndex.build(from: try LibraryCoder.library.decode(bytes).payload,
                                                                                  libraryDigest: RevisionFingerprint.digest(bytes)))
                }
            )
        }
        _ = await session.save(followUp: followUp)
        emit(["result": "boundaryNotReached"])
        return 1
    }

    func libraryKillAt() async -> Int32 {
        guard let raw = args["boundary"], let boundary = PublicationBoundary(rawValue: raw),
              let container = args.url("container"), let recovery, let cache = args.url("cache") else {
            emit(["error": "library-kill-at needs --boundary --container --recovery --cache"])
            return 2
        }
        let store = LibraryStore(containerFolder: container, settings: FileLibrarySettings(url: file), bookmarks: PathBookmarks(),
                                 recovery: recovery, indexCache: LibraryIndexCache(url: cache), hooks: ExitAtBoundary(boundary: boundary, marker: args.url("marker")))
        _ = await store.load()
        let name = args["collection"] ?? "Killed at \(raw)"
        do {
            _ = try await store.update { var library = $0; library.collections.append(LibraryCollection(name: name)); return library }
        } catch {
            emit(["error": "update failed: \(error)"])
            return 3
        }
        emit(["result": "boundaryNotReached"])
        return 1
    }

    /// Records a read-write document bookmark for `--show` at `--doc` (created by this executable, as the app does).
    func recordLocation() -> Int32 {
        guard let showRaw = args["show"], let showUUID = UUID(uuidString: showRaw), let doc = args.url("doc") else {
            emit(["error": "record-location needs --show --doc"])
            return 2
        }
        do {
            try ShowLocationStore(root: file).record(ShowID(showUUID), at: doc)
            emit(["result": "recorded"])
            return 0
        } catch {
            emit(["result": "failed", "detail": "\(error)"])
            return 1
        }
    }

    /// M1-DUR-029: in a new process, resolve the device-local read-write bookmark, start access, open the show,
    /// edit, Save (read-back verified), acknowledge to the library, stop access.
    func reopenSave() async -> Int32 {
        guard let showRaw = args["show"], let showUUID = UUID(uuidString: showRaw), let recovery else {
            emit(["error": "reopen-save needs --show --recovery"])
            return 2
        }
        let showID = ShowID(showUUID)
        let locations = ShowLocationStore(root: file)
        let title = args["title"] ?? "Reopened \(getpid())"
        var library: LibraryStore?
        if let settings = args.url("library-settings"), let container = args.url("container"), let cache = args.url("cache") {
            let store = LibraryStore(containerFolder: container, settings: FileLibrarySettings(url: settings), bookmarks: PathBookmarks(),
                                     recovery: recovery, indexCache: LibraryIndexCache(url: cache))
            _ = await store.load()
            library = store
        }
        let opener = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: recovery)
        let (outcome, saved) = await locations.withReopenedShow(showID, opener: opener) { url, document, fingerprint -> [String: Any] in
            let session = ShowSession(key: .show(showID), url: url, payload: document.payload, base: fingerprint,
                                      revision: document.revision, publisher: DocumentPublisher(coder: coder, recovery: recovery))
            _ = try? await session.edit { try $0.renamingShow(to: title) }
            switch await session.save() {
            case let .success(receipt):
                var ack = "none"
                if let library {
                    let result = await library.acknowledgeShowPublication(showID, title: title, publication: receipt.publication)
                    ack = if case .published? = result { "published" } else { "\(String(describing: result))" }
                }
                return ["result": "saved", "revision": receipt.revision, "publicationID": receipt.publication.publicationID.uuidString, "libraryAck": ack]
            case let .failure(error):
                return describe(error)
            }
        }
        let balance = locations.scopeBalance
        var object: [String: Any] = ["scopesStarted": balance.started, "scopesStopped": balance.stopped]
        switch outcome {
        case let .opened(_, _, _, refreshed): object["outcome"] = "opened"; object["refreshedStaleBookmark"] = refreshed
        case let .regrantRequired(reason): object["outcome"] = "regrantRequired"; object["reason"] = reason
        case let .relinkRequired(candidate, reason): object["outcome"] = "relinkRequired"; object["reason"] = reason; object["candidate"] = candidate?.path ?? ""
        case let .refused(open): object["outcome"] = "refused"; object["detail"] = "\(open)"
        case .noRecord: object["outcome"] = "noRecord"
        }
        if let saved { object.merge(saved) { $1 } }
        emit(object)
        return 0
    }
}

/// File-backed location setting for the probe (the app uses UserDefaults).
final class FileLibrarySettings: LibraryLocationSettingsStoring {
    let url: URL
    init(url: URL) { self.url = url }
    func load() -> LibraryLocationSetting {
        (try? JSONDecoder().decode(LibraryLocationSetting.self, from: Data(contentsOf: url))) ?? LibraryLocationSetting()
    }
    func save(_ setting: LibraryLocationSetting) throws {
        try JSONEncoder().encode(setting).write(to: url, options: .atomic)
    }
}

/// Path "bookmarks" for the unsandboxed probe (no security scope exists outside the sandbox).
struct PathBookmarks: FolderBookmarking {
    func bookmark(for folder: URL) throws -> Data { Data(folder.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true), false)
    }
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

extension Probe {
    func library() async -> Int32 {
        guard let container = args.url("container"), let recovery, let cache = args.url("cache") else {
            emit(["error": "library needs --container --recovery --cache"])
            return 2
        }
        let store = LibraryStore(containerFolder: container, settings: FileLibrarySettings(url: file), bookmarks: PathBookmarks(),
                                 recovery: recovery, indexCache: LibraryIndexCache(url: cache))
        var start = ContinuousClock.now
        let loaded = await store.load()
        var object: [String: Any] = ["load": "\(loaded)", "loadSeconds": seconds(.now - start)]
        if let count = Int(args["add"] ?? "") {
            start = .now
            let result = try? await store.update { library in
                var library = library
                for index in 0..<count {
                    library = LibraryReconciler.registering(ShowID(), title: "Synthetic Library Show \(index)", publication: nil, in: library)
                }
                library.collections.append(LibraryCollection(name: "Synthetic Collection \(library.collections.count + 1)",
                                                             showIDs: library.entries.prefix(3).map(\.showID)))
                return library
            }
            object["update"] = result.map { if case let .published(receipt) = $0 { "saved r\(receipt.revision)" } else { "\($0)" } } ?? "threw"
            object["updateSeconds"] = seconds(.now - start)
        }
        if let folder = args.url("move-to") {
            start = .now
            object["move"] = "\(await store.moveLibrary(to: folder))"
            object["moveSeconds"] = seconds(.now - start)
        }
        let library = await store.library
        object["entries"] = library?.entries.count ?? -1
        object["collections"] = library?.collections.count ?? -1
        object["location"] = "\(await store.locationStatus.title)"
        emit(object)
        return 0
    }
}

@main
struct ProbeMain {
    static func main() async {
        let args = Arguments(CommandLine.arguments)
        guard let file = args.url("file") else {
            emit(["error": "usage: wwpersist-probe <create|save|open|versions|autosave|kill-at> --file F ..."])
            exit(2)
        }
        let recovery = args.url("recovery").map { RecoveryStore(root: $0) }
        exit(await Probe(args: args, file: file, recovery: recovery).run())
    }
}
