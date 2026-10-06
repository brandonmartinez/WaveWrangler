import Foundation
import Testing
import WWCore
import WWPersistence

/// The "Moving library — checking copy…" progress comes from the store's real step reports (#161 review): a real
/// `LibraryStore` move, registered through `onMoveStep` with the app's relay, shows copying → checking → none.
@MainActor
@Suite("Move step relay")
struct MoveStepRelayTests {
    private final class Shown {
        var steps: [LibraryMoveStep?] = []
        var current: LibraryMoveStep?
    }

    private func store(_ root: URL) -> LibraryStore {
        LibraryStore(
            containerFolder: root.appending(path: "Container", directoryHint: .isDirectory),
            settings: InMemorySettings(),
            bookmarks: PathBookmarks(),
            recovery: RecoveryStore(root: root.appending(path: "Recovery", directoryHint: .isDirectory)),
            indexCache: LibraryIndexCache(url: root.appending(path: "index.json"))
        )
    }

    private func shownSteps(hold: Duration) async throws -> [LibraryMoveStep?] {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveStepRelay-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = store(root)
        try await Self.seed(library)
        let shown = Shown()
        await library.onMoveStep(MoveStepRelay.handler(holdAfterChecking: hold, current: { shown.current }) { step in
            shown.current = step
            shown.steps.append(step)
        })
        guard case .success(.moved) = await library.moveLibrary(to: root.appending(path: "Destination", directoryHint: .isDirectory)) else {
            Issue.record("move")
            return []
        }
        for _ in 0..<100 where shown.steps.last != .some(nil) { try await Task.sleep(for: .milliseconds(20)) }
        return shown.steps
    }

    nonisolated private static func seed(_ library: LibraryStore) async throws {
        _ = await library.load()
        _ = try await library.update { var model = $0; model.collections.append(LibraryCollection(name: "Moved")); return model }
    }

    @Test func realMoveShowsCopyingThenCheckingThenNothing() async throws {
        #expect(try await shownSteps(hold: .zero) == [.copying, .checking, nil])
    }

    @Test func heldCheckingStepStaysUntilTheHoldEnds() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let steps = try await shownSteps(hold: .milliseconds(300))
        #expect(steps == [.copying, .checking, nil])
        #expect(clock.now - start >= .milliseconds(300), "the end is shown only after the hold")
    }
}

private final class InMemorySettings: LibraryLocationSettingsStoring, @unchecked Sendable {
    private var setting = LibraryLocationSetting()
    func load() -> LibraryLocationSetting { setting }
    func save(_ setting: LibraryLocationSetting) throws { self.setting = setting }
}

private struct PathBookmarks: FolderBookmarking {
    func bookmark(for folder: URL) throws -> Data { Data(folder.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true), false)
    }
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}
