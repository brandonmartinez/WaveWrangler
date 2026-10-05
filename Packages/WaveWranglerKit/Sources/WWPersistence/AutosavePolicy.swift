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
    /// Quiet period after which an edit burst counts as settled (C2b "at quiescence").
    public static let quiescenceSeconds: Double = 0.5
    /// A verified publication must be expected by this long after the last edit (≤2 s gate with a ≥0.5 s
    /// margin); otherwise an unpublished edit checkpoint is written at quiescence.
    public static let publicationExpectedWithin: Double = 1.5
    /// Measured headroom for stage + flush + verify + read-back on this host (p95 well under this; see tests).
    public static let publicationAllowance: Double = 0.25

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

    /// Whether an unpublished edit checkpoint must be written at quiescence because a verified publication is
    /// not expected within `publicationExpectedWithin` of the last edit.
    public var needsEditCheckpoint: Bool {
        enabled && delaySeconds + Self.publicationAllowance > Self.publicationExpectedWithin
    }
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
    /// Record a C2b unpublished edit checkpoint (not a save) — only while enabled.
    case editCheckpoint
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
        if preference.needsEditCheckpoint {
            schedule(.editCheckpoint, after: AutosavePreference.quiescenceSeconds, generation: generation)
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
