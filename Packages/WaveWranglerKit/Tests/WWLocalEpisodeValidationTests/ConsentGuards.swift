import CryptoKit
import Darwin
import Foundation

/// Path-free harness error: messages carry only S-labels, reasons and errno values, never a path or name.
struct HarnessError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Consent guards for the local-episode harness (docs/planning/kickoffs/m2.md, "Content consent").
enum ConsentGuards {
    /// The repository root, derived from this file's location (Packages/WaveWranglerKit/Tests/<target>/<file>).
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { url.deleteLastPathComponent() }
        return url
    }

    /// Checks the scratch directory and returns its resolved location. It must be an existing, empty
    /// directory on a local, non-ubiquitous volume. After symlink resolution it must not equal, contain or sit
    /// inside the approved episode folder, and it must not sit inside the repository or a cloud-synced
    /// location (~/Library/Mobile Documents, ~/Library/CloudStorage).
    @discardableResult
    static func checkScratch(
        _ scratch: URL,
        episode: URL,
        repositoryRoot: URL = ConsentGuards.repositoryRoot,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        guard let resolvedScratch = realPath(scratch) else { throw HarnessError("scratch directory missing or unresolvable") }
        guard let resolvedEpisode = realPath(episode) else { throw HarnessError("approved folder missing or unresolvable") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedScratch.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HarnessError("scratch is not a directory")
        }

        let s = resolvedScratch.pathComponents
        let e = resolvedEpisode.pathComponents
        if s == e { throw HarnessError("scratch is the approved folder") }
        if isWithin(s, e) { throw HarnessError("scratch is inside the approved folder") }
        if isWithin(e, s) { throw HarnessError("scratch contains the approved folder") }
        if isWithin(s, resolve(repositoryRoot).pathComponents) { throw HarnessError("scratch is inside the repository") }
        let library = resolve(home).appendingPathComponent("Library", isDirectory: true)
        for synced in ["Mobile Documents", "CloudStorage"] where isWithin(s, resolve(library.appendingPathComponent(synced, isDirectory: true)).pathComponents) {
            throw HarnessError("scratch is inside a cloud-synced folder")
        }

        let values: URLResourceValues
        do {
            values = try resolvedScratch.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
        } catch {
            throw HarnessError("scratch volume facts unavailable: \(errnoDescription(error))")
        }
        guard values.volumeIsLocal == true else { throw HarnessError("scratch is not on a local volume") }
        guard values.isUbiquitousItem != true else { throw HarnessError("scratch is a ubiquitous (cloud) item") }

        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: resolvedScratch.path)
        } catch {
            throw HarnessError("scratch directory unreadable: \(errnoDescription(error))")
        }
        guard entries.isEmpty else { throw HarnessError("scratch directory not empty") }
        return resolvedScratch
    }

    /// Plain read-only SHA-256 of an approved audio item (FileHandle opens O_RDONLY; never writes). Errors
    /// carry only `label` and the errno, never the Cocoa description, which contains the path.
    static func sha256(_ url: URL, label: String) throws(HarnessError) -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw HarnessError("SHA-256 of \(label): open failed, \(errnoDescription(error))")
        }
        defer { try? handle.close() }
        return try digest(handle, label: label)
    }

    static func digest(_ handle: FileHandle, label: String) throws(HarnessError) -> String {
        var hasher = SHA256()
        while true {
            let block: Data
            do {
                block = try handle.read(upToCount: 8 << 20) ?? Data()
            } catch {
                throw HarnessError("SHA-256 of \(label): read failed, \(errnoDescription(error))")
            }
            if block.isEmpty { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "errno N" from the first POSIX error in the NSError chain; never the error's description.
    static func errnoDescription(_ error: any Error) -> String {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSPOSIXErrorDomain { return "errno \(candidate.code)" }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "errno unknown"
    }

    static func isWithin(_ path: [String], _ ancestor: [String]) -> Bool {
        path.count > ancestor.count && Array(path.prefix(ancestor.count)) == ancestor
    }

    static func realPath(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Resolves the longest existing prefix with realpath and keeps the rest literal, so missing cloud
    /// folders still compare correctly against resolved scratch paths.
    static func resolve(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let resolved = realPath(standardized) { return resolved }
        let parent = standardized.deletingLastPathComponent()
        guard parent.path != standardized.path else { return standardized }
        return resolve(parent).appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
}
