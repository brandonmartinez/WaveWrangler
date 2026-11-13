import Darwin
import Foundation

/// Retains the original inode and latches lost ownership so later errors cannot adopt external edits.
final class ExportOwnedArtifact {
    let descriptor: Int32
    let name: String
    private var witness: ExportOutputWitness
    private var changed = false

    init(descriptor: Int32, name: String) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw ExportFailure.destination("Cannot establish exclusive ownership of \(name)")
        }
        self.descriptor = descriptor
        self.name = name
        witness = ExportOutputWitness(metadata)
    }

    deinit { Darwin.close(descriptor) }

    @discardableResult
    func validate(in directory: Int32, missingAllowed: Bool = false) throws -> Bool {
        guard !changed else { throw failure() }
        var current = stat()
        if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT, missingAllowed { return false }
            changed = true
            throw failure()
        }
        var retained = stat()
        guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              fstat(descriptor, &retained) == 0,
              ExportOutputWitness(current) == witness,
              ExportOutputWitness(retained) == witness else {
            changed = true
            throw failure()
        }
        return true
    }

    /// Destination-only: a ctime change requires a stable, exact comparison of every copied byte.
    func validateDestinationCopy(in directory: Int32, verifyBytes: Bool = false,
                                 compare: (Int64) async throws -> Bool,
                                 isolation: isolated (any Actor)? = #isolation) async throws {
        for _ in 0..<3 {
            let candidate = try destinationCopyWitness(in: directory)
            if !verifyBytes, candidate == witness { return }
            guard try await compare(Int64(candidate.bytes)) else {
                changed = true
                throw ExportFailure.verification("Destination copy differs from the verified local output: \(name). Its bytes were preserved.")
            }
            let verified = try destinationCopyWitness(in: directory)
            if verified == candidate {
                witness = verified
                return
            }
        }
        changed = true
        throw ExportFailure.destination("Destination metadata kept changing during byte verification: \(name). Its bytes were preserved.")
    }

    func destinationCopyIsCurrent(in directory: Int32) throws -> Bool {
        try destinationCopyWitness(in: directory) == witness
    }

    private func destinationCopyWitness(in directory: Int32) throws -> ExportOutputWitness {
        guard !changed else { throw failure() }
        var current = stat(), retained = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(descriptor, &retained) == 0 else {
            changed = true
            throw failure()
        }
        for metadata in [current, retained] {
            let value = ExportOutputWitness(metadata)
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
                  value.device == witness.device, value.inode == witness.inode,
                  value.bytes == witness.bytes,
                  value.modifiedSeconds == witness.modifiedSeconds,
                  value.modifiedNanoseconds == witness.modifiedNanoseconds else {
                changed = true
                throw failure()
            }
        }
        return ExportOutputWitness(retained)
    }

    /// Only after a validated, synchronous owned write; expected size bounds partial PCM writes.
    func checkpoint(in directory: Int32, missingAllowed: Bool = false, expectedBytes: Int64? = nil) throws {
        guard !changed else { throw failure() }
        var current = stat()
        if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT, missingAllowed { return }
            changed = true
            throw failure()
        }
        var retained = stat()
        guard fstat(descriptor, &retained) == 0,
              current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              current.st_dev == witness.device, current.st_ino == witness.inode,
              ExportOutputWitness(current) == ExportOutputWitness(retained),
              expectedBytes == nil || retained.st_size == expectedBytes else {
            changed = true
            throw failure()
        }
        witness = ExportOutputWitness(retained)
    }

    func remove(in directory: Int32, missingAllowed: Bool = true) throws {
        if try validate(in: directory, missingAllowed: missingAllowed) {
            guard unlinkat(directory, name, 0) == 0 else {
                throw ExportFailure.destination("Remove owned \(name): \(String(cString: strerror(errno)))")
            }
        }
    }

    private func failure() -> ExportFailure {
        .destination("Private export artifact changed: \(name). Its bytes were preserved; restart export and inspect retained staging.")
    }
}
