import WWCore
import WWTimeMap

/// A caller's lane assertion. Source/channel identity is not evidence of access or complete backing.
public struct CommonEditLaneKey: Sendable, Hashable {
    public let source: SourceID
    public let occurrence: SourceOccurrenceID
    public let channel: Int

    public init(source: SourceID, occurrence: SourceOccurrenceID, channel: Int) {
        self.source = source
        self.occurrence = occurrence
        self.channel = channel
    }
}

public enum CommonEditManifestLane: Sendable, Hashable {
    case audio(CommonEditLaneKey)
    case intentionalSilence(String)
}

public enum CommonEditAudioRole: Sendable, Hashable {
    case selectedPrimary
    case backup
}

/// A caller's role assertion, not an organizer-issued selection or access witness.
public struct CommonEditAudioRoleClaim: Sendable, Hashable {
    public let key: CommonEditLaneKey
    public let role: CommonEditAudioRole

    public init(key: CommonEditLaneKey, role: CommonEditAudioRole) {
        self.key = key
        self.role = role
    }
}

public struct ExcludedBackupLane: Sendable {
    public let key: CommonEditLaneKey
    public var status: String { "backup not verified; excluded from cut proof" }

    fileprivate init(key: CommonEditLaneKey) {
        self.key = key
    }
}

/// Untrusted input: the caller must not infer episode completeness from this value or its revision.
public struct CommonEditLaneManifest: Sendable {
    public let revision: String
    /// Audio lanes must have explicit selected-Primary role claims; silence is separately supported.
    public let lanes: [CommonEditManifestLane]
    /// Metadata only: these occurrences have no survey, source proof or render participation.
    public let excludedBackups: [CommonEditLaneKey]
    /// An absent or contradictory claim refuses; these caller assertions do not prove actual roles.
    public let roleClaims: [CommonEditAudioRoleClaim]

    public init(revision: String, lanes: [CommonEditManifestLane],
                excludedBackups: [CommonEditLaneKey] = [],
                roleClaims: [CommonEditAudioRoleClaim] = []) {
        self.revision = revision
        self.lanes = lanes
        self.excludedBackups = excludedBackups
        self.roleClaims = roleClaims
    }

    func hasCompleteSelectedPrimaryClassification() -> Bool {
        let admitted = lanes.compactMap { lane -> CommonEditLaneKey? in
            if case let .audio(key) = lane { return key }
            return nil
        }
        return roleClaims.count == admitted.count + excludedBackups.count &&
            Set(roleClaims.map(\.key)).count == roleClaims.count &&
            Set(roleClaims.filter { $0.role == .selectedPrimary }.map(\.key)) == Set(admitted) &&
            Set(roleClaims.filter { $0.role == .backup }.map(\.key)) == Set(excludedBackups)
    }
}

/// Supplied half-open absolute grid intervals, not independently reviewed protection evidence.
public struct CommonEditLaneSurvey: Sendable {
    public let lane: CommonEditManifestLane
    public let coverage: [RemovedFrameSpan]
    public let intentionalSilence: [RemovedFrameSpan]
    public let protected: [RemovedFrameSpan]
    public let requestedFades: [RemovedFrameSpan]
    public let finalMergedFades: [RemovedFrameSpan]

    public init(
        lane: CommonEditManifestLane, coverage: [RemovedFrameSpan],
        intentionalSilence: [RemovedFrameSpan] = [],
        protected: [RemovedFrameSpan] = [],
        requestedFades: [RemovedFrameSpan] = [],
        finalMergedFades: [RemovedFrameSpan] = []
    ) {
        self.lane = lane
        self.coverage = coverage
        self.intentionalSilence = intentionalSilence
        self.protected = protected
        self.requestedFades = requestedFades
        self.finalMergedFades = finalMergedFades
    }
}

public enum CommonEditAttestationRefusal: Error, Equatable, Sendable {
    case invalidManifest
    case duplicateLane
    case missingSurvey
    case invalidSurvey
    case uncoveredFrame
    case ambiguousInverse
    case protectedFrame
    case unsafeFade
    case inspectionLimit
    case trustedAuthorityUnavailable
}

/// A structural result only; it is not a render authorization, source/access witness or accepted cut.
public struct ProvisionalCommonEditCheck: Sendable {
    public let inspectedFrames: Int64
    public let audioLanes: Int
    public let excludedBackups: [ExcludedBackupLane]

    fileprivate init(inspectedFrames: Int64, audioLanes: Int,
                     excludedBackups: [CommonEditLaneKey]) {
        self.inspectedFrames = inspectedFrames
        self.audioLanes = audioLanes
        self.excludedBackups = excludedBackups.map(ExcludedBackupLane.init(key:))
    }
}

public enum CommonEditPreflight {
    /// A finite exhaustive structural check; longer episodes refuse until an interval proof exists.
    public static let maximumInspectedFrames: Int64 = 8_192
    public static let maximumInspectedLanes = 16
    public static let maximumInspectedWork: Int64 = 65_536
    public static let maximumInverseEvaluations: Int64 = 131_072
    public static let maximumInspectedIntervals = 32
    public static let maximumAggregateIntervals = 256

    public static func check(
        map: CommonEpisodeEditMap, manifest: CommonEditLaneManifest,
        surveys: [CommonEditLaneSurvey]
    ) throws(CommonEditAttestationRefusal) -> ProvisionalCommonEditCheck {
        guard manifest.excludedBackups.count <= maximumInspectedLanes,
              manifest.lanes.count <= maximumInspectedLanes - manifest.excludedBackups.count,
              manifest.roleClaims.count <= maximumInspectedLanes,
              withinInspectionBudget(map: map,
                                     laneCount: manifest.lanes.count + manifest.excludedBackups.count,
                                     surveyCount: surveys.count),
              withinSurveyIntervalBudget(surveys)
        else { throw CommonEditAttestationRefusal.inspectionLimit }
        guard manifest.hasCompleteSelectedPrimaryClassification() else {
            throw CommonEditAttestationRefusal.invalidManifest
        }
        let placements = map.alignment.groups.flatMap(\.placements)
        let occurrences = Dictionary(uniqueKeysWithValues: placements.map { ($0.occurrence.id, $0.occurrence) })
        let audio = manifest.lanes.compactMap { lane -> CommonEditLaneKey? in
            if case let .audio(key) = lane { return key }
            return nil
        }
        let audioOccurrences = Set(audio.map(\.occurrence))
        let excludedOccurrences = manifest.excludedBackups.map(\.occurrence)
        guard !manifest.revision.isEmpty, !placements.isEmpty, !manifest.lanes.isEmpty,
              audioOccurrences.union(excludedOccurrences) == Set(occurrences.keys),
              Set(excludedOccurrences).count == excludedOccurrences.count,
              audioOccurrences.isDisjoint(with: excludedOccurrences),
              Set(audio.map(\.source)).isDisjoint(with: manifest.excludedBackups.map(\.source)),
              audio.allSatisfy({ key in
                  key.channel >= 0 && occurrences[key.occurrence]?.source == key.source
              }),
              manifest.excludedBackups.allSatisfy({ key in
                  key.channel >= 0 && occurrences[key.occurrence]?.source == key.source
              }),
              manifest.lanes.allSatisfy({ lane in
                  if case let .intentionalSilence(id) = lane { return !id.isEmpty }
                  return true
              })
        else { throw CommonEditAttestationRefusal.invalidManifest }
        guard Set(manifest.lanes).count == manifest.lanes.count,
              Set(surveys.map(\.lane)).count == surveys.count else {
            throw CommonEditAttestationRefusal.duplicateLane
        }
        guard manifest.lanes.count == surveys.count,
              Set(manifest.lanes) == Set(surveys.map(\.lane)) else {
            throw CommonEditAttestationRefusal.missingSurvey
        }
        for survey in surveys {
            for spans in [survey.coverage, survey.intentionalSilence, survey.protected,
                          survey.requestedFades, survey.finalMergedFades] {
                guard valid(spans, in: map) else { throw CommonEditAttestationRefusal.invalidSurvey }
            }
            guard survey.protected.allSatisfy({ contained($0, in: survey.coverage) }),
                  survey.requestedFades.allSatisfy({ contained($0, in: survey.finalMergedFades) })
            else { throw CommonEditAttestationRefusal.invalidSurvey }
            guard !survey.protected.contains(where: { p in map.removals.contains(where: { intersects(p, $0) }) })
            else { throw CommonEditAttestationRefusal.protectedFrame }
            for fade in survey.finalMergedFades {
                guard contained(fade, in: survey.coverage),
                      !map.removals.contains(where: { intersects(fade, $0) }),
                      !survey.protected.contains(where: { intersects(fade, $0) })
                else { throw CommonEditAttestationRefusal.unsafeFade }
            }
            for frame in map.alignedFrameOrigin..<map.alignedFrameEnd {
                let instant = map.outputRate.instant(ofFrame: frame)
                let output: CommonAlignedOutputMapping
                do { output = try map.outputPosition(atAlignedInstant: instant) }
                catch { throw .ambiguousInverse }
                switch output {
                case .mapped(let position):
                    guard map.alignedInstant(atOutputFrame: position.nearestFrame) == instant else {
                        throw CommonEditAttestationRefusal.ambiguousInverse
                    }
                case .removed(let span):
                    guard span.start <= frame && frame < span.end else { throw CommonEditAttestationRefusal.ambiguousInverse }
                case .outsideCoverage:
                    throw CommonEditAttestationRefusal.ambiguousInverse
                }
                let covered = survey.coverage.contains { $0.start <= frame && frame < $0.end }
                let silent = survey.intentionalSilence.contains { $0.start <= frame && frame < $0.end }
                switch survey.lane {
                case .intentionalSilence:
                    guard !covered, silent else { throw CommonEditAttestationRefusal.uncoveredFrame }
                case .audio(let key):
                    let inverse: InverseMapping
                    do { inverse = try map.alignment.sourceFrame(at: instant, in: key.occurrence) }
                    catch { throw .ambiguousInverse }
                    switch inverse {
                    case .source(let position):
                        guard covered, !silent, let occurrence = occurrences[key.occurrence],
                              position.frame >= 0, position.frame < occurrence.frameCount
                        else { throw CommonEditAttestationRefusal.uncoveredFrame }
                        let mapped: ForwardMapping
                        do { mapped = try map.alignment.alignedTime(ofFrame: position.frame, in: key.occurrence) }
                        catch { throw .ambiguousInverse }
                        guard case let .aligned(forward) = mapped, forward.epoch == position.epoch else {
                            throw CommonEditAttestationRefusal.ambiguousInverse
                        }
                        let sourceFrameError: ExactRational
                        let halfSourceFrame: ExactRational
                        do {
                            // The exact inverse is quantized on the source grid, not the output grid.
                            sourceFrameError = try position.exactFrame.subtracting(ExactRational(position.frame))
                            halfSourceFrame = try ExactRational(1, 2)
                        }
                        catch { throw .ambiguousInverse }
                        guard position.exactFrame.roundedHalfUp() == Int128(position.frame),
                              sourceFrameError.magnitude <= halfSourceFrame else {
                            throw CommonEditAttestationRefusal.ambiguousInverse
                        }
                    case .outsideCoverage:
                        guard silent, !covered else { throw CommonEditAttestationRefusal.uncoveredFrame }
                    case .gap, .unsupported:
                        throw CommonEditAttestationRefusal.ambiguousInverse
                    }
                }
            }
        }
        return ProvisionalCommonEditCheck(inspectedFrames: map.alignedFrameCount,
                                          audioLanes: audio.count,
                                          excludedBackups: manifest.excludedBackups)
    }

    static func withinInspectionBudget(
        map: CommonEpisodeEditMap, laneCount: Int, surveyCount: Int
    ) -> Bool {
        guard map.alignedFrameCount <= maximumInspectedFrames,
              laneCount <= maximumInspectedLanes, surveyCount <= maximumInspectedLanes,
              let lanes = Int64(exactly: laneCount),
              map.removals.count <= maximumInspectedIntervals,
              map.alignment.groups.count <= maximumInspectedLanes
        else { return false }
        let (work, overflow) = map.alignedFrameCount.multipliedReportingOverflow(by: lanes)
        guard !overflow, work <= maximumInspectedWork else { return false }
        let (surveyWork, surveyOverflow) = map.alignedFrameCount.multipliedReportingOverflow(by: Int64(surveyCount))
        guard !surveyOverflow else { return false }
        let (inverseEvaluations, inverseOverflow) = surveyWork.multipliedReportingOverflow(by: 2)
        guard !inverseOverflow, inverseEvaluations <= maximumInverseEvaluations else { return false }
        var occurrences = 0
        for group in map.alignment.groups {
            guard group.placements.count <= maximumInspectedLanes - occurrences,
                  group.epochs.count <= maximumInspectedIntervals,
                  group.epochs.allSatisfy({ epoch in
                      if case let .mapped(segments, _) = epoch.mapping {
                          return segments.count <= maximumInspectedIntervals
                      }
                      return true
                  }),
                  group.placements.allSatisfy({ $0.spans.count <= maximumInspectedIntervals })
            else { return false }
            occurrences += group.placements.count
        }
        return true
    }

    static func withinIntervalBudget(_ survey: CommonEditLaneSurvey) -> Bool {
        [survey.coverage, survey.intentionalSilence, survey.protected,
         survey.requestedFades, survey.finalMergedFades].allSatisfy {
            $0.count <= maximumInspectedIntervals
        }
    }

    private static func withinSurveyIntervalBudget(_ surveys: [CommonEditLaneSurvey]) -> Bool {
        var remaining = maximumAggregateIntervals
        for survey in surveys {
            for count in [survey.coverage.count, survey.intentionalSilence.count,
                          survey.protected.count, survey.requestedFades.count,
                          survey.finalMergedFades.count] {
                guard count <= maximumInspectedIntervals, count <= remaining else { return false }
                remaining -= count
            }
        }
        return true
    }

    private static func intersects(_ a: RemovedFrameSpan, _ b: RemovedFrameSpan) -> Bool {
        a.start < b.end && b.start < a.end
    }

    private static func contained(_ span: RemovedFrameSpan, in spans: [RemovedFrameSpan]) -> Bool {
        var cursor = span.start
        for covered in spans where covered.end > cursor {
            guard covered.start <= cursor else { return false }
            cursor = covered.end
            if cursor >= span.end { return true }
        }
        return false
    }

    private static func valid(_ spans: [RemovedFrameSpan], in map: CommonEpisodeEditMap) -> Bool {
        spans.enumerated().allSatisfy { index, span in
            span.start >= map.alignedFrameOrigin && span.start < span.end &&
            span.end <= map.alignedFrameEnd &&
            (index == 0 || spans[index - 1].end <= span.start)
        }
    }
}

/// Never grants rendering: a live organizer/access witness, independently complete protection survey,
/// accepted-map content proof and Mac-owned atomic map/history publication are not provided here.
public enum CommonEditAttestation {
    public static func prepare(
        map: CommonEpisodeEditMap, manifest: CommonEditLaneManifest,
        surveys: [CommonEditLaneSurvey]
    ) throws(CommonEditAttestationRefusal) -> Never {
        _ = try CommonEditPreflight.check(map: map, manifest: manifest, surveys: surveys)
        throw CommonEditAttestationRefusal.trustedAuthorityUnavailable
    }
}

private extension ExactRational {
    var magnitude: ExactRational { numerator < 0 ? negated() : self }
}
