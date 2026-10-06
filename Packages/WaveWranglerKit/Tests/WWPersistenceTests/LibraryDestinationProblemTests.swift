import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// §5.1 step 6: a destination folder whose library this version can't use is reported with a typed problem, and
/// nothing is written to it on any path (move, Use That Library, move back into the app).
@Suite("Library destination problems")
struct LibraryDestinationProblemTests {
    /// The current library (one collection) in its container.
    private func current() async throws -> (LibraryRig, LibraryStore) {
        let rig = LibraryRig("current")
        let store = rig.store()
        _ = await store.load()
        _ = try await store.update { var library = $0; library.collections.append(LibraryCollection(name: "Mine")); return library }
        return (rig, store)
    }

    /// A folder holding a published library, then altered by `alter`.
    /// The rig is returned so its temporary directory lives as long as the test uses it.
    private func folderLibrary(_ label: String, alter: (URL) throws -> Void) async throws -> (folder: URL, file: URL, rig: LibraryRig) {
        let other = LibraryRig(label)
        let store = other.store()
        _ = await store.load()
        _ = try await store.update { var library = $0; library.collections.append(LibraryCollection(name: "Theirs")); return library }
        try alter(other.containerFile)
        return (other.container, other.containerFile, other)
    }

    @Test func newerFormatLibraryIsReportedAndNeverWritten() async throws {
        let (rig, store) = try await current(); _ = rig
        let target = try await folderLibrary("newer") { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("\"schemaVersion\":\(SchemaVersion.library)"))
            try text.replacingOccurrences(of: "\"schemaVersion\":\(SchemaVersion.library)", with: "\"schemaVersion\":99")
                .write(to: file, atomically: true, encoding: .utf8)
        }
        let before = try Data(contentsOf: target.file)
        #expect(await store.moveLibrary(to: target.folder)
            == .success(.destinationUnusable(target.file, problem: .newerFormat(found: 99, supported: SchemaVersion.library))))
        #expect(try Data(contentsOf: target.file) == before, "move: nothing written")
        guard case .failure = await store.useLibrary(in: target.folder) else {
            Issue.record("Use That Library must refuse a newer-format library")
            return
        }
        #expect(try Data(contentsOf: target.file) == before, "Use That Library: no down-save")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.folder.path).sorted() == [LibraryLocationSetting.defaultFileName],
                "no other files written into the folder")
        #expect(await store.levelState == .ready, "the current library stays in use")
        #expect(await store.library?.collections.map(\.name) == ["Mine"])
    }

    @Test func unreadableLibraryIsReportedAndNeverWritten() async throws {
        let (rig, store) = try await current(); _ = rig
        let target = try await folderLibrary("unreadable") { _ in }
        let before = try Data(contentsOf: target.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.file.path) }
        #expect(await store.moveLibrary(to: target.folder) == .success(.destinationUnusable(target.file, problem: .unreadable)))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.file.path)
        #expect(try Data(contentsOf: target.file) == before)
        #expect(await store.levelState == .ready)
    }

    @Test func nonLibraryFileIsReportedAndNeverWritten() async throws {
        let (rig, store) = try await current(); _ = rig
        let target = try await folderLibrary("notlibrary") { file in
            try Data("not a library".utf8).write(to: file)
        }
        let before = try Data(contentsOf: target.file)
        #expect(await store.moveLibrary(to: target.folder) == .success(.destinationUnusable(target.file, problem: .notALibrary)))
        #expect(try Data(contentsOf: target.file) == before)
    }

    @Test func readableLibraryIsStillOfferedForCombining() async throws {
        let (rig, store) = try await current(); _ = rig
        let target = try await folderLibrary("ready") { _ in }
        guard case .success(.destinationHasLibrary(let url, _)) = await store.moveLibrary(to: target.folder) else {
            Issue.record("a readable library in the folder is offered for Use That Library")
            return
        }
        #expect(url == target.file)
    }

    /// ST-33 step 3: a move reports copying, then checking, then that it's over.
    @Test func moveReportsCopyingThenChecking() async throws {
        let (rig, store) = try await current(); _ = rig
        let steps = StepRecorder()
        await store.onMoveStep { steps.append($0) }
        let destination = TempDirectory("move-steps").sub("Destination")
        guard case .success(.moved) = await store.moveLibrary(to: destination) else {
            Issue.record("move to an empty folder")
            return
        }
        #expect(steps.values == [.copying, .checking, nil])
        let failed = StepRecorder()
        await store.onMoveStep { failed.append($0) }
        let readOnly = TempDirectory("move-steps-ro").sub("ReadOnly")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        _ = await store.moveLibrary(to: readOnly)
        #expect(failed.values == [.copying, nil], "a failed copy is never reported as checking")
    }

    @Test func problemReasonsAreDescriptive() {
        #expect(LibraryDestinationProblem.unreadable.reason.contains("could not be read"))
        #expect(LibraryDestinationProblem.newerFormat(found: 99, supported: 2).reason.contains("format 99"))
        #expect(LibraryDestinationProblem.notALibrary.reason.contains("not a readable library"))
    }
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LibraryMoveStep?] = []
    func append(_ step: LibraryMoveStep?) { lock.withLock { recorded.append(step) } }
    var values: [LibraryMoveStep?] { lock.withLock { recorded } }
}
