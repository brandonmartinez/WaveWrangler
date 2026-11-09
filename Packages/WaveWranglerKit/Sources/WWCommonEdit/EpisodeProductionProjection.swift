import Foundation
import WWCore

public enum EpisodeProductionError: Error, Sendable, Equatable, LocalizedError {
    case staleComposition
    case staleSpeakerRange
    case invalidSpeakerRange
    case invalidEpisodeRange
    case unresolvedBoundary
    case invalidClockPosition

    public var errorDescription: String? {
        switch self {
        case .staleComposition: "The composition changed. Refresh the episode boundaries."
        case .staleSpeakerRange: "Speaker In/Out belongs to an older alignment. Review the markers before playback."
        case .invalidSpeakerRange: "Speaker In/Out must overlap available dialogue."
        case .invalidEpisodeRange: "Episode Start must be earlier than Episode End."
        case .unresolvedBoundary: "An episode boundary needs placement review."
        case .invalidClockPosition: "This time is outside the supported timeline."
        }
    }
}

public enum EpisodeClock: String, Sendable, Codable, CaseIterable {
    case episode, speaker, timeline

    public var title: String {
        switch self {
        case .episode: "Episode Time"
        case .speaker: "Speaker Time"
        case .timeline: "Timeline Time"
        }
    }
}

/// One immutable projection for finished-episode bounds and presentation clocks.
/// The media hull and underlying signed composition grid are never rebased or trimmed.
public struct EpisodeProductionProjection: Sendable, Equatable {
    public let composition: ProgramComposition
    public let episodeFrames: Range<Int64>?
    public let speakerAlignedFrames: Range<Int64>?
    public let speakerProgramFrames: Range<Int64>?
    public let restrictSpeech: Bool

    public init(episode: Episode, composition: ProgramComposition) throws {
        guard try ProgramTimeline(episode: episode, dialogueFrames: composition.timeline.dialogueFrames)
            .composition() == composition else { throw EpisodeProductionError.staleComposition }
        let anchors = [episode.productionRange?.start, episode.productionRange?.end].compactMap { $0 }
        guard anchors.allSatisfy({ $0.isValid(in: episode) }) else {
            throw EpisodeProductionError.unresolvedBoundary
        }
        self.composition = composition
        restrictSpeech = episode.productionRange?.restrictSpeech == true
        let timeline = composition.timeline
        let working = episode.cleanup?.explicitWorkingRange
        if let working, working.alignmentRevision != episode.alignment?.acceptedRevision {
            throw EpisodeProductionError.staleSpeakerRange
        }
        let aligned: Range<Int64>?
        if let coverage = timeline.dialogueFrames {
            let first = try working?.tracksIn.map(Self.frame(seconds:)) ?? coverage.lowerBound
            let last = try working?.tracksOut.map(Self.frame(seconds:)) ?? coverage.upperBound
            let lo = max(first, coverage.lowerBound), hi = min(last, coverage.upperBound)
            guard lo < hi else { throw EpisodeProductionError.invalidSpeakerRange }
            aligned = lo..<hi
        } else {
            guard working == nil else { throw EpisodeProductionError.invalidSpeakerRange }
            aligned = nil
        }
        speakerAlignedFrames = aligned
        let speaker: Range<Int64>?
        if let aligned {
            let lo = try Self.projectEdge(aligned.lowerBound, end: false, timeline: timeline)
            let hi = try Self.projectEdge(aligned.upperBound, end: true, timeline: timeline)
            speaker = lo < hi ? lo..<hi : nil
        } else {
            speaker = nil
        }
        speakerProgramFrames = speaker
        let automatic = [speaker].compactMap { $0 }
            + composition.clips.map(\.programFrames) + timeline.insertions.map(\.programFrames)
        let automaticStart = automatic.map(\.lowerBound).min()
        let automaticEnd = automatic.map(\.upperBound).max()
        let start = try episode.productionRange?.start.map { try Self.resolve($0, timeline: timeline) }
            ?? automaticStart
        let end = try episode.productionRange?.end.map { try Self.resolve($0, timeline: timeline) }
            ?? automaticEnd
        if let start, let end, start >= end { throw EpisodeProductionError.invalidEpisodeRange }
        if composition.programFrames == nil {
            episodeFrames = nil
            return
        }
        switch (start, end) {
        case (nil, nil): episodeFrames = nil
        case let (start?, end?): episodeFrames = start..<end
        default: throw EpisodeProductionError.invalidEpisodeRange
        }
    }

    public func clockFrame(atProgramFrame frame: Int64, clock: EpisodeClock) throws -> Int64? {
        try Self.check(frame)
        switch clock {
        case .timeline: return frame
        case .episode: return episodeFrames.map { frame - $0.lowerBound }
        case .speaker:
            guard let speakerAlignedFrames,
                  case .dialogue(let aligned) = try composition.timeline.inverse(atProgramFrame: frame) else {
                return nil
            }
            let cuts = composition.timeline.cuts
            return cuts.editedFrame(forAlignedFrame: aligned)
                - cuts.editedFrame(forAlignedFrame: speakerAlignedFrames.lowerBound)
        }
    }

    public func programFrame(atClockFrame frame: Int64, clock: EpisodeClock) throws -> Int64? {
        let clockLimit = clock == .timeline ? AudioArrangement.frameLimit : 2 * AudioArrangement.frameLimit
        guard (-clockLimit...clockLimit).contains(frame) else {
            throw EpisodeProductionError.invalidClockPosition
        }
        let position: Int64?
        switch clock {
        case .timeline: position = frame
        case .episode: position = episodeFrames.map { frame + $0.lowerBound }
        case .speaker:
            guard let speakerAlignedFrames else { return nil }
            let cuts = composition.timeline.cuts
            let edited = frame + cuts.editedFrame(forAlignedFrame: speakerAlignedFrames.lowerBound)
            try Self.check(edited)
            let aligned = cuts.alignedFrame(forEditedFrame: edited)
            if case .mapped(let mapped) = try composition.timeline.dialoguePosition(atAlignedFrame: aligned) {
                position = mapped
            } else {
                position = nil
            }
        }
        if let position { try Self.check(position) }
        return position
    }

    /// Boundary ramp stays entirely inside the permitted range. It never leaks excluded samples.
    public func speechGain(atProgramFrame frame: Int64) -> Float {
        guard restrictSpeech else { return 1 }
        guard let bounds = speakerProgramFrames, bounds.contains(frame) else { return 0 }
        return Float(min(1, Double(min(frame - bounds.lowerBound, bounds.upperBound - 1 - frame)) / 240))
    }

    private static func resolve(_ anchor: AudioPlacementAnchor, timeline: ProgramTimeline) throws -> Int64 {
        switch try timeline.project(anchor) {
        case .placed(let frame), .clampedToCutSeam(let frame, _): return frame
        case .reviewRequired, .outsideDialogueCoverage: throw EpisodeProductionError.unresolvedBoundary
        }
    }

    private static func projectEdge(_ frame: Int64, end: Bool, timeline: ProgramTimeline) throws -> Int64 {
        let base = timeline.cuts.editedFrame(forAlignedFrame: frame)
        let inserted = timeline.insertions.filter { end ? $0.baseFrame < base : $0.baseFrame <= base }
            .reduce(Int64(0)) { $0 + Int64($1.programFrames.count) }
        let result = base + inserted
        try check(result)
        return result
    }

    private static func frame(seconds: Double) throws -> Int64 {
        guard seconds.isFinite, abs(seconds) <= 86_400 else {
            throw EpisodeProductionError.invalidClockPosition
        }
        return Int64(ceil(seconds * Double(AudioArrangement.frameRate)))
    }

    private static func check(_ frame: Int64) throws {
        guard (-AudioArrangement.frameLimit...AudioArrangement.frameLimit).contains(frame) else {
            throw EpisodeProductionError.invalidClockPosition
        }
    }
}
