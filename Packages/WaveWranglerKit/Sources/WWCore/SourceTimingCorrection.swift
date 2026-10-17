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
}
