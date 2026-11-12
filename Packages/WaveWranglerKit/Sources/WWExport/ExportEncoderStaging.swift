import Darwin
import Foundation

/// File descriptors retain ownership across writer closure and prevent inode reuse during cleanup.
final class ExportEncoderStaging {
    let directory: URL
    private let parent: Int32
    private let descriptor: Int32
    private let identity: stat
    private struct Artifact {
        let descriptor: Int32
        var witness: ExportOutputWitness
        var changed = false
    }
    private var artifacts: [String: Artifact] = [:]
    private var removed = false

    init(parent directory: URL) throws {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Self.failure("Open encoder staging parent") }
        let name = "ww-export-\(UUID().uuidString)"
        guard mkdirat(parent, name, 0o700) == 0 else {
            let error = Self.failure("Create encoder staging")
            Darwin.close(parent)
            throw error
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var identity = stat()
        guard fd >= 0, fstat(fd, &identity) == 0 else {
            let error = Self.failure("Inspect encoder staging")
            if fd >= 0 { Darwin.close(fd) }
            let result = unlinkat(parent, name, AT_REMOVEDIR)
            let cleanup = result == 0 ? "" : "; \(Self.failure("Remove empty encoder staging"))"
            Darwin.close(parent)
            throw ExportFailure.destination("\(error)\(cleanup)")
        }
        self.parent = parent
        descriptor = fd
        self.identity = identity
        self.directory = directory.appendingPathComponent(name, isDirectory: true)
    }

    deinit {
        for artifact in artifacts.values { Darwin.close(artifact.descriptor) }
        Darwin.close(descriptor)
        Darwin.close(parent)
    }

    func create(_ name: String) throws -> URL {
        try validateDirectory()
        let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("Create owned encoder output") }
        try record(name, descriptor: fd)
        return directory.appendingPathComponent(name)
    }

    /// Only call after a successful framework export, never for a failed or still-running remux.
    func recordCompletedRemux(_ name: String) throws {
        try validateDirectory()
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("Open completed metadata remux") }
        try record(name, descriptor: fd)
    }

    private func record(_ name: String, descriptor fd: Int32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, artifacts[name] == nil else {
            Darwin.close(fd)
            throw ExportFailure.destination("Cannot establish exclusive ownership of encoder output")
        }
        artifacts[name] = Artifact(descriptor: fd, witness: ExportOutputWitness(metadata))
    }

    /// Check before every writer mutation; a changed file must never become owned again via checkpoint.
    func validateArtifacts(missingAllowed: Bool = false) throws {
        try validateDirectory()
        var errors: [String] = []
        for name in artifacts.keys.sorted() {
            do { try validate(name, missingAllowed: missingAllowed) }
            catch { errors.append(String(describing: error)) }
        }
        try report(errors)
    }

    /// Record our writer's changes using the retained original descriptor, not a reopened replacement.
    func checkpoint(missingAllowed: Bool = false) throws {
        try validateDirectory()
        var errors: [String] = []
        for name in artifacts.keys.sorted() {
            guard var artifact = artifacts[name], !artifact.changed else { continue }
            var current = stat()
            var owned = stat()
            let result = fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW)
            if result != 0, errno == ENOENT, missingAllowed { continue }
            guard result == 0,
                  fstat(artifact.descriptor, &owned) == 0,
                  current.st_dev == artifact.witness.device, current.st_ino == artifact.witness.inode,
                  current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  ExportOutputWitness(current) == ExportOutputWitness(owned) else {
                artifacts[name]?.changed = true
                errors.append("Encoder output changed during writing: \(name); it was preserved")
                continue
            }
            artifact.witness = ExportOutputWitness(owned)
            artifacts[name] = artifact
        }
        try report(errors)
    }

    func remove(_ name: String) throws {
        try validateDirectory()
        if try validate(name, missingAllowed: true) {
            guard unlinkat(descriptor, name, 0) == 0 else { throw Self.failure("Remove owned \(name)") }
        }
        if let artifact = artifacts.removeValue(forKey: name) { Darwin.close(artifact.descriptor) }
    }

    func cleanup() throws {
        guard !removed else { return }
        try validateDirectory()
        var errors: [String] = []
        for name in artifacts.keys.sorted() {
            do { try remove(name) }
            catch { errors.append(String(describing: error)) }
        }
        // Never enumerate and adopt unknown entries, and never recursively delete this directory.
        if unlinkat(parent, directory.lastPathComponent, AT_REMOVEDIR) == 0 {
            removed = true
        } else {
            errors.append("\(Self.failure("Remove empty encoder staging")); unexpected or changed entries were preserved")
        }
        try report(errors)
    }

    @discardableResult
    private func validate(_ name: String, missingAllowed: Bool) throws -> Bool {
        guard let artifact = artifacts[name], !artifact.changed else {
            throw ExportFailure.destination("Encoder output changed: \(name); it was preserved")
        }
        var current = stat()
        if fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT, missingAllowed { return false }
            artifacts[name]?.changed = true
            throw Self.failure("Inspect owned \(name)")
        }
        guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              ExportOutputWitness(current) == artifact.witness else {
            artifacts[name]?.changed = true
            throw ExportFailure.destination("Encoder output changed: \(name); it was preserved")
        }
        return true
    }

    private func validateDirectory() throws {
        var current = stat()
        var path = stat()
        guard fstatat(parent, directory.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(directory.path, &path) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              path.st_dev == identity.st_dev, path.st_ino == identity.st_ino else {
            throw ExportFailure.destination("Encoder staging changed; it was not followed or removed")
        }
    }

    private func report(_ errors: [String]) throws {
        if !errors.isEmpty { throw ExportFailure.destination(errors.joined(separator: "; ")) }
    }

    private static func failure(_ operation: String) -> ExportFailure {
        .destination("\(operation): \(String(cString: strerror(errno)))")
    }
}
