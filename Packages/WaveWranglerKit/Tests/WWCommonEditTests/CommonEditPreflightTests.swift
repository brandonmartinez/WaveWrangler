import Testing
import WWCore
import WWTimeMap
@testable import WWCommonEdit

@Suite("Common edit structural preflight (synthetic, untrusted manifest)")
struct CommonEditPreflightTests {
    @Test func completeSuppliedManifestRemainsUntrusted() throws {
        let fx = try Fixture()
        let check = try fx.check()
        #expect(check.inspectedFrames == 36)
        #expect(check.audioLanes == 2)
        #expect(throws: CommonEditAttestationRefusal.trustedAuthorityUnavailable) {
            try CommonEditAttestation.prepare(map: fx.map, manifest: fx.manifest, surveys: fx.surveys)
        }
        #expect(try fx.map.outputPosition(atAlignedInstant: q(67, 96_000)) == .mapped(
            CommonOutputPosition(exactFrame: q(67, 2), nearestFrame: fx.map.outputFrameCount)
        )) // rounded endpoint is a position, never a sample address
    }

    @Test func mismatchedSuppliedKeyAndDuplicateOrMissingRevisionRefuse() throws {
        var fx = try Fixture()
        let original = fx.manifest
        let source = SourceID()
        fx.manifest = .init(revision: original.revision, lanes: [
            .audio(.init(source: source, occurrence: fx.secondary.occurrence, channel: 0)),
            .audio(.init(source: fx.primary.source, occurrence: fx.primary.occurrence, channel: 0)),
        ])
        #expect(throws: CommonEditAttestationRefusal.invalidManifest) { try fx.check() }
        fx.manifest = .init(revision: original.revision, lanes: [original.lanes[0], original.lanes[0]])
        #expect(throws: CommonEditAttestationRefusal.invalidManifest) { try fx.check() }
        fx.manifest = original
        fx.surveys.append(fx.surveys[0])
        #expect(throws: CommonEditAttestationRefusal.duplicateLane) { try fx.check() }
        fx.surveys.removeLast()
        fx.manifest = .init(revision: "", lanes: original.lanes)
        #expect(throws: CommonEditAttestationRefusal.invalidManifest) { try fx.check() }
    }

    @Test func missingLaneSurveyAndExtraOrMissingBackingRefuse() throws {
        var fx = try Fixture()
        fx.surveys.removeLast()
        #expect(throws: CommonEditAttestationRefusal.missingSurvey) { try fx.check() }
        fx.surveys = [fx.survey(fx.primary), fx.survey(fx.secondary)]
        fx.manifest = .init(revision: "supplied", lanes: [.audio(fx.primary)])
        #expect(throws: CommonEditAttestationRefusal.invalidManifest) { try fx.check() }
        fx.manifest = .init(revision: "supplied", lanes: [.audio(fx.primary), .audio(fx.secondary),
                                                         .intentionalSilence("supplied silence")])
        #expect(throws: CommonEditAttestationRefusal.missingSurvey) { try fx.check() }
    }

    @Test func explicitlySuppliedSilenceLaneIsCheckedButNotTrusted() throws {
        var fx = try Fixture()
        fx.manifest = .init(revision: "supplied", lanes: [
            .audio(fx.primary), .audio(fx.secondary), .intentionalSilence("bed"),
        ])
        fx.surveys.append(.init(
            lane: .intentionalSilence("bed"), coverage: [],
            intentionalSilence: [RemovedFrameSpan(start: -2, end: 34)]
        ))
        #expect(try fx.check().audioLanes == 2)
        fx.surveys[2] = .init(lane: .intentionalSilence("bed"), coverage: [],
                              intentionalSilence: [RemovedFrameSpan(start: -2, end: 33)])
        #expect(throws: CommonEditAttestationRefusal.uncoveredFrame) { try fx.check() }
    }

    @Test func negativeGridGapAndTrailingSilenceRefuseWhenNotCovered() throws {
        var fx = try Fixture()
        #expect(fx.map.alignedFrameOrigin == -2)
        fx.surveys[1] = fx.survey(fx.secondary, coverage: [RemovedFrameSpan(start: 0, end: 30)])
        #expect(throws: CommonEditAttestationRefusal.uncoveredFrame) { try fx.check() }
        fx.surveys[1] = fx.survey(fx.secondary, silence: [RemovedFrameSpan(start: 31, end: 34)])
        #expect(throws: CommonEditAttestationRefusal.uncoveredFrame) { try fx.check() }
    }

    @Test func mixedRateExactSourceInverseUsesSourceFrameRounding() throws {
        let fx = try LowRateFixture()
        let inverse = try fx.map.alignment.sourceFrame(
            at: fx.map.outputRate.instant(ofFrame: 2), in: fx.lane.occurrence
        )
        guard case let .source(position) = inverse else {
            Issue.record("Expected a mapped fractional source position")
            return
        }
        #expect(position.exactFrame == q(1, 3))
        #expect(position.frame == 0)
        #expect(position.epoch == fx.epoch)
        #expect(try fx.check().inspectedFrames == 6)
        #expect(throws: CommonEditAttestationRefusal.trustedAuthorityUnavailable) {
            try CommonEditAttestation.prepare(map: fx.map, manifest: fx.manifest, surveys: fx.surveys)
        }
    }

    @Test func mixedRateCannotClaimUnavailableSourceFrame() throws {
        var fx = try LowRateFixture()
        fx.map = try CommonEpisodeEditMap(
            alignment: fx.map.alignment, alignmentRevision: 2, editRevision: 3,
            outputRate: NominalRate(48_000), alignedFrameOrigin: 0, alignedFrameCount: 10, removals: []
        )
        fx.surveys = [.init(lane: .audio(fx.lane), coverage: [RemovedFrameSpan(start: 0, end: 10)])]
        #expect(throws: CommonEditAttestationRefusal.uncoveredFrame) { try fx.check() }
    }

    @Test func adjacentIntervalsHaveIdenticalProtectionAndFadeContainment() throws {
        var fx = try Fixture()
        fx.surveys[0] = fx.survey(fx.primary, coverage: [
            RemovedFrameSpan(start: 0, end: 16), RemovedFrameSpan(start: 16, end: 32),
        ], protected: [RemovedFrameSpan(start: 15, end: 17)],
            requestedFades: [RemovedFrameSpan(start: 18, end: 20)],
            finalFades: [RemovedFrameSpan(start: 17, end: 19), RemovedFrameSpan(start: 19, end: 21)])
        #expect(try fx.check().audioLanes == 2)

        fx.surveys[0] = fx.survey(fx.primary, protected: [RemovedFrameSpan(start: 15, end: 17)],
                                  requestedFades: [RemovedFrameSpan(start: 18, end: 20)],
                                  finalFades: [RemovedFrameSpan(start: 17, end: 19),
                                               RemovedFrameSpan(start: 19, end: 21)])
        #expect(try fx.check().audioLanes == 2)

        fx.surveys[0] = fx.survey(fx.primary, coverage: [
            RemovedFrameSpan(start: 0, end: 16), RemovedFrameSpan(start: 16, end: 32),
        ], requestedFades: [RemovedFrameSpan(start: 16, end: 18)],
            finalFades: [RemovedFrameSpan(start: 15, end: 17), RemovedFrameSpan(start: 17, end: 19)])
        #expect(try fx.check().audioLanes == 2)

        fx.surveys[0] = fx.survey(fx.primary, coverage: [
            RemovedFrameSpan(start: 0, end: 16), RemovedFrameSpan(start: 17, end: 32),
        ], protected: [RemovedFrameSpan(start: 15, end: 18)])
        #expect(throws: CommonEditAttestationRefusal.invalidSurvey) { try fx.check() }

        fx.surveys[0] = fx.survey(fx.primary, coverage: [
            RemovedFrameSpan(start: 0, end: 16), RemovedFrameSpan(start: 17, end: 32),
        ], finalFades: [RemovedFrameSpan(start: 15, end: 18)])
        #expect(throws: CommonEditAttestationRefusal.unsafeFade) { try fx.check() }

        fx.surveys[0] = fx.survey(fx.primary, requestedFades: [RemovedFrameSpan(start: 18, end: 20)],
                                  finalFades: [RemovedFrameSpan(start: 17, end: 19),
                                               RemovedFrameSpan(start: 20, end: 21)])
        #expect(throws: CommonEditAttestationRefusal.invalidSurvey) { try fx.check() }
    }

    @Test func unsupportedInverseIsNotSilence() throws {
        var fx = try Fixture()
        let original = fx.map.alignment.groups[1]
        let unsupported = try GroupTimeMap(
            group: original.group, reference: original.reference,
            epochs: [EpochClockMap(epoch: original.epochs[0].epoch, mapping: .unsupported(.estimatorAbstained))],
            placements: original.placements
        )
        fx.map = try Fixture.editMap(AlignedTimelineMap(
            reference: fx.map.alignment.reference, groups: [fx.map.alignment.groups[0], unsupported]
        ))
        #expect(throws: CommonEditAttestationRefusal.ambiguousInverse) { try fx.check() }
    }

    @Test func knownGapInverseRefusesDespiteClaimedCoverage() throws {
        var fx = try Fixture()
        let original = fx.map.alignment.groups[1]
        let firstEpoch = original.epochs[0].epoch
        let nextEpoch = RecordingEpochID()
        let offset = q(-2, 48_000)
        let first = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: q(10, 48_000),
                                           rateRatio: .one, alignedOffset: offset)
        let second = try AffineClockSegment(groupClockStart: q(12, 48_000),
                                            groupClockEnd: q(32, 48_000),
                                            rateRatio: .one, alignedOffset: offset)
        let provenance = MapProvenance.manual(ManualCorrection(basis: .numericEntry))
        let split = try GroupTimeMap(
            group: original.group, reference: original.reference,
            epochs: [
                EpochClockMap(epoch: firstEpoch, mapping: .mapped(segments: [first], provenance: provenance)),
                EpochClockMap(epoch: nextEpoch, mapping: .mapped(segments: [second], provenance: provenance)),
            ],
            placements: [OccurrencePlacement(
                occurrence: original.placements[0].occurrence,
                spans: [EpochSpan(startFrame: 0, endFrame: 10, epoch: firstEpoch, groupClockOffset: .zero),
                        EpochSpan(startFrame: 12, endFrame: 32, epoch: nextEpoch, groupClockOffset: .zero)]
            )]
        )
        fx.map = try Fixture.editMap(AlignedTimelineMap(
            reference: fx.map.alignment.reference, groups: [fx.map.alignment.groups[0], split]
        ))
        let inverse = try fx.map.alignment.sourceFrame(at: fx.map.outputRate.instant(ofFrame: 8),
                                                       in: fx.secondary.occurrence)
        guard case .gap = inverse else {
            Issue.record("Expected a known source gap at the aligned grid frame")
            return
        }
        #expect(throws: CommonEditAttestationRefusal.ambiguousInverse) { try fx.check() }
    }

    @Test func protectedRemovalAndFinalMergedFadeRefuse() throws {
        var fx = try Fixture()
        fx.surveys[1] = fx.survey(fx.secondary, protected: [RemovedFrameSpan(start: 10, end: 11)])
        #expect(throws: CommonEditAttestationRefusal.protectedFrame) { try fx.check() }
        fx.surveys[1] = fx.survey(fx.secondary, protected: [RemovedFrameSpan(start: 8, end: 9)],
                                  finalFades: [RemovedFrameSpan(start: 8, end: 10)])
        #expect(throws: CommonEditAttestationRefusal.unsafeFade) { try fx.check() }
        fx.surveys[1] = fx.survey(fx.secondary, finalFades: [RemovedFrameSpan(start: 9, end: 12)])
        #expect(throws: CommonEditAttestationRefusal.unsafeFade) { try fx.check() }
        fx.surveys[1] = fx.survey(fx.secondary, requestedFades: [RemovedFrameSpan(start: 8, end: 9)])
        #expect(throws: CommonEditAttestationRefusal.invalidSurvey) { try fx.check() }
    }

    @Test func malformedIntervalsAndLongDomainsRefuse() throws {
        var fx = try Fixture()
        fx.surveys[0] = fx.survey(fx.primary, protected: [
            RemovedFrameSpan(start: 3, end: 5), RemovedFrameSpan(start: 4, end: 6),
        ])
        #expect(throws: CommonEditAttestationRefusal.invalidSurvey) { try fx.check() }
        fx.map = try CommonEpisodeEditMap(
            alignment: fx.map.alignment, alignmentRevision: 2, editRevision: 3,
            outputRate: NominalRate(48_000), alignedFrameOrigin: -2,
            alignedFrameCount: CommonEditPreflight.maximumInspectedFrames + 1, removals: []
        )
        #expect(throws: CommonEditAttestationRefusal.inspectionLimit) { try fx.check() }
    }

    @Test func fullMapWorkAndLaneCountAreBoundedBeforeSurveyInspection() throws {
        let fx = try Fixture()
        let full = try CommonEpisodeEditMap(
            alignment: fx.map.alignment, alignmentRevision: fx.map.alignmentRevision,
            editRevision: fx.map.editRevision, outputRate: fx.map.outputRate,
            alignedFrameOrigin: fx.map.alignedFrameOrigin, alignedFrameCount: 8_192, removals: []
        )
        let more = (0..<7).map { CommonEditManifestLane.intentionalSilence("extra-\($0)") }
        #expect(throws: CommonEditAttestationRefusal.inspectionLimit) {
            try CommonEditPreflight.check(
                map: full, manifest: .init(revision: "supplied", lanes: fx.manifest.lanes + more),
                surveys: []
            )
        }
        #expect(throws: CommonEditAttestationRefusal.missingSurvey) {
            try CommonEditPreflight.check(
                map: full, manifest: .init(revision: "supplied", lanes: fx.manifest.lanes + more.dropLast()),
                surveys: []
            )
        }
        let many = (0..<17).map { CommonEditManifestLane.intentionalSilence("lane-\($0)") }
        #expect(throws: CommonEditAttestationRefusal.inspectionLimit) {
            try CommonEditPreflight.check(map: fx.map,
                                          manifest: .init(revision: "supplied", lanes: many),
                                          surveys: [])
        }
        let tooManySpans = (0..<33).map {
            RemovedFrameSpan(start: Int64($0 - 2), end: Int64($0 - 1))
        }
        var surveys = fx.surveys
        surveys[0] = .init(lane: fx.manifest.lanes[0], coverage: tooManySpans)
        #expect(throws: CommonEditAttestationRefusal.inspectionLimit) {
            try CommonEditPreflight.check(map: fx.map, manifest: fx.manifest, surveys: surveys)
        }
    }
}

private struct Fixture {
    let primary: CommonEditLaneKey
    let secondary: CommonEditLaneKey
    var map: CommonEpisodeEditMap
    var manifest: CommonEditLaneManifest
    var surveys: [CommonEditLaneSurvey]

    init() throws {
        let referenceGroup = RecorderGroupID(), referenceEpoch = RecordingEpochID()
        let referenceOccurrence = SourceOccurrenceID()
        let reference = TimelineReference(group: referenceGroup, epoch: referenceEpoch, occurrence: referenceOccurrence)
        let primarySource = SourceID(), secondarySource = SourceID()
        primary = .init(source: primarySource, occurrence: referenceOccurrence, channel: 0)
        secondary = .init(source: secondarySource, occurrence: SourceOccurrenceID(), channel: 0)
        let own = try Self.group(
            group: referenceGroup, epoch: referenceEpoch, lane: primary, reference: reference,
            offset: .zero, provenance: .timelineReference
        )
        let other = try Self.group(
            group: RecorderGroupID(), epoch: RecordingEpochID(), lane: secondary, reference: reference,
            offset: q(-2, 48_000), provenance: .manual(ManualCorrection(basis: .numericEntry))
        )
        map = try Self.editMap(AlignedTimelineMap(reference: reference, groups: [own, other]))
        manifest = .init(revision: "supplied-not-trusted", lanes: [.audio(primary), .audio(secondary)])
        surveys = []
        surveys = [survey(primary), survey(secondary)]
    }

    func check() throws -> ProvisionalCommonEditCheck {
        try CommonEditPreflight.check(map: map, manifest: manifest, surveys: surveys)
    }

    func survey(
        _ key: CommonEditLaneKey, coverage: [RemovedFrameSpan]? = nil,
        silence: [RemovedFrameSpan]? = nil, protected: [RemovedFrameSpan] = [],
        requestedFades: [RemovedFrameSpan] = [], finalFades: [RemovedFrameSpan] = []
    ) -> CommonEditLaneSurvey {
        let isPrimary = key == primary
        return .init(
            lane: .audio(key),
            coverage: coverage ?? [RemovedFrameSpan(start: isPrimary ? 0 : -2, end: isPrimary ? 32 : 30)],
            intentionalSilence: silence ?? (isPrimary ?
                [RemovedFrameSpan(start: -2, end: 0), RemovedFrameSpan(start: 32, end: 34)] :
                [RemovedFrameSpan(start: 30, end: 34)]),
            protected: protected, requestedFades: requestedFades, finalMergedFades: finalFades
        )
    }

    static func editMap(_ alignment: AlignedTimelineMap) throws -> CommonEpisodeEditMap {
        try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: 2, editRevision: 3,
            outputRate: NominalRate(48_000), alignedFrameOrigin: -2,
            alignedFrameCount: 36, removals: [RemovedFrameSpan(start: 10, end: 12)]
        )
    }

    private static func group(
        group: RecorderGroupID, epoch: RecordingEpochID, lane: CommonEditLaneKey,
        reference: TimelineReference, offset: ExactRational, provenance: MapProvenance
    ) throws -> GroupTimeMap {
        let segment = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: q(32, 48_000),
                                             rateRatio: .one, alignedOffset: offset)
        let placement = OccurrencePlacement(
            occurrence: try SourceOccurrence(id: lane.occurrence, source: lane.source,
                                             nominalRate: NominalRate(48_000), frameCount: 32),
            spans: [EpochSpan(startFrame: 0, endFrame: 32, epoch: epoch, groupClockOffset: .zero)]
        )
        return try GroupTimeMap(
            group: group, reference: reference,
            epochs: [EpochClockMap(epoch: epoch, mapping: .mapped(segments: [segment], provenance: provenance))],
            placements: [placement]
        )
    }
}

private struct LowRateFixture {
    let lane: CommonEditLaneKey
    let epoch: RecordingEpochID
    var map: CommonEpisodeEditMap
    let manifest: CommonEditLaneManifest
    var surveys: [CommonEditLaneSurvey]

    init() throws {
        let group = RecorderGroupID()
        epoch = RecordingEpochID()
        lane = .init(source: SourceID(), occurrence: SourceOccurrenceID(), channel: 0)
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: lane.occurrence)
        let segment = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: q(2, 8_000),
                                             rateRatio: .one, alignedOffset: .zero)
        let placement = OccurrencePlacement(
            occurrence: try SourceOccurrence(id: lane.occurrence, source: lane.source,
                                             nominalRate: NominalRate(8_000), frameCount: 2),
            spans: [EpochSpan(startFrame: 0, endFrame: 2, epoch: epoch, groupClockOffset: .zero)]
        )
        let groupMap = try GroupTimeMap(
            group: group, reference: reference,
            epochs: [EpochClockMap(epoch: epoch, mapping: .mapped(
                segments: [segment], provenance: .timelineReference
            ))],
            placements: [placement]
        )
        map = try CommonEpisodeEditMap(
            alignment: AlignedTimelineMap(reference: reference, groups: [groupMap]),
            alignmentRevision: 2, editRevision: 3, outputRate: NominalRate(48_000),
            alignedFrameOrigin: 0, alignedFrameCount: 6, removals: []
        )
        manifest = .init(revision: "supplied-not-trusted", lanes: [.audio(lane)])
        surveys = [.init(lane: .audio(lane), coverage: [RemovedFrameSpan(start: 0, end: 6)])]
    }

    func check() throws -> ProvisionalCommonEditCheck {
        try CommonEditPreflight.check(map: map, manifest: manifest, surveys: surveys)
    }
}

private func q(_ n: Int64, _ d: Int64) -> ExactRational { try! ExactRational(n, d) }
