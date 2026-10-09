import Testing
import WWCommonEdit
import WWCore
import WWTimeMap
@testable import WWRender

@Suite("Synthetic common edit PCM bridge (not production admission)")
struct SyntheticCommonEditPCMTests {
    @Test func shortenUsesOneMapForAsymmetricAudioAndSilenceAcrossChunks() throws {
        let fixture = try PCMFixture()
        let (plan, input) = try fixture.prepare(.shorten)
        let small = try SyntheticCommonEditPCMRenderer.render(plan, input: input, chunkFrames: 3)
        let whole = try SyntheticCommonEditPCMRenderer.render(plan, input: input, chunkFrames: 22)
        #expect(small.plan.mapping.map == whole.plan.mapping.map)
        #expect(small.chunks.map(\.firstOutputFrame) == [0, 3, 6, 9, 12, 15, 18])
        #expect(small.chunks.reduce(0) { $0 + $1.frameCount } == 20)
        #expect(small.chunks.allSatisfy { $0.channelCount == 3 && $0.frameCount <= 3 })
        #expect(Self.lanes(small) == Self.lanes(whole))
        let output = Self.lanes(small)
        #expect(output[0] == [0, 0, 1, 2, 3, 4] + (7...20).map(Float.init))
        #expect(output[1] == [100, 101, 102, 103, 104, 105] +
                (108...121).map(Float.init))
        #expect(output[2] == [Float](repeating: 0, count: 20))
        #expect(plan.mapping.map.keptSpans.map(\.outputStart) == [0, 6])
    }

    @Test func liftKeepsDurationAndMutesOnlyReservedGrid() throws {
        let fixture = try PCMFixture()
        let (plan, input) = try fixture.prepare(.lift)
        let output = Self.lanes(try SyntheticCommonEditPCMRenderer.render(
            plan, input: input, chunkFrames: 5
        ))
        #expect(plan.mapping.map.outputFrameCount == 22)
        #expect(output[0] == [0, 0] + (1...4).map(Float.init) +
                [0, 0] + (7...20).map(Float.init))
        #expect(output[1] == (100...105).map(Float.init) +
                [0, 0] + (108...121).map(Float.init))
        #expect(output[2].allSatisfy { $0 == 0 })
    }

    @Test func priorAdjacentRemovalIsAppliedOnceAndOverlapsRefuse() throws {
        let fixture = try PCMFixture()
        let adjacent = try CommonEpisodeEditMap(
            alignment: fixture.base.alignment, alignmentRevision: fixture.base.alignmentRevision,
            editRevision: fixture.base.editRevision, outputRate: fixture.base.outputRate,
            alignedFrameOrigin: -2, alignedFrameCount: 22,
            removals: [.init(start: 2, end: 4)]
        )
        let (plan, input) = try fixture.prepare(.shorten, base: adjacent)
        #expect(plan.mapping.map.removals == [.init(start: 2, end: 4),
                                               .init(start: 4, end: 6)])
        let output = Self.lanes(try SyntheticCommonEditPCMRenderer.render(
            plan, input: input, chunkFrames: 3
        ))
        #expect(output[0] == [0, 0, 1, 2] + (7...20).map(Float.init))
        #expect(output[1] == (100...103).map(Float.init) +
                (108...121).map(Float.init))
        let overlapping = try CommonEpisodeEditMap(
            alignment: fixture.base.alignment, alignmentRevision: fixture.base.alignmentRevision,
            editRevision: fixture.base.editRevision, outputRate: fixture.base.outputRate,
            alignedFrameOrigin: -2, alignedFrameCount: 22,
            removals: [.init(start: 4, end: 5)]
        )
        #expect(throws: ProvisionalCutMappingError.invalidGrid) {
            try fixture.mapping(.shorten, base: overlapping)
        }
    }

    @Test func exactFadesNeverTouchAdjacentFramesAndSplitFootprintsCanMerge() throws {
        let fixture = try PCMFixture()
        let (plan, input) = try fixture.prepare(.shorten, withFades: true)
        let output = Self.lanes(try SyntheticCommonEditPCMRenderer.render(
            plan, input: input, chunkFrames: 1
        ))
        #expect(output[0][3] == 2)
        #expect(output[0][4] == 1.5)
        #expect(output[0][5] == 0)
        #expect(output[0][6] == 3.5)
        #expect(output[0][7] == 8)
        #expect(output[1][3] == 103)
        #expect(output[1][4] == 52)
        #expect(output[1][5] == 0)
        #expect(output[1][6] == 54)
        #expect(output[1][7] == 109)
        #expect(output[2].allSatisfy { $0 == 0 })
        let lost = [SyntheticLaneFade(identity: fixture.identities[0],
                                      frames: .init(start: 2, end: 3), direction: .fadeOut)]
        #expect(throws: SyntheticCommonEditPCMError.invalidFade) {
            try fixture.prepare(.shorten, withFades: true, fades: lost)
        }
        let crossed = [SyntheticLaneFade(identity: fixture.identities[0],
                                         frames: .init(start: 3, end: 7), direction: .fadeOut)]
        #expect(throws: SyntheticCommonEditPCMError.invalidFade) {
            try fixture.prepare(.shorten, withFades: true, fades: crossed)
        }
    }

    @Test func staleKeysIncompleteInputAndInvalidSamplesRefuse() throws {
        let fixture = try PCMFixture()
        let (plan, input) = try fixture.prepare(.shorten)
        let stale = try CommonEpisodeEditMap(
            alignment: fixture.base.alignment, alignmentRevision: fixture.base.alignmentRevision,
            editRevision: fixture.base.editRevision + 1, outputRate: fixture.base.outputRate,
            alignedFrameOrigin: fixture.base.alignedFrameOrigin,
            alignedFrameCount: fixture.base.alignedFrameCount, removals: []
        )
        #expect(throws: SyntheticCommonEditPCMError.invalidPlan) {
            try SyntheticCommonEditPCMPlan(
                base: stale, mapping: plan.mapping, mode: .shorten,
                manifest: fixture.manifest, surveys: fixture.surveys, fades: []
            )
        }
        #expect(throws: SyntheticCommonEditPCMError.invalidInput) {
            try SyntheticCommonEditPCMRenderer.render(plan, input: .init(lanes: [
                input.lanes[1], input.lanes[0], input.lanes[2],
            ]), chunkFrames: 3)
        }
        #expect(throws: SyntheticCommonEditPCMError.invalidInput) {
            try SyntheticCommonEditPCMRenderer.render(plan, input: .init(lanes: [
                (input.lanes[0].identity, Array(input.lanes[0].samples.dropLast())),
                input.lanes[1], input.lanes[2],
            ]), chunkFrames: 3)
        }
        #expect(throws: SyntheticCommonEditPCMError.invalidInput) {
            try SyntheticCommonEditPCMRenderer.render(plan, input: .init(lanes: [
                input.lanes[0], input.lanes[1],
                (input.lanes[2].identity, [Float](repeating: 1, count: 22)),
            ]), chunkFrames: 3)
        }
        var inventedPadding = input.lanes[0].samples
        inventedPadding[0] = 1
        #expect(throws: SyntheticCommonEditPCMError.invalidInput) {
            try SyntheticCommonEditPCMRenderer.render(plan, input: .init(lanes: [
                (input.lanes[0].identity, inventedPadding), input.lanes[1], input.lanes[2],
            ]), chunkFrames: 3)
        }
        var nonfinite = input.lanes[0].samples
        nonfinite[1] = .nan
        #expect(throws: SyntheticCommonEditPCMError.invalidInput) {
            try SyntheticCommonEditPCMRenderer.render(plan, input: .init(lanes: [
                (input.lanes[0].identity, nonfinite), input.lanes[1], input.lanes[2],
            ]), chunkFrames: 3)
        }
        #expect(throws: SyntheticCommonEditPCMError.resourceLimit) {
            try SyntheticCommonEditPCMRenderer.render(plan, input: input, chunkFrames: .max)
        }
    }

    @Test func cancelledBeforePCMWorkReturnsNoProduct() async throws {
        let fixture = try PCMFixture()
        let (plan, input) = try fixture.prepare(.shorten)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try SyntheticCommonEditPCMRenderer.render(plan, input: input, chunkFrames: 3)
                return false
            } catch {
                return error == .cancelled
            }
        }
        #expect(await cancelled.value)
    }

    @Test func protectedAndMissingStructuralProofRefuseBeforePCM() throws {
        let fixture = try PCMFixture()
        var protected = fixture.surveys
        protected[1] = .init(lane: protected[1].lane, coverage: protected[1].coverage,
                             protected: [.init(start: 4, end: 5)])
        #expect(throws: ProvisionalCutMappingError.protectedFrame) {
            try fixture.mapping(.shorten, surveys: protected)
        }
        let mapping = try fixture.mapping(.shorten)
        #expect(throws: SyntheticCommonEditPCMError.invalidPlan) {
            try SyntheticCommonEditPCMPlan(
                base: fixture.base, mapping: mapping, mode: .shorten,
                manifest: fixture.manifest, surveys: Array(fixture.surveys.dropLast()), fades: []
            )
        }
        #expect(throws: SyntheticCommonEditPCMError.invalidPlan) {
            try SyntheticCommonEditPCMPlan(
                base: fixture.base, mapping: mapping, mode: .lift,
                manifest: fixture.manifest, surveys: fixture.surveys, fades: []
            )
        }
        #expect(throws: CommonEditAttestationRefusal.trustedAuthorityUnavailable) {
            try CommonEditAttestation.prepare(
                map: mapping.map, manifest: fixture.manifest, surveys: fixture.surveys
            )
        }
    }

    private static func lanes(_ result: SyntheticCommonEditPCMResult) -> [[Float]] {
        (0..<result.plan.mapping.lanes.count).map { lane in
            result.chunks.flatMap { chunk in
                Array(chunk.samples[lane * chunk.frameCount ..< (lane + 1) * chunk.frameCount])
            }
        }
    }
}

private struct PCMFixture {
    let base: CommonEpisodeEditMap
    let identities: [KeyedEditLane]
    let manifest: CommonEditLaneManifest
    let surveys: [CommonEditLaneSurvey]

    init() throws {
        let rate = try NominalRate(48_000)
        let primaryEpoch = RecordingEpochID(), backupEpoch = RecordingEpochID()
        let primaryID = SourceOccurrenceID(), backupID = SourceOccurrenceID()
        let primarySource = SourceID(), backupSource = SourceID()
        let primaryGroup = RecorderGroupID()
        let reference = TimelineReference(group: primaryGroup, epoch: primaryEpoch,
                                          occurrence: primaryID)
        func group(
            id: RecorderGroupID, epoch: RecordingEpochID, source: SourceID,
            occurrence idOfOccurrence: SourceOccurrenceID, count: Int64, offset: Int64
        ) throws -> GroupTimeMap {
            let segment = try AffineClockSegment(
                groupClockStart: .zero, groupClockEnd: try ExactRational(count, 48_000),
                rateRatio: .one, alignedOffset: try ExactRational(offset, 48_000)
            )
            let recording = try SourceOccurrence(
                id: idOfOccurrence, source: source, nominalRate: rate, frameCount: count
            )
            return try GroupTimeMap(
                group: id, reference: reference,
                epochs: [.init(epoch: epoch, mapping: .mapped(
                    segments: [segment],
                    provenance: .manual(.init(basis: .numericEntry))
                ))],
                placements: [.init(
                    occurrence: recording,
                    spans: [.init(startFrame: 0, endFrame: count,
                                  epoch: epoch, groupClockOffset: .zero)]
                )]
            )
        }
        let primary = try group(id: primaryGroup, epoch: primaryEpoch, source: primarySource,
                                occurrence: primaryID, count: 20, offset: 0)
        let backup = try group(id: RecorderGroupID(), epoch: backupEpoch, source: backupSource,
                               occurrence: backupID, count: 22, offset: -2)
        base = try CommonEpisodeEditMap(
            alignment: AlignedTimelineMap(reference: reference, groups: [primary, backup]),
            alignmentRevision: 7, editRevision: 8, outputRate: rate,
            alignedFrameOrigin: -2, alignedFrameCount: 22, removals: []
        )
        identities = [
            .init(lane: .audio(.init(source: primarySource, occurrence: primaryID, channel: 0)),
                  epoch: primaryEpoch, alignmentRevision: 7, revision: "primary"),
            .init(lane: .audio(.init(source: backupSource, occurrence: backupID, channel: 1)),
                  epoch: backupEpoch, alignmentRevision: 7, revision: "backup"),
            .init(lane: .intentionalSilence("bed"), epoch: nil,
                  alignmentRevision: 7, revision: "silence"),
        ]
        manifest = .init(revision: "episode", lanes: identities.map(\.lane))
        surveys = [
            .init(lane: identities[0].lane, coverage: [.init(start: 0, end: 20)],
                  intentionalSilence: [.init(start: -2, end: 0)]),
            .init(lane: identities[1].lane, coverage: [.init(start: -2, end: 20)]),
            .init(lane: identities[2].lane, coverage: [],
                  intentionalSilence: [.init(start: -2, end: 20)]),
        ]
    }

    func mapping(_ mode: ProvisionalCutMode, base suppliedBase: CommonEpisodeEditMap? = nil,
                 surveys: [CommonEditLaneSurvey]? = nil,
                 withFades: Bool = false) throws -> ProvisionalKeyedCutMapping {
        let laneSurveys = surveys ?? self.surveys
        let proofs = identities.enumerated().map { index, key in
            KeyedLaneFootprintInput(
                identity: key, survey: laneSurveys[index],
                sourceCoverage: index == 2 ? [] :
                    [.init(start: 0, end: index == 0 ? 20 : 22)],
                requestedFadeOut: withFades && index < 2
                    ? .init(start: index == 0 ? 2 : 4, end: index == 0 ? 4 : 6) : nil,
                requestedFadeIn: withFades && index < 2
                    ? .init(start: index == 0 ? 6 : 8, end: index == 0 ? 8 : 10) : nil,
                finalMergedFades: withFades && index < 2
                    ? [.init(start: index == 0 ? 2 : 4, end: index == 0 ? 4 : 6),
                       .init(start: index == 0 ? 6 : 8, end: index == 0 ? 8 : 10)] : []
            )
        }
        return try KeyedCutMapping.map(
            base: suppliedBase ?? base, manifest: manifest, manifestRevision: "episode",
            laneKeys: identities, selectedPrimary: identities[0], primary: identities[0],
            sourceFrames: .init(start: 4, end: 6), mode: mode, outputRate: base.outputRate,
            fadeOutOutputFrames: withFades ? 2 : 0, fadeInOutputFrames: withFades ? 2 : 0,
            proofs: proofs
        )
    }

    func prepare(
        _ mode: ProvisionalCutMode, withFades: Bool = false,
        fades supplied: [SyntheticLaneFade]? = nil, base suppliedBase: CommonEpisodeEditMap? = nil
    ) throws -> (SyntheticCommonEditPCMPlan, SyntheticAlignedPCM) {
        let mapping = try mapping(mode, base: suppliedBase, withFades: withFades)
        let finalSurveys: [CommonEditLaneSurvey] = zip(surveys, mapping.lanes).map { survey, lane in
            .init(lane: survey.lane, coverage: survey.coverage,
                  intentionalSilence: survey.intentionalSilence,
                  finalMergedFades: lane.finalMergedGridFades)
        }
        let fades: [SyntheticLaneFade] = supplied ?? (withFades ? identities.prefix(2).flatMap { identity in
            [SyntheticLaneFade(identity: identity, frames: .init(start: 2, end: 4),
                               direction: .fadeOut),
             SyntheticLaneFade(identity: identity, frames: .init(start: 6, end: 8),
                               direction: .fadeIn)]
        } : [])
        let plan = try SyntheticCommonEditPCMPlan(
            base: suppliedBase ?? base, mapping: mapping, mode: mode, manifest: manifest,
            surveys: finalSurveys, fades: fades
        )
        let input = SyntheticAlignedPCM(lanes: [
            (identities[0], [0, 0] + (1...20).map(Float.init)),
            (identities[1], (100...121).map(Float.init)),
            (identities[2], [Float](repeating: 0, count: 22)),
        ])
        return (plan, input)
    }
}
