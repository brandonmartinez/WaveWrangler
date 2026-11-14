import Foundation
import WWCore
import WWPersistence

// Explicit opt-in only:
// package-trial --file NEW_DIRECTORY --recovery LOCAL_DIRECTORY
// package-convert --file LEGACY_SHOW --destination NEW_LOCAL_DIRECTORY
extension Probe {
    private func providerState(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .isPackageKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey])
        return [
            "isUbiquitousItem": values.isUbiquitousItem as Any? ?? NSNull(),
            "isPackage": values.isPackage as Any? ?? NSNull(),
            "isUploaded": values.ubiquitousItemIsUploaded as Any? ?? NSNull(),
            "downloadingStatus": values.ubiquitousItemDownloadingStatus?.rawValue as Any? ?? NSNull(),
            "hasUnresolvedConflicts": values.ubiquitousItemHasUnresolvedConflicts as Any? ?? NSNull(),
        ]
    }

    private struct StoredFile {
        let bytes: Data
        let inode: UInt64
    }

    private func storedFiles(_ url: URL) throws -> [String: StoredFile] {
        var files: [String: StoredFile] = [:]
        let manifest = url.appending(path: ShowPackage.manifestName)
        let children = try FileManager.default.contentsOfDirectory(at: url.appending(path: ShowPackage.componentsName),
            includingPropertiesForKeys: nil)
        for child in [manifest] + children {
            let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
            guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
                throw CocoaError(.fileReadUnknown)
            }
            files[child.lastPathComponent] = StoredFile(bytes: try Data(contentsOf: child), inode: inode)
        }
        return files
    }

    func syntheticPackageShow(episodes: Int = 8, wordsPerGeneration: Int = 2_000,
        artwork: Data? = nil) throws -> ShowDocumentModel {
        var model = ShowDocumentModel.untitled(title: "Synthetic package trial")
        for index in 0..<episodes {
            let source = SourceRecord(displayNameHint: "generated-placeholder-\(index).wav")
            var words: [TranscriptWord] = []
            for position in 0..<wordsPerGeneration {
                let start = Double(position) / 10
                words.append(TranscriptWord(text: position.isMultiple(of: 7) ? "um" : "generated",
                    sourceStartFrame: Int64(position * 4_800), sourceEndFrame: Int64(position * 4_800 + 4_000),
                    alignedStart: start, alignedEnd: start + 0.08))
            }
            let current = SpeakerTranscript(speaker: SpeakerID(), primary: .init(sourceID: source.id, statedChannel: 0),
                sourceRate: 48_000, sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
                model: "synthetic-only", workingRange: nil, words: words)
            var previous = current
            previous.id = UUID()
            previous.words = words.map { word in var result = word; result.id = UUID(); return result }
            var cleanup = EpisodeCleanup(transcripts: [previous]).proposingFillers()
            if var review = cleanup.fillerReviews?.first {
                review.decision = .rejected
                cleanup.fillerReviews = [review]
            }
            cleanup.transcriptHistory = [previous]
            cleanup.transcripts = [current]
            var episode = Episode(title: "Synthetic episode \(index + 1)", sources: [source])
            episode.cleanup = cleanup
            model = try model.addingEpisode(episode)
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        model.show.publication = .init(artwork: .image(try PublicationArtwork(data: artwork ?? png)))
        return model
    }

    func packageTrial() -> Int32 {
        do {
            let ops = LocalFileOperations()
            guard !ops.exists(file) else { throw CocoaError(.fileWriteFileExists) }
            guard let recovery else { throw PersistenceError.malformed("A local recovery directory is required") }
            let parentState = try providerState(file.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let url = file.appending(path: "Synthetic.wwshow")
            let coder = ShowPackageCoder()
            let publisher = DocumentPublisher(coder: coder, recovery: recovery)
            let model = try syntheticPackageShow()
            let legacy = try JSONEnvelopeCoder<ShowDocumentModel>.show.encode(model, revision: 1)
            let start = ContinuousClock.now
            let first = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            let createSeconds = seconds(.now - start)
            guard try coder.decode(ops.read(url)).payload == model else { throw PersistenceError.checksumMismatch }
            let before = try storedFiles(url)
            let originalWrapper = try FileWrapper(url: url, options: [.immediate])
            let changed = try model.renamingShow(to: "Synthetic catalog-only edit")
            let edit = try coder.encodeDocument(changed, revision: 2, publicationID: UUID())
            let wrapper = try ShowPackage.fileWrapper(for: edit.data, reusing: originalWrapper)
            let oldComponents = originalWrapper.fileWrappers?[ShowPackage.componentsName]?.fileWrappers ?? [:]
            let newComponents = wrapper.fileWrappers?[ShowPackage.componentsName]?.fileWrappers ?? [:]
            let shared = Set(oldComponents.keys).intersection(newComponents.keys)
            let reusedCount = shared.filter { oldComponents[$0] === newComponents[$0] }.count
            let saveStart = ContinuousClock.now
            _ = try publisher.publish(encoded: edit, key: .show(model.show.id), to: url,
                target: .inPlace(expectedBase: first.fingerprint), retainPrior: true, isCanceled: { false },
                step: .external { destination, _ in
                    try wrapper.write(to: destination, options: [.atomic], originalContentsURL: destination)
                }, followUp: .none)
            let saveSeconds = seconds(.now - saveStart)
            guard try coder.decode(ops.read(url)).payload == changed else { throw PersistenceError.checksumMismatch }
            let after = try storedFiles(url)
            let unchanged = Set(before.keys).intersection(after.keys).filter { before[$0]?.bytes == after[$0]?.bytes }
            let retainedInodes = unchanged.filter { before[$0]?.inode == after[$0]?.inode }.count
            emit([
                "result": "packageLocalRoundTripVerified", "legacyBytes": legacy.count,
                "packageBytes": before.values.reduce(0) { $0 + $1.bytes.count },
                "storedFiles": before.count, "unchangedFiles": unchanged.count,
                "reusedComponentWrappers": reusedCount, "unchangedFilesRetainingInodes": retainedInodes,
                "newOrChangedBytes": after.filter { before[$0.key]?.bytes != $0.value.bytes }.values.reduce(0) { $0 + $1.bytes.count },
                "createSeconds": createSeconds, "catalogSaveSeconds": saveSeconds,
                "testRootProviderState": parentState, "packageProviderState": try providerState(url),
                "remoteRecoveryVerified": false, "crossDeviceVerified": false,
                "transferEfficiencyVerified": false, "distributedConflictsVerified": false,
            ])
            return 0
        } catch {
            emit(["result": "packageTrialFailed", "detail": "\(error)"])
            return 1
        }
    }

    /// Copies authorized legacy document content only. Never resolves or opens its referenced sources.
    func packageConvert() -> Int32 {
        do {
            let ops = LocalFileOperations()
            guard let destination = args.url("destination"), !ops.exists(destination) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let original = try NSFileCoordination().coordinateReading(at: file) { try ops.read($0) }
            guard !ShowPackage.isSnapshot(original) else { throw PersistenceError.malformed("Expected a legacy show") }
            let expected = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(original)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let copy = destination.appending(path: "Converted.wwshow")
            try ops.writeNew(original, to: copy)
            let recovery = RecoveryStore(root: destination.appending(path: "Recovery"))
            let coder = ShowPackageCoder()
            let publisher = DocumentPublisher(coder: coder, recovery: recovery)
            let receipt = try DocumentMigrator.show(publisher: publisher).migrate(copy,
                key: .show(expected.payload.show.id), expectedOriginal: original)
            guard try ops.read(receipt.backup) == original,
                  try NSFileCoordination().coordinateReading(at: file, { try ops.read($0) }) == original else {
                throw PersistenceError.checksumMismatch
            }
            let decoded = try coder.decode(ops.read(copy))
            guard decoded.payload == expected.payload else { throw PersistenceError.checksumMismatch }
            // Independent JSON-tree comparison includes every identity, historical word and human judgment.
            let legacyTree = try JSONSerialization.jsonObject(with: original) as? NSDictionary
            let encoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.encode(decoded.payload, revision: decoded.revision)
            let newTree = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            guard let legacyPayload = legacyTree?["payload"] as? NSDictionary,
                  let newPayload = newTree?["payload"] as? NSDictionary,
                  legacyPayload == newPayload else {
                throw PersistenceError.malformed("Independent payload comparison failed")
            }
            let files = try storedFiles(copy)
            emit(["result": "localCopyConversionVerified", "legacyBytes": original.count,
                "packageBytes": files.values.reduce(0) { $0 + $1.bytes.count }, "storedFiles": files.count,
                "originalUnchanged": true, "exactBackupVerified": true, "independentPayloadMatch": true])
            return 0
        } catch {
            emit(["result": "packageConversionFailed", "detail": "\(error)"])
            return 1
        }
    }
}
