import Darwin
import Foundation

/// The only file-system surface persistence uses. Everything goes through this protocol so that the fault
/// harness can interrupt each publication boundary and audit that no write ever targets a referenced source.
///
/// There is deliberately no "write in place" operation: canonical bytes are always written to a new staged
/// file and then published by replacement.
public protocol FileOperations: Sendable {
    func read(_ url: URL) throws -> Data
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    /// Creates a new file (fails if anything exists at `url`), writes all bytes and flushes them to storage.
    func writeNew(_ data: Data, to url: URL) throws
    /// Publishes `staged` at `destination`: replaces an existing item or moves into place if none exists.
    func replace(_ destination: URL, withStaged staged: URL) throws
    /// Moves an app-owned file within the same volume, refusing to overwrite anything.
    func moveNew(_ source: URL, to destination: URL) throws
    /// Removes an app-owned staging/recovery/cache item. Never used on canonical documents or sources.
    func remove(_ url: URL) throws
    func contentsOfDirectory(_ url: URL) throws -> [URL]
    /// A private staging directory on the same volume as `destination` (outside the user's folder).
    func makeStagingDirectory(appropriateFor destination: URL) throws -> URL
}

/// Production file operations backed by Foundation/POSIX.
public struct LocalFileOperations: FileOperations {
    public init() {}

    public func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.uncached])
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func writeNew(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError.current() }
        var closed = false
        defer { if !closed { close(fd) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError.current() }
        closed = true
        guard close(fd) == 0 else { throw POSIXError.current() }
    }

    public func replace(_ destination: URL, withStaged staged: URL) throws {
        if exists(destination) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: [])
        } else {
            try moveNew(staged, to: destination)
        }
    }

    public func moveNew(_ source: URL, to destination: URL) throws {
        // renamex_np with RENAME_EXCL never overwrites an existing item.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError.current() }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    public func makeStagingDirectory(appropriateFor destination: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(),
            create: true
        )
    }
}

extension POSIXError {
    static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
