import Foundation

public enum TranscriptionChunking: Sendable {
    case fixed, pausePreferred

    public var revision: String {
        switch self {
        case .fixed: "fixed-28s-context-1s-v1"
        case .pausePreferred: "pause-v1-core28-context1-lookback4-rms10ms-min300ms-cap50dB-relative20dB"
        }
    }
}

public struct TranscriptionWindow: Sendable, Equatable {
    public let coreFrames: Range<Int64>
    public let audioFrames: Range<Int64>

    public func owns(startSeconds: Double, endSeconds: Double) -> Bool {
        // Compare in window-relative coordinates, avoiding large/fractional timeline cancellation.
        let center = (startSeconds + endSeconds) * 24_000
        return center >= Double(coreFrames.lowerBound - audioFrames.lowerBound)
            && center < Double(coreFrames.upperBound - audioFrames.lowerBound)
    }
}

public enum TranscriptionChunkingError: Error, LocalizedError {
    case invalidRange, invalidPCM

    public var errorDescription: String? {
        switch self {
        case .invalidRange: "The transcription range must contain audio frames within the supported aligned timeline."
        case .invalidPCM: "The transcription boundary analysis received invalid or incorrectly sized audio."
        }
    }
}

/// Recognition boundaries only. Every aligned frame belongs to exactly one core; context is never cut authority.
public struct TranscriptionChunkPlanner: Sendable {
    public static let sampleRate: Int64 = 48_000
    private let range: Range<Int64>
    private let policy: TranscriptionChunking
    private var cursor: Int64

    public init(start: Double, end: Double, policy: TranscriptionChunking = .pausePreferred) throws {
        guard start.isFinite, end.isFinite, (-86_400...86_400).contains(start),
              (-86_400...86_400).contains(end), end > start else {
            throw TranscriptionChunkingError.invalidRange
        }
        let first = Int64((start * 48_000).rounded()), last = Int64((end * 48_000).rounded())
        guard last > first else { throw TranscriptionChunkingError.invalidRange }
        range = first..<last
        cursor = first
        self.policy = policy
    }

    /// Render just this bounded candidate, inside the lane's resource admission.
    public var candidate: TranscriptionWindow? {
        guard cursor < range.upperBound else { return nil }
        return window(endingAt: min(range.upperBound, cursor + 28 * Self.sampleRate))
    }

    public mutating func next(pcm: [Float]) throws -> TranscriptionWindow {
        try Task.checkCancellation()
        guard let candidate, pcm.count == candidate.audioFrames.count else {
            throw TranscriptionChunkingError.invalidPCM
        }
        let end: Int64
        if policy == .pausePreferred, candidate.coreFrames.upperBound < range.upperBound {
            end = try Self.pauseBoundary(candidate: candidate, pcm: pcm) ?? candidate.coreFrames.upperBound
        } else {
            end = candidate.coreFrames.upperBound
        }
        let selected = window(endingAt: end)
        cursor = end
        return selected
    }

    private func window(endingAt end: Int64) -> TranscriptionWindow {
        TranscriptionWindow(coreFrames: cursor..<end,
            audioFrames: max(range.lowerBound, cursor - Self.sampleRate)..<min(range.upperBound, end + Self.sampleRate))
    }

    // Internal minimum parameter supports a bounded threshold comparison without exposing a user control.
    static func pauseBoundary(candidate: TranscriptionWindow, pcm: [Float], minimumQuietHops: Int = 30) throws -> Int64? {
        let hop: Int64 = 480
        let maximum = candidate.coreFrames.upperBound
        let searchStart = maximum - 4 * sampleRate
        let scanEnd = candidate.audioFrames.upperBound
        var energies: [Double] = []
        var frame = searchStart
        while frame + hop <= scanEnd {
            try Task.checkCancellation()
            let offset = Int(frame - candidate.audioFrames.lowerBound)
            var energy = 0.0
            for sample in pcm[offset..<(offset + Int(hop))] {
                guard sample.isFinite, abs(sample) <= 8 else { throw TranscriptionChunkingError.invalidPCM }
                energy += Double(sample) * Double(sample)
            }
            energies.append(sqrt(energy / Double(hop)))
            frame += hop
        }
        let ordered = energies.sorted()
        guard !ordered.isEmpty else { return nil }
        // A relative gate keeps uniformly quiet speech/noise from becoming a "pause".
        let threshold = min(pow(10, -50.0 / 20), ordered[(ordered.count - 1) * 9 / 10] * 0.1)
        var quietStart: Int?
        var selected: Int64?
        for index in 0...energies.count {
            if index < energies.count, energies[index] <= threshold {
                if quietStart == nil { quietStart = index }
            } else if let first = quietStart {
                if index - first >= minimumQuietHops {
                    let center = searchStart + Int64(first + index) * hop / 2
                    let boundary = min(maximum, center)
                    if boundary >= searchStart { selected = max(selected ?? boundary, boundary) }
                }
                quietStart = nil
            }
        }
        return selected
    }
}
