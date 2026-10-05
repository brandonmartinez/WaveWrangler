import Foundation

/// One unresolved conflict version a sync provider kept for a file (for example iCloud keeping the other Mac's
/// copy after two Macs saved the same file at the same time).
public struct ProviderConflictVersion: Sendable, Equatable {
    /// Stable for the life of the version (its location in the provider's version store).
    public let id: String
    public let savingComputer: String?
    public let modified: Date?
    /// The version's bytes, or `nil` when they can't be read.
    public let bytes: Data?

    public init(id: String, savingComputer: String?, modified: Date?, bytes: Data?) {
        self.id = id
        self.savingComputer = savingComputer
        self.modified = modified
        self.bytes = bytes
    }
}

/// Reads and resolves provider conflict versions. Resolving only marks versions resolved; it never removes,
/// replaces or writes the file.
public protocol ProviderVersionInspecting: Sendable {
    func unresolvedConflictVersions(of url: URL) -> [ProviderConflictVersion]
    /// Marks exactly the versions with these ids resolved (inside a coordinated write on `url`).
    func markResolved(_ ids: Set<String>, of url: URL) throws
}

/// `NSFileVersion`-backed provider versions.
public struct FileVersionInspector: ProviderVersionInspecting {
    public init() {}

    public func unresolvedConflictVersions(of url: URL) -> [ProviderConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map { version in
            ProviderConflictVersion(id: version.url.path, savingComputer: version.localizedNameOfSavingComputer,
                                    modified: version.modificationDate, bytes: try? Data(contentsOf: version.url))
        }
    }

    public func markResolved(_ ids: Set<String>, of url: URL) throws {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated) ?? [] where ids.contains(version.url.path) {
                version.isResolved = true
            }
        }
        if let coordinationError { throw coordinationError }
    }
}

/// No provider versions (locations that aren't synced, tests).
public struct NoProviderVersions: ProviderVersionInspecting {
    public init() {}
    public func unresolvedConflictVersions(of url: URL) -> [ProviderConflictVersion] { [] }
    public func markResolved(_ ids: Set<String>, of url: URL) throws {}
}
