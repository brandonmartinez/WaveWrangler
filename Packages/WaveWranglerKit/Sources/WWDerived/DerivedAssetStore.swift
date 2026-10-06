import Darwin
import Foundation
import WWCore
import WWPersistence

public enum DerivedAssetStoreError: Error, Sendable, Equatable {
    /// The cache root is a source's folder or inside one. Derived data never lives next to originals.
    case rootInsideSourceLocation(root: String, source: String)
    /// The cache root is in iCloud Drive or a File Provider (cloud storage) location: derived data stays local.
    case rootInCloudStorage(root: String)
    case rootNotAbsolute
    case notADigest(String)
    case stagingFailed(String)
    case verificationFailed(String)
    case publishFailed(String)
}

/// A staged, flushed and read-back-verified asset waiting for its currency check. Only the coordinator
/// commits or discards it.
public struct StagedDerivedAsset: Sendable {
    public let key: DerivedAssetKey
    let url: URL
    let digest: String
}

/// The app-owned cache of derived assets (WW-020).
///
/// Layout: `<root>/assets/<key digest>` (published) and `<root>/staging/<uuid>` (in progress). The root is an
/// app cache location (default: the user Caches directory), never a source folder, and every path is confined
/// under it. Each asset file is self-describing:
/// `"WWDA1\n"` · header length (8 bytes, big-endian) · header JSON `{key, payloadLength, payloadDigest}` · payload.
///
/// Publication mirrors WW-009 C3: write the whole asset to a new staging file and flush it → read it back and
/// verify → (coordinator) currency check → atomic move into `assets/`. A crash leaves at most an orphan in
/// `staging/`, which `recover()` removes. A damaged or mismatching published file is treated as *missing*
/// (rebuild), never as authoritative. Sources are never opened, written, moved or removed here.
public struct DerivedAssetStore: Sendable {
    static let magic = Data("WWDA1\n".utf8)

    public let root: URL
    let files: any FileOperations
    let rootPolicy: CacheRootPolicy

    var assetsDirectory: URL { root.appendingPathComponent("assets", isDirectory: true) }
    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// The default root: `~/Library/Caches/<bundle id>/DerivedAssets/v1` (inside the app container when sandboxed).
    public static func defaultRoot(bundleIdentifier: String) throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("DerivedAssets", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// - Parameter sourceLocations: current location hints of referenced sources; the root must not be any
    ///   source's folder (or inside one).
    public init(root: URL, sourceLocations: [URL], files: any FileOperations = LocalFileOperations()) throws(DerivedAssetStoreError) {
        try self.init(root: root, sourceLocations: sourceLocations, files: files, rootPolicy: .system)
    }

    init(root: URL, sourceLocations: [URL], files: any FileOperations = LocalFileOperations(), rootPolicy: CacheRootPolicy) throws(DerivedAssetStoreError) {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw .rootNotAbsolute }
        let resolvedRoot = Self.resolved(root)
        try Self.checkLocal(resolvedRoot, policy: rootPolicy)
        try Self.checkOutside(resolvedRoot, sourceLocations: sourceLocations, policy: rootPolicy)
        self.root = resolvedRoot
        self.files = files
        self.rootPolicy = rootPolicy
        do {
            try files.createDirectory(assetsDirectory)
            try files.createDirectory(stagingDirectory)
        } catch {
            throw .stagingFailed("create cache directories: \(error.localizedDescription)")
        }
    }

    /// Re-checks the root against newly added sources.
    public func checkOutside(sourceLocations: [URL]) throws(DerivedAssetStoreError) {
        try Self.checkOutside(root, sourceLocations: sourceLocations, policy: rootPolicy)
    }

    /// Refuses a root that is a source's folder or lies anywhere under it (next to or among originals), and a
    /// root that would contain a source. The one exception is exactly the user's `Library` folder (e.g. a source
    /// in the home folder and the cache in `~/Library/Caches`): it is app-managed and never a recording folder.
    /// A `Library` folder anywhere else (`<source folder>/Library`) gets no exception.
    ///
    /// Paths are compared canonically: symbolic links resolved, then case- and Unicode-normalization-folded
    /// unconditionally. macOS volumes are case-insensitive by default; on a case-sensitive volume the fold can
    /// only refuse more, never allow a root among originals.
    static func checkOutside(_ root: URL, sourceLocations: [URL], policy: CacheRootPolicy) throws(DerivedAssetStoreError) {
        let rootKey = canonicalKey(root)
        let libraries = Set(policy.userLibraries.map(canonicalKey))
        for location in sourceLocations {
            let sourceKey = canonicalKey(resolved(location))
            let folder = Array(sourceKey.dropLast())
            if sourceKey.count > rootKey.count, Array(sourceKey.prefix(rootKey.count)) == rootKey {
                throw .rootInsideSourceLocation(root: root.path, source: location.path)
            }
            guard rootKey.count >= folder.count, Array(rootKey.prefix(folder.count)) == folder else { continue }
            if rootKey.count > folder.count, libraries.contains(Array(rootKey.prefix(folder.count + 1))) { continue }
            throw .rootInsideSourceLocation(root: root.path, source: location.path)
        }
    }

    /// Refuses a root in cloud storage: under `~/Library/Mobile Documents` (iCloud Drive) or
    /// `~/Library/CloudStorage` (File Provider), or whose nearest existing folder is a ubiquitous item. Reads
    /// only the cache location's own metadata.
    static func checkLocal(_ root: URL, policy: CacheRootPolicy) throws(DerivedAssetStoreError) {
        let rootKey = canonicalKey(root)
        for library in policy.userLibraries {
            for cloud in ["Mobile Documents", "CloudStorage"] {
                let cloudKey = canonicalKey(resolved(library.appendingPathComponent(cloud, isDirectory: true)))
                if rootKey.count >= cloudKey.count, Array(rootKey.prefix(cloudKey.count)) == cloudKey {
                    throw .rootInCloudStorage(root: root.path)
                }
            }
        }
        if policy.isUbiquitous(existingAncestor(of: root)) { throw .rootInCloudStorage(root: root.path) }
    }

    /// Path components folded for comparison (case and Unicode normalization).
    static func canonicalKey(_ url: URL) -> [String] {
        resolved(url).pathComponents.map { $0.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }
    }

    static func existingAncestor(of url: URL) -> URL {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing = existing.deletingLastPathComponent()
        }
        return existing
    }

    /// Resolves symlinks in the longest existing ancestor (e.g. `/var` → `/private/var`), so containment
    /// checks compare real locations even before the cache folders exist.
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for component in missing { result.appendPathComponent(component) }
        return result
    }

    // MARK: - Publication (C3 order)

    /// Writes and flushes a new staging file, then reads it back and verifies it. Runs off the coordinator.
    public func stage(_ payload: Data, for key: DerivedAssetKey) throws(DerivedAssetStoreError) -> StagedDerivedAsset {
        let digest = key.digest
        let url = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let bytes: Data
        do { bytes = try Self.encode(payload, key: key) } catch { throw .stagingFailed("encode: \(error)") }
        do {
            try files.writeNew(bytes, to: url)
        } catch {
            try? files.remove(url)
            throw .stagingFailed(error.localizedDescription)
        }
        let readBack: Data
        do { readBack = try files.read(url) } catch {
            try? files.remove(url)
            throw .verificationFailed("read back: \(error.localizedDescription)")
        }
        guard readBack == bytes, Self.decode(readBack, expecting: key) == payload else {
            try? files.remove(url)
            throw .verificationFailed("staged bytes differ")
        }
        return StagedDerivedAsset(key: key, url: url, digest: digest)
    }

    /// Atomically moves a verified staged asset into place. Called by the coordinator only after its currency
    /// check, with no suspension in between.
    func commit(_ staged: StagedDerivedAsset) throws(DerivedAssetStoreError) {
        let destination = try assetURL(digest: staged.digest)
        do {
            if files.exists(destination) {
                // Same key ⇒ same content contract; a damaged copy is replaced by the verified one.
                try files.replace(destination, withStaged: staged.url)
            } else {
                try files.moveNew(staged.url, to: destination)
            }
        } catch {
            discard(staged)
            throw .publishFailed(error.localizedDescription)
        }
    }

    func discard(_ staged: StagedDerivedAsset) {
        try? files.remove(staged.url)
    }

    // MARK: - Reading

    /// The published payload for `key`, or `nil` if absent, damaged or recorded for a different key.
    public func payload(for key: DerivedAssetKey) -> Data? {
        guard let url = try? assetURL(digest: key.digest), files.exists(url), let bytes = try? files.read(url) else { return nil }
        return Self.decode(bytes, expecting: key)
    }

    /// Removes orphaned staging files left by an interrupted publication. Published assets are untouched.
    @discardableResult
    public func recover() -> Int {
        let orphans = (try? files.contentsOfDirectory(stagingDirectory)) ?? []
        var removed = 0
        for orphan in orphans where Self.isConfined(orphan, under: stagingDirectory) {
            if (try? files.remove(orphan)) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes published assets whose digest is not in `live`. Never touches anything outside `assets/`.
    @discardableResult
    public func prune(keeping live: Set<String>) -> Int {
        let published = (try? files.contentsOfDirectory(assetsDirectory)) ?? []
        var removed = 0
        for url in published where Self.isConfined(url, under: assetsDirectory) && !live.contains(url.lastPathComponent) {
            if (try? files.remove(url)) != nil { removed += 1 }
        }
        return removed
    }

    func assetURL(digest: String) throws(DerivedAssetStoreError) -> URL {
        guard CanonicalDigest.isDigest(digest) else { throw .notADigest(digest) }
        return assetsDirectory.appendingPathComponent(digest, isDirectory: false)
    }

    static func isConfined(_ url: URL, under directory: URL) -> Bool {
        let parent = resolved(url).deletingLastPathComponent().pathComponents
        return parent == resolved(directory).pathComponents
    }

    // MARK: - Encoding

    struct Header: Codable, Equatable {
        var key: DerivedAssetKey
        var payloadLength: Int
        var payloadDigest: String
    }

    static func encode(_ payload: Data, key: DerivedAssetKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(Header(key: key, payloadLength: payload.count, payloadDigest: CanonicalDigest.hex(of: payload)))
        var length = UInt64(header.count).bigEndian
        var bytes = magic
        bytes.append(Data(bytes: &length, count: 8))
        bytes.append(header)
        bytes.append(payload)
        return bytes
    }

    static func decode(_ bytes: Data, expecting key: DerivedAssetKey) -> Data? {
        let bytes = Data(bytes)
        guard bytes.count >= magic.count + 8, bytes.prefix(magic.count) == magic else { return nil }
        let lengthBytes = bytes.subdata(in: magic.count..<(magic.count + 8))
        let headerLength = lengthBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let headerStart = magic.count + 8
        guard headerLength <= UInt64(bytes.count - headerStart) else { return nil }
        let headerEnd = headerStart + Int(headerLength)
        guard let header = try? JSONDecoder().decode(Header.self, from: bytes.subdata(in: headerStart..<headerEnd)) else { return nil }
        let payload = bytes.subdata(in: headerEnd..<bytes.count)
        guard header.key == key, header.payloadLength == payload.count, header.payloadDigest == CanonicalDigest.hex(of: payload) else {
            return nil
        }
        return payload
    }
}

/// Where a cache root may live. `system` uses the real user `Library` (from the account database, so it is the
/// same inside the App Sandbox) plus the process's own `Library` (the container's, when sandboxed).
struct CacheRootPolicy: Sendable {
    var userLibraries: [URL]
    var isUbiquitous: @Sendable (URL) -> Bool

    static var system: CacheRootPolicy {
        var libraries = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library", isDirectory: true)]
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            libraries.append(URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Library", isDirectory: true))
        }
        return CacheRootPolicy(userLibraries: libraries) { url in
            (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        }
    }
}
