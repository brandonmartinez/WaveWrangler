import Darwin
import Foundation

/// All content here is newly generated output, never a source-reader entry point.
final class ExportJobStorage {
    var directory: URL { staging.directory }
    private let staging: ExportEncoderStaging
    private let destination: URL
    private let descriptor: Int32
    private let identity: stat
    private var publication: ExportEncoderStaging?

    init(request: ExportJobRequest, temporaryDirectory: URL) throws {
        let destination = request.directory.standardizedFileURL
        guard destination == destination.resolvingSymlinksInPath(),
              try destination.resourceValues(forKeys: [.isDirectoryKey, .isAliasFileKey]).isDirectory == true,
              try destination.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else {
            throw ExportFailure.destination("Choose a real folder, not an alias or symbolic link")
        }
        for protected in request.protectedLocations {
            let path = protected.resolvingSymlinksInPath().standardizedFileURL.path
            guard destination.path != path, !destination.path.hasPrefix(path + "/") else {
                throw ExportFailure.destination("Export cannot be placed inside a recording, show, or protected staging location")
            }
        }
        let fd = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("Open destination") }
        var original = stat()
        guard fstat(fd, &original) == 0 else { Darwin.close(fd); throw Self.failure("Inspect destination") }
        do {
            for delivery in request.deliveries {
                var existing = stat()
                guard fstatat(fd, delivery.filename, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                    throw ExportFailure.destination("Destination already exists: \(delivery.filename). Choose a different name.")
                }
            }
            let temporary = Darwin.open(temporaryDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard temporary >= 0 else { throw Self.failure("Open local export temporary directory") }
            defer { Darwin.close(temporary) }
            var local = stat()
            guard fstat(temporary, &local) == 0 else { throw Self.failure("Inspect local temporary directory") }
            let frames = request.productionFrames.count64
            var localBudget = frames * 8 + 64 * 1_024 * 1_024
            var destinationBudget: Int64 = 0
            for delivery in request.deliveries {
                let outputFrames = Int64(ceil(Double(frames) * Double(delivery.settings.sampleRate) / 48_000))
                let bytes = outputFrames * Int64(delivery.settings.channels * 4) + 32 * 1_024 * 1_024
                localBudget += bytes * 2
                destinationBudget += bytes
                if case .wave(let encoding) = delivery.settings.codec,
                   outputFrames * Int64(delivery.settings.channels * (encoding.rawValue / 8))
                    > Int64(UInt32.max) - 1_048_576 {
                    throw ExportFailure.destination("Requested WAV exceeds RIFF's 4 GiB limit. Choose a compressed format.")
                }
            }
            // Copies can coexist with every local output, even when both folders share a volume.
            if local.st_dev == original.st_dev {
                try Self.checkCapacity(fd, bytes: localBudget + destinationBudget, location: "local and destination")
            } else {
                try Self.checkCapacity(temporary, bytes: localBudget, location: "local temporary")
                try Self.checkCapacity(fd, bytes: destinationBudget, location: "destination")
            }
            staging = try ExportEncoderStaging(parent: temporaryDirectory, prefix: ".ww-export-job-")
        } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
        identity = original
        self.destination = destination
    }

    deinit { Darwin.close(descriptor) }

    func validateOwnership() throws { try staging.validateDirectory() }

    private func validateDestination() throws {
        var current = stat()
        guard lstat(destination.path, &current) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFailure.destination("Destination folder moved or changed during export")
        }
    }

    func publish(_ file: VerifiedExport, filename: String,
                 check: @Sendable () async throws -> Void,
                 beforeCommit: @Sendable () async throws -> Void,
                 isolation: isolated (any Actor)? = #isolation) async throws -> URL {
        try validateOwnership()
        try validateDestination()
        guard file.stagingURL.deletingLastPathComponent().deletingLastPathComponent() == directory else {
            throw ExportFailure.destination("Only this job's verified outputs may be published")
        }
        let encoderName = file.stagingURL.deletingLastPathComponent().lastPathComponent
        let encoder = openat(staging.descriptor, encoderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard encoder >= 0 else { throw Self.failure("Open private encoder directory") }
        defer { Darwin.close(encoder) }
        var encoderIdentity = stat()
        guard fstat(encoder, &encoderIdentity) == 0 else { throw Self.failure("Inspect private encoder directory") }
        let source = openat(encoder, file.stagingURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Self.failure("Open verified local output") }
        defer { Darwin.close(source) }
        func validateSource() throws {
            try validateOwnership()
            var folder = stat(), path = stat(), retained = stat()
            guard fstatat(staging.descriptor, encoderName, &folder, AT_SYMLINK_NOFOLLOW) == 0,
                  folder.st_mode & S_IFMT == S_IFDIR, folder.st_dev == encoderIdentity.st_dev,
                  folder.st_ino == encoderIdentity.st_ino,
                  fstatat(encoder, file.stagingURL.lastPathComponent, &path, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(source, &retained) == 0,
                  path.st_mode & S_IFMT == S_IFREG, path.st_nlink == 1, retained.st_nlink == 1,
                  ExportOutputWitness(path) == file.witness, ExportOutputWitness(retained) == file.witness else {
                throw ExportFailure.destination("Verified local output changed before publication")
            }
        }
        try validateSource()
        if publication == nil {
            publication = try ExportEncoderStaging(parent: destination, prefix: ".ww-export-publish-")
        }
        guard let publication else { throw ExportFailure.invalidState }
        _ = try publication.create(filename)
        let target = try publication.artifact(named: filename)
        var buffer = [UInt8](repeating: 0, count: 262_144)
        var comparison = buffer
        var offset: Int64 = 0
        while offset < file.byteCount {
            try await check()
            try validateDestination()
            try validateSource()
            try publication.validateDirectory()
            try target.validate(in: publication.descriptor)
            let count = Int(min(Int64(buffer.count), file.byteCount - offset))
            try Self.read(source, into: &buffer, count: count, offset: offset)
            var written = 0
            while written < count {
                try target.validate(in: publication.descriptor)
                let result = buffer.withUnsafeBytes {
                    pwrite(target.descriptor, $0.baseAddress!.advanced(by: written), count - written, off_t(offset))
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw Self.failure("Copy verified export") }
                written += result
                offset += Int64(result)
                try target.checkpoint(in: publication.descriptor, expectedBytes: offset)
            }
            try validateSource()
        }
        try target.validate(in: publication.descriptor)
        guard fsync(target.descriptor) == 0 else { throw Self.failure("Synchronize destination export") }
        try target.validate(in: publication.descriptor)
        // Byte-for-byte verification transfers the local decode verification to this exact copy.
        offset = 0
        while offset < file.byteCount {
            try await check()
            try validateDestination()
            try validateSource()
            try publication.validateDirectory()
            try target.validate(in: publication.descriptor)
            let count = Int(min(Int64(buffer.count), file.byteCount - offset))
            try Self.read(source, into: &buffer, count: count, offset: offset)
            try Self.read(target.descriptor, into: &comparison, count: count, offset: offset)
            guard buffer.prefix(count).elementsEqual(comparison.prefix(count)) else {
                throw ExportFailure.verification("Destination copy differs from the verified local output")
            }
            try validateSource()
            try target.validate(in: publication.descriptor)
            offset += Int64(count)
        }
        try await beforeCommit()
        try validateDestination()
        try validateSource()
        try publication.validateDirectory()
        try target.validate(in: publication.descriptor)
        guard renameatx_np(publication.descriptor, filename, descriptor, filename, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.failure("Publish \(filename) without overwriting")
        }
        // The rename is the per-file commit point. Never roll it back on later failure.
        return destination.appendingPathComponent(filename)
    }

    func cleanupPublication() throws {
        try publication?.validateArtifacts(missingAllowed: true)
        try publication?.cleanup()
    }

    func cleanup() throws { try staging.cleanup() }

    private static func read(_ descriptor: Int32, into buffer: inout [UInt8], count: Int, offset: Int64) throws {
        var read = 0
        while read < count {
            let result = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress!.advanced(by: read), count - read, off_t(offset + Int64(read)))
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw Self.failure("Read export copy for verification") }
            read += result
        }
    }

    private static func checkCapacity(_ descriptor: Int32, bytes: Int64, location: String) throws {
        var filesystem = statvfs()
        guard fstatvfs(descriptor, &filesystem) == 0 else { throw failure("Check \(location) disk capacity") }
        let available = Double(filesystem.f_bavail) * Double(filesystem.f_frsize)
        guard available >= Double(bytes) else {
            throw ExportFailure.destination("Insufficient \(location) disk space; export needs at least \(bytes) available bytes")
        }
    }

    private static func failure(_ operation: String) -> ExportFailure {
        .destination("\(operation): \(String(cString: strerror(errno)))")
    }
}
