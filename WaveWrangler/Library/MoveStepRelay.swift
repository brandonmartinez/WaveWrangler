import Foundation
import WWPersistence

/// Relays `LibraryStore.onMoveStep` reports to main-actor UI state, in order (ST-33 step 3). Also compiled into the
/// unhosted WaveWranglerTests target, which drives it from a real `LibraryStore` move.
enum MoveStepRelay {
    typealias Sleeper = @MainActor @Sendable (Duration) async -> Void

    /// Each reported step is shown on the main actor in report order.
    /// `holdAfterChecking` (UI tests only; zero otherwise) keeps "checking" visible that long before the end.
    static func handler(
        holdAfterChecking: Duration,
        sleep: @escaping Sleeper = { try? await Task.sleep(for: $0) },
        current: @escaping @MainActor () -> LibraryMoveStep?,
        show: @escaping @MainActor (LibraryMoveStep?) -> Void
    ) -> @Sendable (LibraryMoveStep?) -> Void {
        let queue = MoveQueue()
        return { step in
            queue.append(startingNewMove: step == .copying) { generation in
                guard queue.isCurrent(generation) else { return }
                if step == nil, holdAfterChecking > .zero, current() == .checking {
                    await sleep(holdAfterChecking)
                }
                guard queue.isCurrent(generation) else { return }
                show(step)
            }
        }
    }

    private final class MoveQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        private var tail: Task<Void, Never>?

        func append(
            startingNewMove: Bool,
            _ operation: @escaping @MainActor @Sendable (Int) async -> Void
        ) {
            lock.withLock {
                if startingNewMove {
                    generation += 1
                    tail = nil
                }
                let operationGeneration = generation
                let previous = tail
                tail = Task { @MainActor in
                    if let previous {
                        await previous.value
                    }
                    await operation(operationGeneration)
                }
            }
        }

        func isCurrent(_ operationGeneration: Int) -> Bool {
            lock.withLock { operationGeneration == generation }
        }
    }
}
