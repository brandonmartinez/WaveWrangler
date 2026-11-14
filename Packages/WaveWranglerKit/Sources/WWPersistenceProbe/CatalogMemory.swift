import CoreGraphics
import Darwin
import Foundation
import ImageIO
import WWCore
import WWPersistence

/// Opt-in, generated-only codec/publication measurements, not editor/Undo/UI memory qualification.
extension Probe {
    func catalogGenerate() -> Int32 {
        do {
            guard let count = Int(args["episodes"] ?? "8"), (1...32).contains(count),
                  let words = Int(args["words"] ?? "8000"),
                  (1...8_000).contains(words),
                  file.pathExtension.lowercased() == "wwshow",
                  !LocalFileOperations().exists(file) else {
                throw PersistenceError.malformed("Use a new fixture path, 1...32 episodes and 1...8000 words")
            }
            let storage = args["storage"] ?? "package"
            guard storage == "package", args["flat-copy"] == nil else {
                throw PersistenceError.malformed("Storage must be package; flat show generation is no longer supported")
            }
            let indexedCopy = args["indexed-copy"].map { URL(fileURLWithPath: $0) }
            if let indexedCopy {
                guard indexedCopy != file,
                      !LocalFileOperations().exists(indexedCopy) else {
                    throw PersistenceError.malformed("Indexed comparison requires a new, distinct path and package primary")
                }
            }
            let artwork = try catalogArtwork()
            let model = try syntheticPackageShow(episodes: count, wordsPerGeneration: words, artwork: artwork)
            let bytes = try ShowPackageCoder().encode(model, revision: 1)
            try LocalFileOperations().writeNew(bytes, to: file)
            if let indexedCopy {
                try LocalFileOperations().writeNew(ShowCatalogCoder().encode(ShowCatalog(model), revision: 1), to: indexedCopy)
            }
            emit(["result": "generated", "storage": storage, "episodes": count,
                "currentWords": count * words, "historicalWords": count * words,
                "currentTranscripts": count, "historicalTranscripts": count,
                "artworkBytes": artwork.count, "artworkImages": 1, "snapshotBytes": bytes.count,
                "identicalModelIndexedCopy": indexedCopy != nil])
            return 0
        } catch {
            emit(["result": "generationFailed", "detail": "\(error)"])
            return 1
        }
    }

    func catalogMemory() -> Int32 {
        do {
            let storage = args["storage"] ?? "package"
            if storage == "indexed" { return try indexedCatalogMemory() }
            guard storage == "package" else {
                throw PersistenceError.malformed("Storage must be package or indexed")
            }

            let baseline = try catalogMemorySample()
            let start = ContinuousClock.now
            let (document, fingerprint, snapshotBytes) = try autoreleasepool {
                let bytes = try LocalFileOperations().read(file)
                guard ShowPackage.isSnapshot(bytes) else {
                    throw PersistenceError.malformed("Fixture does not match the requested storage")
                }
                return (try ShowPackageCoder().decode(bytes), RevisionFingerprint(of: bytes), bytes.count)
            }
            let openSeconds = seconds(.now - start)
            var result: [String: Any] = ["result": "measured", "scope": "headlessCodecAndVerifiedPublisher",
                "storage": storage, "baseline": baseline, "openRetained": try catalogMemorySample(),
                "openSeconds": openSeconds, "snapshotBytes": snapshotBytes,
                "episodes": document.payload.episodes.count,
                "currentWords": document.payload.episodes.reduce(0) { $0 + ($1.cleanup?.transcripts.reduce(0) { $0 + $1.words.count } ?? 0) },
                "historicalWords": document.payload.episodes.reduce(0) { $0 + ($1.cleanup?.transcriptHistory?.reduce(0) { $0 + $1.words.count } ?? 0) },
                "artworkBytes": document.payload.show.publication?.artwork?.image?.data.count ?? 0,
                "peakScope": "getrusage process-lifetime maximum RSS, not phase-local or physical-footprint peak"]
            if args["save"] == "1" {
                guard let recovery else { throw PersistenceError.malformed("Save measurement requires local recovery") }
                let saveStart = ContinuousClock.now
                try autoreleasepool {
                    let edited = try document.payload.renamingShow(to: "Synthetic catalog memory save \(document.revision + 1)")
                    let key = DocumentKey.show(edited.show.id)
                    _ = try DocumentPublisher(coder: ShowPackageCoder(), recovery: recovery).publish(
                        edited, revision: document.revision + 1, key: key, to: file,
                        target: .inPlace(expectedBase: fingerprint))
                }
                result["saveSeconds"] = seconds(.now - saveStart)
                result["saveRetained"] = try catalogMemorySample()
                result["saveIncludes"] = "rename, encode, validate, exact prior recovery checkpoint, stage/flush, replace, verified readback"
            }
            try withExtendedLifetime(document) {
                result["final"] = try catalogMemorySample()
                emit(result)
            }
            return 0
        } catch {
            emit(["result": "measurementFailed", "detail": "\(error)"])
            return 1
        }
    }

    private func indexedCatalogMemory() throws -> Int32 {
        let baseline = try catalogMemorySample()
        let start = ContinuousClock.now
        let (document, fingerprint, snapshotBytes) = try autoreleasepool {
            let bytes = try LocalFileOperations().read(file)
            return (try ShowCatalogCoder().decode(bytes), RevisionFingerprint(of: bytes), bytes.count)
        }
        let openSeconds = seconds(.now - start)
        let catalog = document.payload
        var result: [String: Any] = ["result": "measured", "scope": "headlessIndexedCatalogAndVerifiedPublisher",
            "storage": "indexed", "baseline": baseline, "openRetained": try catalogMemorySample(),
            "openSeconds": openSeconds, "snapshotBytes": snapshotBytes, "episodes": catalog.episodes.count,
            "residentEpisodes": 0, "currentWordsLoaded": 0, "historicalWordsLoaded": 0,
            "artworkBytes": catalog.header.show.publication?.artwork?.image?.data.count ?? 0,
            "peakScope": "getrusage process-lifetime maximum RSS, not phase-local or physical-footprint peak"]
        var loaded: Episode?
        if args["episode"] == "1" {
            let episodeStart = ContinuousClock.now
            guard let stored = catalog.episodes.first else { throw PersistenceError.malformed("Empty catalog fixture") }
            loaded = try autoreleasepool { try stored.load(in: catalog.header) }
            result["episodeOpenSeconds"] = seconds(.now - episodeStart)
            result["episodeRetained"] = try catalogMemorySample()
            result["residentEpisodes"] = 1
            result["currentWordsLoaded"] = loaded?.cleanup?.transcripts.reduce(0) { $0 + $1.words.count } ?? 0
            result["historicalWordsLoaded"] = loaded?.cleanup?.transcriptHistory?.reduce(0) { $0 + $1.words.count } ?? 0
        }
        if args["save"] == "1" {
            guard let recovery, var edited = loaded else {
                throw PersistenceError.malformed("Indexed save requires an explicitly loaded episode and recovery")
            }
            let saveStart = ContinuousClock.now
            try autoreleasepool {
                edited.title = "Single episode memory save \(document.revision + 1)"
                let draft = ShowCatalogDraft(header: catalog.header,
                    episodes: [.resident(edited)] + catalog.episodes.dropFirst().map { .stored($0) }, archiveOwner: catalog)
                let candidate = try draft.resolved()
                let receipt = try DocumentPublisher(coder: ShowCatalogCoder(), recovery: recovery).publish(
                    candidate, revision: document.revision + 1, key: .show(catalog.header.show.id), to: file,
                    target: .inPlace(expectedBase: fingerprint))
                let saved = try ShowCatalogCoder().decode(LocalFileOperations().read(receipt.url)).payload
                guard Array(saved.episodes.dropFirst()) == Array(catalog.episodes.dropFirst()),
                      try saved.episodes.first?.load(in: saved.header) == edited else {
                    throw PersistenceError.malformed("Single-episode save changed unvisited data")
                }
                result["unvisitedStoredComponentsPreserved"] = true
            }
            result["saveSeconds"] = seconds(.now - saveStart)
            result["saveRetained"] = try catalogMemorySample()
        }
        try withExtendedLifetime((document, loaded)) {
            result["final"] = try catalogMemorySample()
            emit(result)
        }
        return 0
    }

    private func catalogMemorySample() throws -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw PersistenceError.malformed("task_info failed: \(status)")
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        return ["residentBytes": info.resident_size, "physicalFootprintBytes": info.phys_footprint,
            "processPeakResidentBytes": UInt64(usage.ru_maxrss)]
    }

    private func catalogArtwork() throws -> Data {
        let width = 256
        var state: UInt64 = 7513
        var pixels = Data(count: width * width * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                for channel in 0..<3 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 32)
                }
                bytes[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PersistenceError.encodingFailed("Generated artwork construction failed")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw PersistenceError.encodingFailed("Generated PNG destination failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PersistenceError.encodingFailed("Generated PNG encoding failed")
        }
        return output as Data
    }
}
