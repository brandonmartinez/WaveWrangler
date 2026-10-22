import Foundation

/// A human-requested removal on the original aligned 48 kHz listening grid.
/// Alignment and source recordings stay unchanged; a marker may retain its review provenance.
public struct ManualEpisodeCut: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let markerID: UUID?
    public let alignmentRevision: Int
    public let startFrame: Int64
    public let endFrame: Int64

    public static let frameRate: Int64 = 48_000
    public static let frameLimit = frameRate * 86_400

    public init(id: UUID = UUID(), markerID: UUID? = nil, alignmentRevision: Int,
                startFrame: Int64, endFrame: Int64) {
        self.id = id
        self.markerID = markerID
        self.alignmentRevision = alignmentRevision
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    public var isValid: Bool {
        alignmentRevision > 0 && startFrame >= -Self.frameLimit
            && endFrame <= Self.frameLimit && endFrame > startFrame
    }

    public var alignedStart: Double { Double(startFrame) / Double(Self.frameRate) }
    public var alignedEnd: Double { Double(endFrame) / Double(Self.frameRate) }
}

/// One ripple prescription shared by every track, including hidden and muted tracks.
/// Signed aligned coordinates are preserved before the first cut. Seams belong to the following audio.
public struct ManualCutTimeline: Sendable, Equatable {
    public let removals: [Range<Int64>]
    public static let unedited = Self(removals: [])

    private init(removals: [Range<Int64>]) { self.removals = removals }

    public init(cuts: [ManualEpisodeCut]) throws(DomainError) {
        guard cuts.allSatisfy(\.isValid) else { throw .invalidCleanup }
        var merged: [Range<Int64>] = []
        for cut in cuts.sorted(by: { $0.startFrame < $1.startFrame }) {
            if let last = merged.last, cut.startFrame <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, cut.endFrame)
            } else {
                merged.append(cut.startFrame..<cut.endFrame)
            }
        }
        self.init(removals: merged)
    }

    public func editedFrame(forAlignedFrame frame: Int64) -> Int64 {
        var removed: Int64 = 0
        for span in removals {
            if frame < span.lowerBound { break }
            removed += min(frame, span.upperBound) - span.lowerBound
            if frame < span.upperBound { break }
        }
        return frame - removed
    }

    public func alignedFrame(forEditedFrame frame: Int64) -> Int64 {
        var removed: Int64 = 0
        for span in removals {
            if frame < span.lowerBound - removed { break }
            removed += span.upperBound - span.lowerBound
        }
        return frame + removed
    }

    public func editedTime(forAlignedTime time: Double) -> Double {
        var removed = 0.0
        for span in removals {
            let lo = Double(span.lowerBound) / Double(ManualEpisodeCut.frameRate)
            let hi = Double(span.upperBound) / Double(ManualEpisodeCut.frameRate)
            if time < lo { break }
            removed += min(time, hi) - lo
            if time < hi { break }
        }
        return time - removed
    }

    public func alignedTime(forEditedTime time: Double) -> Double {
        var removed = 0.0
        for span in removals {
            let lo = Double(span.lowerBound) / Double(ManualEpisodeCut.frameRate)
            if time < lo - removed { break }
            removed += Double(span.count) / Double(ManualEpisodeCut.frameRate)
        }
        return time + removed
    }

    /// Split a bounded listening request without ever decoding the removed interval.
    public func alignedRanges(forEditedFrames frames: Range<Int64>) -> [Range<Int64>] {
        var result: [Range<Int64>] = []
        var cursor = frames.lowerBound
        var removed: Int64 = 0
        for span in removals {
            let seam = span.lowerBound - removed
            if cursor < min(seam, frames.upperBound) {
                let end = min(seam, frames.upperBound)
                result.append((cursor + removed)..<(end + removed))
                cursor = end
            }
            if cursor >= frames.upperBound { break }
            removed += span.upperBound - span.lowerBound
        }
        if cursor < frames.upperBound {
            result.append((cursor + removed)..<(frames.upperBound + removed))
        }
        return result
    }

    public func keptAlignedRanges(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var cursor = range.lowerBound
        for span in removals {
            let lo = Double(span.lowerBound) / Double(ManualEpisodeCut.frameRate)
            let hi = Double(span.upperBound) / Double(ManualEpisodeCut.frameRate)
            if hi <= cursor { continue }
            if lo > range.upperBound { break }
            if lo > cursor { result.append(cursor...min(lo, range.upperBound)) }
            cursor = max(cursor, hi)
            if cursor > range.upperBound { break }
        }
        if cursor <= range.upperBound { result.append(cursor...range.upperBound) }
        return result
    }
}

extension Episode {
    public var activeManualCuts: [ManualEpisodeCut] {
        (cleanup?.manualCuts ?? []).filter { $0.alignmentRevision == alignment?.acceptedRevision }
    }

    public func manualCutTimeline(revealing cutID: UUID? = nil) throws(DomainError) -> ManualCutTimeline {
        try ManualCutTimeline(cuts: activeManualCuts.filter { $0.id != cutID })
    }
}
