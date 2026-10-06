import CryptoKit
import Foundation
import WWCore
import WWPersistence
import WWSources

// M1-DUR-025 (m1-freeze-2) cross-machine relink and recovery commands (headless; synthetic files only).
//
//   src-make    --file DIR --count N --seed S             (random-byte source files; prints paths + sha256)
//   src-record  --file RECORDS --show UUID --source UUID --source-file PATH   (device access record, as at import)
//   src-eval    --file RECORDS --show UUID --source UUID  (metadata-only availability from this Mac's record)
//   src-relink  --file RECORDS --show UUID --source UUID --source-file PATH --confirm 0|1   (explicit choice)
//   digest      --file F
//   hold-save   --file F --title T --recovery DIR --ready R --go G   (edit + C2b checkpoint, wait, then save)
//   checkpoint  --file F --title T --recovery DIR         (edit + C2b checkpoint, then quit without saving)
//   offer       --file F --recovery DIR                    (relaunch: the C2b offer for this show)

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

extension Probe {
    var sourceContext: SourceAccessContext { SourceAccessContext() }

    func sourceKey() -> DeviceAccessKey? {
        guard let show = args["show"].flatMap(UUID.init(uuidString:)), let source = args["source"].flatMap(UUID.init(uuidString:)) else { return nil }
        return DeviceAccessKey(showID: ShowID(show), sourceID: SourceID(source))
    }

    /// The app's own device-access store (WWSources `FileDeviceAccessStore`), so records round-trip exactly as
    /// in the app (full-precision dates). `--file` is the store's folder.
    var accessStore: FileDeviceAccessStore { FileDeviceAccessStore(fileURL: file.appending(path: "source-access-records.json")) }

    func loadRecord(_ key: DeviceAccessKey) async -> DeviceAccessRecord? {
        try? await accessStore.record(for: key)
    }

    func saveRecord(_ record: DeviceAccessRecord) async throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try await accessStore.save(record)
    }

    func comparisonText(_ comparison: IdentityComparison) -> String {
        switch comparison {
        case .matches: "matches"
        case let .differs(fields, unknown): "differs(\(fields.map(\.rawValue).joined(separator: ",")); unknown \(unknown.count))"
        case let .unknown(fields): "unknown(\(fields.count) fields)"
        }
    }

    func sourceMake() -> Int32 {
        let count = Int(args["count"] ?? "3") ?? 3
        var seed = UInt64(args["seed"] ?? "1") ?? 1
        do {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            var files: [[String: Any]] = []
            for index in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let size = 4096 + Int(seed % 61440)
                var state = seed
                var generated = [UInt8](repeating: 0, count: size)
                for i in 0..<size {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    generated[i] = UInt8(truncatingIfNeeded: state >> 33)
                }
                let bytes = Data(generated)
                let url = file.appending(path: "source-\(index).wav")
                try bytes.write(to: url, options: .atomic)
                files.append(["path": url.path, "sha256": sha256Hex(bytes), "bytes": size])
            }
            emit(["result": "made", "files": files])
            return 0
        } catch {
            emit(["result": "error", "detail": "\(error)"])
            return 1
        }
    }

    func sourceRecord() async -> Int32 {
        guard let key = sourceKey(), let candidate = args.url("source-file") else { emit(["error": "src-record needs --show --source --source-file"]); return 2 }
        let evaluator = RelinkEvaluator(context: sourceContext)
        let proposal = evaluator.evaluate(candidate: candidate, for: key, record: nil)
        do {
            // Initial import on this Mac: the user chose the file, so it is the confirmed baseline.
            let record = try evaluator.apply(proposal, to: nil, userConfirmed: true)
            try await saveRecord(record)
            emit(["result": "recorded", "comparison": comparisonText(proposal.comparison)])
            return 0
        } catch {
            emit(["result": "error", "detail": "\(error)"])
            return 1
        }
    }

    func sourceEvaluate() async -> Int32 {
        guard let key = sourceKey() else { emit(["error": "src-eval needs --show --source"]); return 2 }
        let record = await loadRecord(key)
        let evaluation = SourceAvailabilityEvaluator(context: sourceContext).evaluate(key: key, record: record, setting: .off)
        let observation = evaluation.observation
        emit(["hasRecord": record != nil, "location": "\(observation.location)", "access": observation.access.rawValue,
              "identity": "\(observation.identity)", "resolvedPath": evaluation.resolvedURL?.path ?? "",
              "host": hostLabel()])
        return 0
    }

    func sourceRelink() async -> Int32 {
        guard let key = sourceKey(), let candidate = args.url("source-file") else { emit(["error": "src-relink needs --show --source --source-file"]); return 2 }
        let evaluator = RelinkEvaluator(context: sourceContext)
        let record = await loadRecord(key)
        let proposal = evaluator.evaluate(candidate: candidate, for: key, record: record)
        var object: [String: Any] = ["hasRecord": record != nil, "comparison": comparisonText(proposal.comparison),
                                     "requiresConfirmation": proposal.requiresConfirmation, "canApply": proposal.canApply, "host": hostLabel()]
        do {
            let updated = try evaluator.apply(proposal, to: record, userConfirmed: args["confirm"] == "1")
            try await saveRecord(updated)
            object["result"] = "applied"
        } catch let error as RelinkError {
            object["result"] = "\(error)"
        } catch {
            object["result"] = "error \(error)"
        }
        emit(object)
        return 0
    }

    func digest() -> Int32 {
        guard let data = try? Data(contentsOf: file) else { emit(["result": "unreadable"]); return 1 }
        emit(["result": "ok", "sha256": sha256Hex(data), "bytes": data.count])
        return 0
    }

    /// B holds an unpublished edit (with its C2b edit checkpoint) while the other Mac publishes; then saves.
    func holdSave() async -> Int32 {
        guard let session = openSession(), let ready = args.url("ready"), let go = args.url("go") else { return 2 }
        let openedEpochMs = epochMs()
        let title = args["title"] ?? "Held \(getpid())"
        do { try await session.edit { try $0.renamingShow(to: title) } } catch { emit(["result": "error", "detail": "edit failed"]); return 3 }
        let editedEpochMs = epochMs()
        let checkpointed = await session.writeEditCheckpoint()
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        guard waitFor(go, timeout: 900) else { emit(["result": "timeout"]); return 1 }
        var object: [String: Any] = ["checkpointWritten": checkpointed, "title": title, "host": hostLabel(),
                                     "openedEpochMs": openedEpochMs, "editedEpochMs": editedEpochMs, "goEpochMs": epochMs()]
        switch await session.save() {
        case let .success(receipt):
            object.merge(["result": "saved", "revision": receipt.revision, "publicationID": receipt.publication.publicationID.uuidString]) { $1 }
        case let .failure(error):
            object.merge(describe(error)) { $1 }
        }
        object["status"] = "\(await session.status.state)"
        let key = await session.key
        object["editCheckpointsKept"] = recovery?.editCheckpoints(for: key).count ?? 0
        emit(object)
        return 0
    }

    /// An unpublished edit with its C2b checkpoint, then quit without saving.
    func checkpoint() async -> Int32 {
        guard let session = openSession() else { return 2 }
        let title = args["title"] ?? "Unsaved \(getpid())"
        do { try await session.edit { try $0.renamingShow(to: title) } } catch { emit(["result": "error", "detail": "edit failed"]); return 3 }
        let editedEpochMs = epochMs()
        let written = await session.writeEditCheckpoint()
        emit(["result": written ? "checkpointed" : "notCheckpointed", "title": title, "status": "\(await session.status.state)", "host": hostLabel(),
              "editedEpochMs": editedEpochMs])
        return 0
    }

    /// Relaunch: what the show window offers for this show's C2b records (set aside first, as ShowDocument does).
    func offer() -> Int32 {
        guard let recovery else { emit(["error": "offer needs --recovery"]); return 2 }
        guard case let .editable(document, fingerprint) = opener.open(file) else { emit(["result": "notEditable"].merging(describe(opener.open(file))) { $1 }); return 1 }
        let key = DocumentKey.show(document.payload.show.id)
        try? recovery.setAsideEditCheckpoints(for: key)
        let showID = document.payload.show.id
        let offer = EditCheckpointOffer.assess(recovery.offeredEditCheckpoints(for: key), documentID: key.rawValue, onDisk: fingerprint,
                                               coder: coder, belongsToDocument: { $0.show.id == showID })
        emit(["result": "assessed", "currentTitle": document.payload.show.title, "currentRevision": document.revision,
              "candidateTitle": offer.candidate?.payload.show.title ?? "", "relation": offer.candidate.map { "\($0.relation)" } ?? "none",
              "mode": offer.candidateMode(restoreInEffect: false).map { "\($0)" } ?? "none",
              "usable": offer.usable.count, "problems": offer.problems.count, "host": hostLabel()])
        return 0
    }
}
