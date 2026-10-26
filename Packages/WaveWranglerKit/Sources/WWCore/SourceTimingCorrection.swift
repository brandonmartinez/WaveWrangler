import Foundation

public struct SourceTimingSegment: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case quietTransition, anchorGuided, estimated }

    public var sourceStart: Double
    public var sourceEnd: Double
    public var alignedStart: Double
    public var rateRatio: Double
    public var kind: Kind?

    public init(sourceStart: Double, sourceEnd: Double, alignedStart: Double, rateRatio: Double, kind: Kind? = nil) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.alignedStart = alignedStart
        self.rateRatio = rateRatio
        self.kind = kind
    }

    public var alignedEnd: Double { alignedStart + (sourceEnd - sourceStart) * rateRatio }

    public enum AudioPreservationError: String, Error, LocalizedError, Sendable {
        case invalidTiming = "The file timing is invalid. No audio-preserving correction was applied."
        case unsafeTransition = "The measured timing cannot retain all audio within the supported playback rates. Remove adaptive file timing or review the transition manually; no audio was muted."

        public var errorDescription: String? { rawValue }
    }

    /// Steep joins may replace neighboring support with an explicitly estimated transition ramp.
    public static func preservingAudio(
        in segments: [Self], duration: Double
    ) throws(AudioPreservationError) -> [Self] {
        guard duration.isFinite, duration > 0, duration <= 7200,
              !segments.isEmpty,
              segments.allSatisfy({
                  $0.sourceStart.isFinite && $0.sourceEnd.isFinite && $0.alignedStart.isFinite
                      && $0.alignedEnd.isFinite && (0.98...1.02).contains($0.rateRatio)
                      && $0.sourceStart >= 0 && $0.sourceEnd > $0.sourceStart && $0.sourceEnd <= duration
              }),
              zip(segments, segments.dropFirst()).allSatisfy({
                  $0.sourceEnd <= $1.sourceStart && $0.alignedEnd <= $1.alignedStart
              }) else { throw .invalidTiming }
        let supported = try smoothingTransitions(in: segments)
        guard let first = supported.first, let last = supported.last else { throw .invalidTiming }
        var result: [Self] = []
        if first.sourceStart > 0 {
            var leading = Self(sourceStart: 0, sourceEnd: first.sourceStart,
                alignedStart: first.alignedStart - first.sourceStart * first.rateRatio,
                rateRatio: first.rateRatio, kind: .estimated)
            if leading.alignedEnd > first.alignedStart { leading.alignedStart = leading.alignedStart.nextDown }
            result.append(leading)
        }
        for (index, segment) in supported.enumerated() {
            if index > 0 {
                let left = supported[index - 1]
                let gap = segment.sourceStart - left.sourceEnd
                if gap > 0 {
                    var rate = (segment.alignedStart - left.alignedEnd) / gap
                    guard (0.98...1.02).contains(rate) else { throw .unsafeTransition }
                    if left.alignedEnd + gap * rate > segment.alignedStart { rate = rate.nextDown }
                    result.append(Self(sourceStart: left.sourceEnd, sourceEnd: segment.sourceStart,
                        alignedStart: left.alignedEnd, rateRatio: rate, kind: .estimated))
                }
            }
            result.append(segment)
        }
        if last.sourceEnd < duration {
            result.append(Self(sourceStart: last.sourceEnd, sourceEnd: duration,
                alignedStart: last.alignedEnd, rateRatio: last.rateRatio, kind: .estimated))
        }
        guard result.count <= 21600, result.allSatisfy({
            (-86400...86400).contains($0.alignedStart) && $0.alignedEnd <= 86400
                && (0.98...1.02).contains($0.rateRatio)
        }), zip(result, result.dropFirst()).allSatisfy({
            $0.sourceEnd == $1.sourceStart && $0.alignedEnd <= $1.alignedStart
        }) else { throw .invalidTiming }
        return result
    }

    private static func smoothingTransitions(in segments: [Self]) throws(AudioPreservationError) -> [Self] {
        var result = segments
        var index = 0
        let rates = 0.98...1.02
        while index + 1 < result.count {
            let left = result[index], right = result[index + 1]
            let gap = right.sourceStart - left.sourceEnd
            guard gap > 0, !rates.contains((right.alignedStart - left.alignedEnd) / gap) else {
                index += 1
                continue
            }
            var lower = index, upper = index + 1
            func envelopeRate() -> Double {
                (result[upper].alignedEnd - result[lower].alignedStart)
                    / (result[upper].sourceEnd - result[lower].sourceStart)
            }
            while !rates.contains(envelopeRate()) {
                guard lower > 0 || upper + 1 < result.count else { throw .unsafeTransition }
                lower = max(0, lower - 1)
                upper = min(result.count - 1, upper + 1)
            }
            let first = result[lower], last = result[upper]
            var start = first.sourceStart, end = last.sourceEnd
            if lower == index, upper == index + 1, (0.980001...1.019999).contains(envelopeRate()) {
                var lo = 0.0, hi = 1.0
                for _ in 0..<56 {
                    let fraction = (lo + hi) / 2
                    let a = left.sourceEnd - fraction * (left.sourceEnd - left.sourceStart)
                    let b = right.sourceStart + fraction * (right.sourceEnd - right.sourceStart)
                    let alignedA = left.alignedStart + (a - left.sourceStart) * left.rateRatio
                    let alignedB = right.alignedStart + (b - right.sourceStart) * right.rateRatio
                    if (0.980001...1.019999).contains((alignedB - alignedA) / (b - a)) { hi = fraction }
                    else { lo = fraction }
                }
                start = left.sourceEnd - hi * (left.sourceEnd - left.sourceStart)
                end = right.sourceStart + hi * (right.sourceEnd - right.sourceStart)
            }
            let alignedStart = first.alignedStart + (start - first.sourceStart) * first.rateRatio
            let alignedEnd = last.alignedStart + (end - last.sourceStart) * last.rateRatio
            var rate = (alignedEnd - alignedStart) / (end - start)
            if alignedStart + (end - start) * rate > alignedEnd { rate = rate.nextDown }
            guard rates.contains(rate) else { throw .unsafeTransition }
            var replacement: [Self] = []
            if start > first.sourceStart {
                var prefix = first
                prefix.sourceEnd = start
                replacement.append(prefix)
            }
            replacement.append(Self(sourceStart: start, sourceEnd: end, alignedStart: alignedStart,
                rateRatio: rate, kind: .estimated))
            if end < last.sourceEnd {
                var suffix = last
                suffix.sourceStart = end
                suffix.alignedStart = alignedEnd
                replacement.append(suffix)
            }
            result.replaceSubrange(lower...upper, with: replacement)
            index = max(0, lower - 1)
        }
        return result
    }
}

/// A human-accepted file-local correction, separate from recorder clock authority.
public struct SourceTimingCorrection: Sendable, Equatable, Codable {
    public var version: Int
    public var source: SourceID
    public var group: RecorderGroupID
    public var epoch: RecordingEpochID
    public var reference: SourceID
    public var sourceRate: Int
    public var sourceFrames: Int64
    public var channelCount: Int
    public var analysisDigest: String
    public var processing: String
    public var segments: [SourceTimingSegment]

    public init(source: SourceID, group: RecorderGroupID, epoch: RecordingEpochID, reference: SourceID,
                sourceRate: Int, sourceFrames: Int64, channelCount: Int, analysisDigest: String,
                processing: String, segments: [SourceTimingSegment]) {
        version = Self.version(for: segments)
        self.source = source
        self.group = group
        self.epoch = epoch
        self.reference = reference
        self.sourceRate = sourceRate
        self.sourceFrames = sourceFrames
        self.channelCount = channelCount
        self.analysisDigest = analysisDigest
        self.processing = processing
        self.segments = segments
    }

    public var isValid: Bool {
        guard version == Self.version(for: segments),
              source != reference, (8000...192000).contains(sourceRate),
              sourceFrames > 0, sourceFrames <= Int64(sourceRate) * 7200,
              (1...32).contains(channelCount), analysisDigest.utf8.count == 64,
              analysisDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              processing == "ww-native-time-pitch-multichannel/1",
              !segments.isEmpty, segments.count <= 21600 else { return false }
        let duration = Double(sourceFrames) / Double(sourceRate)
        for segment in segments {
            guard segment.sourceStart.isFinite, segment.sourceEnd.isFinite, segment.alignedStart.isFinite,
                  segment.rateRatio.isFinite, (0.98...1.02).contains(segment.rateRatio),
                  segment.sourceStart >= 0, segment.sourceEnd > segment.sourceStart,
                  segment.sourceEnd <= duration, (-86400...86400).contains(segment.alignedStart),
                  segment.alignedEnd.isFinite, segment.alignedEnd <= 86400 else { return false }
        }

        return zip(segments, segments.dropFirst()).allSatisfy {
            $0.sourceEnd <= $1.sourceStart && $0.alignedEnd <= $1.alignedStart
        }
    }

    private static func version(for segments: [SourceTimingSegment]) -> Int {
        if segments.contains(where: { $0.kind == .anchorGuided || $0.kind == .estimated }) { return 3 }
        return segments.contains { $0.kind == .quietTransition } ? 2 : 1
    }

    public func alignedTime(at sourceSeconds: Double) -> Double? {
        guard let segment = segments.first(where: { $0.sourceStart <= sourceSeconds && sourceSeconds < $0.sourceEnd })
        else { return nil }
        return segment.alignedStart + (sourceSeconds - segment.sourceStart) * segment.rateRatio
    }

    public var retainsAllAudio: Bool {
        isValid && segments.first?.sourceStart == 0
            && segments.last?.sourceEnd == Double(sourceFrames) / Double(sourceRate)
            && zip(segments, segments.dropFirst()).allSatisfy { $0.sourceEnd == $1.sourceStart }
    }

    public func preservingAudio() throws -> Self {
        guard isValid else { throw SourceTimingSegment.AudioPreservationError.invalidTiming }
        var copy = self
        copy.segments = try SourceTimingSegment.preservingAudio(
            in: segments, duration: Double(sourceFrames) / Double(sourceRate))
        copy.version = Self.version(for: copy.segments)
        guard copy.retainsAllAudio else { throw SourceTimingSegment.AudioPreservationError.invalidTiming }
        return copy
    }
}
