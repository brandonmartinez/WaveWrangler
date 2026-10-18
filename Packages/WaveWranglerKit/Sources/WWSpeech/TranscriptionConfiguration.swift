import Foundation
import WWWhisperNative

public enum TranscriptionBackend: String, Sendable, CaseIterable {
    case automatic, cpu, metal

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .cpu: "CPU / Accelerate"
        case .metal: "CPU + GPU / Metal"
        }
    }
}

public enum TranscriptionThreads: Int, Sendable, CaseIterable {
    case one = 1, two = 2, four = 4, eight = 8
}

public enum TranscriptionConfigurationError: Error, Sendable, LocalizedError {
    case metalUnavailable
    case resourceBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "The requested Metal backend is unavailable or could not initialize. No CPU substitution was made. Choose CPU in Settings > Transcription and retry."
        case .resourceBudgetExceeded:
            "This transcription exceeds the app-wide memory or thread budget before loading audio or weights. Choose fewer CPU threads, Base English, or a source with fewer channels."
        }
    }
}

/// Resolved once before a job starts; preferences never retarget active or queued work.
public struct TranscriptionConfiguration: Sendable, Equatable {
    public let requestedBackend: TranscriptionBackend
    public let backend: TranscriptionBackend
    public let threads: TranscriptionThreads
    public static var metalAvailable: Bool { ww_whisper_metal_available() == 1 }
    public static let cpu = Self(requested: .cpu, resolved: .cpu, threads: .four)

    private init(requested: TranscriptionBackend, resolved: TranscriptionBackend, threads: TranscriptionThreads) {
        requestedBackend = requested
        backend = resolved
        self.threads = threads
    }

    public static func resolve(
        backend: TranscriptionBackend, threads: TranscriptionThreads,
        metalAvailable: Bool = Self.metalAvailable
    ) throws -> Self {
        if backend == .metal, !metalAvailable { throw TranscriptionConfigurationError.metalUnavailable }
        let resolved: TranscriptionBackend = backend == .automatic ? (metalAvailable ? .metal : .cpu) : backend
        return Self(requested: backend, resolved: resolved, threads: threads)
    }

    public func revision(weights: LocalWhisperWeights) -> String {
        "whisper.cpp/1.6.2+ww-token-bounds-v1+metal-v1/\(weights.rawValue)/\(weights.sha256)/verbatim-v1/requested=\(requestedBackend.rawValue);backend=\(backend.rawValue);threads=\(threads.rawValue)"
    }
}

public struct TranscriptionResources: Sendable, Equatable {
    public let memoryBytes: Int
    public let cpuThreads: Int
    public let metalWorkers: Int

    public init(memoryBytes: Int = 0, cpuThreads: Int = 0, metalWorkers: Int = 0) {
        self.memoryBytes = memoryBytes
        self.cpuThreads = cpuThreads
        self.metalWorkers = metalWorkers
    }

    public init(weights: LocalWhisperWeights, configuration: TranscriptionConfiguration, renderBytes: Int = 32 << 20) throws {
        // Includes independently retained verified bytes, native weights/graphs, and resampling buffers.
        // Add the lane's multichannel renderer envelope before loading either audio or the model.
        let base = weights == .turbo ? 3 << 30 : 768 << 20
        guard renderBytes >= 0, renderBytes <= Int.max - base else {
            throw TranscriptionConfigurationError.resourceBudgetExceeded
        }
        memoryBytes = base + renderBytes
        cpuThreads = configuration.threads.rawValue
        metalWorkers = configuration.backend == .metal ? 1 : 0
    }
}

public struct TranscriptionResourceBudget: Sendable {
    public let memoryBytes: Int
    public let cpuThreads: Int
    public let metalWorkers: Int

    public init(memoryBytes: Int, cpuThreads: Int, metalWorkers: Int) {
        self.memoryBytes = memoryBytes
        self.cpuThreads = cpuThreads
        self.metalWorkers = metalWorkers
    }

    public static var system: Self {
        Self(memoryBytes: Int(min(16 << 30, max(4 << 30, ProcessInfo.processInfo.physicalMemory / 4))),
             cpuThreads: min(16, max(1, ProcessInfo.processInfo.activeProcessorCount)), metalWorkers: 2)
    }
}
