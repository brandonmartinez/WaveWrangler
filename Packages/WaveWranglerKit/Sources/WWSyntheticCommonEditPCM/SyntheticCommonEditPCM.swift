import WWCommonEdit

struct SyntheticPCMChunk: Sendable {
    let firstOutputFrame: Int64
    let frameCount: Int
    let channelCount: Int
    let samples: [Float]
}

/// Test-only, already-aligned PCM. This internal boundary has no source provider or production issuer.
struct SyntheticAlignedPCM: Sendable {
    let lanes: [(identity: KeyedEditLane, samples: [Float])]
}

enum SyntheticCommonEditPCMError: Error, Equatable {
    case invalidPlan
    case invalidInput
    case invalidFade
    case resourceLimit
    case cancelled
    case structuralPreflight(CommonEditAttestationRefusal)
}

enum SyntheticFadeDirection: Sendable, Equatable {
    case fadeOut
    case fadeIn
}

struct SyntheticLaneFade: Sendable {
    let identity: KeyedEditLane
    let frames: RemovedFrameSpan
    let direction: SyntheticFadeDirection
}

/// An immutable, provisional prescription shared by synthetic preview and export consumers.
/// It is not a cut admission, source-access witness, or production render authorization.
struct SyntheticCommonEditPCMPlan: Sendable {
    let base: CommonEpisodeEditMap
    let mapping: ProvisionalKeyedCutMapping
    let mode: ProvisionalCutMode
    let manifest: CommonEditLaneManifest
    let surveys: [CommonEditLaneSurvey]
    let fades: [SyntheticLaneFade]

    init(
        base: CommonEpisodeEditMap, mapping: ProvisionalKeyedCutMapping,
        mode: ProvisionalCutMode, manifest: CommonEditLaneManifest,
        surveys: [CommonEditLaneSurvey], fades: [SyntheticLaneFade]
    ) throws(SyntheticCommonEditPCMError) {
        guard base.alignedFrameCount <= CommonEditPreflight.maximumInspectedFrames,
              manifest.lanes.count <= CommonEditPreflight.maximumInspectedLanes,
              surveys.count <= CommonEditPreflight.maximumInspectedLanes,
              fades.count <= CommonEditPreflight.maximumInspectedIntervals
        else { throw .resourceLimit }
        guard base.alignment == mapping.map.alignment,
              base.alignmentRevision == mapping.map.alignmentRevision,
              base.outputRate == mapping.map.outputRate,
              base.alignedFrameOrigin == mapping.map.alignedFrameOrigin,
              base.alignedFrameCount == mapping.map.alignedFrameCount,
              mapping.grid.start >= base.alignedFrameOrigin,
              mapping.grid.start < mapping.grid.end,
              mapping.grid.end <= base.alignedFrameEnd,
              !base.removals.contains(where: {
                  $0.start < mapping.grid.end && mapping.grid.start < $0.end
              }),
              mapping.lanes.count == manifest.lanes.count,
              mapping.lanes.map(\.identity.lane) == manifest.lanes,
              Set(mapping.lanes.map(\.identity)).count == mapping.lanes.count,
              mapping.lanes.allSatisfy({
                  !$0.identity.revision.isEmpty &&
                  $0.identity.alignmentRevision == base.alignmentRevision &&
                  ($0.identity.epoch != nil) == ($0.sourceRemoval != nil)
              }),
              !manifest.revision.isEmpty,
              manifest.revision == mapping.manifestRevision,
              surveys.map(\.lane) == manifest.lanes,
              zip(mapping.lanes, surveys).allSatisfy({
                  $0.survey == $1 && $0.finalMergedGridFades == $1.finalMergedFades
              }),
              surveys.allSatisfy({ survey in
                  !survey.protected.contains {
                      $0.start < mapping.grid.end && mapping.grid.start < $0.end
                  }
              })
        else { throw .invalidPlan }
        let (revision, overflow) = base.editRevision.addingReportingOverflow(1)
        guard !overflow else { throw .invalidPlan }
        let removals = mode == .shorten
            ? (base.removals + [mapping.grid]).sorted { $0.start < $1.start }
            : base.removals
        guard let expected = try? CommonEpisodeEditMap(
            alignment: base.alignment, alignmentRevision: base.alignmentRevision,
            editRevision: revision, outputRate: base.outputRate,
            alignedFrameOrigin: base.alignedFrameOrigin, alignedFrameCount: base.alignedFrameCount,
            removals: removals
        ), expected == mapping.map
        else { throw .invalidPlan }
        do { _ = try CommonEditPreflight.check(map: mapping.map, manifest: manifest, surveys: surveys) }
        catch { throw .structuralPreflight(error) }

        for lane in mapping.lanes {
            let envelope = fades.filter { $0.identity == lane.identity }
                .sorted { $0.frames.start < $1.frames.start }
            if case .intentionalSilence = lane.identity.lane, !envelope.isEmpty {
                throw .invalidFade
            }
            var covered: [RemovedFrameSpan] = []
            for fade in envelope {
                guard fade.frames.start >= base.alignedFrameOrigin,
                      fade.frames.start < fade.frames.end,
                      fade.frames.end <= base.alignedFrameEnd,
                      !mapping.map.removals.contains(where: {
                          $0.start < fade.frames.end && fade.frames.start < $0.end
                      }),
                      !(mode == .lift && fade.frames.start < mapping.grid.end &&
                        mapping.grid.start < fade.frames.end),
                      covered.last.map({ $0.end <= fade.frames.start }) ?? true
                else { throw .invalidFade }
                covered.append(fade.frames)
            }
            let claimed = lane.finalMergedGridFades
            guard claimed.allSatisfy({ $0.start < $0.end }),
                  lane.survey.requestedFades ==
                      [lane.requestedFadeOutGrid, lane.requestedFadeInGrid].compactMap({ $0 })
            else { throw .invalidFade }
            let merged = Self.union(claimed)
            guard envelope.count == merged.count else { throw .invalidFade }
            for (fade, footprint) in zip(envelope, merged) {
                let out = lane.requestedFadeOutGrid.map {
                    $0.start >= footprint.start && $0.end <= footprint.end &&
                    footprint.end <= mapping.grid.start
                } ?? false
                let inside = lane.requestedFadeInGrid.map {
                    $0.start >= footprint.start && $0.end <= footprint.end &&
                    footprint.start >= mapping.grid.end
                } ?? false
                guard out != inside, fade.frames == footprint,
                      fade.direction == (out ? .fadeOut : .fadeIn)
                else { throw .invalidFade }
            }
        }
        guard fades.allSatisfy({ fade in mapping.lanes.contains { $0.identity == fade.identity } })
        else { throw .invalidFade }
        self.base = base
        self.mapping = mapping
        self.mode = mode
        self.manifest = manifest
        self.surveys = surveys
        self.fades = fades
    }

    private static func union(_ spans: [RemovedFrameSpan]) -> [RemovedFrameSpan] {
        var merged: [RemovedFrameSpan] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

struct SyntheticCommonEditPCMResult: Sendable {
    let plan: SyntheticCommonEditPCMPlan
    let chunks: [SyntheticPCMChunk]
}

enum SyntheticCommonEditPCMRenderer {
    static func render(
        _ plan: SyntheticCommonEditPCMPlan, input: SyntheticAlignedPCM, chunkFrames: Int
    ) throws(SyntheticCommonEditPCMError) -> SyntheticCommonEditPCMResult {
        guard !Task.isCancelled else { throw .cancelled }
        let count = plan.base.alignedFrameCount
        let laneCount = plan.mapping.lanes.count
        guard chunkFrames > 0, chunkFrames <= Int(CommonEditPreflight.maximumInspectedFrames),
              count <= CommonEditPreflight.maximumInspectedFrames,
              laneCount <= CommonEditPreflight.maximumInspectedLanes
        else { throw .resourceLimit }
        guard input.lanes.count == laneCount else { throw .invalidInput }
        for (index, (supplied, expected)) in zip(input.lanes, plan.mapping.lanes).enumerated() {
            guard supplied.identity == expected.identity,
                  Int64(supplied.samples.count) == count,
                  supplied.samples.allSatisfy(\.isFinite)
            else { throw .invalidInput }
            if case .intentionalSilence = expected.identity.lane {
                guard supplied.samples.allSatisfy({ $0 == 0 }) else { throw .invalidInput }
            }
            for silence in plan.surveys[index].intentionalSilence {
                let lower = Int(silence.start - plan.base.alignedFrameOrigin)
                let upper = Int(silence.end - plan.base.alignedFrameOrigin)
                guard supplied.samples[lower..<upper].allSatisfy({ $0 == 0 }) else {
                    throw .invalidInput
                }
            }
        }

        let map = plan.mapping.map
        var chunks: [SyntheticPCMChunk] = []
        var outputFrame: Int64 = 0
        while outputFrame < map.outputFrameCount {
            guard !Task.isCancelled else { throw .cancelled }
            let frames = Int(min(Int64(chunkFrames), map.outputFrameCount - outputFrame))
            var output = [Float](repeating: 0, count: frames * laneCount)
            for offset in 0..<frames {
                let destination = outputFrame + Int64(offset)
                guard let aligned = map.alignedInstant(atOutputFrame: destination) else {
                    throw .invalidPlan
                }
                // Map endpoints are already on this exact grid; locate the source using kept spans
                // rather than independently re-rounding or rippling a lane.
                guard let kept = map.keptSpans.first(where: {
                    destination >= $0.outputStart && destination < $0.outputEnd
                }) else { throw .invalidPlan }
                let sourceFrame = kept.alignedStart + destination - kept.outputStart
                guard aligned == map.outputRate.instant(ofFrame: sourceFrame) else {
                    throw .invalidPlan
                }
                if plan.mode == .lift &&
                    sourceFrame >= plan.mapping.grid.start && sourceFrame < plan.mapping.grid.end {
                    continue
                }
                let sourceIndex = Int(sourceFrame - plan.base.alignedFrameOrigin)
                for lane in 0..<laneCount {
                    let sample = input.lanes[lane].samples[sourceIndex]
                    let fade = plan.fades.first { $0.identity == input.lanes[lane].identity &&
                        sourceFrame >= $0.frames.start && sourceFrame < $0.frames.end }
                    if let fade {
                        let length = fade.frames.end - fade.frames.start
                        let position = sourceFrame - fade.frames.start
                        let gain = fade.direction == .fadeOut
                            ? Float(length - position - 1) / Float(length)
                            : Float(position + 1) / Float(length)
                        output[lane * frames + offset] = sample * gain
                    } else {
                        output[lane * frames + offset] = sample
                    }
                }
            }
            chunks.append(SyntheticPCMChunk(
                firstOutputFrame: outputFrame, frameCount: frames,
                channelCount: laneCount, samples: output
            ))
            outputFrame += Int64(frames)
        }
        guard !Task.isCancelled else { throw .cancelled }
        return SyntheticCommonEditPCMResult(plan: plan, chunks: chunks)
    }
}
