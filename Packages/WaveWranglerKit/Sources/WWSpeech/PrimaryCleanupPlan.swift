import Foundation
import WWCore
import WWTimeMap

public struct CleanupTimingRegion: Sendable, Equatable {
    public let occurrence: SourceOccurrenceID
    public let epoch: RecordingEpochID
    public let sourceStart: Double
    public let sourceEnd: Double
    public let alignedStart: Double
    public let rate: Double
    public var alignedEnd: Double { alignedStart + (sourceEnd - sourceStart) * rate }

    public init(occurrence: SourceOccurrenceID, epoch: RecordingEpochID, sourceStart: Double,
                sourceEnd: Double, alignedStart: Double, rate: Double) {
        self.occurrence = occurrence
        self.epoch = epoch
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.alignedStart = alignedStart
        self.rate = rate
    }
}

public struct CleanupSpeakerLane: Sendable, Identifiable {
    public var id: SpeakerID { speaker }
    public let speaker: SpeakerID
    public let name: String
    public let primary: ChannelReference
    public let sourceName: String
    public let sourceRate: Int
    public let sourceFrames: Int64
    public let regions: [CleanupTimingRegion]
    public let start: Double
    public let end: Double

    /// No interpolation across gaps, epochs or occurrences; every covered piece must be continuous.
    public func sourceRange(start: Double, end: Double) -> Range<Int64>? {
        guard start.isFinite, end.isFinite, end > start, (8000...192000).contains(sourceRate),
              sourceFrames > 0, sourceFrames <= 192_000 * 86_400,
              regions.allSatisfy({
                  $0.sourceStart.isFinite && $0.sourceEnd.isFinite && $0.alignedStart.isFinite
                      && $0.alignedEnd.isFinite && $0.rate.isFinite && $0.rate > 0
                      && $0.sourceStart >= 0 && $0.sourceEnd > $0.sourceStart
                      && $0.sourceEnd <= Double(sourceFrames) / Double(sourceRate)
              }) else { return nil }
        let pieces = regions.filter { $0.alignedStart < end && $0.alignedEnd > start }
        guard let first = pieces.first, let last = pieces.last,
              first.alignedStart <= start, last.alignedEnd >= end,
              zip(pieces, pieces.dropFirst()).allSatisfy({
                  $0.occurrence == $1.occurrence && $0.epoch == $1.epoch
                      && Self.sameBoundary($0.sourceEnd, $1.sourceStart)
                      && Self.sameBoundary($0.alignedEnd, $1.alignedStart)
              }) else { return nil }
        let a = first.sourceStart + (start - first.alignedStart) / first.rate
        let b = last.sourceStart + (end - last.alignedStart) / last.rate
        let lo = Int64(max(0, a * Double(sourceRate)).rounded(.down))
        let hi = Int64(min(Double(sourceFrames), b * Double(sourceRate)).rounded(.up))
        guard lo >= 0, hi > lo, hi <= sourceFrames else { return nil }
        return lo..<hi
    }

    private static func sameBoundary(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 8 * max(a.ulp, b.ulp)
    }
}

/// Metadata-only readiness. The app must additionally verify active timing and live source access.
public struct PrimaryCleanupPlan: Sendable {
    public let alignmentRevision: Int?
    public let lanes: [CleanupSpeakerLane]
    public let blockers: [String]
    public var isReady: Bool { alignmentRevision != nil && !lanes.isEmpty && blockers.isEmpty }

    /// The union of per-Primary ranges, not their shared overlap. Omitted bounds never crop offset ends.
    public var alignedRange: ClosedRange<Double>? {
        guard let start = lanes.map(\.start).min(), let end = lanes.map(\.end).max(),
              start.isFinite, end.isFinite, end > start else { return nil }
        return start...end
    }

    public static func make(model: ShowDocumentModel, episode episodeID: EpisodeID,
                            map: AlignedTimelineMap?) -> Self {
        guard let episode = model.episode(episodeID) else {
            return Self(alignmentRevision: nil, lanes: [], blockers: ["This episode is no longer available."])
        }
        let revision = episode.alignment?.acceptedRevision
        var blockers: [String] = []
        var lanes: [CleanupSpeakerLane] = []
        if revision == nil || map == nil { blockers.append("Alignment needed: accept and save timing for every Primary before transcription.") }
        if episode.speakerAssignments.isEmpty { blockers.append("Assign a Primary recording to each speaker in Setup.") }
        if episode.speakerAssignments.count > 64 { blockers.append("Cleanup currently supports at most 64 speaker Primaries.") }
        let assignedSources = Set(episode.speakerAssignments.compactMap(\.primary?.sourceID))
        for source in episode.sources where source.role == .primary && !assignedSources.contains(source.id) {
            blockers.append("\(source.displayNameHint): assign this Primary to a speaker before transcription.")
        }
        let range = episode.cleanup?.explicitWorkingRange
        if let range, range.alignmentRevision != revision {
            blockers.append("Explicit IN/OUT belong to older alignment. Review episode IN/OUT to keep them, or reset to the full available range. IN/OUT are optional.")
        }
        for assignment in episode.speakerAssignments {
            let name = model.speaker(assignment.speakerID)?.name ?? "Unknown speaker"
            guard let primary = assignment.primary,
                  assignment.primaryConfirmation == .userConfirmed,
                  !assignment.backups.contains(primary),
                  let source = episode.source(primary.sourceID),
                  source.role == .primary, source.roleConfirmation == .userConfirmed,
                  !episode.speakerAssignments.contains(where: {
                      $0.speakerID != assignment.speakerID && $0.primary == primary
                  }) else {
                blockers.append("\(name): choose a Primary in Recordings & Speakers. Selecting Primary confirms the choice.")
                continue
            }
            guard let channel = primary.resolvedChannel(in: episode) else {
                blockers.append("\(name): choose a valid speaker channel for \(source.displayNameHint) in Recordings & Speakers. Mono recordings use their only channel automatically.")
                continue
            }
            guard !assignment.backups.contains(where: {
                $0.sourceID == primary.sourceID && $0.resolvedChannel(in: episode) == channel
            }), !episode.speakerAssignments.contains(where: {
                $0.speakerID != assignment.speakerID && $0.primary?.sourceID == primary.sourceID
                    && $0.primary?.resolvedChannel(in: episode) == channel
            }) else {
                blockers.append("\(name): choose a unique Primary speaker channel in Recordings & Speakers.")
                continue
            }
            guard let map else { continue }
            let placements = map.groups.flatMap(\.placements).filter { $0.occurrence.source == source.id }
            guard placements.count == 1, let placement = placements.first,
                  let group = map.groups.first(where: { $0.placements.contains(placement) }),
                  group.group == source.placement.recorderGroupID else {
                blockers.append("\(name): this Primary has no unique accepted placement.")
                continue
            }
            let nominalRate = placement.occurrence.nominalRate.framesPerSecond
            let frames = placement.occurrence.frameCount
            guard (8000...192000).contains(nominalRate),
                  frames > 0, frames <= 192_000 * 86_400 else {
                blockers.append("\(name): cleanup requires a supported 8-192 kHz Primary and bounded source duration.")
                continue
            }
            let rate = Int(nominalRate)
            var regions: [CleanupTimingRegion] = []
            if let correction = episode.alignment?.acceptedMap?.sourceCorrections?.first(where: { $0.source == source.id }) {
                guard correction.isValid, correction.sourceRate == rate, correction.sourceFrames == frames,
                      correction.group == group.group, channel < correction.channelCount,
                      placement.spans.contains(where: { $0.epoch == correction.epoch }) else {
                    blockers.append("\(name): file-local timing no longer matches this Primary.")
                    continue
                }
                regions = correction.segments.map {
                    CleanupTimingRegion(occurrence: placement.occurrence.id, epoch: correction.epoch,
                        sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd, alignedStart: $0.alignedStart, rate: $0.rateRatio)
                }
            } else {
                for span in placement.spans {
                    guard let epoch = group.epochs.first(where: { $0.epoch == span.epoch }),
                          case let .mapped(segments, _) = epoch.mapping else { continue }
                    let offset = span.groupClockOffset.approximateDouble
                    for segment in segments {
                        let lo = max(Double(span.startFrame) / Double(rate),
                                     segment.groupClockStart.approximateDouble - offset)
                        let hi = min(Double(span.endFrame) / Double(rate),
                                     segment.groupClockEnd.approximateDouble - offset)
                        guard hi > lo else { continue }
                        let a = segment.rateRatio.approximateDouble
                        regions.append(CleanupTimingRegion(occurrence: placement.occurrence.id, epoch: span.epoch,
                            sourceStart: lo, sourceEnd: hi,
                            alignedStart: a * (lo + offset) + segment.alignedOffset.approximateDouble, rate: a))
                    }
                }
            }
            regions.sort { $0.sourceStart < $1.sourceStart }
            guard let first = regions.first, let last = regions.last else {
                blockers.append("\(name): align this Primary before transcription.")
                continue
            }
            let start = ceil(max(first.alignedStart, range?.tracksIn ?? first.alignedStart) * 48_000) / 48_000
            let end = floor(min(last.alignedEnd, range?.tracksOut ?? last.alignedEnd) * 48_000) / 48_000
            let lane = CleanupSpeakerLane(speaker: assignment.speakerID, name: name,
                primary: ChannelReference(sourceID: primary.sourceID, statedChannel: channel),
                sourceName: source.displayNameHint, sourceRate: rate, sourceFrames: frames,
                regions: regions, start: start, end: end)
            lanes.append(lane)
            if end - start < 0.1 {
                blockers.append("\(name): the working range must include at least 0.1 seconds of this Primary.")
            } else if lane.sourceRange(start: start, end: end) == nil
                        || (first.sourceStart > 0 && range?.tracksIn == nil)
                        || (last.sourceEnd < Double(frames) / Double(rate) && range?.tracksOut == nil) {
                blockers.append("\(name): alignment does not cover all audio in the requested range. Accept timing for the remaining audio, or explicitly limit transcription with optional IN/OUT.")
            }
        }
        return Self(alignmentRevision: revision, lanes: lanes, blockers: blockers)
    }
}
