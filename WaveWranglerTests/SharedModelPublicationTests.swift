import Foundation
import Testing
import WWCore

/// #219 review, finding 1. "Start New Epoch at Anchor" computes a whole replacement model from a snapshot
/// of the shared show and then awaits persistence, activation and the split before applying it. Every
/// window on a show shares one `ShowDocumentStore`, so an edit made during any of those awaits is already
/// live, and publishing the snapshot's successor would silently discard it.
@MainActor
@Suite("Shared model publication")
struct SharedModelPublicationTests {
    /// Stands in for the shared `ShowDocumentStore`: the one value both windows write.
    private final class LiveModel {
        var model: ShowDocumentModel
        init(_ model: ShowDocumentModel) { self.model = model }

        /// Mirrors `ShowDocumentStore.applyReplacement(_:expecting:model:afterChange:)`.
        func applyReplacement(expecting expected: ShowDocumentModel, model newModel: ShowDocumentModel) -> Bool {
            guard SharedModelPublication.decide(live: model, expected: expected) == .publish else { return false }
            model = newModel
            return true
        }
    }

    private static func show(_ title: String) -> ShowDocumentModel {
        ShowDocumentModel(show: Show(title: title))
    }

    @Test func unchangedModelStillPublishes() {
        let prior = Self.show("Prior")
        #expect(SharedModelPublication.decide(live: prior, expected: prior) == .publish)
    }

    @Test func anyDifferenceSupersedesTheSnapshot() {
        #expect(SharedModelPublication.decide(live: Self.show("Edited"), expected: Self.show("Prior")) == .superseded)
    }

    /// The split's own sequence, with the concurrent edit landing inside the await. The gate is an async
    /// continuation, not a semaphore or a sleep: nothing blocks a cooperative-pool thread.
    @Test func concurrentEditDuringTheSplitIsNotOverwritten() async {
        let prior = Self.show("Prior")
        let live = LiveModel(prior)
        let split = Self.show("Split result computed from Prior")
        let concurrent = Self.show("Edited in another window")

        let gate = AsyncGate()
        let splitting = Task { @MainActor in
            // Stands in for `runtime.activate` + `runtime.split`, which both suspend.
            await gate.wait()
            return live.applyReplacement(expecting: prior, model: split)
        }

        // The other window's edit lands while the split is suspended.
        live.model = concurrent
        await gate.open()

        #expect(await splitting.value == false)
        #expect(live.model == concurrent, "the concurrent edit must survive the stale split")
    }

    /// Without a concurrent edit the same sequence still applies, so the guard does not break the feature.
    @Test func undisturbedSplitStillApplies() async {
        let prior = Self.show("Prior")
        let live = LiveModel(prior)
        let split = Self.show("Split result computed from Prior")

        let gate = AsyncGate()
        let splitting = Task { @MainActor in
            await gate.wait()
            return live.applyReplacement(expecting: prior, model: split)
        }
        await gate.open()

        #expect(await splitting.value)
        #expect(live.model == split)
    }
}

/// A one-shot async gate. `wait()` suspends until `open()` is called, with no blocking primitive.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters = []
        for continuation in resuming { continuation.resume() }
    }
}
