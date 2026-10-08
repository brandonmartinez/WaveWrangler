import Foundation
import WWTimeMap

/// A diagnostic for a prospective render binding, not a cut approval. No value in this module can
/// attest that the organizer supplied every lane or that an edit was accepted by a person.
public enum CommonRenderRefusal: Error, Equatable, Sendable {
    case organizerAuthorityUnavailable
    case emptyLaneInventory
    case duplicateLane(CommonRenderLaneKey)
    case missingLane(CommonRenderLaneKey)
    case unexpectedLane(CommonRenderLaneKey)
    case unknownOccurrence(SourceOccurrenceID)
    case invalidChannel(CommonRenderLaneKey)
    case missingBacking(CommonRenderLaneKey)
    case invalidBacking(CommonRenderLaneKey)
    case missingProtection(CommonRenderLaneKey)
    case invalidProtection(CommonRenderLaneKey)
    case unsafeRemoval(CommonRenderLaneKey, RemovedFrameSpan)
    case invalidFade(RemovedFrameSpan)
    case overlappingFades(RemovedFrameSpan, RemovedFrameSpan)
    case unsafeFade(CommonRenderLaneKey, RemovedFrameSpan)
    case removalMismatch
    case fadeCountMismatch(expected: Int, actual: Int)
}

/// Identifies an occurrence *and* decoded channel, so repeated uses of a source do not collapse.
public struct CommonRenderLaneKey: Hashable, Sendable {
    public let occurrence: SourceOccurrenceID
    public let decodedChannel: Int

    public init(occurrence: SourceOccurrenceID, decodedChannel: Int) {
        self.occurrence = occurrence
        self.decodedChannel = decodedChannel
    }
}

/// A prospective lane's already-aligned input. Silence must be explicitly identified by the
/// organizer; missing audio is never interpreted as silence.
public enum CommonRenderLaneBacking: Sendable, Equatable {
    case aligned(assetVersion: String, frames: Range<Int64>)
    /// A current, timed assertion of silence; absent backing is not silence.
    case explicitSilence(frames: Range<Int64>)
}

public struct CommonRenderLane: Sendable, Equatable {
    public let key: CommonRenderLaneKey
    public let backing: CommonRenderLaneBacking

    public init(key: CommonRenderLaneKey, backing: CommonRenderLaneBacking) {
        self.key = key
        self.backing = backing
    }
}

/// The same immutable frame prescription for a prospective preview and render. This is NOT an
/// audio renderer, publication token, accepted edit, or evidence of complete source coverage.
public struct CommonRenderBinding: Sendable {
    public let map: CommonEpisodeEditMap
    public let lanes: [CommonRenderLane]

    public var previewPrescription: CommonEpisodeEditMap { map }
    public var renderPrescription: CommonEpisodeEditMap { map }

    fileprivate init(map: CommonEpisodeEditMap, lanes: [CommonRenderLane]) {
        self.map = map
        self.lanes = lanes
    }
}

public enum CommonRenderAdapter {
    /// Refuse production binding until the organizer can provide an authoritative complete-lane
    /// snapshot, accepted edit/protection evidence, and atomic current-revision publication.
    public static func prepare(_ map: CommonEpisodeEditMap) throws(CommonRenderRefusal) -> CommonRenderBinding {
        throw .organizerAuthorityUnavailable
    }

    /// Synthetic-only structural preflight for the future authority seam. The caller-provided
    /// inventory, protection intervals and fade footprints are NOT proof of their own provenance.
    /// Keep this internal until an organizer-backed, revision-checked capability supplies them.
    static func inspectSynthetic(
        map: CommonEpisodeEditMap,
        inventory: [CommonRenderLaneKey],
        lanes: [CommonRenderLane],
        protectedFrames: [CommonRenderLaneKey: [Range<Int64>]],
        claimedRoundedRemovals: [RemovedFrameSpan],
        fadeFootprints: [RemovedFrameSpan]
    ) throws(CommonRenderRefusal) -> CommonRenderBinding {
        guard !inventory.isEmpty else { throw .emptyLaneInventory }
        var expected = Set<CommonRenderLaneKey>()
        for key in inventory {
            guard expected.insert(key).inserted else { throw .duplicateLane(key) }
        }
        var seen = Set<CommonRenderLaneKey>()
        for lane in lanes {
            let key = lane.key
            guard seen.insert(key).inserted else { throw .duplicateLane(key) }
            guard expected.contains(key) else { throw .unexpectedLane(key) }
            guard key.decodedChannel >= 0 else { throw .invalidChannel(key) }
            guard map.alignment.group(containing: key.occurrence) != nil else { throw .unknownOccurrence(key.occurrence) }
            switch lane.backing {
            case .aligned(let version, let frames):
                guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .missingBacking(key) }
                guard frames == 0 ..< map.alignedFrameCount else { throw .invalidBacking(key) }
            case .explicitSilence(let frames):
                guard frames == 0 ..< map.alignedFrameCount else { throw .invalidBacking(key) }
            }
            guard let protected = protectedFrames[key] else { throw .missingProtection(key) }
            var previous: Int64 = 0
            for span in protected {
                guard span.lowerBound >= previous, span.lowerBound < span.upperBound,
                      span.upperBound <= map.alignedFrameCount
                else { throw .invalidProtection(key) }
                previous = span.upperBound
            }
        }
        for key in inventory where !seen.contains(key) { throw .missingLane(key) }
        for key in protectedFrames.keys where !expected.contains(key) { throw .unexpectedLane(key) }

        guard claimedRoundedRemovals == map.removals else { throw .removalMismatch }
        guard fadeFootprints.count == map.removals.count else {
            throw .fadeCountMismatch(expected: map.removals.count, actual: fadeFootprints.count)
        }
        for (index, (cut, fade)) in zip(map.removals, fadeFootprints).enumerated() {
            guard fade.start >= 0, fade.start <= cut.start, fade.end >= cut.end,
                  fade.end <= map.alignedFrameCount
            else { throw .invalidFade(fade) }
            if index > 0, fadeFootprints[index - 1].end > fade.start {
                throw .overlappingFades(fadeFootprints[index - 1], fade)
            }
            for key in inventory {
                guard let protected = protectedFrames[key] else { throw .missingProtection(key) }
                for span in protected {
                    if cut.start < span.upperBound && span.lowerBound < cut.end {
                        throw .unsafeRemoval(key, cut)
                    }
                    if fade.start < span.upperBound && span.lowerBound < fade.end {
                        throw .unsafeFade(key, fade)
                    }
                }
            }
        }
        return CommonRenderBinding(map: map, lanes: lanes)
    }
}
