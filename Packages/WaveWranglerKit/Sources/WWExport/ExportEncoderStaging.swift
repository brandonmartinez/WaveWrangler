import Darwin
import Foundation

/// File descriptors retain ownership across writer closure and prevent inode reuse during cleanup.
final class ExportEncoderStaging {
    let directory: URL
    private let parent: Int32
    private let descriptor: Int32
    private let identity: stat
    private var artifacts: [String: ExportOwnedArtifact] = [:]
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
        guard artifacts[name] == nil else {
            Darwin.close(fd)
            throw ExportFailure.destination("Cannot establish exclusive ownership of encoder output")
        }
        artifacts[name] = try ExportOwnedArtifact(descriptor: fd, name: name)
    }

    /// Check before every writer mutation; a changed file must never become owned again via checkpoint.
    func validateArtifacts(missingAllowed: Bool = false) throws {
        try validateDirectory()
        var errors: [String] = []
        for name in artifacts.keys.sorted() {
            do { try artifacts[name]?.validate(in: descriptor, missingAllowed: missingAllowed) }
            catch { errors.append(String(describing: error)) }
        }
        try report(errors)
    }

    /// Record our writer's changes using the retained original descriptor, not a reopened replacement.
    func checkpoint(missingAllowed: Bool = false) throws {
        try validateDirectory()
        var errors: [String] = []
        for name in artifacts.keys.sorted() {
            do { try artifacts[name]?.checkpoint(in: descriptor, missingAllowed: missingAllowed) }
            catch { errors.append(String(describing: error)) }
        }
        try report(errors)
    }

    func remove(_ name: String) throws {
        try validateDirectory()
        guard let artifact = artifacts[name] else {
            throw ExportFailure.destination("Refusing to remove untracked encoder output: \(name)")
        }
        try artifact.remove(in: descriptor)
        artifacts.removeValue(forKey: name)
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
