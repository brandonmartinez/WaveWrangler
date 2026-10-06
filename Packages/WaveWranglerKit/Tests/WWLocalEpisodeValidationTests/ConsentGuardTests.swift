import Foundation
import Testing

// Always-on (CI included) unit tests of the consent guards, using synthetic temporary directories only.
@Suite("Local episode harness consent guards")
struct ConsentGuardTests {
    /// A synthetic layout under a fresh temporary root: an "episode" folder, a fake repository root and a fake
    /// home directory. It is removed by `cleanUp()`.
    struct Layout {
        let root: URL
        var episode: URL { root.appendingPathComponent("episode", isDirectory: true) }
        var repository: URL { root.appendingPathComponent("repository", isDirectory: true) }
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("wwlev-guard-\(UUID().uuidString)", isDirectory: true)
            for directory in [episode, repository, home] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func directory(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func check(_ scratch: URL, episode: URL? = nil) throws -> URL {
            try ConsentGuards.checkScratch(scratch, episode: episode ?? self.episode, repositoryRoot: repository, home: home)
        }

        func refusal(_ scratch: URL, episode: URL? = nil) -> String? {
            do {
                _ = try check(scratch, episode: episode)
                return nil
            } catch let error as HarnessError {
                return error.description
            } catch {
                return "unexpected \(type(of: error))"
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func acceptsAFreshSiblingDirectoryAndReturnsItResolved() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let scratch = try layout.directory("scratch")
        let resolved = try layout.check(scratch)
        #expect(resolved == ConsentGuards.realPath(scratch))
    }

    @Test func refusesTheEpisodeFolderItsDescendantsAndItsAncestors() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        #expect(layout.refusal(layout.episode) == "scratch is the approved folder")
        #expect(layout.refusal(try layout.directory("episode/nested/scratch")) == "scratch is inside the approved folder")
        let above = try layout.directory("above")
        let episodeBelow = try layout.directory("above/deeper/episode")
        #expect(layout.refusal(above, episode: episodeBelow) == "scratch contains the approved folder")
    }

    @Test func refusesASymlinkThatResolvesIntoTheEpisodeFolder() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let target = try layout.directory("episode/inner")
        let link = layout.root.appendingPathComponent("innocent-looking-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(layout.refusal(link) == "scratch is inside the approved folder")
    }

    @Test func refusesAnEpisodeReachedThroughASymlinkAboveTheScratch() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let scratch = try layout.directory("episode/scratch")
        let episodeLink = layout.root.appendingPathComponent("episode-link")
        try FileManager.default.createSymbolicLink(at: episodeLink, withDestinationURL: layout.episode)
        #expect(layout.refusal(scratch, episode: episodeLink) == "scratch is inside the approved folder")
    }

    @Test func refusesTheRepositoryAndCloudSyncedFolders() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        #expect(layout.refusal(try layout.directory("repository/.build/scratch")) == "scratch is inside the repository")
        #expect(layout.refusal(try layout.directory("home/Library/Mobile Documents/com~apple~CloudDocs/scratch")) == "scratch is inside a cloud-synced folder")
        #expect(layout.refusal(try layout.directory("home/Library/CloudStorage/Provider/scratch")) == "scratch is inside a cloud-synced folder")
        // Elsewhere under the home Library is not a synced root.
        #expect(layout.refusal(try layout.directory("home/Library/Caches/scratch")) == nil)
    }

    @Test func refusesMissingFilesAndNonEmptyDirectories() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        #expect(layout.refusal(layout.root.appendingPathComponent("missing")) == "scratch directory missing or unresolvable")
        let file = layout.root.appendingPathComponent("plain-file")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
        #expect(layout.refusal(file) == "scratch is not a directory")
        let used = try layout.directory("used")
        #expect(FileManager.default.createFile(atPath: used.appendingPathComponent("leftover").path, contents: Data([1])))
        #expect(layout.refusal(used) == "scratch directory not empty")
    }

    @Test func refusalsNeverContainThePaths() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let refusals = [
            layout.refusal(layout.episode),
            layout.refusal(try layout.directory("episode/x")),
            layout.refusal(try layout.directory("repository/x")),
            layout.refusal(layout.root.appendingPathComponent("missing")),
        ].compactMap { $0 }
        #expect(refusals.count == 4)
        for refusal in refusals {
            #expect(!refusal.contains(layout.root.lastPathComponent))
            #expect(!refusal.contains("/"))
        }
    }

    @Test func derivedRepositoryRootIsThisRepository() {
        let root = ConsentGuards.repositoryRoot
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Packages/WaveWranglerKit/Package.swift").path))
    }

    @Test func hashingMatchesAKnownDigest() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let file = layout.root.appendingPathComponent("abc")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("abc".utf8)))
        #expect(try ConsentGuards.sha256(file, label: "S01") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hashingErrorsCarryOnlyTheLabelAndErrno() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let secretName = "secret-name-\(UUID().uuidString).wav"

        // Open failures: a missing item, and a directory (Foundation refuses to open it).
        let missing = layout.root.appendingPathComponent(secretName)
        let openFailure = #expect(throws: HarnessError.self) { try ConsentGuards.sha256(missing, label: "S07") }
        #expect(openFailure?.description == "SHA-256 of S07: open failed, errno \(ENOENT)")
        let directory = try layout.directory(secretName + "-dir")
        let directoryFailure = #expect(throws: HarnessError.self) { try ConsentGuards.sha256(directory, label: "S09") }
        #expect(directoryFailure?.description.hasPrefix("SHA-256 of S09: open failed, errno ") == true)

        // Read failure: a write-only handle cannot be read (EBADF).
        let file = layout.root.appendingPathComponent(secretName + "-file")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3])))
        let writeOnly = try FileHandle(forWritingTo: file)
        defer { try? writeOnly.close() }
        let readFailure = #expect(throws: HarnessError.self) { try ConsentGuards.digest(writeOnly, label: "S08") }
        #expect(readFailure?.description == "SHA-256 of S08: read failed, errno \(EBADF)")

        for failure in [openFailure, directoryFailure, readFailure].compactMap({ $0 }) {
            #expect(!failure.description.contains(secretName))
            #expect(!failure.description.contains(layout.root.lastPathComponent))
            #expect(!failure.description.contains("/"))
        }
    }

    @Test func errnoDescriptionFollowsTheUnderlyingErrorChain() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
            NSFilePathErrorKey: "/private/secret/path.wav",
            NSUnderlyingErrorKey: posix,
        ])
        #expect(ConsentGuards.errnoDescription(cocoa) == "errno \(EACCES)")
        #expect(ConsentGuards.errnoDescription(NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSFilePathErrorKey: "/x/y"])) == "errno unknown")
    }
}
