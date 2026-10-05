import Dispatch
import Foundation
import Synchronization

/// User autosave preference (C6): ON by default, configurable delay, or OFF. Explicit Save always works.
public struct AutosavePreference: Sendable, Equatable, Codable {
    /// UserDefaults keys. A missing key means the default.
    public static let enabledKey = "WWAutosaveEnabled"
    public static let delayKey = "WWAutosaveDelaySeconds"

    /// Bounded set of quiescence delays (seconds after the last edit).
    public static let allowedDelays: [Double] = [1, 2, 5, 10, 30]
    public static let defaultDelay: Double = 1
    /// A device-local recovery draft is recorded after this quiet period whenever the configured publication
    /// delay is longer, so a longer cadence never removes the ≤2 s recovery checkpoint.
    public static let recoveryDraftDelay: Double = 1

    public var enabled: Bool
    public var delaySeconds: Double

    public init(enabled: Bool = true, delaySeconds: Double = AutosavePreference.defaultDelay) {
        self.enabled = enabled
        self.delaySeconds = Self.allowedDelays.contains(delaySeconds) ? delaySeconds : Self.defaultDelay
    }

    public init(defaults: UserDefaults) {
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let delay = defaults.object(forKey: Self.delayKey) as? Double ?? Self.defaultDelay
        self.init(enabled: enabled, delaySeconds: delay)
    }

    public func write(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(delaySeconds, forKey: Self.delayKey)
    }

    /// Whether a separate recovery draft is needed before the configured publication fires.
    public var needsRecoveryDraft: Bool { enabled && delaySeconds > Self.recoveryDraftDelay }
}

/// Thread-safe holder of the *actual* enabled flag, consulted at every scheduling boundary and again when
/// queued automatic work starts.
public final class AutosaveGate: Sendable {
    private let state: Mutex<AutosavePreference>

    public init(_ preference: AutosavePreference = AutosavePreference()) {
        state = Mutex(preference)
    }

    public var preference: AutosavePreference {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    public var isEnabled: Bool { preference.enabled }
}

/// What a quiescence timer asks its owner to do.
public enum QuiescentWork: Sendable, Equatable {
    /// Publish the document (automatic save) — only issued while the gate is enabled at fire time.
    case publish
    /// Record a device-local recovery draft (not a save) — only while enabled.
    case recoveryDraft
}

/// Debounces edits into quiescent automatic work. Checks the gate when scheduling *and* when a queued timer
/// fires, so work queued before autosave was turned OFF is skipped (reported via `onSkipped`), never run and
/// never reported as success.
public final class QuiescenceScheduler: Sendable {
    public typealias Work = @Sendable (QuiescentWork) -> Void

    private struct State {
        var generation = 0
        var lastEdit: ContinuousClock.Instant?
    }

    private let gate: AutosaveGate
    private let queue: DispatchQueue
    private let work: Work
    private let onSkipped: @Sendable () -> Void
    private let state = Mutex(State())

    public init(gate: AutosaveGate, queue: DispatchQueue, onSkipped: @escaping @Sendable () -> Void = {}, work: @escaping Work) {
        self.gate = gate
        self.queue = queue
        self.work = work
        self.onSkipped = onSkipped
    }

    /// Notes an edit and (re)schedules quiescent work. Returns false when autosave is OFF (nothing scheduled).
    @discardableResult
    public func noteEdit() -> Bool {
        let generation = state.withLock { state in
            state.generation += 1
            state.lastEdit = .now
            return state.generation
        }
        let preference = gate.preference
        guard preference.enabled else { return false }
        if preference.needsRecoveryDraft {
            schedule(.recoveryDraft, after: AutosavePreference.recoveryDraftDelay, generation: generation)
        }
        schedule(.publish, after: preference.delaySeconds, generation: generation)
        return true
    }

    /// Re-schedules publication for pending edits (e.g. autosave turned back ON).
    public func reschedulePending() {
        _ = noteEdit()
    }

    /// Invalidates any queued work (e.g. after an explicit Save or close).
    public func cancelPending() {
        state.withLock { $0.generation += 1 }
    }

    public var lastEdit: ContinuousClock.Instant? { state.withLock { $0.lastEdit } }

    private func schedule(_ kind: QuiescentWork, after seconds: Double, generation: Int) {
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            guard state.withLock({ $0.generation == generation }) else { return }
            guard gate.isEnabled else {
                if kind == .publish { onSkipped() }
                return
            }
            work(kind)
        }
    }
}
