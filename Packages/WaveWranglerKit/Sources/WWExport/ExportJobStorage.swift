import Darwin
import Foundation

/// All content here is newly generated output, never a source-reader entry point.
final class ExportJobStorage {
    let directory: URL
    private let destination: URL
    private let descriptor: Int32
    private let identity: stat
    private let ownedIdentity: stat
    private var removed = false

    init(request: ExportJobRequest) throws {
        let destination = request.directory.standardizedFileURL
        guard destination == destination.resolvingSymlinksInPath(),
              try destination.resourceValues(forKeys: [.isDirectoryKey, .isAliasFileKey]).isDirectory == true,
              try destination.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else {
            throw ExportFailure.destination("Choose a real local folder, not an alias or symbolic link")
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
            let frames = request.productionFrames.count64
            var budget = frames * 8 + 64 * 1_024 * 1_024
            for delivery in request.deliveries {
                let outputFrames = Int64(ceil(Double(frames) * Double(delivery.settings.sampleRate) / 48_000))
                // Conservative PCM-sized budget even for compressed formats, plus metadata/remux duplication.
                let bytes = outputFrames * Int64(delivery.settings.channels * 4) + 32 * 1_024 * 1_024
                budget += bytes * 2
                if case .wave(let encoding) = delivery.settings.codec,
                   outputFrames * Int64(delivery.settings.channels * (encoding.rawValue / 8))
                    > Int64(UInt32.max) - 1_048_576 {
                    throw ExportFailure.destination("Requested WAV exceeds RIFF's 4 GiB limit. Choose a compressed format.")
                }
            }
            var filesystem = statvfs()
            guard fstatvfs(fd, &filesystem) == 0 else { throw Self.failure("Check disk capacity") }
            let available = Double(filesystem.f_bavail) * Double(filesystem.f_frsize)
            guard available >= Double(budget) else {
                throw ExportFailure.destination("Insufficient disk space; export needs at least \(budget) available bytes")
            }
            let name = ".ww-export-job-\(UUID().uuidString)"
            guard mkdirat(fd, name, 0o700) == 0 else { throw Self.failure("Create private staging") }
            var owned = stat()
            guard fstatat(fd, name, &owned, AT_SYMLINK_NOFOLLOW) == 0 else {
                let inspection = Self.failure("Inspect private staging")
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
                    throw ExportFailure.destination("\(inspection); \(Self.failure("Remove uninitialized staging"))")
                }
                throw inspection
            }
            directory = destination.appendingPathComponent(name, isDirectory: true)
            ownedIdentity = owned
        } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
        identity = original
        self.destination = destination
    }

    deinit { Darwin.close(descriptor) }

    func validateOwnership() throws {
        var current = stat()
        guard lstat(destination.path, &current) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFailure.destination("Destination folder moved or changed during export")
        }
        var owned = stat()
        guard fstatat(descriptor, directory.lastPathComponent, &owned, AT_SYMLINK_NOFOLLOW) == 0,
              owned.st_dev == ownedIdentity.st_dev, owned.st_ino == ownedIdentity.st_ino,
              owned.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFailure.destination("Private staging changed; it was not followed or removed")
        }
    }

    func publish(_ file: VerifiedExport, filename: String) throws -> URL {
        try validateOwnership()
        guard file.stagingURL.deletingLastPathComponent().deletingLastPathComponent() == directory else {
            throw ExportFailure.destination("Only this job's verified outputs may be published")
        }
        let root = openat(descriptor, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Self.failure("Open owned staging for publication") }
        defer { Darwin.close(root) }
        var metadata = stat()
        guard fstat(root, &metadata) == 0, metadata.st_dev == ownedIdentity.st_dev,
              metadata.st_ino == ownedIdentity.st_ino else {
            throw ExportFailure.destination("Private staging changed before publication")
        }
        let encoder = openat(root, file.stagingURL.deletingLastPathComponent().lastPathComponent,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard encoder >= 0 else { throw Self.failure("Open private encoder directory") }
        defer { Darwin.close(encoder) }
        guard fstatat(encoder, file.stagingURL.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              ExportOutputWitness(metadata) == file.witness else {
            throw ExportFailure.destination("Verified output changed before publication")
        }
        guard renameatx_np(encoder, file.stagingURL.lastPathComponent, descriptor, filename, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.failure("Publish \(filename) without overwriting")
        }
        // A successful rename is the per-file commit point. Never roll it back or delete it on later failure.
        return destination.appendingPathComponent(filename)
    }

    func cleanup() throws {
        guard !removed else { return }
        try validateOwnership()
        let fd = openat(descriptor, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("Open owned staging for cleanup") }
        defer { Darwin.close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_dev == ownedIdentity.st_dev,
              current.st_ino == ownedIdentity.st_ino else {
            throw ExportFailure.destination("Private staging changed before cleanup")
        }
        guard unlinkat(descriptor, directory.lastPathComponent, AT_REMOVEDIR) == 0 else {
            throw Self.failure("Remove empty owned staging; unexpected files were preserved")
        }
        removed = true
    }

    private static func failure(_ operation: String) -> ExportFailure {
        .destination("\(operation): \(String(cString: strerror(errno)))")
    }
}
