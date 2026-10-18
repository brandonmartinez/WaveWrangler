import Foundation

struct CleanupTranscriptionProgress: Sendable, Equatable {
    enum Stage: Sendable, Equatable { case waiting, loading, rendering, recognizing, completedWindow, verifying }
    struct ActiveSpeaker: Sendable, Equatable, Identifiable {
        var id: Int { speakerIndex }
        let speaker: String
        let speakerIndex: Int
        let windowIndex: Int
        let windowCount: Int
        let alignedStart: Double
        let alignedEnd: Double
        let stage: Stage
    }
    let stage: Stage
    let speaker: String
    let speakerIndex: Int
    let speakerCount: Int
    let windowIndex: Int
    let windowCount: Int
    let alignedStart: Double
    let alignedEnd: Double
    var completedSeconds: Double
    let totalSeconds: Double
    var sequence: UInt64 = 0
    var workerLimit = 1
    var activeSpeakers: [ActiveSpeaker] = []

    var fraction: Double { min(1, max(0, completedSeconds / totalSeconds)) }
    var heading: String {
        if stage == .verifying { return "Finalizing: verifying sources and accepted timing…" }
        if activeSpeakers.count > 1 { return "Processing \(activeSpeakers.count) speakers concurrently…" }
        if let active = activeSpeakers.first {
            if active.stage == .loading { return "Loading verified local weights for \(active.speaker)…" }
            return active.stage == .rendering
                ? "Preparing aligned audio for \(active.speaker)…" : "Transcribing \(active.speaker)…"
        }
        if sequence > 0, completedSeconds < totalSeconds { return "Waiting for the shared worker, memory, or thread budget…" }
        switch stage {
        case .waiting: return "Waiting for the shared worker, memory, or thread budget…"
        case .loading: return "Loading verified local weights for \(speaker)…"
        case .rendering: return "Preparing aligned audio for \(speaker)…"
        case .recognizing: return "Transcribing \(speaker)…"
        case .completedWindow: return "Recognized chunk \(windowIndex) for \(speaker)"
        case .verifying: return "Finalizing: verifying sources and accepted timing…"
        }
    }
}

actor CleanupTranscriptionReporter {
    private let sink: @Sendable (CleanupTranscriptionProgress) async -> Void
    private let workerLimit: Int
    private var completed: [Int: Double] = [:]
    private var active: [Int: CleanupTranscriptionProgress.ActiveSpeaker] = [:]
    private var sequence: UInt64 = 0

    init(workerLimit: Int, sink: @escaping @Sendable (CleanupTranscriptionProgress) async -> Void) {
        self.workerLimit = workerLimit
        self.sink = sink
    }

    func report(_ update: CleanupTranscriptionProgress) async {
        if update.speakerIndex > 0, update.stage != .verifying {
            completed[update.speakerIndex] = max(completed[update.speakerIndex] ?? 0, update.completedSeconds)
            if update.stage == .completedWindow, update.windowIndex == update.windowCount {
                active[update.speakerIndex] = nil
            } else {
                active[update.speakerIndex] = .init(speaker: update.speaker, speakerIndex: update.speakerIndex,
                    windowIndex: update.windowIndex, windowCount: update.windowCount,
                    alignedStart: update.alignedStart, alignedEnd: update.alignedEnd, stage: update.stage)
            }
        }
        var packet = update
        packet.completedSeconds = update.stage == .verifying
            ? update.totalSeconds : min(update.totalSeconds, completed.values.reduce(0, +))
        packet.workerLimit = workerLimit
        packet.activeSpeakers = active.values.sorted { $0.speakerIndex < $1.speakerIndex }
        sequence += 1
        packet.sequence = sequence
        await sink(packet)
    }
}

struct CleanupTranscriptionStatus {
    let startedAt: Date
    private(set) var progress: CleanupTranscriptionProgress?
    private var processingStartedAt: Date?
    private var lastCompletionAt: Date?

    init(startedAt: Date) { self.startedAt = startedAt }

    @discardableResult
    mutating func record(_ update: CleanupTranscriptionProgress, at now: Date = Date()) -> Bool {
        // Concurrent callbacks can arrive at the UI after a newer aggregate packet.
        guard update.sequence >= (progress?.sequence ?? 0) else { return false }
        if processingStartedAt == nil, update.stage != .waiting { processingStartedAt = now }
        if update.completedSeconds > (progress?.completedSeconds ?? 0) { lastCompletionAt = now }
        progress = update
        return true
    }

    func elapsed(at now: Date) -> Double { max(0, now.timeIntervalSince(startedAt)) }

    func estimatedRemaining(at now: Date) -> Double? {
        guard let progress, progress.completedSeconds > 0, progress.completedSeconds < progress.totalSeconds,
              let first = processingStartedAt, let last = lastCompletionAt, last > first else { return nil }
        let estimate = (progress.totalSeconds - progress.completedSeconds) / progress.completedSeconds
            * last.timeIntervalSince(first) - max(0, now.timeIntervalSince(last))
        return estimate > 0 ? estimate : nil
    }

    static func time(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
