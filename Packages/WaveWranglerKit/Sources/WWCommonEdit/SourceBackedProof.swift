import Foundation
import WWCore
import WWDecode
import WWTimeMap

/// A transient diagnostic, not a capability to shorten, render or publish. SourceDecoder has
/// verified each read-only source before this value is returned; later changes still invalidate it.
public struct ProvisionalSourceBackedProof: Sendable {
    public let map: CommonEpisodeEditMap
    public let episode: EpisodeID
    public let lanes: [ProvenSourceLane]

    private init(map: CommonEpisodeEditMap, episode: EpisodeID, lanes: [ProvenSourceLane]) {
        self.map = map
        self.episode = episode
        self.lanes = lanes
    }

    /// Inspect actual decoded samples, never an editor-supplied "verified" bit or protection list.
    /// Every nonzero source sample is protected, irrespective of speaker or transcript assignment.
    /// `knownProtectedFrames` only adds vetoes (including intentional protected silence); omission
    /// never establishes a complete speech survey. Exact zero is not a speech classification.
    public static func inspect(
        episode: Episode,
        map: CommonEpisodeEditMap,
        sourceURLs: [SourceID: URL],
        decoder: SourceDecoder,
        finalFadeFootprints: [RemovedFrameSpan],
        knownProtectedFrames: [CommonRenderLaneKey: [Range<Int64>]] = [:]
    ) async throws -> Self {
        let inventory = try ProvisionalLaneInventory.inspect(episode: episode, map: map)
        let expected = Set(inventory.requirements.map(\.source))
        for source in expected where sourceURLs[source] == nil { throw SourceProofRefusal.sourceUnavailable(source) }
        for source in sourceURLs.keys where !expected.contains(source) { throw SourceProofRefusal.unexpectedSource(source) }
        guard let inputs = episode.alignment?.acceptedMap?.inputs.sources else {
            throw SourceProofRefusal.acceptedInputsUnavailable
        }
        var decoded: [SourceID: DecodedSource<SourceSignal>] = [:]
        for source in episode.sources {
            let id = source.id
            guard let url = sourceURLs[id], let input = inputs.first(where: { $0.sourceID == id }),
                  input.formatInterpretationVersion == FormatInterpretation.currentVersion,
                  input.contentDigest == nil
            else { throw SourceProofRefusal.unverifiedMapInput(id) }
            do {
                decoded[id] = try await decoder.decode(url, source: id) { format in
                    NonzeroSignalSink(channels: format.channelCount)
                }
            } catch let failure as DecodeFailure {
                throw SourceProofRefusal.decodeFailed(id, failure)
            }
        }

        guard finalFadeFootprints.count == map.removals.count else { throw SourceProofRefusal.fadeCountMismatch }
        var fades: [RemovedFrameSpan] = []
        for (cut, fade) in zip(map.removals, finalFadeFootprints) {
            guard fade.start >= 0, fade.start <= cut.start, fade.end >= cut.end,
                  fade.end <= map.alignedFrameCount else { throw SourceProofRefusal.invalidFade(fade) }
            if let last = fades.last, fade.start <= last.end {
                fades[fades.count - 1] = RemovedFrameSpan(start: min(last.start, fade.start),
                                                          end: max(last.end, fade.end))
            } else {
                fades.append(fade)
            }
        }
        let gridStart = map.outputRate.instant(ofFrame: 0)
        let gridEnd = map.outputRate.instant(ofFrame: map.alignedFrameCount)
        var lanes: [ProvenSourceLane] = []
        for group in map.alignment.groups {
            for placement in group.placements {
                let occurrence = placement.occurrence
                guard let result = decoded[occurrence.source] else {
                    throw SourceProofRefusal.sourceUnavailable(occurrence.source)
                }
                let format = result.interpretation
                guard format.output.representsSourceSamplesExactly else {
                    throw SourceProofRefusal.inexactDecode(occurrence.source)
                }
                guard format.source == occurrence.source,
                      Int64(format.sourceSampleRate) == occurrence.nominalRate.framesPerSecond,
                      format.frames.validFrames == occurrence.frameCount,
                      format.channelCount == episode.source(occurrence.source)?.observations.channelCount.value,
                      result.product.frames == occurrence.frameCount
                else { throw SourceProofRefusal.formatChanged(occurrence.source) }

                let coverage = try intervals(
                    group: group, placement: placement, frames: 0..<occurrence.frameCount
                )
                let ordered = coverage.sorted { $0.lowerBound < $1.lowerBound }
                guard (ordered.first?.lowerBound ?? .zero) >= gridStart else {
                    throw SourceProofRefusal.negativeAlignedOrigin(occurrence.id)
                }
                var end = gridStart
                var hasInterval = false
                for interval in ordered {
                    guard interval.lowerBound <= end else {
                        throw SourceProofRefusal.uncovered(occurrence.id)
                    }
                    guard !hasInterval || interval.lowerBound >= end else {
                        throw SourceProofRefusal.nonuniqueCoverage(occurrence.id)
                    }
                    end = max(end, interval.upperBound)
                    hasInterval = true
                }
                guard end >= gridEnd else { throw SourceProofRefusal.uncovered(occurrence.id) }
                guard end == gridEnd else { throw SourceProofRefusal.outsideEpisodeCoverage(occurrence.id) }
                for cut in map.removals {
                    for boundary in [cut.start, cut.end] {
                        let instant = map.outputRate.instant(ofFrame: boundary)
                        guard case .source = try map.alignment.sourceFrame(at: instant, in: occurrence.id)
                        else { throw SourceProofRefusal.boundaryNotInvertible(occurrence.id, boundary) }
                    }
                }
                for channel in 0..<format.channelCount {
                    let key = CommonRenderLaneKey(occurrence: occurrence.id, decodedChannel: channel)
                    var previous: Int64 = 0
                    for protected in knownProtectedFrames[key] ?? [] {
                        guard protected.lowerBound >= previous,
                              protected.lowerBound < protected.upperBound,
                              protected.upperBound <= map.alignedFrameCount
                        else { throw SourceProofRefusal.invalidKnownProtection(key) }
                        previous = protected.upperBound
                        let interval = map.outputRate.instant(ofFrame: protected.lowerBound)
                            ..< map.outputRate.instant(ofFrame: protected.upperBound)
                        for cut in map.removals where overlaps(interval, cut, rate: map.outputRate) {
                            throw SourceProofRefusal.unsafeRemoval(key, cut)
                        }
                        for fade in fades where overlaps(interval, fade, rate: map.outputRate) {
                            throw SourceProofRefusal.unsafeFade(key, fade)
                        }
                    }
                    for active in result.product.nonzero[channel] {
                        let affected = try intervals(group: group, placement: placement, frames: active)
                        for interval in affected {
                            for cut in map.removals where overlaps(interval, cut, rate: map.outputRate) {
                                throw SourceProofRefusal.unsafeRemoval(key, cut)
                            }
                            for fade in fades where overlaps(interval, fade, rate: map.outputRate) {
                                throw SourceProofRefusal.unsafeFade(key, fade)
                            }
                        }
                    }
                    lanes.append(ProvenSourceLane(key: key, source: occurrence.source,
                                                 interpretation: format,
                                                 digitalSilence: result.product.nonzero[channel].isEmpty))
                }
            }
        }
        guard Set(lanes.map(\.key)) == Set(inventory.requirements.map(\.key)) else {
            throw SourceProofRefusal.incompleteInventory
        }
        for key in knownProtectedFrames.keys where !lanes.contains(where: { $0.key == key }) {
            throw SourceProofRefusal.unknownProtectedLane(key)
        }
        return Self(map: map, episode: episode.id, lanes: lanes)
    }

    private static func overlaps(_ interval: Range<ExactRational>, _ span: RemovedFrameSpan, rate: NominalRate) -> Bool {
        interval.lowerBound < rate.instant(ofFrame: span.end)
            && rate.instant(ofFrame: span.start) < interval.upperBound
    }

    /// Project every part of a decoded source-frame interval through the epoch's exact affine
    /// pieces. A missing/unsupported piece cannot become a fabricated silent backing interval.
    private static func intervals(
        group: GroupTimeMap, placement: OccurrencePlacement, frames: Range<Int64>
    ) throws -> [Range<ExactRational>] {
        let rate = placement.occurrence.nominalRate
        var result: [Range<ExactRational>] = []
        var sourceEnd: Int64 = 0
        for span in placement.spans {
            guard span.startFrame == sourceEnd else {
                throw SourceProofRefusal.uncovered(placement.occurrence.id)
            }
            sourceEnd = span.endFrame
            let low = max(frames.lowerBound, span.startFrame)
            let high = min(frames.upperBound, span.endFrame)
            guard low < high else { continue }
            guard let epoch = group.epochs.first(where: { $0.epoch == span.epoch }),
                  case let .mapped(segments, _) = epoch.mapping
            else { throw SourceProofRefusal.unsupportedEpoch(span.epoch) }
            let first = try rate.instant(ofFrame: low).adding(span.groupClockOffset)
            let last = try rate.instant(ofFrame: high).adding(span.groupClockOffset)
            var covered = first
            for segment in segments {
                let start = max(first, segment.groupClockStart)
                let end = min(last, segment.groupClockEnd)
                guard start < end else { continue }
                guard start == covered else {
                    throw SourceProofRefusal.uncovered(placement.occurrence.id)
                }
                let mappedStart = try segment.rateRatio.multiplied(by: start).adding(segment.alignedOffset)
                let mappedEnd = try segment.rateRatio.multiplied(by: end).adding(segment.alignedOffset)
                result.append(mappedStart..<mappedEnd)
                covered = end
            }
            guard covered == last else { throw SourceProofRefusal.uncovered(placement.occurrence.id) }
        }
        guard sourceEnd == placement.occurrence.frameCount else {
            throw SourceProofRefusal.uncovered(placement.occurrence.id)
        }
        return result
    }
}

public struct ProvenSourceLane: Sendable {
    public let key: CommonRenderLaneKey
    public let source: SourceID
    public let interpretation: FormatInterpretation
    /// True only when every decoded sample in this channel was exactly zero during the verified read.
    public let digitalSilence: Bool
}

public enum SourceProofRefusal: Error, Equatable, Sendable {
    case sourceUnavailable(SourceID)
    case unexpectedSource(SourceID)
    case acceptedInputsUnavailable
    case unverifiedMapInput(SourceID)
    case decodeFailed(SourceID, DecodeFailure)
    case inexactDecode(SourceID)
    case formatChanged(SourceID)
    case unsupportedEpoch(RecordingEpochID)
    case negativeAlignedOrigin(SourceOccurrenceID)
    case uncovered(SourceOccurrenceID)
    case outsideEpisodeCoverage(SourceOccurrenceID)
    case nonuniqueCoverage(SourceOccurrenceID)
    case boundaryNotInvertible(SourceOccurrenceID, Int64)
    case invalidFade(RemovedFrameSpan)
    case fadeCountMismatch
    case invalidKnownProtection(CommonRenderLaneKey)
    case unknownProtectedLane(CommonRenderLaneKey)
    case unsafeRemoval(CommonRenderLaneKey, RemovedFrameSpan)
    case unsafeFade(CommonRenderLaneKey, RemovedFrameSpan)
    case incompleteInventory
}

private struct SourceSignal: Sendable {
    let frames: Int64
    let nonzero: [[Range<Int64>]]
}

private struct NonzeroSignalSink: DecodedAudioSink {
    private var position: Int64 = 0
    private var nonzero: [[Range<Int64>]]
    private var open: [Int64?]

    init(channels: Int) {
        nonzero = Array(repeating: [], count: channels)
        open = Array(repeating: nil, count: channels)
    }

    mutating func append(_ chunk: DecodedChunk) throws {
        guard chunk.firstSourceFrame == position, chunk.channelCount == nonzero.count else {
            throw SignalError.discontinuous
        }
        for channel in nonzero.indices {
            for (offset, sample) in chunk.channel(channel).enumerated() {
                guard sample.isFinite else { throw SignalError.nonfinite }
                let frame = position + Int64(offset)
                if sample != 0 {
                    if open[channel] == nil { open[channel] = frame }
                } else if let start = open[channel] {
                    nonzero[channel].append(start..<frame)
                    open[channel] = nil
                }
            }
        }
        position += Int64(chunk.frameCount)
    }

    mutating func finish() throws -> SourceSignal {
        for channel in nonzero.indices {
            if let start = open[channel] { nonzero[channel].append(start..<position) }
        }
        return SourceSignal(frames: position, nonzero: nonzero)
    }

    mutating func abandon() {
        nonzero.removeAll()
        open.removeAll()
    }

    private enum SignalError: Error { case discontinuous, nonfinite }
}
