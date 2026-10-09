import WWCore
import WWTimeMap

/// Half-open source-frame coordinates of one named occurrence, never output-grid coordinates.
public struct SourceFrameSpan: Sendable, Hashable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}

public enum ProvisionalCutMode: Sendable { case shorten, lift }

/// Caller-supplied snapshot identity; matching revisions do not establish organizer authority.
public struct KeyedEditLane: Sendable, Hashable {
    public let lane: CommonEditManifestLane
    public let epoch: RecordingEpochID?
    public let alignmentRevision: UInt64
    public let revision: String

    public init(lane: CommonEditManifestLane, epoch: RecordingEpochID?,
                alignmentRevision: UInt64, revision: String) {
        self.lane = lane
        self.epoch = epoch
        self.alignmentRevision = alignmentRevision
        self.revision = revision
    }
}

/// Untrusted per-lane observations; protection and merged fades still need independent verification.
public struct KeyedLaneFootprintInput: Sendable {
    public let identity: KeyedEditLane
    public let survey: CommonEditLaneSurvey
    public let sourceCoverage: [SourceFrameSpan]
    public let protected: [SourceFrameSpan]
    public let requestedFadeOut: SourceFrameSpan?
    public let requestedFadeIn: SourceFrameSpan?
    public let finalMergedFades: [SourceFrameSpan]

    public init(
        identity: KeyedEditLane, survey: CommonEditLaneSurvey,
        sourceCoverage: [SourceFrameSpan] = [], protected: [SourceFrameSpan] = [],
        requestedFadeOut: SourceFrameSpan? = nil, requestedFadeIn: SourceFrameSpan? = nil,
        finalMergedFades: [SourceFrameSpan] = []
    ) {
        self.identity = identity
        self.survey = survey
        self.sourceCoverage = sourceCoverage
        self.protected = protected
        self.requestedFadeOut = requestedFadeOut
        self.requestedFadeIn = requestedFadeIn
        self.finalMergedFades = finalMergedFades
    }
}

public struct ProvisionalLaneCutMapping: Sendable {
    public let identity: KeyedEditLane
    public let sourceRemoval: SourceFrameSpan?
    public let finalMergedFades: [SourceFrameSpan]
    public let finalMergedGridFades: [RemovedFrameSpan]
}

/// Neither a WWCutPolicy footprint nor an accepted cut, source witness or render permit.
public struct ProvisionalKeyedCutMapping: Sendable {
    public let grid: RemovedFrameSpan
    public let map: CommonEpisodeEditMap
    public let lanes: [ProvisionalLaneCutMapping]
}

public enum ProvisionalCutMappingError: Error, Equatable, Sendable {
    case invalidLanes
    case invalidGrid
    case ambiguousInverse
    case incompleteCoverage
    case protectedFrame
    case invalidFade
    case structuralPreflight(CommonEditAttestationRefusal)
}

public enum KeyedCutMapping {
    /// Rounds the selected Primary's two exact source boundaries once on the common output grid.
    /// Every audio lane must invert the resulting complete interval in its own occurrence and epoch.
    /// The manifest, surveys, revisions, protection and fade observations remain untrusted.
    public static func map(
        base: CommonEpisodeEditMap, manifest: CommonEditLaneManifest,
        manifestRevision: String, laneKeys: [KeyedEditLane],
        selectedPrimary: KeyedEditLane, primary: KeyedEditLane,
        sourceFrames: SourceFrameSpan, mode: ProvisionalCutMode,
        outputRate: NominalRate, fadeOutOutputFrames: Int64, fadeInOutputFrames: Int64,
        proofs: [KeyedLaneFootprintInput]
    ) throws(ProvisionalCutMappingError) -> ProvisionalKeyedCutMapping {
        guard !manifestRevision.isEmpty, manifest.revision == manifestRevision,
              !laneKeys.isEmpty, laneKeys.count == manifest.lanes.count,
              proofs.count == laneKeys.count,
              Set(laneKeys).count == laneKeys.count,
              Set(manifest.lanes).count == manifest.lanes.count,
              laneKeys.map(\.lane) == manifest.lanes,
              proofs.map(\.identity) == laneKeys,
              zip(proofs, laneKeys).allSatisfy({ $0.survey.lane == $1.lane }),
              laneKeys.allSatisfy({ !$0.revision.isEmpty &&
                  $0.alignmentRevision == base.alignmentRevision }),
              laneKeys.filter({ $0 == selectedPrimary }).count == 1,
              primary == selectedPrimary
        else { throw .invalidLanes }
        guard outputRate == base.outputRate, fadeOutOutputFrames >= 0,
              fadeInOutputFrames >= 0 else { throw .invalidGrid }
        guard case let .audio(primaryKey) = primary.lane, let primaryEpoch = primary.epoch,
              sourceFrames.start >= 0, sourceFrames.start < sourceFrames.end
        else { throw .invalidGrid }

        let placements = base.alignment.groups.flatMap(\.placements)
        let occurrences = Dictionary(uniqueKeysWithValues: placements.map { ($0.occurrence.id, $0.occurrence) })
        let audioKeys = laneKeys.compactMap { identity -> CommonEditLaneKey? in
            if case let .audio(key) = identity.lane { return key }
            return nil
        }
        guard Set(audioKeys.map(\.occurrence)) == Set(occurrences.keys),
              laneKeys.allSatisfy({ identity in
                  switch identity.lane {
                  case let .audio(key):
                      return key.channel >= 0 && identity.epoch != nil &&
                          occurrences[key.occurrence]?.source == key.source
                  case let .intentionalSilence(id):
                      return !id.isEmpty && identity.epoch == nil
                  }
              }),
              let primaryOccurrence = occurrences[primaryKey.occurrence]
        else { throw .invalidLanes }
        guard sourceFrames.end < primaryOccurrence.frameCount else { throw .invalidGrid }

        let start = try alignedBoundary(sourceFrames.start, occurrence: primaryKey.occurrence,
                                        epoch: primaryEpoch, alignment: base.alignment)
        let end = try alignedBoundary(sourceFrames.end, occurrence: primaryKey.occurrence,
                                      epoch: primaryEpoch, alignment: base.alignment)
        let qStart = try roundedGrid(start, rate: outputRate)
        let qEnd = try roundedGrid(end, rate: outputRate)
        let grid = RemovedFrameSpan(start: qStart, end: qEnd)
        guard qStart >= base.alignedFrameOrigin, qEnd > qStart, qEnd <= base.alignedFrameEnd,
              qEnd - qStart <= CommonEditPreflight.maximumInspectedFrames,
              !base.removals.contains(where: { $0.start < qEnd && qStart < $0.end })
        else { throw .invalidGrid }
        let removals: [RemovedFrameSpan]
        if mode == .shorten {
            removals = (base.removals + [grid]).sorted { $0.start < $1.start }
        } else {
            removals = base.removals
        }
        let (nextRevision, overflow) = base.editRevision.addingReportingOverflow(1)
        guard !overflow,
              let map = try? CommonEpisodeEditMap(
                  alignment: base.alignment, alignmentRevision: base.alignmentRevision,
                  editRevision: nextRevision, outputRate: outputRate,
                  alignedFrameOrigin: base.alignedFrameOrigin, alignedFrameCount: base.alignedFrameCount,
                  removals: removals
              ) else { throw .invalidGrid }

        var mapped: [ProvisionalLaneCutMapping] = []
        var gridSurveys: [CommonEditLaneSurvey] = []
        for proof in proofs {
            switch proof.identity.lane {
            case .intentionalSilence:
                guard proof.sourceCoverage.isEmpty, proof.protected.isEmpty,
                      proof.requestedFadeOut == nil, proof.requestedFadeIn == nil,
                      proof.finalMergedFades.isEmpty,
                      contains(grid, in: proof.survey.intentionalSilence)
                else { throw .incompleteCoverage }
                gridSurveys.append(proof.survey)
                mapped.append(.init(identity: proof.identity, sourceRemoval: nil,
                                    finalMergedFades: [], finalMergedGridFades: []))
            case let .audio(key):
                guard let occurrence = occurrences[key.occurrence], let epoch = proof.identity.epoch,
                      valid(proof.sourceCoverage, limit: occurrence.frameCount),
                      valid(proof.protected, limit: occurrence.frameCount),
                      valid(proof.finalMergedFades, limit: occurrence.frameCount),
                      proof.protected.allSatisfy({ contains($0, in: proof.sourceCoverage) })
                else { throw .incompleteCoverage }
                let startPosition = try inverse(qStart, key: key, epoch: epoch, base: base)
                let endPosition = try inverse(qEnd, key: key, epoch: epoch, base: base)
                let removal = SourceFrameSpan(start: startPosition, end: endPosition)
                guard removal.start >= 0, removal.start < removal.end,
                      removal.end <= occurrence.frameCount,
                      removal.end - removal.start <= CommonEditPreflight.maximumInspectedFrames,
                      contains(removal, in: proof.sourceCoverage),
                      contains(grid, in: proof.survey.coverage),
                      !proof.survey.intentionalSilence.contains(where: { $0.start < qEnd && qStart < $0.end })
                else { throw .incompleteCoverage }
                if proof.identity == primary && removal != sourceFrames { throw .invalidGrid }
                for frame in qStart..<qEnd {
                    let source = try inverse(frame, key: key, epoch: epoch, base: base)
                    guard source >= removal.start, source < removal.end,
                          contains(SourceFrameSpan(start: source, end: source + 1), in: proof.sourceCoverage)
                    else { throw .incompleteCoverage }
                }
                for sourceFrame in removal.start..<removal.end {
                    guard let forward = try? base.alignment.alignedTime(
                        ofFrame: sourceFrame, in: key.occurrence
                    ), case let .aligned(position) = forward, position.epoch == epoch
                    else { throw .ambiguousInverse }
                }
                guard !proof.protected.contains(where: { intersects($0, removal) }) else {
                    throw .protectedFrame
                }
                let fades = try validateFades(proof, removal: removal, limit: occurrence.frameCount,
                                              map: map, fadeOutLength: fadeOutOutputFrames,
                                              fadeInLength: fadeInOutputFrames)
                guard (proof.survey.requestedFades.isEmpty ||
                       proof.survey.requestedFades == fades.requested),
                      (proof.survey.finalMergedFades.isEmpty ||
                       proof.survey.finalMergedFades == fades.final) else { throw .invalidFade }
                gridSurveys.append(.init(
                    lane: proof.identity.lane, coverage: proof.survey.coverage,
                    intentionalSilence: proof.survey.intentionalSilence,
                    protected: proof.survey.protected, requestedFades: fades.requested,
                    finalMergedFades: fades.final
                ))
                mapped.append(.init(identity: proof.identity, sourceRemoval: removal,
                                    finalMergedFades: proof.finalMergedFades,
                                    finalMergedGridFades: fades.final))
            }
        }
        do { _ = try CommonEditPreflight.check(map: map, manifest: manifest, surveys: gridSurveys) }
        catch { throw .structuralPreflight(error) }
        return .init(grid: grid, map: map, lanes: mapped)
    }

    private static func alignedBoundary(
        _ frame: Int64, occurrence: SourceOccurrenceID, epoch: RecordingEpochID,
        alignment: AlignedTimelineMap
    ) throws(ProvisionalCutMappingError) -> ExactRational {
        guard let mapped = try? alignment.alignedTime(ofFrame: frame, in: occurrence),
              case let .aligned(position) = mapped, position.epoch == epoch else {
            throw .ambiguousInverse
        }
        return position.instant
    }

    private static func roundedGrid(
        _ instant: ExactRational, rate: NominalRate
    ) throws(ProvisionalCutMappingError) -> Int64 {
        guard let exact = try? instant.multiplied(by: ExactRational(rate.framesPerSecond)) else {
            throw .invalidGrid
        }
        let rounded = exact.roundedHalfUp()
        guard rounded >= Int128(Int64.min), rounded < Int128(Int64.max) else { throw .invalidGrid }
        return Int64(rounded)
    }

    private static func inverse(
        _ gridFrame: Int64, key: CommonEditLaneKey, epoch: RecordingEpochID,
        base: CommonEpisodeEditMap
    ) throws(ProvisionalCutMappingError) -> Int64 {
        guard let mapped = try? base.alignment.sourceFrame(
            at: base.outputRate.instant(ofFrame: gridFrame), in: key.occurrence
        ), case let .source(position) = mapped, position.epoch == epoch,
              position.occurrence == key.occurrence,
              let forward = try? base.alignment.alignedTime(ofFrame: position.frame, in: key.occurrence),
              case let .aligned(aligned) = forward, aligned.epoch == epoch,
              let error = try? aligned.instant.subtracting(base.outputRate.instant(ofFrame: gridFrame))
                  .multiplied(by: ExactRational(base.outputRate.framesPerSecond)),
              error >= ExactRational(-1), error <= ExactRational(1)
        else { throw .ambiguousInverse }
        return position.frame
    }

    private static func validateFades(
        _ proof: KeyedLaneFootprintInput, removal: SourceFrameSpan, limit: Int64,
        map: CommonEpisodeEditMap, fadeOutLength: Int64, fadeInLength: Int64
    ) throws(ProvisionalCutMappingError) -> (requested: [RemovedFrameSpan], final: [RemovedFrameSpan]) {
        let out = proof.requestedFadeOut, inside = proof.requestedFadeIn
        guard (out != nil) == (fadeOutLength > 0),
              (inside != nil) == (fadeInLength > 0),
              case let .audio(key) = proof.identity.lane, let epoch = proof.identity.epoch
        else { throw .invalidFade }
        var requestedGrid: [RemovedFrameSpan] = []
        for (span, length) in [(out, fadeOutLength), (inside, fadeInLength)] {
            guard let span else { continue }
            let grid = try gridFade(span, key: key, epoch: epoch, map: map, limit: limit)
            guard grid.end - grid.start == length else { throw .invalidFade }
            requestedGrid.append(grid)
        }
        for requested in [out, inside].compactMap({ $0 }) {
            guard valid([requested], limit: limit),
                  contains(requested, in: proof.finalMergedFades) else { throw .invalidFade }
        }
        guard out.map({ $0.end <= removal.start }) ?? true,
              inside.map({ $0.start >= removal.end }) ?? true,
              proof.finalMergedFades.allSatisfy({
                  contains($0, in: proof.sourceCoverage) && !intersects($0, removal)
              }) else { throw .invalidFade }
        guard !proof.finalMergedFades.contains(where: { fade in
            proof.protected.contains(where: { intersects(fade, $0) })
        }) else { throw .protectedFrame }
        var finalGrid: [RemovedFrameSpan] = []
        for fade in proof.finalMergedFades {
            finalGrid.append(try gridFade(fade, key: key, epoch: epoch, map: map, limit: limit))
        }
        return (requestedGrid, finalGrid)
    }

    private static func gridFade(
        _ fade: SourceFrameSpan, key: CommonEditLaneKey, epoch: RecordingEpochID,
        map: CommonEpisodeEditMap, limit: Int64
    ) throws(ProvisionalCutMappingError) -> RemovedFrameSpan {
        guard valid([fade], limit: limit), fade.end < limit,
              fade.end - fade.start <= CommonEditPreflight.maximumInspectedFrames
        else { throw .invalidFade }
        let start = try alignedBoundary(fade.start, occurrence: key.occurrence,
                                        epoch: epoch, alignment: map.alignment)
        let end = try alignedBoundary(fade.end, occurrence: key.occurrence,
                                      epoch: epoch, alignment: map.alignment)
        let first = try roundedGrid(start, rate: map.outputRate)
        let last = try roundedGrid(end, rate: map.outputRate)
        let grid = RemovedFrameSpan(start: first, end: last)
        guard first >= map.alignedFrameOrigin, last <= map.alignedFrameEnd,
              first < last else { throw .invalidFade }
        for sourceFrame in fade.start..<fade.end {
            let instant = try alignedBoundary(sourceFrame, occurrence: key.occurrence,
                                               epoch: epoch, alignment: map.alignment)
            guard case .mapped = try? map.outputPosition(atAlignedInstant: instant) else {
                throw .invalidFade
            }
        }
        return grid
    }

    private static func intersects(_ a: SourceFrameSpan, _ b: SourceFrameSpan) -> Bool {
        a.start < b.end && b.start < a.end
    }

    private static func contains(_ span: SourceFrameSpan, in spans: [SourceFrameSpan]) -> Bool {
        var cursor = span.start
        for part in spans where part.end > cursor {
            guard part.start <= cursor else { return false }
            cursor = part.end
            if cursor >= span.end { return true }
        }
        return false
    }

    private static func contains(_ span: RemovedFrameSpan, in spans: [RemovedFrameSpan]) -> Bool {
        var cursor = span.start
        for part in spans where part.end > cursor {
            guard part.start <= cursor else { return false }
            cursor = part.end
            if cursor >= span.end { return true }
        }
        return false
    }

    private static func valid(_ spans: [SourceFrameSpan], limit: Int64) -> Bool {
        spans.enumerated().allSatisfy { index, span in
            span.start >= 0 && span.start < span.end && span.end <= limit &&
            (index == 0 || spans[index - 1].end <= span.start)
        }
    }
}
