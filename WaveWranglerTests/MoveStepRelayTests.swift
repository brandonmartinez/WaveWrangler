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

    private actor LivenessGate {
        private struct Timeout: Error, CustomStringConvertible {
            let label: String
            var description: String { "timed out waiting for \(label)" }
        }

        private var finished = false
        private var waiter: CheckedContinuation<Void, any Error>?

        func open() {
            guard !finished else { return }
            finished = true
            waiter?.resume()
            waiter = nil
        }

        func wait(for label: String) async throws {
            if finished { return }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self.fail(Timeout(label: label))
            }
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { waiter = $0 }
        }

        private func fail(_ error: any Error) {
            guard !finished else { return }
            finished = true
            waiter?.resume(throwing: error)
            waiter = nil
        }
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

    private func shownSteps(
        hold: Duration,
        shown: Shown = Shown(),
        sleep: @escaping MoveStepRelay.Sleeper = { try? await Task.sleep(for: $0) }
    ) async throws -> [LibraryMoveStep?] {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveStepRelay-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = store(root)
        try await Self.seed(library)
        let finished = LivenessGate()
        await library.onMoveStep(MoveStepRelay.handler(holdAfterChecking: hold, sleep: sleep, current: { shown.current }) { step in
            shown.current = step
            shown.steps.append(step)
            if step == nil {
                Task { await finished.open() }
            }
        })
        guard case .success(.moved) = await library.moveLibrary(to: root.appending(path: "Destination", directoryHint: .isDirectory)) else {
            Issue.record("move")
            return []
        }
        try await finished.wait(for: "the move relay to report its end")
        return shown.steps
    }

    nonisolated private static func seed(_ library: LibraryStore) async throws {
        _ = await library.load()
        _ = try await library.update { var model = $0; model.collections.append(LibraryCollection(name: "Moved")); return model }
    }

    @Test func realMoveShowsCopyingThenCheckingThenNothing() async throws {
        #expect(try await shownSteps(hold: .zero) == [.copying, .checking, nil])
    }

    @Test func checkingReportedJustBeforeTheEndIsShownForTheHold() async throws {
        let shown = Shown()
        let sleepStarted = LivenessGate()
        let releaseSleep = LivenessGate()
        let finished = LivenessGate()
        let report = MoveStepRelay.handler(holdAfterChecking: .milliseconds(300), sleep: { duration in
            #expect(duration == .milliseconds(300))
            await sleepStarted.open()
            do {
                try await releaseSleep.wait(for: "the checking hold to be released")
            } catch {
                Issue.record(error)
            }
        }, current: { shown.current }) { step in
            shown.current = step
            shown.steps.append(step)
            if step == nil {
                Task { await finished.open() }
            }
        }
        report(.copying)
        report(.checking)
        report(nil)
        try await sleepStarted.wait(for: "the checking hold to start")
        #expect(shown.steps == [.copying, .checking])
        await releaseSleep.open()
        try await finished.wait(for: "the held end report")
        #expect(shown.steps == [.copying, .checking, nil])
    }

    @Test func heldCheckingStepStaysUntilTheHoldEnds() async throws {
        let shown = Shown()
        let sleepStarted = LivenessGate()
        let releaseSleep = LivenessGate()
        let move = Task {
            try await shownSteps(hold: .milliseconds(300), shown: shown) { duration in
                #expect(duration == .milliseconds(300))
                await sleepStarted.open()
                do {
                    try await releaseSleep.wait(for: "the real move hold to be released")
                } catch {
                    Issue.record(error)
                }
            }
        }
        try await sleepStarted.wait(for: "the real move checking hold to start")
        #expect(shown.steps == [.copying, .checking])
        await releaseSleep.open()
        #expect(try await move.value == [.copying, .checking, nil])
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
