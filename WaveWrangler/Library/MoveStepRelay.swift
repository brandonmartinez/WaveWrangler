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
        let queue = Queue()
        return { step in
            queue.append {
                if step == nil, holdAfterChecking > .zero, current() == .checking {
                    await sleep(holdAfterChecking)
                }
                show(step)
            }
        }
    }

    private final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var tail: Task<Void, Never>?

        func append(_ operation: @escaping @MainActor @Sendable () async -> Void) {
            lock.withLock {
                let previous = tail
                tail = Task { @MainActor in
                    if let previous {
                        await previous.value
                    }
                    await operation()
                }
            }
        }
    }
}
