import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Show document packages", .serialized)
struct ShowPackageTests {
    let coder = ShowPackageCoder()
    let ops = LocalFileOperations()

    static func richShow() throws -> ShowDocumentModel {
        let fixture = AlignmentPersistenceFixture()
        var model = fixture.show(with: .init(maps: [try fixture.version(1, map: fixture.map())], acceptedRevision: 1))
        let speaker = SpeakerID()
        var words: [TranscriptWord] = []
        for index in 0..<2_000 {
            let start = Double(index) / 100
            let word = TranscriptWord(text: index.isMultiple(of: 3) ? "um" : "synthetic",
                sourceStartFrame: Int64(index * 480), sourceEndFrame: Int64(index * 480 + 400),
                alignedStart: start, alignedEnd: start + 0.008)
            words.append(word)
        }
        let current = SpeakerTranscript(speaker: speaker, primary: .init(sourceID: fixture.host, statedChannel: 0),
            sourceRate: 48_000, sourceIdentity: String(repeating: "a", count: 64), alignmentRevision: 1,
            model: "synthetic", workingRange: nil, words: words)
        var old = current
        old.id = UUID()
        old.words = words.map { word in var result = word; result.id = UUID(); return result }
        var cleanup = EpisodeCleanup(transcripts: [old]).proposingFillers()
        if var review = cleanup.fillerReviews?.first {
            review.decision = .rejected
            cleanup.fillerReviews = [review]
        }
        cleanup.transcriptHistory = [old]
        cleanup.transcripts = [current]
        model.episodes[0].cleanup = cleanup
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        model.show.publication = .init(creator: "Synthetic artist", artwork: .image(try PublicationArtwork(data: png)))
        model.episodes.append(Episode(title: "Another episode"))
        return model
    }

    @Test func roundTripPreservesAllHistoricalIdentitiesJudgmentsAndBinaryArtwork() throws {
        let model = try Self.richShow()
        let uncompressed = try JSONEnvelopeCoder<ShowDocumentModel>.canonicalBytes(of: model)
        let encoded = try coder.encode(model, revision: 17)
        let decoded = try coder.decode(encoded)
        let payloadMatches = decoded.payload == model
        #expect(payloadMatches)
        #expect(encoded.count < uncompressed.count / 2)
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Synthetic.wwshow")
        try ops.writeNew(encoded, to: url)
        #expect(try ops.read(url) == encoded)
        let uppercase = directory.url.appending(path: "Uppercase.WWSHOW")
        try ops.writeNew(encoded, to: uppercase)
        #expect(try uppercase.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try ops.read(uppercase) == encoded)
        let files = try FileManager.default.contentsOfDirectory(at: url.appending(path: ShowPackage.componentsName),
            includingPropertiesForKeys: nil)
        let artwork = try #require(model.show.publication?.artwork?.image?.data)
        #expect(try files.contains { try Data(contentsOf: $0) == artwork })
        let stamp = RevisionFingerprint(of: encoded)
        #expect(stamp.schemaVersion == SchemaVersion.show)
        #expect(stamp.revision == 17)
    }

    @Test func versionOneChecksumMatchesIndependentCanonicalPayloadEncoding() throws {
        var models = [ShowDocumentModel.untitled(), try Self.richShow()]
        models[0].show.notes = "Escapes: \" \\ \n and non-ASCII: caf\u{e9}"
        for model in models {
            let id = UUID()
            let checksum = JSONEnvelopeCoder<ShowDocumentModel>.checksum(of:
                try JSONEnvelopeCoder<ShowDocumentModel>.canonicalBytes(of: model))
            let package = try coder.encodeDocument(model, revision: 3, publicationID: id)
            #expect(package.publication.checksum == checksum)
            let decoded = try coder.decode(package.data)
            let matches = decoded.payload == model
            #expect(matches)
        }
    }

    @Test func metadataAndSingleEpisodeEditsReuseUnchangedComponentWrappers() throws {
        let model = try Self.richShow()
        let first = try ShowPackage.fileWrapper(for: coder.encode(model, revision: 1))
        let edited = try model.renamingShow(to: "Changed catalog only")
        let second = try ShowPackage.fileWrapper(for: coder.encode(edited, revision: 2), reusing: first)
        let old = try #require(first.fileWrappers?[ShowPackage.componentsName]?.fileWrappers)
        let next = try #require(second.fileWrappers?[ShowPackage.componentsName]?.fileWrappers)
        let shared = Set(old.keys).intersection(next.keys)
        #expect(shared.count == old.count - 1)
        #expect(shared.allSatisfy { old[$0] === next[$0] })
        var episodeEdit = edited
        episodeEdit.episodes[1].title = "Changed one episode"
        let third = try ShowPackage.fileWrapper(for: coder.encode(episodeEdit, revision: 3), reusing: second)
        let final = try #require(third.fileWrappers?[ShowPackage.componentsName]?.fileWrappers)
        #expect(Set(next.keys).symmetricDifference(final.keys).count == 2)
        #expect(Set(next.keys).intersection(final.keys).allSatisfy { next[$0] === final[$0] })
    }

    @Test func exactStoredBytesNotJustSemanticModelGuardAgainstConflicts() throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Synthetic.wwshow")
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        let publisher = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        let model = Fixtures.show(seed: 6)
        let first = try publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        let manifest = url.appending(path: ShowPackage.manifestName)
        try (Data(contentsOf: manifest) + Data("\n".utf8)).write(to: manifest)
        let changed = try ops.read(url)
        let semanticallyUnchanged = try coder.decode(changed).payload == model
        #expect(semanticallyUnchanged)
        #expect(RevisionFingerprint(of: changed).byteDigest != first.fingerprint.byteDigest)
        #expect(throws: PublicationError.self) {
            try publisher.publish(model, revision: 2, key: .show(model.show.id), to: url,
                target: .inPlace(expectedBase: first.fingerprint))
        }
        #expect(try ops.read(url) == changed)
        #expect(try recovery.conflictCandidates(for: .show(model.show.id)).count == 1)
    }

    @Test func storageOnlyMigrationPreservesPayloadAndRefusesChangedOpenedBase() throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Synthetic.wwshow")
        let model = try Self.richShow()
        let original = try coder.encode(model, revision: 12)
        try ops.writeNew(original, to: url)
        let cachedType = try url.resourceValues(forKeys: [.isDirectoryKey])
        #expect(cachedType.isDirectory == true)
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        let publisher = DocumentPublisher(coder: ShowCatalogCoder(), coordination: AlreadyCoordinated(), recovery: recovery)
        let migrator = DocumentMigrator.show(publisher: publisher)
        #expect(throws: PublicationError.self) {
            try migrator.migrate(url, key: .show(model.show.id), expectedOriginal: original + Data("\n".utf8))
        }
        #expect(try recovery.migrationBackups(for: .show(model.show.id)).isEmpty)
        let receipt = try migrator.migrate(url, key: .show(model.show.id), expectedOriginal: original)
        #expect(try Data(contentsOf: receipt.backup) == original)
        let migratedMatches = try coder.decode(ops.read(url)).payload == model
        #expect(migratedMatches)
        #expect(receipt.publication.revision == 13)
    }

    @Test(arguments: [1, 2])
    func unknownNewerPackageOrModelRefusesBeforePayloadOrRecovery(_ kind: Int) throws {
        let directory = TempDirectory()
        let url = directory.sub("Newer.wwshow")
        let packageVersion = kind == 1 ? ShowPackage.version + 1 : 1
        let modelVersion = kind == 2 ? SchemaVersion.show + 1 : SchemaVersion.show
        let manifest = Data("""
        {"format":"com.brandonmartinez.wavewrangler.show-package","schemaVersion":\(packageVersion),"modelSchemaVersion":\(modelVersion),"futurePayload":"not this version's shape"}
        """.utf8)
        try manifest.write(to: url.appending(path: ShowPackage.manifestName))
        // Components intentionally does not exist: refusal must not try to read it.
        let opener = DocumentOpener(coder: coder, coordination: AlreadyCoordinated(), recovery: nil)
        guard case let .refusedNewerFormat(found, supported, _) = opener.open(url) else {
            Issue.record("Expected an unknown-newer refusal, not recovery")
            return
        }
        #expect(found == (kind == 1 ? ShowPackage.version + 1 : SchemaVersion.show + 1))
        #expect(supported == (kind == 1 ? ShowPackage.version : SchemaVersion.show))
        #expect(try Data(contentsOf: url.appending(path: ShowPackage.manifestName)) == manifest)
    }

    @Test(arguments: ["corrupt", "missing", "extra", "symlink", "oversized"])
    func damagedComponentsAreNeverOpenedAsCompleteDocuments(_ damage: String) throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Synthetic.wwshow")
        try ops.writeNew(coder.encode(try Self.richShow(), revision: 1), to: url)
        let components = url.appending(path: ShowPackage.componentsName)
        let file = try #require(FileManager.default.contentsOfDirectory(at: components, includingPropertiesForKeys: nil).first)
        switch damage {
        case "corrupt": try Data("bad".utf8).write(to: file)
        case "missing": try FileManager.default.removeItem(at: file)
        case "extra": try Data("unknown".utf8).write(to: url.appending(path: "Unknown"))
        case "symlink":
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: url.appending(path: ShowPackage.manifestName))
        default:
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 64 * 1_024 * 1_024 + 1)
            try handle.close()
        }
        #expect(throws: (any Error).self) { try coder.decode(ops.read(url)) }
    }

    @Test(arguments: PublicationBoundary.show.filter { $0 != .libraryAcknowledged })
    func publicationInterruptionsLeaveOnlyWholeOldOrNewPackages(_ boundary: PublicationBoundary) throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Synthetic.wwshow")
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        let model = Fixtures.show(seed: 3)
        let clean = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery)
        let first = try clean.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
        let changed = try model.renamingShow(to: "Changed")
        struct Stop: PublicationHooks {
            let boundary: PublicationBoundary
            func reached(_ point: PublicationBoundary) throws {
                if boundary == point { throw SimulatedCrash(boundary: point, detail: "Package boundary") }
            }
        }
        let faulty = DocumentPublisher(coder: coder, coordination: AlreadyCoordinated(), recovery: recovery, hooks: Stop(boundary: boundary))
        #expect(throws: SimulatedCrash.self) {
            try faulty.publish(changed, revision: 2, key: .show(model.show.id), to: url,
                target: .inPlace(expectedBase: first.fingerprint))
        }
        let reopened = try coder.decode(ops.read(url))
        let isWholeExpectedModel = reopened.payload == (boundary == .published || boundary == .readBackVerified ? changed : model)
        #expect(isWholeExpectedModel)
        let checkpoints = try recovery.validatedCheckpoints(for: .show(model.show.id), coder: coder)
        if boundary != .candidateValidated { #expect(checkpoints.contains { $0.document.payload == model }) }
    }

    @Test(arguments: ["empty-compressed", "zero-expanded", "unknown-encoding", "length", "unknown-field"])
    func malformedComponentDescriptorsRefuseWithoutCrashing(_ damage: String) throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Synthetic.wwshow")
        try ops.writeNew(coder.encode(Fixtures.show(seed: 6), revision: 1), to: url)
        let manifestURL = url.appending(path: ShowPackage.manifestName)
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var reference = try #require(manifest["catalog"] as? [String: Any])
        switch damage {
        case "empty-compressed":
            let components = url.appending(path: ShowPackage.componentsName)
            let original = try #require(reference["digest"] as? String)
            try FileManager.default.removeItem(at: components.appending(path: original))
            let digest = RevisionFingerprint.digest(Data())
            try Data().write(to: components.appending(path: digest))
            reference["digest"] = digest
            reference["encoding"] = "lzfse"
            reference["byteCount"] = 1
        case "zero-expanded":
            reference["encoding"] = "lzfse"
            reference["byteCount"] = 0
        case "unknown-encoding": reference["encoding"] = "future-compressor"
        case "length": reference["byteCount"] = 1
        default: reference["futureMeaning"] = true
        }
        manifest["catalog"] = reference
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        #expect(throws: PersistenceError.self) { try coder.decode(ops.read(url)) }
    }

    @Test func canceledUpgradeLeavesOriginalAndExactBackup() throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "VersionOne.wwshow")
        let model = Fixtures.show(seed: 6)
        let original = try coder.encode(model, revision: 1)
        try ops.writeNew(original, to: url)
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        let publisher = DocumentPublisher(coder: ShowCatalogCoder(), coordination: AlreadyCoordinated(), recovery: recovery)
        #expect(throws: PublicationError.canceled) {
            try DocumentMigrator.show(publisher: publisher).migrate(url,
                key: .show(model.show.id), expectedOriginal: original, isCanceled: { true })
        }
        #expect(try ops.read(url) == original)
        let backups = try recovery.migrationBackups(for: .show(model.show.id))
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    @Test func tooManyEpisodesAreRefusedByEncoderBeforePublication() throws {
        var model = Fixtures.show(seed: 6)
        model.episodes = (0...10_000).map { Episode(title: "Synthetic episode \($0)") }
        var refused = false
        do { _ = try coder.encode(model, revision: 1) }
        catch PersistenceError.encodingFailed { refused = true }
        #expect(refused)
    }

    @Test func packageEditCheckpointIsDeviceLocalAndWholeModelReadable() throws {
        let directory = TempDirectory()
        let model = Fixtures.show(seed: 6)
        let key = DocumentKey.show(model.show.id)
        let base = try coder.encode(model, revision: 1)
        let edited = try model.renamingShow(to: "Unsaved package edit")
        let snapshot = try coder.encode(edited, revision: 2)
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        let record = try recovery.writeEditCheckpoint(snapshot: snapshot, base: RevisionFingerprint(of: base),
            schemaVersion: SchemaVersion.show, for: key)
        let bytes = record.snapshot
        #expect(ShowPackage.isSnapshot(bytes))
        let matches = try coder.decode(bytes).payload == edited
        #expect(matches)
        #expect(try recovery.latestEditCheckpoint(for: key)?.snapshot == snapshot)
    }
}
