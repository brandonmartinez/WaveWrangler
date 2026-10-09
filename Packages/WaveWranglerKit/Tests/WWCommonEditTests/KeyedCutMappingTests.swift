import Testing
import WWCore
import WWTimeMap
@testable import WWCommonEdit

@Suite("Keyed all-lane cut mapping (synthetic, provisional)")
struct KeyedCutMappingTests {
    @Test func knownBackupCannotEnterDefaultEmptyExclusionCutProof() throws {
        let fx = try Fixture(knownBackup: true)
        guard case let .audio(knownBackup) = fx.identities[1].lane,
              knownBackup.occurrence == fx.base.alignment.groups[1].placements[0].occurrence.id else {
            Issue.record("Expected the known Backup occurrence in the fixture")
            return
        }
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.invalidLanes) {
                try fx.map(mode: mode, excludedBackups: [])
            }
        }
    }

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

    @Test func neitherMappedModeAttestsCallerSuppliedManifest() throws {
        let fx = try Fixture()
        let proofs = fx.fadeFreeProofs()
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let result = try fx.map(mode: mode, proofs: proofs, fadeOutOutputFrames: 0,
                                    fadeInOutputFrames: 0)
            #expect(throws: CommonEditAttestationRefusal.trustedAuthorityUnavailable) {
                try CommonEditAttestation.prepare(
                    map: result.map,
                    manifest: .init(revision: "episode", lanes: fx.identities.map(\.lane),
                                    roleClaims: fx.roleClaims),
                    surveys: proofs.map(\.survey)
                )
            }
        }
    }

    @Test func selectedPrimariesMapWhileEveryBackupIsExplicitlyExcluded() throws {
        let fx = try Fixture(knownBackup: true)
        let selected = [fx.identities[0], fx.identities[2], fx.identities[3]]
        let proofs = [fx.proofs[0], fx.proofs[2], fx.proofs[3]]
        guard case let .audio(backup) = fx.identities[1].lane else {
            Issue.record("Expected the excluded Backup occurrence")
            return
        }
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let result = try fx.map(mode: mode, proofs: proofs, identities: selected,
                                    excludedBackups: [backup])
            #expect(result.lanes.map(\.identity) == selected)
            #expect(result.lanes[0].sourceRemoval == SourceFrameSpan(start: 10, end: 12))
            #expect(result.lanes[1].sourceRemoval == SourceFrameSpan(start: 12, end: 14))
            #expect(result.excludedBackups.map(\.key) == [backup])
            #expect(result.excludedBackups[0].status == "backup not verified; excluded from cut proof")
            #expect(throws: CommonEditAttestationRefusal.trustedAuthorityUnavailable) {
                try CommonEditAttestation.prepare(
                    map: result.map,
                    manifest: .init(revision: "episode", lanes: selected.map(\.lane),
                                    excludedBackups: [backup], roleClaims: fx.roleClaims),
                    surveys: proofs.map(\.survey)
                )
            }
        }
    }

    @Test func missingOrMisclassifiedPrimaryAndBackupProofsRefuse() throws {
        let fx = try Fixture(knownBackup: true)
        let selected = [fx.identities[0], fx.identities[2], fx.identities[3]]
        let proofs = [fx.proofs[0], fx.proofs[2], fx.proofs[3]]
        guard case let .audio(backup) = fx.identities[1].lane,
              case let .audio(otherPrimary) = fx.identities[2].lane else {
            Issue.record("Expected audio occurrences")
            return
        }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(proofs: proofs, identities: selected)
        }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(proofs: [proofs[0], proofs[2]], identities: selected,
                       excludedBackups: [backup])
        }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(proofs: proofs, identities: selected, excludedBackups: [backup, backup])
        }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(proofs: proofs, identities: selected,
                       excludedBackups: [backup, otherPrimary])
        }
        let missingCoverage = proofs[1]
        #expect(throws: ProvisionalCutMappingError.incompleteCoverage) {
            try fx.map(proofs: [
                proofs[0],
                .init(identity: missingCoverage.identity, survey: missingCoverage.survey),
                proofs[2],
            ], identities: selected, excludedBackups: [backup])
        }
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let protected = fx.proofs[2]
            let checked = KeyedLaneFootprintInput(
                identity: protected.identity, survey: protected.survey,
                sourceCoverage: protected.sourceCoverage,
                protected: [SourceFrameSpan(start: 13, end: 14)],
                requestedFadeOut: protected.requestedFadeOut,
                requestedFadeIn: protected.requestedFadeIn,
                finalMergedFades: protected.finalMergedFades
            )
            #expect(throws: ProvisionalCutMappingError.protectedFrame) {
                try fx.map(mode: mode, proofs: [proofs[0], checked, proofs[2]],
                           identities: selected, excludedBackups: [backup])
            }
        }
    }

    @Test func excludedBackupNeedsNoInverseButSelectedPrimaryStillDoes() throws {
        let fx = try Fixture(knownBackup: true)
        let backup = fx.base.alignment.groups[1]
        let unsupported = try GroupTimeMap(
            group: backup.group, reference: backup.reference,
            epochs: [.init(epoch: fx.identities[1].epoch!,
                           mapping: .unsupported(.estimatorAbstained))],
            placements: backup.placements
        )
        let alignment = try AlignedTimelineMap(
            reference: fx.base.alignment.reference,
            groups: [fx.base.alignment.groups[0], unsupported, fx.base.alignment.groups[2]]
        )
        let base = try CommonEpisodeEditMap(
            alignment: alignment, alignmentRevision: fx.base.alignmentRevision,
            editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
            alignedFrameOrigin: fx.base.alignedFrameOrigin,
            alignedFrameCount: fx.base.alignedFrameCount, removals: []
        )
        let selected = [fx.identities[0], fx.identities[2], fx.identities[3]]
        let proofs = [fx.proofs[0], fx.proofs[2], fx.proofs[3]]
        guard case let .audio(backupKey) = fx.identities[1].lane,
              case let .audio(otherKey) = fx.identities[2].lane else {
            Issue.record("Expected distinct audio occurrences")
            return
        }
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let result = try fx.map(mode: mode, proofs: proofs, identities: selected,
                                    excludedBackups: [backupKey], base: base)
            #expect(result.excludedBackups.map(\.key) == [backupKey])
            #expect(result.lanes.count == 3)
        }
        let onlyPrimary = [fx.identities[0], fx.identities[3]]
        let onlyProofs = [fx.proofs[0], fx.proofs[3]]
        let excluded = [backupKey, otherKey]
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(proofs: onlyProofs, identities: onlyPrimary,
                       excludedBackups: excluded, fadeOutOutputFrames: 2,
                       fadeInOutputFrames: 2, base: base)
        }
        #expect(throws: ProvisionalCutMappingError.invalidLanes) {
            try fx.map(base: base)
        }
        let other = fx.base.alignment.groups[2]
        let unsupportedPrimary = try GroupTimeMap(
            group: other.group, reference: other.reference,
            epochs: [.init(epoch: fx.identities[2].epoch!,
                           mapping: .unsupported(.estimatorAbstained))],
            placements: other.placements
        )
        let primaryAlignment = try AlignedTimelineMap(
            reference: fx.base.alignment.reference,
            groups: [fx.base.alignment.groups[0], unsupported, unsupportedPrimary]
        )
        let primaryBase = try CommonEpisodeEditMap(
            alignment: primaryAlignment, alignmentRevision: fx.base.alignmentRevision,
            editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
            alignedFrameOrigin: fx.base.alignedFrameOrigin,
            alignedFrameCount: fx.base.alignedFrameCount, removals: []
        )
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.ambiguousInverse) {
                try fx.map(mode: mode, proofs: proofs, identities: selected,
                           excludedBackups: [backupKey], base: primaryBase)
            }
        }
    }

    @Test func sharedBackupSourceCannotBeAdmittedThroughAnotherOccurrence() throws {
        let fx = try Fixture(sharedBackupSource: true, knownBackup: true)
        guard case let .audio(backup) = fx.identities[1].lane else {
            Issue.record("Expected a Backup occurrence")
            return
        }
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.invalidLanes) {
                try fx.map(mode: mode, proofs: [fx.proofs[0], fx.proofs[2], fx.proofs[3]],
                           identities: [fx.identities[0], fx.identities[2], fx.identities[3]],
                           excludedBackups: [backup])
            }
        }
    }

    @Test func absentDuplicateOrContradictoryRoleClaimsRefuseBeforeMapping() throws {
        let fx = try Fixture(knownBackup: true)
        let selected = [fx.identities[0], fx.identities[2], fx.identities[3]]
        let proofs = [fx.proofs[0], fx.proofs[2], fx.proofs[3]]
        guard case let .audio(backup) = fx.identities[1].lane,
              case let .audio(primary) = fx.identities[0].lane else {
            Issue.record("Expected selected Primary and Backup keys")
            return
        }
        let wrong = CommonEditAudioRoleClaim(key: backup, role: .selectedPrimary)
        let wrongChannel = CommonEditAudioRoleClaim(
            key: .init(source: primary.source, occurrence: primary.occurrence, channel: 1),
            role: .selectedPrimary
        )
        for claims in [
            [],
            Array(fx.roleClaims.dropLast()),
            fx.roleClaims + [fx.roleClaims[1]],
            [fx.roleClaims[0], wrong, fx.roleClaims[2]],
            [wrongChannel, fx.roleClaims[1], fx.roleClaims[2]],
        ] {
            for mode in [ProvisionalCutMode.shorten, .lift] {
                #expect(throws: ProvisionalCutMappingError.invalidLanes) {
                    try fx.map(mode: mode, proofs: proofs, identities: selected,
                               excludedBackups: [backup], roleClaims: claims)
                }
            }
        }
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.invalidLanes) {
                try fx.map(mode: mode, roleClaims: fx.roleClaims)
            }
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

    @Test func roundedEndIncludesEveryAffectedSourceFrameInBothModes() throws {
        let fx = try Fixture(primaryRate: 44_100)
        let request = SourceFrameSpan(start: 9, end: 11)
        for mode in [ProvisionalCutMode.shorten, .lift] {
            let unprotected = try fx.map(mode: mode, proofs: fx.fadeFreeProofs(),
                                         source: request, fadeOutOutputFrames: 0,
                                         fadeInOutputFrames: 0)
            #expect(unprotected.grid == RemovedFrameSpan(start: 10, end: 12))
            #expect(unprotected.lanes[0].sourceRemoval == SourceFrameSpan(start: 9, end: 12))
            #expect(unprotected.lanes[1].sourceRemoval == SourceFrameSpan(start: 12, end: 14))

            for lane in [0, 1, 2] {
                let affected: Int64 = lane == 0 ? 11 : 12
                #expect(throws: ProvisionalCutMappingError.protectedFrame) {
                    try fx.map(mode: mode, proofs: fx.fadeFreeProofs(
                        protected: [lane: SourceFrameSpan(start: affected, end: affected + 1)],
                        gridProtected: lane == 0 ? RemovedFrameSpan(start: 12, end: 13) : nil
                    ), source: request, fadeOutOutputFrames: 0, fadeInOutputFrames: 0)
                }
            }
            #expect(throws: ProvisionalCutMappingError.protectedFrame) {
                try fx.map(mode: mode, proofs: fx.fadeFreeProofs(
                    gridProtected: RemovedFrameSpan(start: 10, end: 11)
                ), source: request, fadeOutOutputFrames: 0, fadeInOutputFrames: 0)
            }

            let adjacent = try fx.map(mode: mode, proofs: fx.fadeFreeProofs(
                protected: [0: SourceFrameSpan(start: 8, end: 9),
                            1: SourceFrameSpan(start: 14, end: 15)],
                gridProtected: RemovedFrameSpan(start: 12, end: 13)
            ), source: request, fadeOutOutputFrames: 0, fadeInOutputFrames: 0)
            #expect(adjacent.lanes[0].sourceRemoval == SourceFrameSpan(start: 9, end: 12))
        }
    }

    @Test func wholeMapAndAggregateLaneWorkRefuseBeforeProofProcessing() throws {
        let fx = try Fixture()
        let long = try CommonEpisodeEditMap(
            alignment: fx.base.alignment, alignmentRevision: fx.base.alignmentRevision,
            editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
            alignedFrameOrigin: fx.base.alignedFrameOrigin, alignedFrameCount: 8_193, removals: []
        )
        #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
            try fx.map(proofs: [], base: long)
        }
        let full = try CommonEpisodeEditMap(
            alignment: fx.base.alignment, alignmentRevision: fx.base.alignmentRevision,
            editRevision: fx.base.editRevision, outputRate: fx.base.outputRate,
            alignedFrameOrigin: fx.base.alignedFrameOrigin, alignedFrameCount: 8_192, removals: []
        )
        let extra = (0..<5).map { index in
            KeyedEditLane(lane: .intentionalSilence("extra-\(index)"), epoch: nil,
                          alignmentRevision: fx.base.alignmentRevision, revision: "s-\(index)")
        }
        #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
            try fx.map(proofs: [], identities: fx.identities + extra, base: full)
        }
        let many = (0..<17).map { index in
            KeyedEditLane(lane: .intentionalSilence("lane-\(index)"), epoch: nil,
                          alignmentRevision: fx.base.alignmentRevision, revision: "s-\(index)")
        }
        #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
            try fx.map(proofs: [], identities: fx.identities + many)
        }
        var excessSpans = fx.proofs
        let spans = (0..<33).map { SourceFrameSpan(start: Int64($0), end: Int64($0 + 1)) }
        excessSpans[1] = fx.proof(1, coverage: spans)
        #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
            try fx.map(proofs: excessSpans)
        }
    }

    @Test func aggregateMergedFadeSourceWorkRefusesBeforeMapping() throws {
        let fx = try Fixture()
        let fades = (0..<32).map { index in
            SourceFrameSpan(start: Int64(index) * 8_193, end: Int64(index) * 8_193 + 8_192)
        }
        let proofs = fx.proofs.map { original in
            KeyedLaneFootprintInput(
                identity: original.identity, survey: original.survey,
                sourceCoverage: original.sourceCoverage,
                finalMergedFades: original.identity.epoch == nil ? [] : fades
            )
        }
        // Three audio lanes would walk 786,432 source frames; an invalid cut makes
        // the old path return invalidGrid without running any of those scans.
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
                try fx.map(mode: mode, proofs: proofs, source: .init(start: 32, end: 32),
                           fadeOutOutputFrames: 0, fadeInOutputFrames: 0)
            }
        }
    }

    @Test func requestedAndFinalFadeScansShareTheSourceBudget() throws {
        let fx = try Fixture()
        let fades = (0..<8).map { index in
            SourceFrameSpan(start: Int64(index) * 8_193, end: Int64(index) * 8_193 + 8_192)
        }
        var proofs = fx.proofs
        let old = proofs[1]
        proofs[1] = .init(
            identity: old.identity, survey: old.survey,
            sourceCoverage: old.sourceCoverage,
            requestedFadeOut: fades[0], finalMergedFades: fades
        )
        #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
            try fx.map(proofs: proofs, source: .init(start: 32, end: 32))
        }
    }

    @Test func cutAndMergedFadeSourceScansShareTheAggregateLimit() throws {
        let fx = try Fixture()
        let fades = (0..<8).map { index in
            let start = Int64(index) * 8_193
            return SourceFrameSpan(start: start, end: start + (index == 7 ? 8_190 : 8_192))
        }
        var proofs = fx.fadeFreeProofs()
        let old = proofs[0]
        proofs[0] = .init(identity: old.identity, survey: old.survey,
                          sourceCoverage: old.sourceCoverage, finalMergedFades: fades)
        // The fades cost 65,534 frames, then three affected source cuts add six.
        // The deliberately uncovered fades must never reach per-lane inspection.
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.structuralPreflight(.inspectionLimit)) {
                try fx.map(mode: mode, proofs: proofs, fadeOutOutputFrames: 0,
                           fadeInOutputFrames: 0)
            }
        }
    }

    @Test func sourceFootprintsContainAllForwardFramesInsideSharedGrid() throws {
        for rate: Int64 in [44_100, 48_000] {
            let fx = try Fixture(primaryRate: rate)
            for mode in [ProvisionalCutMode.shorten, .lift] {
                for first in stride(from: Int64(4), through: 20, by: 2) {
                    let mapping = try fx.map(
                        mode: mode, proofs: fx.fadeFreeProofs(),
                        source: .init(start: first, end: first + 2),
                        fadeOutOutputFrames: 0, fadeInOutputFrames: 0
                    )
                    let lower = fx.base.outputRate.instant(ofFrame: mapping.grid.start)
                    let upper = fx.base.outputRate.instant(ofFrame: mapping.grid.end)
                    for lane in mapping.lanes.prefix(3) {
                        guard case let .audio(key) = lane.identity.lane,
                              let removal = lane.sourceRemoval else {
                            Issue.record("Expected an audio-lane source footprint")
                            continue
                        }
                        for frame: Int64 in 0..<32 {
                            guard case let .aligned(position) = try fx.base.alignment.alignedTime(
                                ofFrame: frame, in: key.occurrence
                            ) else {
                                Issue.record("Expected a mapped source frame")
                                continue
                            }
                            if position.instant >= lower && position.instant < upper {
                                #expect(frame >= removal.start && frame < removal.end)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func roundedMergedFadeOverlappingGridRefusesLiftAndShorten() throws {
        let fx = try Fixture(secondaryRate: 44_100)
        var proofs = fx.fadeFreeProofs()
        let secondary = proofs[1]
        proofs[1] = .init(
            identity: secondary.identity, survey: secondary.survey,
            sourceCoverage: secondary.sourceCoverage,
            finalMergedFades: [SourceFrameSpan(start: 4, end: 6)]
        )
        for mode in [ProvisionalCutMode.shorten, .lift] {
            #expect(throws: ProvisionalCutMappingError.invalidFade) {
                try fx.map(mode: mode, proofs: proofs, source: .init(start: 4, end: 6),
                           fadeOutOutputFrames: 0, fadeInOutputFrames: 0)
            }
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
        let secondary = fx.base.alignment.groups[1]
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
            group: secondary.group, reference: secondary.reference,
            epochs: [.init(epoch: epoch, mapping: .mapped(segments: [first], provenance: provenance)),
                     .init(epoch: next, mapping: .mapped(segments: [second], provenance: provenance))],
            placements: [.init(
                occurrence: secondary.placements[0].occurrence,
                spans: [.init(startFrame: 0, endFrame: 11, epoch: epoch, groupClockOffset: .zero),
                        .init(startFrame: 13, endFrame: 32, epoch: next, groupClockOffset: .zero)]
            )]
        )
        let unsupported = try GroupTimeMap(
            group: secondary.group, reference: secondary.reference,
            epochs: [.init(epoch: epoch, mapping: .unsupported(.estimatorAbstained))],
            placements: secondary.placements
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
        let secondary = fx.base.alignment.groups[1]
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
            group: secondary.group, reference: secondary.reference,
            epochs: [.init(epoch: epoch, mapping: .mapped(segments: [first], provenance: provenance)),
                     .init(epoch: next, mapping: .mapped(segments: [second], provenance: provenance))],
            placements: [.init(
                occurrence: secondary.placements[0].occurrence,
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
    let roleClaims: [CommonEditAudioRoleClaim]

    init(primaryRate: Int64 = 48_000, secondaryRate: Int64 = 48_000,
         sharedBackupSource: Bool = false, knownBackup: Bool = false) throws {
        let source = SourceID(), rate = try NominalRate(48_000)
        let group = RecorderGroupID(), epoch = RecordingEpochID(), occurrence = SourceOccurrenceID()
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: occurrence)
        let primary = try Self.group(reference: reference, group: group, epoch: epoch,
                                     source: source, occurrence: occurrence, offset: 0,
                                     nominalRate: primaryRate)
        let otherSource = SourceID()
        let otherPrimarySource = sharedBackupSource ? otherSource : SourceID()
        let secondaryID = SourceOccurrenceID(), otherID = SourceOccurrenceID()
        let secondaryEpoch = RecordingEpochID(), otherEpoch = RecordingEpochID()
        let secondary = try Self.group(reference: reference, group: RecorderGroupID(),
                                       epoch: secondaryEpoch, source: otherSource,
                                       occurrence: secondaryID, offset: -2,
                                       nominalRate: secondaryRate)
        let other = try Self.group(reference: reference, group: RecorderGroupID(),
                                   epoch: otherEpoch, source: otherPrimarySource, occurrence: otherID,
                                   offset: -2, nominalRate: secondaryRate)
        base = try CommonEpisodeEditMap(
            alignment: AlignedTimelineMap(reference: reference, groups: [primary, secondary, other]),
            alignmentRevision: 7, editRevision: 8, outputRate: rate,
            alignedFrameOrigin: -2, alignedFrameCount: 36, removals: []
        )
        let identities: [KeyedEditLane] = [
            .init(lane: .audio(.init(source: source, occurrence: occurrence, channel: 0)),
                  epoch: epoch, alignmentRevision: 7, revision: "p"),
            .init(lane: .audio(.init(source: otherSource, occurrence: secondaryID, channel: 0)),
                  epoch: secondaryEpoch, alignmentRevision: 7, revision: "s"),
            .init(lane: .audio(.init(source: otherPrimarySource, occurrence: otherID, channel: 1)),
                  epoch: otherEpoch, alignmentRevision: 7, revision: "o"),
            .init(lane: .intentionalSilence("bed"), epoch: nil, alignmentRevision: 7, revision: "s"),
        ]
        self.identities = identities
        roleClaims = identities.prefix(3).enumerated().compactMap { index, identity in
            guard case let .audio(key) = identity.lane else { return nil }
            return CommonEditAudioRoleClaim(
                key: key, role: knownBackup && index == 1 ? .backup : .selectedPrimary
            )
        }
        proofs = (0..<4).map { index in
            let lane = identities[index]
            let start: Int64 = index == 0 ? 0 : -2
            let end: Int64 = index == 0 ? (primaryRate == 48_000 ? 32 : 34) :
                (secondaryRate == 48_000 ? 30 : 32)
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
                     [RemovedFrameSpan(start: end, end: 34)])),
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

    func fadeFreeProofs(protected: [Int: SourceFrameSpan] = [:],
                        gridProtected: RemovedFrameSpan? = nil) -> [KeyedLaneFootprintInput] {
        proofs.enumerated().map { index, original in
            let survey = original.survey
            return .init(
                identity: original.identity,
                survey: .init(lane: survey.lane, coverage: survey.coverage,
                              intentionalSilence: survey.intentionalSilence,
                              protected: index == 0 ? gridProtected.map { [$0] } ?? [] : []),
                sourceCoverage: original.sourceCoverage,
                protected: protected[index].map { [$0] } ?? []
            )
        }
    }

    func map(mode: ProvisionalCutMode = .shorten, proofs: [KeyedLaneFootprintInput]? = nil,
             identities: [KeyedEditLane]? = nil, primary: KeyedEditLane? = nil,
             excludedBackups: [CommonEditLaneKey] = [],
             roleClaims: [CommonEditAudioRoleClaim]? = nil,
             source: SourceFrameSpan = .init(start: 10, end: 12),
             outputRate: NominalRate? = nil,
             fadeOutOutputFrames: Int64 = 2,
             fadeInOutputFrames: Int64 = 2,
             base: CommonEpisodeEditMap? = nil) throws -> ProvisionalKeyedCutMapping {
        try KeyedCutMapping.map(
            base: base ?? self.base,
            manifest: .init(revision: "episode", lanes: (identities ?? self.identities).map(\.lane),
                            excludedBackups: excludedBackups,
                            roleClaims: roleClaims ?? self.roleClaims),
            manifestRevision: "episode", laneKeys: identities ?? self.identities,
            selectedPrimary: self.identities[0], primary: primary ?? self.identities[0],
            sourceFrames: source, mode: mode,
            outputRate: outputRate ?? self.base.outputRate, fadeOutOutputFrames: fadeOutOutputFrames,
            fadeInOutputFrames: fadeInOutputFrames, proofs: proofs ?? self.proofs
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
