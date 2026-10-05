import Foundation
import Testing
import WWCore
@testable import WWPersistence

private typealias ShowCoder = JSONEnvelopeCoder<ShowDocumentModel>
private typealias ShowSession = CanonicalDocumentSession<ShowCoder>

/// Corruption variants shared by M1-DUR-017 (show) and M1-DUR-023 (library).
enum Corruption: String, CaseIterable {
    case truncated, checksumMismatch, invalidJSON, schemaInvalid, empty, duplicateKey, wrongDocumentID

    /// Corrupts `bytes` (a valid envelope). `other` supplies a different valid document for `wrongDocumentID`.
    func apply(to bytes: Data, other: Data, _ rng: inout SeededGenerator) throws -> Data {
        switch self {
        case .truncated:
            return bytes.prefix(HoldoutGen.int(1...(bytes.count - 2), &rng))
        case .checksumMismatch:
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["checksum"] = "sha256:" + String(repeating: "0", count: 64)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        case .invalidJSON:
            var copy = bytes
            copy[HoldoutGen.int(0...(copy.count - 1), &rng)] = UInt8(ascii: "{")
            copy.append(contentsOf: Data("}}garbage".utf8))
            return copy
        case .schemaInvalid:
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["payload"] = ["unexpected": true]
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        case .empty:
            return Data()
        case .duplicateKey:
            // Insert a second "revision" key with a different value right after the opening brace.
            var text = String(decoding: bytes, as: UTF8.self)
            text.insert(contentsOf: "\"revision\":999999,", at: text.index(after: text.startIndex))
            return Data(text.utf8)
        case .wrongDocumentID:
            return other
        }
    }
}

@Suite("M1 durability holdout — open, refusal and recovery", .serialized, .enabled(if: Holdout.enabled, "WW_HOLDOUT=1"))
struct HoldoutOpenRecoveryTests {
    // MARK: DUR-016 migration from an older synthetic schema

    @Test func dur016Migration() async {
        let result = await runFamily("M1-DUR-016", calibration: 10, holdout: 100,
                                     notes: ["Synthetic schema 0 (not a shipped WaveWrangler format); expectations authored independently of the migration."]) { index, seed in
            let variant = ["plain", "cancelThenRetry", "faultThenRetry"][index % 3]
            let dir = TempDirectory("dur016")
            let rig = Rig(dir: dir)
            let url = rig.url("Legacy.wwshow")
            let original = try SyntheticV0.bytes(seed: seed % 1_000_000, revision: 1 + Int(seed % 20))
            try original.write(to: url)
            let key = DocumentKey(rawValue: "legacy-\(index)")
            switch variant {
            case "cancelThenRetry":
                #expect(throws: PublicationError.cancelled) { try DocumentMigrator(publisher: rig.publisher, steps: [SyntheticV0.step]).migrate(url, key: key, isCancelled: { true }) }
                try check(try Data(contentsOf: url) == original, "cancel changed the original")
            case "faultThenRetry":
                let boundary = (PublicationBoundary.migration + [.baseChecked, .stagedFlushed])[(index / 3) % 5]
                let faults = FaultState(boundary == .stagedFlushed ? .tornPublish(fraction: 0.5) : .crash(at: boundary))
                let faulty = Rig(ops: FaultInjectingFileOperations(faults: faults), hooks: FaultHooks(faults: faults), dir: dir)
                _ = try? DocumentMigrator(publisher: faulty.publisher, steps: [SyntheticV0.step]).migrate(url, key: key)
                try check(faults.fired, "fault did not fire")
                // After the fault: the original, or (torn publish) a damaged file with the backup intact.
                let current = try Data(contentsOf: url)
                if current != original {
                    let backups = try rig.recovery.migrationBackups(for: key).map { try Data(contentsOf: $0) }
                    try check(backups.contains(original), "torn publish without an intact backup")
                    try original.write(to: url)   // the user restores the preserved original from the backup
                }
            default: break
            }
            let receipt = try DocumentMigrator(publisher: rig.publisher, steps: [SyntheticV0.step]).migrate(url, key: key)
            try check(try Data(contentsOf: receipt.backup) == original, "backup differs from original bytes")
            try check(try rig.recovery.migrationBackups(for: key).count == 1, "backup not unique")
            guard case let .editable(document, _) = rig.opener.open(url) else { throw CaseFailure(description: "migrated document not editable") }
            let failures = SyntheticV0.step.expectations(original, document.payload)
            try check(failures.isEmpty, "expectations: \(failures)")
            return CaseResult(variant)
        }
        expectAllPassed(result)
    }

    // MARK: DUR-017 corrupt show document

    @Test func dur017CorruptShow() async {
        let result = await runFamily("M1-DUR-017", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variant = Corruption.allCases[index % Corruption.allCases.count]
            let rig = Rig(label: "dur017")
            let model = HoldoutGen.show(&rng)
            let key = DocumentKey.show(model.show.id)
            let url = rig.url()
            let first = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
            let r2 = try model.renamingShow(to: model.show.title + " r2")
            _ = try rig.publisher.publish(r2, revision: 2, key: key, to: url, target: .inPlace(expectedBase: first.fingerprint))
            let other = try ShowCoder.show.encode(HoldoutGen.show(&rng), revision: 2)
            let corrupt = try variant.apply(to: try Data(contentsOf: url), other: other, &rng)
            try corrupt.write(to: url)
            let opener = DocumentOpener<ShowCoder>.show(recovery: rig.recovery)
            guard case let .damaged(error, candidates) = opener.open(url, key: key) else { throw CaseFailure(description: "\(variant) not refused") }
            let reason = "\(error)".prefix { $0 != "(" }
            let first1 = try #require(candidates.first, "no validated checkpoint offered")
            try check(first1.document.payload == model && first1.document.revision == 1, "offered checkpoint")
            // Offered as a new copy; the suspect file is untouched; never recreated from an index.
            let session = ShowSession.recovered(first1, originalURL: url, publisher: rig.publisher)
            let copy = rig.url("Recovered.wwshow")
            guard case .success = await session.duplicate(to: copy) else { throw CaseFailure(description: "recover as copy failed") }
            try check(try Data(contentsOf: url) == corrupt, "suspect file changed")
            try check(decodeShow(copy)?.payload == model, "recovered copy")
            return CaseResult("\(variant.rawValue):\(reason)")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-018 unknown-newer show document

    @Test func dur018UnknownNewerShow() async {
        let result = await runFamily("M1-DUR-018", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let rig = Rig(label: "dur018")
            let model = HoldoutGen.show(&rng)
            let key = DocumentKey.show(model.show.id)
            let url = rig.url()
            _ = try rig.publisher.publish(model, revision: 1, key: key, to: url, target: .newLocation)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["schemaVersion"] = SchemaVersion.show + HoldoutGen.int(1...5, &rng)
            let variant = index % 2 == 0 ? "validPayload" : "partiallyUnknownPayload"
            if variant == "partiallyUnknownPayload" {
                var payload = try #require(object["payload"] as? [String: Any])
                payload["fromTheFuture"] = ["field": index]
                object["payload"] = payload
                object["futureEnvelopeField"] = true
            }
            let newer = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try newer.write(to: url)
            guard case let .refusedNewerFormat(found, supported, _) = rig.opener.open(url, key: key) else { throw CaseFailure(description: "not refused") }
            let session = ShowSession.refusingNewerFormat(key: key, url: url, payload: model, found: found, supported: supported, publisher: rig.publisher)
            var refusals = 0
            if await session.edit({ $0 }) == false { refusals += 1 }
            if case .failure(.readOnly) = await session.save() { refusals += 1 }
            if case .failure(.readOnly) = await session.save(automatic: true) { refusals += 1 }
            if case .failure(.readOnly) = await session.saveAs(rig.url("Downsave.wwshow")) { refusals += 1 }
            if case .failure(.readOnly) = await session.duplicate(to: rig.url("Copy.wwshow")) { refusals += 1 }
            if (try? DocumentMigrator(publisher: rig.publisher, steps: [SyntheticV0.step]).migrate(url, key: key)) == nil { refusals += 1 }
            try check(refusals == 6, "refused \(refusals)/6")
            try check(try Data(contentsOf: url) == newer, "bytes changed")
            try check(!FileManager.default.fileExists(atPath: rig.url("Downsave.wwshow").path) && !FileManager.default.fileExists(atPath: rig.url("Copy.wwshow").path), "down-save written")
            return CaseResult("\(variant):6/6 refused")
        }
        expectAllPassed(result)
    }

    // MARK: DUR-020 derived index deletion and rebuild

    @Test func dur020IndexDeleteRebuild() async {
        let result = await runFamily("M1-DUR-020", calibration: 10, holdout: 100) { index, seed in
            var rng = SeededGenerator(seed: seed)
            let variant = ["delete", "corrupt", "replaceWithOtherLibrary", "stale"][index % 4]
            let rig = LibraryRig("dur020")
            let store = rig.store()
            _ = await store.load()
            let shows = HoldoutGen.shows(2...30, &rng)
            _ = try await store.update { var model = HoldoutGen.library(shows, &rng); model.libraryID = $0.libraryID; return model }
            let canonical = try Data(contentsOf: rig.containerFile)
            let library = try #require(await store.library)
            switch variant {
            case "delete": LibraryIndexCache(url: rig.cacheURL).invalidate()
            case "corrupt": try Data("{not an index".utf8).write(to: rig.cacheURL)
            case "replaceWithOtherLibrary":
                var otherRng = SeededGenerator(seed: seed &+ 1)
                let other = HoldoutGen.library(HoldoutGen.shows(2...5, &otherRng), &otherRng)
                // Another library's own index (built from that library's bytes).
                let otherBytes = try LibraryCoder.library.encode(other, revision: 1)
                try LibraryIndexCache(url: rig.cacheURL).store(LibraryIndex.build(from: other, libraryDigest: RevisionFingerprint.digest(otherBytes)))
            default:
                try LibraryIndexCache(url: rig.cacheURL).store(LibraryIndex.build(from: library, libraryDigest: "stale"))
            }
            let reopened = rig.store()
            _ = await reopened.load()
            let rebuilt = try #require(await reopened.index)
            let expected = LibraryIndex.build(from: library, libraryDigest: RevisionFingerprint.digest(canonical))
            try check(rebuilt == expected, "rebuilt index differs from the expected derived value")
            try check(try Data(contentsOf: rig.containerFile) == canonical, "canonical library changed")
            let loaded = try #require(await reopened.library)
            try check(loaded == library, "semantic loss")
            for collection in library.collections { try check(rebuilt.showsByCollection[collection.id] == collection.showIDs, "collection order") }
            try check(Set(rebuilt.shows.filter(\.isUnavailable).map(\.showID)) == Set(library.entries.filter { $0.unavailable != nil }.map(\.showID)), "unavailable entries")
            return CaseResult(variant)
        }
        expectAllPassed(result)
    }
}
