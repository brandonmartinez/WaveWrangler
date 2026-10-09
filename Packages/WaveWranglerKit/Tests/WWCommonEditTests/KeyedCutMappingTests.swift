import Testing
import WWCore
import WWTimeMap
@testable import WWCommonEdit

@Suite("Keyed all-lane cut mapping (synthetic, provisional)")
struct KeyedCutMappingTests {
    @Test func bothModesUseOneRoundedGridAndEveryLane() throws {
        let fx = try Fixture()
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let result = try fx.map(mode: mode)
            #expect(result.grid == RemovedFrameSpan(start: 10, end: 12))
            #expect(result.map.outputRate.framesPerSecond == 48_000)
            #expect(result.map.removals == (mode == .shorten ? [result.grid] : []))
            #expect(result.lanes.map(\.identity) == fx.identities)
            #expect(result.lanes[0].sourceRemoval == SourceFrameSpan(start: 10, end: 12))
            #expect(result.lanes[1].sourceRemoval == SourceFrameSpan(start: 12, end: 14))
            #expect(result.lanes[2].sourceRemoval == SourceFrameSpan(start: 12, end: 14))
            #expect(result.lanes[3].sourceRemoval == nil)
            #expect(result.lanes[1].finalMergedFades == [
                SourceFrameSpan(start: 10, end: 12), SourceFrameSpan(start: 14, end: 16),
            ])
            #expect(result.lanes[1].finalMergedGridFades == [
                RemovedFrameSpan(start: 8, end: 10), RemovedFrameSpan(start: 12, end: 14),
            ])
            #expect(result.lanes[3].finalMergedGridFades.isEmpty)
        }
    }

    @Test func mixedRateRoundsPrimaryBoundariesOnceForAllLanes() throws {
        let fx = try Fixture(primaryRate: 44_100)
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let result = try fx.map(mode: mode)
            #expect(result.grid == RemovedFrameSpan(start: 11, end: 13))
            #expect(result.lanes[0].sourceRemoval == SourceFrameSpan(start: 10, end: 12))
            #expect(result.lanes[1].sourceRemoval == SourceFrameSpan(start: 13, end: 15))
            #expect(result.lanes[2].sourceRemoval == SourceFrameSpan(start: 13, end: 15))
            #expect(result.lanes[1].finalMergedGridFades == [
                RemovedFrameSpan(start: 9, end: 11), RemovedFrameSpan(start: 13, end: 15),
            ])
        }
    }

    @Test func staleMissingDuplicateReorderedAndCrossRevisionProofsRefuse() throws {
        let fx = try Fixture()
        for proof in [
            Array(fx.proofs.dropLast()),
            fx.proofs + [fx.proofs[1]],
            [fx.proofs[1], fx.proofs[0], fx.proofs[2], fx.proofs[3]],
        ] {
            #expect(throws: ProvisionalCutMappingError.invalidLanes) {
                try fx.map(proofs: proof)
            }
        }
        var stale = fx.proofs
        stale[1] = fx.proof(1, revision: "stale")
        #expect(throws: ProvisionalCutMappingError.invalidLanes) { try fx.map(proofs: stale) }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(primary: fx.identities[1])
        }
        var crossRevision = fx.identities
        crossRevision[1] = .init(lane: crossRevision[1].lane, epoch: crossRevision[1].epoch,
                                  alignmentRevision: 8, revision: crossRevision[1].revision)
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(identities: crossRevision)
        }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(identities: [fx.identities[0], fx.identities[1], fx.identities[1], fx.identities[3]])
        }
    }

    @Test func adjacentSourceCoverageAndMergedFadeUnionPassButPositiveGapsRefuse() throws {
        let fx = try Fixture()
        var proofs = fx.proofs
        proofs[1] = fx.proof(1, coverage: [
            SourceFrameSpan(start: 0, end: 13), SourceFrameSpan(start: 13, end: 32),
        ], requestedOut: SourceFrameSpan(start: 10, end: 12),
           finalFades: [SourceFrameSpan(start: 9, end: 11), SourceFrameSpan(start: 11, end: 12),
                        SourceFrameSpan(start: 14, end: 16)])
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(try fx.map(mode: mode, proofs: proofs).lanes.count == 4)
        }
        proofs[1] = fx.proof(1, coverage: [
            SourceFrameSpan(start: 0, end: 13), SourceFrameSpan(start: 14, end: 32),
        ])
        #expect(throws: ProvisionalCutMappingError.incompleteCoverage) { try fx.map(proofs: proofs) }
    }

    @Test func inverseGapAndUnsupportedEpochNeverBecomeSilence() throws {
        let fx = try Fixture()
        let backup = fx.base.alignment.groups[1]
        let epoch = fx.identities[1].epoch!
        let next = RecordingEpochID()
        let offset = try ExactRational(-2, 48_000)
        let first = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: try ExactRational(11, 48_000),
            rateRatio: .one, alignedOffset: offset
        )
        let second = try AffineClockSegment(
            groupClockStart: try ExactRational(13, 48_000),
            groupClockEnd: try ExactRational(32, 48_000),
            rateRatio: .one, alignedOffset: offset
        )
        let provenance = MapProvenance.manual(ManualCorrection(basis: .numericEntry))
        let gap = try GroupTimeMap(
            group: backup.group, reference: backup.reference,
            epochs: [.init(epoch: epoch, mapping: .mapped(segments: [first], provenance: provenance)),
                     .init(epoch: next, mapping: .mapped(segments: [second], provenance: provenance))],
            placements: [.init(
                occurrence: backup.placements[0].occurrence,
                spans: [.init(startFrame: 0, endFrame: 11, epoch: epoch, groupClockOffset: .zero),
                        .init(startFrame: 13, endFrame: 32, epoch: next, groupClockOffset: .zero)]
            )]
        )
        let unsupported = try GroupTimeMap(
            group: backup.group, reference: backup.reference,
            epochs: [.init(epoch: epoch, mapping: .unsupported(.estimatorAbstained))],
            placements: backup.placements
        )
        for group in [gap, unsupported] {
            let alignment = try AlignedTimelineMap(
                reference: fx.base.alignment.reference,
                groups: [fx.base.alignment.groups[0], group, fx.base.alignment.groups[2]]
            )
            let base = try CommonEpisodeEditMap(
                alignment: alignment, alignmentRevision: fx.base.alignmentRevision,
                editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
                alignedFrameOrigin: fx.base.alignedFrameOrigin,
                alignedFrameCount: fx.base.alignedFrameCount, removals: []
            )
            for mode in [ProvisionalCutMode.shorten, .lift] {
                #expect(throws: ProvisionalCutMappingError.ambiguousInverse) {
                    try fx.map(mode: mode, base: base)
                }
            }
        }
    }

    @Test func sourceGapBetweenOutputSamplesRefuses() throws {
        let fx = try Fixture()
        let backup = fx.base.alignment.groups[1]
        let epoch = fx.identities[1].epoch!
        let next = RecordingEpochID()
        let offset = try ExactRational(-2, 48_000)
        let slope = try ExactRational(1, 2)
        let first = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: try ExactRational(25, 48_000),
            rateRatio: slope, alignedOffset: offset
        )
        let second = try AffineClockSegment(
            groupClockStart: try ExactRational(26, 48_000),
            groupClockEnd: try ExactRational(32, 48_000),
            rateRatio: slope, alignedOffset: offset
        )
        let provenance = MapProvenance.manual(ManualCorrection(basis: .numericEntry))
        let skipped = try GroupTimeMap(
            group: backup.group, reference: backup.reference,
            epochs: [.init(epoch: epoch, mapping: .mapped(segments: [first], provenance: provenance)),
                     .init(epoch: next, mapping: .mapped(segments: [second], provenance: provenance))],
            placements: [.init(
                occurrence: backup.placements[0].occurrence,
                spans: [.init(startFrame: 0, endFrame: 25, epoch: epoch, groupClockOffset: .zero),
                        .init(startFrame: 26, endFrame: 32, epoch: next, groupClockOffset: .zero)]
            )]
        )
        let alignment = try AlignedTimelineMap(
            reference: fx.base.alignment.reference,
            groups: [fx.base.alignment.groups[0], skipped, fx.base.alignment.groups[2]]
        )
        let base = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: fx.base.alignmentRevision,
            editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
            alignedFrameOrigin: fx.base.alignedFrameOrigin,
            alignedFrameCount: fx.base.alignedFrameCount, removals: []
        )
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.ambiguousInverse) {
                try fx.map(mode: mode, base: base)
            }
        }
    }

    @Test func protectedRemovalAndWrongSidedOverlappingOrUnmergedFadesRefuseBothModes() throws {
        let fx = try Fixture()
        for mode in [ProvisionalCutMode.shorten, .lift] {
            var proofs = fx.proofs
            proofs[2] = fx.proof(2, protected: [SourceFrameSpan(start: 13, end: 14)])
            #expect(throws: ProvisionalCutMappingError.protectedFrame) {
                try fx.map(mode: mode, proofs: proofs)
            }
            proofs[2] = fx.proof(2, requestedOut: SourceFrameSpan(start: 14, end: 16))
            #expect(throws: ProvisionalCutMappingError.invalidFade) {
                try fx.map(mode: mode, proofs: proofs)
            }
            proofs[2] = fx.proof(2, finalFades: [SourceFrameSpan(start: 11, end: 13)])
            #expect(throws: ProvisionalCutMappingError.invalidFade) {
                try fx.map(mode: mode, proofs: proofs)
            }
            proofs[2] = fx.proof(2, finalFades: [SourceFrameSpan(start: 10, end: 11)])
            #expect(throws: ProvisionalCutMappingError.invalidFade) {
                try fx.map(mode: mode, proofs: proofs)
            }
        }
    }

    @Test func gridMismatchPartialSurveyAndOverflowRefuse() throws {
        let fx = try Fixture()
        var proofs = fx.proofs
        proofs[1] = fx.proof(1, survey: .init(
            lane: fx.identities[1].lane, coverage: [RemovedFrameSpan(start: -2, end: 11)],
            intentionalSilence: [RemovedFrameSpan(start: 30, end: 34)]
        ))
        #expect(throws: ProvisionalCutMappingError.incompleteCoverage) { try fx.map(proofs: proofs) }
        #expect(throws: ProvisionalCutMappingError.invalidGrid) {
            try fx.map(outputRate: try NominalRate(44_100))
        }
        #expect(throws: ProvisionalCutMappingError.invalidGrid) {
            try fx.map(source: SourceFrameSpan(start: .max - 1, end: .max))
        }
        #expect(throws: ProvisionalCutMappingError.invalidFade) {
            try fx.map(fadeOutOutputFrames: 3)
        }
        proofs = fx.proofs
        proofs[1] = fx.proof(1, requestedOut: .init(start: .min, end: .max))
        #expect(throws: ProvisionalCutMappingError.invalidFade) {
            try fx.map(proofs: proofs)
        }
        proofs = fx.proofs
        proofs[1] = fx.proof(1, survey: .init(
            lane: fx.identities[1].lane, coverage: [RemovedFrameSpan(start: -2, end: 30)],
            intentionalSilence: [RemovedFrameSpan(start: 30, end: 34)],
            finalMergedFades: [RemovedFrameSpan(start: 8, end: 10)]
        ))
        #expect(throws: ProvisionalCutMappingError.invalidFade) {
            try fx.map(proofs: proofs)
        }
        let preexisting = try CommonEpisodeEditMap(
            alignment: fx.base.alignment, alignmentRevision: fx.base.alignmentRevision,
            editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
            alignedFrameOrigin: fx.base.alignedFrameOrigin,
            alignedFrameCount: fx.base.alignedFrameCount,
            removals: [RemovedFrameSpan(start: 8, end: 9)]
        )
        #expect(throws: ProvisionalCutMappingError.invalidFade) {
            try fx.map(base: preexisting)
        }
    }
}

private struct Fixture {
    let base: CommonEpisodeEditMap
    let identities: [KeyedEditLane]
    let proofs: [KeyedLaneFootprintInput]

    init(primaryRate: Int64 = 48_000) throws {
        let source = SourceID(), rate = try NominalRate(48_000)
        let group = RecorderGroupID(), epoch = RecordingEpochID(), occurrence = SourceOccurrenceID()
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: occurrence)
        let primary = try Self.group(reference: reference, group: group, epoch: epoch,
                                     source: source, occurrence: occurrence, offset: 0,
                                     nominalRate: primaryRate)
        let otherSource = SourceID()
        let backupID = SourceOccurrenceID(), otherID = SourceOccurrenceID()
        let backupEpoch = RecordingEpochID(), otherEpoch = RecordingEpochID()
        let backup = try Self.group(reference: reference, group: RecorderGroupID(),
                                    epoch: backupEpoch, source: otherSource, occurrence: backupID, offset: -2)
        let other = try Self.group(reference: reference, group: RecorderGroupID(),
                                   epoch: otherEpoch, source: otherSource, occurrence: otherID, offset: -2)
        base = try CommonEpisodeEditMap(
            alignment: AlignedTimelineMap(reference: reference, groups: [primary, backup, other]),
            alignmentRevision: 7, editRevision: 8, outputRate: rate,
            alignedFrameOrigin: -2, alignedFrameCount: 36, removals: []
        )
        let identities: [KeyedEditLane] = [
            .init(lane: .audio(.init(source: source, occurrence: occurrence, channel: 0)),
                  epoch: epoch, alignmentRevision: 7, revision: "p"),
            .init(lane: .audio(.init(source: otherSource, occurrence: backupID, channel: 0)),
                  epoch: backupEpoch, alignmentRevision: 7, revision: "b"),
            .init(lane: .audio(.init(source: otherSource, occurrence: otherID, channel: 1)),
                  epoch: otherEpoch, alignmentRevision: 7, revision: "o"),
            .init(lane: .intentionalSilence("bed"), epoch: nil, alignmentRevision: 7, revision: "s"),
        ]
        self.identities = identities
        proofs = (0..<4).map { index in
            let lane = identities[index]
            let start: Int64 = index == 0 ? 0 : -2
            let end: Int64 = index == 0 ? (primaryRate == 48_000 ? 32 : 34) : 30
            return KeyedLaneFootprintInput(
                identity: lane,
                survey: .init(lane: lane.lane, coverage: index == 3 ? [] :
                    [RemovedFrameSpan(start: start, end: end)],
                    intentionalSilence: index == 3 ?
                    [RemovedFrameSpan(start: -2, end: 34)] :
                    (index == 0 ?
                     (primaryRate == 48_000 ?
                      [RemovedFrameSpan(start: -2, end: 0), RemovedFrameSpan(start: 32, end: 34)] :
                      [RemovedFrameSpan(start: -2, end: 0)]) :
                     [RemovedFrameSpan(start: 30, end: 34)])),
                sourceCoverage: index == 3 ? [] : [SourceFrameSpan(start: 0, end: 32)],
                requestedFadeOut: index == 3 ? nil :
                    SourceFrameSpan(start: index == 0 ? 8 : (primaryRate == 48_000 ? 10 : 11),
                                    end: index == 0 ? 10 : (primaryRate == 48_000 ? 12 : 13)),
                requestedFadeIn: index == 3 ? nil :
                    SourceFrameSpan(start: index == 0 ? 12 : (primaryRate == 48_000 ? 14 : 15),
                                    end: index == 0 ? 14 : (primaryRate == 48_000 ? 16 : 17)),
                finalMergedFades: index == 3 ? [] :
                    [SourceFrameSpan(start: index == 0 ? 8 : (primaryRate == 48_000 ? 10 : 11),
                                     end: index == 0 ? 10 : (primaryRate == 48_000 ? 12 : 13)),
                     SourceFrameSpan(start: index == 0 ? 12 : (primaryRate == 48_000 ? 14 : 15),
                                     end: index == 0 ? 14 : (primaryRate == 48_000 ? 16 : 17))]
            )
        }
    }

    func proof(_ index: Int, revision: String? = nil,
               coverage: [SourceFrameSpan]? = nil, protected: [SourceFrameSpan] = [],
               requestedOut: SourceFrameSpan? = nil,
               finalFades: [SourceFrameSpan]? = nil,
               survey: CommonEditLaneSurvey? = nil) -> KeyedLaneFootprintInput {
        let old = proofs[index]
        return .init(identity: .init(lane: old.identity.lane, epoch: old.identity.epoch,
                                     alignmentRevision: old.identity.alignmentRevision,
                                     revision: revision ?? old.identity.revision),
                     survey: survey ?? old.survey, sourceCoverage: coverage ?? old.sourceCoverage,
                     protected: protected, requestedFadeOut: requestedOut ?? old.requestedFadeOut,
                     requestedFadeIn: old.requestedFadeIn,
                     finalMergedFades: finalFades ?? old.finalMergedFades)
    }

    func map(mode: ProvisionalCutMode = .shorten, proofs: [KeyedLaneFootprintInput]? = nil,
             identities: [KeyedEditLane]? = nil, primary: KeyedEditLane? = nil,
             source: SourceFrameSpan = .init(start: 10, end: 12),
             outputRate: NominalRate? = nil,
             fadeOutOutputFrames: Int64 = 2,
             base: CommonEpisodeEditMap? = nil) throws -> ProvisionalKeyedCutMapping {
        try KeyedCutMapping.map(
            base: base ?? self.base,
            manifest: .init(revision: "episode", lanes: (identities ?? self.identities).map(\.lane)),
            manifestRevision: "episode", laneKeys: identities ?? self.identities,
            selectedPrimary: self.identities[0], primary: primary ?? self.identities[0],
            sourceFrames: source, mode: mode,
            outputRate: outputRate ?? self.base.outputRate, fadeOutOutputFrames: fadeOutOutputFrames,
            fadeInOutputFrames: 2, proofs: proofs ?? self.proofs
        )
    }

    private static func group(reference: TimelineReference, group: RecorderGroupID,
                              epoch: RecordingEpochID, source: SourceID,
                              occurrence: SourceOccurrenceID, offset: Int64,
                              nominalRate: Int64 = 48_000) throws -> GroupTimeMap {
        let rate = try NominalRate(nominalRate)
        let segment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: try ExactRational(32, nominalRate),
            rateRatio: .one, alignedOffset: try ExactRational(offset, 48_000)
        )
        return try GroupTimeMap(
            group: group, reference: reference,
            epochs: [.init(epoch: epoch, mapping: .mapped(
                segments: [segment], provenance: group == reference.group ? .timelineReference :
                    .manual(ManualCorrection(basis: .numericEntry))
            ))],
            placements: [.init(
                occurrence: try SourceOccurrence(id: occurrence, source: source,
                                                 nominalRate: rate, frameCount: 32),
                spans: [.init(startFrame: 0, endFrame: 32, epoch: epoch, groupClockOffset: .zero)]
            )]
        )
    }
}
