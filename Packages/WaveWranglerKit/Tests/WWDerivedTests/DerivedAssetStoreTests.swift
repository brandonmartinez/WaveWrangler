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
