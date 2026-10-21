import Foundation

/// Exact output-frame windows shared by every audible track, with bounded producer look-ahead.
public struct AlignedAuditionSchedule: Sendable {
    public static let initialFrames: Int64 = 48_000
    public static let followingFrames: Int64 = 24_000
    public static let maximumAheadSeconds = 3.0

    public let firstFrame: Int64
    public let endFrame: Int64
    public private(set) var nextFrame: Int64

    public init(startSeconds: Double, endSeconds: Double) throws {
        guard startSeconds.isFinite, endSeconds.isFinite,
              (-86_400...86_400).contains(startSeconds),
              (-86_400...86_400).contains(endSeconds), endSeconds > startSeconds else {
            throw WaveformWindowError.invalidWindow
        }
        firstFrame = Int64(floor(startSeconds * Double(AlignedAuditionWindowReader.outputRate)))
        endFrame = Int64(ceil(endSeconds * Double(AlignedAuditionWindowReader.outputRate)))
        nextFrame = firstFrame
    }

    public mutating func next() -> Range<Int64>? {
        guard nextFrame < endFrame else { return nil }
        let count = nextFrame == firstFrame ? Self.initialFrames : Self.followingFrames
        let frames = nextFrame..<min(endFrame, nextFrame + count)
        nextFrame = frames.upperBound
        return frames
    }
}
