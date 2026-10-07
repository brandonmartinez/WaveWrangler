import Foundation
import Testing
import WWCore
@testable import WWDerived
import WWPersistence

@Suite("Derived asset store")
struct DerivedAssetStoreTests {
    @Test func stagesVerifiesAndPublishesIntoTheCacheOnly() throws {
        let directory = try TemporaryDirectory("store")
        let store = try makeStore(directory)
        let key = DerivedAssetKey.sample()
        let staged = try store.stage(Data("peaks".utf8), for: key)
        #expect(store.payload(for: key) == nil, "staged is not published")
        try store.commit(staged)
        #expect(store.payload(for: key) == Data("peaks".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path) == [key.digest])
    }

    @Test func discardedStagingLeavesNothing() throws {
        let directory = try TemporaryDirectory("store")
        let store = try makeStore(directory)
        let key = DerivedAssetKey.sample()
        store.discard(try store.stage(Data([1, 2, 3]), for: key))
        #expect(store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path).isEmpty)
    }

    /// Derived assets never live next to originals: a cache root that is (or is inside) any source's folder is
    /// refused, including through a symbolic link.
    @Test func refusesACacheRootInsideASourceFolder() throws {
        let directory = try TemporaryDirectory("store")
        let media = try directory.folder("media")
        let source = try directory.writeWAV("media/host.wav", frames: 16, seed: 1)
        try FileManager.default.createSymbolicLink(at: directory.file("alias"), withDestinationURL: media)
        let insideRoots = [
            media,
            media.appendingPathComponent("WaveWrangler Cache", isDirectory: true),
            directory.file("alias").appendingPathComponent("cache", isDirectory: true),
        ]
        for root in insideRoots {
            #expect(throws: DerivedAssetStoreError.self, "\(root.path)") {
                try DerivedAssetStore(root: root, sourceLocations: [source])
            }
        }
        #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent("WaveWrangler Cache").path), "nothing created")
        #expect(try FileManager.default.contentsOfDirectory(atPath: media.path) == ["host.wav"])

        let sibling = try DerivedAssetStore(root: directory.file("cache"), sourceLocations: [source])
        #expect(throws: DerivedAssetStoreError.self) {
            try sibling.checkOutside(sourceLocations: [sibling.root.appendingPathComponent("x.wav")])
        }
        #expect(throws: DerivedAssetStoreError.rootNotAbsolute) {
            try DerivedAssetStore(root: URL(string: "https://example.invalid/cache")!, sourceLocations: [])
        }
    }

    /// Review #182 finding 4: containment compares canonical paths, so a differently-cased spelling of a
    /// source folder is still refused (APFS is case-insensitive).
    @Test func refusesADifferentlyCasedSpellingOfASourceFolder() throws {
        let directory = try TemporaryDirectory("store")
        let media = try directory.folder("Media")
        let source = try directory.writeWAV("Media/Host.wav", frames: 16, seed: 1)
        let policy = CacheRootPolicy(userLibraries: [directory.file("home/Library")]) { _ in false }
        for root in [directory.file("media"), directory.file("MEDIA/cache"), directory.file("mEdIa/Library/Caches/ww")] {
            #expect(throws: DerivedAssetStoreError.rootInsideSourceLocation(root: DerivedAssetStore.resolved(root).path, source: source.path), "\(root.path)") {
                try DerivedAssetStore(root: root, sourceLocations: [source], rootPolicy: policy)
            }
        }
        // A differently-cased source location is matched too.
        #expect(throws: DerivedAssetStoreError.self) {
            try DerivedAssetStore(root: media.appendingPathComponent("cache"), sourceLocations: [directory.file("MEDIA/HOST.WAV")], rootPolicy: policy)
        }
        // A stale location hint (folder not on disk, so resolution cannot correct its case) is folded too.
        #expect(throws: DerivedAssetStoreError.self) {
            try DerivedAssetStore(root: directory.file("media/offline/cache"), sourceLocations: [directory.file("Media/Offline/take.wav")], rootPolicy: policy)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: media.path) == ["Host.wav"], "nothing created among originals")
    }

    /// The `Library` exception is exactly the user's Library: `<source folder>/Library` gets none, while a source
    /// in the home folder still allows `~/Library/Caches` (in any letter case).
    @Test func onlyTheUserLibraryIsExemptFromSourceFolderContainment() throws {
        let directory = try TemporaryDirectory("store")
        let home = try directory.folder("home")
        let policy = CacheRootPolicy(userLibraries: [home.appendingPathComponent("Library")]) { _ in false }

        let media = try directory.folder("media")
        let source = try directory.writeWAV("media/host.wav", frames: 16, seed: 1)
        #expect(throws: DerivedAssetStoreError.self) {
            try DerivedAssetStore(root: media.appendingPathComponent("Library/Caches/ww"), sourceLocations: [source], rootPolicy: policy)
        }
        #expect(throws: DerivedAssetStoreError.self, "the real policy gives <source folder>/Library no exception either") {
            try DerivedAssetStore(root: media.appendingPathComponent("Library/Caches/ww"), sourceLocations: [source])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: media.path) == ["host.wav"], "nothing created among originals")

        let homeSource = try directory.writeWAV("home/interview.wav", frames: 16, seed: 2)
        for root in [home.appendingPathComponent("Library/Caches/ww"), directory.file("HOME/library/Caches/ww2")] {
            _ = try DerivedAssetStore(root: root, sourceLocations: [homeSource], rootPolicy: policy)
        }
        #expect(throws: DerivedAssetStoreError.self, "the home folder itself is still refused") {
            try DerivedAssetStore(root: home.appendingPathComponent("Caches/ww"), sourceLocations: [homeSource], rootPolicy: policy)
        }
    }

    /// Derived data stays local: iCloud Drive, File Provider (CloudStorage) and ubiquitous locations are refused
    /// before anything is created, even with no sources at all.
    @Test func refusesACacheRootInCloudStorage() throws {
        let directory = try TemporaryDirectory("store")
        let home = try directory.folder("home")
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let policy = CacheRootPolicy(userLibraries: [library]) { _ in false }
        let cloudRoots = [
            library.appendingPathComponent("CloudStorage/OneDrive-Personal/ww", isDirectory: true),
            directory.file("HOME/Library/cloudstorage/Box/ww"),
            library.appendingPathComponent("Mobile Documents/com~apple~CloudDocs/ww", isDirectory: true),
        ]
        for root in cloudRoots {
            #expect(throws: DerivedAssetStoreError.rootInCloudStorage(root: DerivedAssetStore.resolved(root).path), "\(root.path)") {
                try DerivedAssetStore(root: root, sourceLocations: [], rootPolicy: policy)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: library.path), "nothing created")

        // A ubiquitous location anywhere (reported by the volume's metadata) is refused too.
        let synced = try directory.folder("synced")
        let ubiquitous = CacheRootPolicy(userLibraries: [library]) { url in url.standardizedFileURL.path.hasSuffix("/synced") }
        #expect(throws: DerivedAssetStoreError.self) {
            try DerivedAssetStore(root: synced.appendingPathComponent("cache/ww"), sourceLocations: [], rootPolicy: ubiquitous)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: synced.path).isEmpty, "nothing created")
        _ = try DerivedAssetStore(root: directory.file("local/ww"), sourceLocations: [], rootPolicy: ubiquitous)

        #expect(throws: DerivedAssetStoreError.self, "the real policy refuses the user's CloudStorage") {
            try DerivedAssetStore(root: try #require(CacheRootPolicy.system.userLibraries.last).appendingPathComponent("CloudStorage/WaveWranglerTestNonexistent-\(UUID().uuidString)/ww"), sourceLocations: [])
        }
    }

    @Test func damagedOrMismatchedAssetsAreTreatedAsMissing() throws {
        let directory = try TemporaryDirectory("store")
        let store = try makeStore(directory)
        let key = DerivedAssetKey.sample()
        let otherKey = DerivedAssetKey.sample(kind: "other")
        try store.commit(try store.stage(Data("payload".utf8), for: key))
        let published = store.assetsDirectory.appendingPathComponent(key.digest)

        // A file recorded for a different key, sitting under this key's name.
        var bytes = try Data(contentsOf: published)
        let foreign = try DerivedAssetStore.encode(Data("payload".utf8), key: otherKey)
        try foreign.write(to: published)
        #expect(store.payload(for: key) == nil)

        // Truncated and bit-flipped payloads.
        try bytes.prefix(bytes.count - 1).write(to: published)
        #expect(store.payload(for: key) == nil)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: published)
        #expect(store.payload(for: key) == nil)
        try Data("garbage".utf8).write(to: published)
        #expect(store.payload(for: key) == nil)

        // Rebuilding replaces the damaged copy.
        try store.commit(try store.stage(Data("payload".utf8), for: key))
        #expect(store.payload(for: key) == Data("payload".utf8))
    }

    @Test func recoveryRemovesOnlyStagingOrphans() throws {
        let directory = try TemporaryDirectory("store")
        let store = try makeStore(directory)
        let kept = DerivedAssetKey.sample()
        try store.commit(try store.stage(Data("kept".utf8), for: kept))
        // Simulate a crash between staging and publication.
        _ = try store.stage(Data("orphan".utf8), for: DerivedAssetKey.sample(kind: "orphan"))
        _ = try store.stage(Data("orphan".utf8), for: DerivedAssetKey.sample(kind: "orphan2"))

        let reopened = try makeStore(directory)
        #expect(reopened.recover() == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: reopened.stagingDirectory.path).isEmpty)
        #expect(reopened.payload(for: kept) == Data("kept".utf8))
    }

    @Test func pruneKeepsLiveAssets() throws {
        let directory = try TemporaryDirectory("store")
        let store = try makeStore(directory)
        let live = DerivedAssetKey.sample(kind: "live")
        let dead = DerivedAssetKey.sample(kind: "dead")
        try store.commit(try store.stage(Data("a".utf8), for: live))
        try store.commit(try store.stage(Data("b".utf8), for: dead))
        #expect(store.prune(keeping: [live.digest]) == 1)
        #expect(store.payload(for: live) != nil)
        #expect(store.payload(for: dead) == nil)
    }

    @Test func pathsAreConfinedToDigestNames() throws {
        let directory = try TemporaryDirectory("store")
        let store = try makeStore(directory)
        for name in ["../escape", "", String(repeating: "A", count: 64), String(repeating: "0", count: 63)] {
            #expect(throws: DerivedAssetStoreError.notADigest(name)) { try store.assetURL(digest: name) }
        }
    }
}
