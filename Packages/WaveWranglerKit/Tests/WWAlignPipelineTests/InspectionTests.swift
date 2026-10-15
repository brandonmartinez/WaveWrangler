import Testing
@testable import WWAlignPipeline
import WWCore
import WWDerived
import WWTimeMap

@Suite("Metadata-only Alignment inspection")
struct InspectionTests {
    @Test func manualPlacementNeedsNoAcousticAnalysisAndMovesEveryGroupEpoch() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 12, signal: .sine(hz: 440))]),
            .init(name: "Device", sources: [
                .init(name: "first", seconds: 12, signal: .sine(hz: 440)),
                .init(name: "second", seconds: 12, signal: .sine(hz: 880)),
            ]),
        ])
        let laterEpoch = try fixture.moveToNewEpoch("second")
        let report = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        #expect(report.records.isEmpty)
        #expect(report.analyses.isEmpty)
        #expect(fixture.content.total.reads == 0)
        let initial = try await fixture.acceptAndActivate(report, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0),
        ])
        let original = try await fixture.pipeline.reviseAcceptedMap(
            model: initial.model, episode: fixture.episodeID,
            decisions: [laterEpoch: .numeric(ppm: 0, offsetMilliseconds: 15_000)]
        )
        try await fixture.pipeline.activate(original)
        let moved = try await fixture.pipeline.shiftAcceptedGroup(
            model: original.model, episode: fixture.episodeID,
            group: fixture.groups[1], microseconds: 1_250_000
        )
        #expect(moved.revision.revision == original.revision.revision + 1)
        let before = try #require(original.map.groups.first { $0.group == fixture.groups[1] })
        let after = try #require(moved.map.groups.first { $0.group == fixture.groups[1] })
        #expect(after.placements == before.placements)
        for (old, new) in zip(before.epochs, after.epochs) {
            guard case let .mapped(oldSegments, _) = old.mapping,
                  case let .mapped(newSegments, _) = new.mapping else {
                Issue.record("both epochs should stay mapped")
                continue
            }
            #expect(oldSegments.count == newSegments.count)
            for (a, b) in zip(oldSegments, newSegments) {
                #expect(a.groupClockStart == b.groupClockStart)
                #expect(a.groupClockEnd == b.groupClockEnd)
                #expect(a.rateRatio == b.rateRatio)
                #expect(abs(b.alignedOffset.approximateDouble - a.alignedOffset.approximateDouble - 1.25) < 0.000_001)
            }
        }
        #expect(moved.map.groups.first { $0.group == fixture.groups[0] }
                == original.map.groups.first { $0.group == fixture.groups[0] })
        try await fixture.pipeline.activate(moved)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == moved.revision.revision)
        let movedAgain = try await fixture.pipeline.shiftAcceptedGroup(
            model: moved.model, episode: fixture.episodeID,
            group: fixture.groups[1], microseconds: -500_000
        )
        let shiftedAgain = try #require(movedAgain.map.groups.first { $0.group == fixture.groups[1] })
        for (old, new) in zip(before.epochs, shiftedAgain.epochs) {
            guard case let .mapped(oldSegments, _) = old.mapping,
                  case let .mapped(newSegments, _) = new.mapping else { continue }
            for (a, b) in zip(oldSegments, newSegments) {
                #expect(abs(b.alignedOffset.approximateDouble - a.alignedOffset.approximateDouble - 0.75) < 0.000_001)
            }
        }
        #expect(movedAgain.revision.revision == moved.revision.revision + 1)
        #expect(movedAgain.map.groups.first { $0.group == fixture.groups[0] }
                == original.map.groups.first { $0.group == fixture.groups[0] })
        try await fixture.pipeline.activate(movedAgain)
        let fineMove = try await fixture.pipeline.shiftAcceptedGroup(
            model: movedAgain.model, episode: fixture.episodeID,
            group: fixture.groups[1], microseconds: 25_750
        )
        let fineGroup = try #require(fineMove.map.groups.first { $0.group == fixture.groups[1] })
        for (old, new) in zip(before.epochs, fineGroup.epochs) {
            guard case let .mapped(oldSegments, _) = old.mapping,
                  case let .mapped(newSegments, _) = new.mapping else { continue }
            for (a, b) in zip(oldSegments, newSegments) {
                #expect(abs(b.alignedOffset.approximateDouble - a.alignedOffset.approximateDouble - 0.77575) < 0.000_001)
            }
        }
        try await fixture.pipeline.activate(model: original.model, episode: fixture.episodeID)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == original.revision.revision)
    }

    @Test func groupMoveRetainsUnsupportedEpochAndRejectsUnplacedGroup() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 12, signal: .sine(hz: 440))]),
            .init(name: "Device", sources: [
                .init(name: "first", seconds: 12, signal: .sine(hz: 440)),
                .init(name: "second", seconds: 12, signal: .sine(hz: 880)),
            ]),
        ])
        let laterEpoch = try fixture.moveToNewEpoch("second")
        let report = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        let unplaced = try await fixture.acceptAndActivate(report, [:])
        await #expect(throws: AlignmentAcceptanceError.self) {
            _ = try await fixture.pipeline.shiftAcceptedGroup(
                model: unplaced.model, episode: fixture.episodeID,
                group: fixture.groups[1], microseconds: 10_000
            )
        }
        let initial = try await fixture.pipeline.reviseAcceptedMap(
            model: unplaced.model, episode: fixture.episodeID,
            decisions: [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0)]
        )
        try await fixture.pipeline.activate(initial)
        let moved = try await fixture.pipeline.shiftAcceptedGroup(
            model: initial.model, episode: fixture.episodeID,
            group: fixture.groups[1], microseconds: 10_000
        )
        let group = try #require(moved.map.groups.first { $0.group == fixture.groups[1] })
        #expect(group.epochs.first(where: { $0.epoch == laterEpoch })?.mapping
                == initial.map.groups.first(where: { $0.group == fixture.groups[1] })?
                    .epochs.first(where: { $0.epoch == laterEpoch })?.mapping)
    }

    @Test func unplacedGroupCanReceiveNegativeManualTimingWithoutEstimation() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 12, signal: .sine(hz: 440))]),
            .init(name: "Device", sources: [.init(name: "early", seconds: 12, signal: .sine(hz: 880))]),
        ])
        let report = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        #expect(report.records.isEmpty)
        #expect(fixture.content.total.reads == 0)
        let unplaced = try await fixture.acceptAndActivate(report, [:])
        let manual = try await fixture.pipeline.reviseAcceptedMap(
            model: unplaced.model, episode: fixture.episodeID,
            decisions: [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: -9_132_000)]
        )
        #expect(manual.map.groups.first { $0.group == fixture.groups[0] }
                == unplaced.map.groups.first { $0.group == fixture.groups[0] })
        let target = try #require(manual.map.groups.first { $0.group == fixture.groups[1] })
        guard case let .mapped(segments, _) = target.epochs[0].mapping else {
            Issue.record("manual negative timing must create a placement")
            return
        }
        #expect(segments[0].alignedOffset.approximateDouble == -9_132)
        try await fixture.pipeline.activate(manual)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == manual.revision.revision)
        #expect(fixture.content.total.reads == 0)
    }

    @Test func manualPlacementRebuildsAPreviouslyMissingRecorderWithoutLosingOtherOffsets() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 12, signal: .sine(hz: 440))]),
            .init(name: "Placed", sources: [.init(name: "placed", seconds: 12, signal: .sine(hz: 880))]),
            .init(name: "Later admitted", sources: [
                .init(name: "late", seconds: 12, signal: .sine(hz: 220), authorized: false)
            ]),
        ])
        let initialReport = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        let initial = try await fixture.acceptAndActivate(initialReport, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 7_500),
        ])
        #expect(initial.map.groups.allSatisfy { $0.group != fixture.groups[2] })
        await #expect(throws: AlignmentAcceptanceError.unknownEpoch(fixture.epochs[2])) {
            _ = try await fixture.pipeline.reviseAcceptedMap(
                model: initial.model, episode: fixture.episodeID,
                decisions: [fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: -2_000)]
            )
        }
        let admitted = fixture.authorizations
            + [ContentWorkAuthorization.explicitUserRequest(for: fixture.id("late"))]
        let report = try await fixture.pipeline.prepareManual(
            model: initial.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: admitted
        )
        #expect(report.records.isEmpty && report.analyses.isEmpty)
        let rebuilt = try await fixture.pipeline.accept(
            model: initial.model, episode: fixture.episodeID, report: report,
            decisions: [fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: -2_000)]
        )
        #expect(rebuilt.map.groups.first(where: { $0.group == fixture.groups[1] })
                == initial.map.groups.first(where: { $0.group == fixture.groups[1] }))
        let placed = try #require(rebuilt.map.groups.first { $0.group == fixture.groups[2] })
        #expect(placed.placements.contains { $0.occurrence.source == fixture.id("late") })
        guard case let .mapped(segments, _) = placed.epochs[0].mapping else {
            Issue.record("a previously omitted recording must become timed")
            return
        }
        #expect(segments[0].alignedOffset.approximateDouble == -2)
        try await fixture.pipeline.activate(rebuilt)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == rebuilt.revision.revision)
    }

    @Test func openingInspectionReadsNoSourceContentOrMetadata() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 22), registered: false)]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 22, rate: 1.00001, offset: 0.02), registered: false)]),
        ])
        let snapshot = try #require(await fixture.pipeline.inspect(
            model: fixture.model,
            episode: fixture.episodeID,
            sources: fixture.sources
        ))
        #expect(snapshot.states.count == 2)
        #expect(snapshot.plan.reference?.source == fixture.id("reference"))
        #expect(fixture.content.total.opens == 0)
        #expect(fixture.content.total.reads == 0)
        #expect(fixture.metadataIO.totalMetadataCalls == 0)
    }

    @Test func activationReconcilesAcceptedRevisionAndUndoClear() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 23))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 23, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let target = fixture.epochs[1]
        let accepted = try await fixture.pipeline.accept(
            model: fixture.model,
            episode: fixture.episodeID,
            report: report,
            decisions: [target: EpochMapDecision.numeric(ppm: 1, offsetMilliseconds: 2)]
        )
        try await fixture.pipeline.activate(accepted)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == accepted.revision.revision)
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == nil)
        try await fixture.pipeline.activate(accepted)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == accepted.revision.revision)
    }

    @Test func repeatedInspectionDoesNotSupersedePendingPersistenceVerification() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 231))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 231, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let target = fixture.epochs[1]
        let accepted = try await fixture.pipeline.accept(
            model: fixture.model,
            episode: fixture.episodeID,
            report: report,
            decisions: [target: .numeric(ppm: 3, offsetMilliseconds: 4)]
        )

        for _ in 0..<2 {
            _ = await fixture.pipeline.inspect(
                model: accepted.model,
                episode: fixture.episodeID,
                sources: fixture.sources
            )
        }

        try await fixture.pipeline.activate(accepted)
        #expect(
            await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID]
                == accepted.revision.revision
        )
    }

    @Test func manualRevisionWorksFromPersistedAcceptedMapWithoutAnalysisReport() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 24))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 24, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let target = fixture.epochs[1]
        let first = try await fixture.acceptAndActivate(
            report, [target: .numeric(ppm: 1, offsetMilliseconds: 2)]
        )
        let revised = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model, episode: fixture.episodeID,
            decisions: [target: .numeric(ppm: 12.04, offsetMilliseconds: 84.2)]
        )
        #expect(revised.revision.revision == first.revision.revision + 1)
        let mapping = try #require(
            revised.map.groups.flatMap(\.epochs).first(where: { $0.epoch == target })
        ).mapping
        guard case let .mapped(segments, .manual(correction)) = mapping else {
            Issue.record("expected a manual map")
            return
        }
        #expect(correction.basis == .numericEntry)
        #expect(abs((segments[0].rateRatio.approximateDouble - 1) * 1_000_000 - 12.04) < 0.001)
        #expect(abs(segments[0].alignedOffset.approximateDouble * 1_000 - 84.2) < 0.001)
    }

    @Test func epochSplitIsARevisionedOccurrencePlacement() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 25))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 25, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let oldEpoch = fixture.epochs[1]
        let accepted = try await fixture.acceptAndActivate(
            report, [oldEpoch: .numeric(ppm: 1, offsetMilliseconds: 2)]
        )
        let targetGroup = try #require(
            accepted.map.groups.first(where: { $0.group == fixture.groups[1] })
        )
        let placement = try #require(
            targetGroup.placements.first(where: { $0.occurrence.source == fixture.id("target") })
        )
        let splitFrame = placement.occurrence.frameCount / 2
        let newEpoch = RecordingEpochID()
        var model = accepted.model
        let episodeIndex = try #require(model.episodes.firstIndex(where: { $0.id == fixture.episodeID }))
        let groupIndex = try #require(
            model.episodes[episodeIndex].recorderGroups.firstIndex(where: { $0.id == fixture.groups[1] })
        )
        model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(
            RecordingEpoch(id: newEpoch, label: "Take 2")
        )

        let split = try await fixture.pipeline.splitAcceptedOccurrence(
            model: model, episode: fixture.episodeID, group: fixture.groups[1],
            source: fixture.id("target"), epoch: oldEpoch, frame: splitFrame,
            newEpoch: newEpoch
        )
        #expect(split.revision.revision == accepted.revision.revision + 1)
        let revisedGroup = try #require(
            split.map.groups.first(where: { $0.group == fixture.groups[1] })
        )
        let revisedPlacement = try #require(
            revisedGroup.placements.first(where: { $0.occurrence.source == fixture.id("target") })
        )
        #expect(revisedPlacement.spans.count == 2)
        #expect(revisedPlacement.spans[0].endFrame == splitFrame)
        #expect(revisedPlacement.spans[1].startFrame == splitFrame)
        #expect(revisedPlacement.spans[1].epoch == newEpoch)
        guard case .unsupported(.notAttempted) = try #require(
            revisedGroup.epochs.first(where: { $0.epoch == newEpoch })
        ).mapping else {
            Issue.record("new epoch must remain unsupported until timed")
            return
        }
        try await fixture.pipeline.activate(split)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == split.revision.revision)
    }

    @Test func anchoredEpochCanSplitBeforeAnExistingRestart() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 25))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 25, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let oldEpoch = fixture.epochs[1]
        let accepted = try await fixture.acceptAndActivate(
            report, [oldEpoch: .anchors([
                AlignmentAnchor(sourceSeconds: 0, alignedSeconds: 0.0842),
                AlignmentAnchor(sourceSeconds: 0.5, alignedSeconds: 0.5),
            ])]
        )
        var model = accepted.model
        let episodeIndex = try #require(model.episodes.firstIndex(where: { $0.id == fixture.episodeID }))
        let groupIndex = try #require(
            model.episodes[episodeIndex].recorderGroups.firstIndex(where: { $0.id == fixture.groups[1] })
        )
        let restart = RecordingEpoch(label: "Restart")
        model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(restart)
        let first = try await fixture.pipeline.splitAcceptedOccurrence(
            model: model, episode: fixture.episodeID, group: fixture.groups[1],
            source: fixture.id("target"), epoch: oldEpoch, frame: 48_000 * 2,
            newEpoch: restart.id
        )
        model = first.model
        let newEpoch = RecordingEpoch(label: "Epoch 3")
        model.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(newEpoch)
        await #expect(throws: AlignmentAcceptanceError.staleSnapshot) {
            try await fixture.pipeline.splitAcceptedOccurrence(
                model: model, episode: fixture.episodeID, group: fixture.groups[1],
                source: fixture.id("target"), epoch: oldEpoch, frame: 48_000 / 2,
                newEpoch: newEpoch.id
            )
        }
        try await fixture.pipeline.activate(first)
        let split = try await fixture.pipeline.splitAcceptedOccurrence(
            model: model, episode: fixture.episodeID, group: fixture.groups[1],
            source: fixture.id("target"), epoch: oldEpoch, frame: 48_000 / 2,
            newEpoch: newEpoch.id
        )
        #expect(split.revision.revision == first.revision.revision + 1)
        let group = try #require(split.map.groups.first(where: { $0.group == fixture.groups[1] }))
        let placement = try #require(group.placements.first(where: { $0.occurrence.source == fixture.id("target") }))
        #expect(placement.spans.map(\.epoch) == [oldEpoch, newEpoch.id, restart.id])
    }

    @Test func anchorRevisionPersistsExactAnchorPairs() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 26))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 26, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let target = fixture.epochs[1]
        let first = try await fixture.acceptAndActivate(
            report, [target: .numeric(ppm: 1, offsetMilliseconds: 2)]
        )
        let anchors = [
            AlignmentAnchor(sourceSeconds: 2.25, alignedSeconds: 2.5),
            AlignmentAnchor(sourceSeconds: 17.75, alignedSeconds: 18.125),
        ]
        let revised = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model, episode: fixture.episodeID,
            decisions: [target: .anchors(anchors)]
        )
        let mapping = try #require(
            revised.map.groups.flatMap(\.epochs).first(where: { $0.epoch == target })
        ).mapping
        guard case let .mapped(_, .manual(correction)) = mapping else {
            Issue.record("expected a manual anchor map")
            return
        }
        #expect(AlignmentAnchorNote.decode(correction.note) == anchors)
    }

    @Test func sourceSpecificAnchorRevisionKeepsTheSelectedSourceInAMultiTrackRecorder() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 26))]),
            .init(name: "Target", sources: [
                .init(name: "other", seconds: 30, signal: .scene(seed: 27)),
                .init(name: "target", seconds: 30, signal: .scene(seed: 26, offset: 0.02)),
            ]),
        ])
        let report = try await fixture.analyse()
        let epoch = fixture.epochs[1]
        let first = try await fixture.acceptAndActivate(
            report, [epoch: .numeric(ppm: 0, offsetMilliseconds: 20)]
        )
        let anchors = [
            AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 2.02),
            AlignmentAnchor(sourceSeconds: 20, alignedSeconds: 20.02),
        ]
        let selected = fixture.id("target")
        let revised = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model, episode: fixture.episodeID,
            decisions: [epoch: .anchorsForSource(selected, anchors)]
        )
        let mapping = try #require(revised.map.groups.flatMap(\.epochs)
            .first(where: { $0.epoch == epoch })?.mapping)
        guard case let .mapped(_, .manual(correction)) = mapping else {
            Issue.record("expected a source-specific manual map")
            return
        }
        #expect(AlignmentAnchorNote.source(in: correction.note) == selected)
        #expect(AlignmentAnchorNote.decode(correction.note) == anchors)
        #expect(AlignmentAnchorNote.source(in: AlignmentAnchorNote.encode(anchors)) == nil)
        try await fixture.pipeline.activate(revised)
        let moved = try await fixture.pipeline.shiftAcceptedGroup(
            model: revised.model, episode: fixture.episodeID,
            group: fixture.groups[1], microseconds: 250_000
        )
        let shifted = try #require(moved.map.groups.flatMap(\.epochs)
            .first(where: { $0.epoch == epoch })?.mapping)
        guard case let .mapped(_, .manual(shiftedCorrection)) = shifted else {
            Issue.record("expected a shifted anchor map")
            return
        }
        #expect(AlignmentAnchorNote.source(in: shiftedCorrection.note) == selected)
        let shiftedAnchors = try #require(AlignmentAnchorNote.decode(shiftedCorrection.note))
        #expect(shiftedAnchors.count == anchors.count)
        #expect(zip(shiftedAnchors, anchors).allSatisfy {
            abs($0.alignedSeconds - $1.alignedSeconds - 0.25) < 0.000_000_1
                && $0.sourceSeconds == $1.sourceSeconds
        })
    }

    @Test func sourceSpecificAnchorFitUsesTheSelectedOccurrenceOffset() throws {
        let epoch = RecordingEpochID()
        let other = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 10_000)
        let selected = try SourceOccurrence(source: SourceID(), nominalRate: NominalRate(1_000), frameCount: 10_000)
        let placements = [
            OccurrencePlacement(occurrence: other, spans: [
                EpochSpan(startFrame: 0, endFrame: 10_000, epoch: epoch, groupClockOffset: ExactRational(10))
            ]),
            OccurrencePlacement(occurrence: selected, spans: [
                EpochSpan(startFrame: 0, endFrame: 10_000, epoch: epoch, groupClockOffset: ExactRational(20))
            ]),
        ]
        let anchors = [
            AlignmentAnchor(sourceSeconds: 2, alignedSeconds: 23),
            AlignmentAnchor(sourceSeconds: 8, alignedSeconds: 29),
        ]
        let groupAnchors = try AlignmentPipeline.groupClockAnchors(
            anchors, source: selected.source, epoch: epoch, placements: placements
        )
        #expect(groupAnchors.map(\.sourceSeconds) == [22, 28])
        #expect(groupAnchors.map(\.alignedSeconds) == [23, 29])
        #expect(throws: AlignmentAcceptanceError.self) {
            try AlignmentPipeline.groupClockAnchors(
                anchors, source: SourceID(), epoch: epoch, placements: placements
            )
        }
    }

    @Test func manualRevisionAndSplitRefuseChangedSourceRevisions() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 27))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 27, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let target = fixture.epochs[1]
        let accepted = try await fixture.acceptAndActivate(
            report, [target: .numeric(ppm: 1, offsetMilliseconds: 2)]
        )
        await fixture.coordinator.updateSource(
            SourceRevision(source: fixture.id("target"), token: "metadata:changed-after-acceptance")
        )

        await #expect(
            throws: AlignmentAcceptanceError.analysisStale([.dependenciesChanged])
        ) {
            _ = try await fixture.pipeline.reviseAcceptedMap(
                model: accepted.model,
                episode: fixture.episodeID,
                decisions: [target: .numeric(ppm: 3, offsetMilliseconds: 4)]
            )
        }

        var splitModel = accepted.model
        let episodeIndex = try #require(
            splitModel.episodes.firstIndex(where: { $0.id == fixture.episodeID })
        )
        let groupIndex = try #require(
            splitModel.episodes[episodeIndex].recorderGroups.firstIndex(where: {
                $0.id == fixture.groups[1]
            })
        )
        let newEpoch = RecordingEpochID()
        splitModel.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(
            RecordingEpoch(id: newEpoch, label: "Take 2")
        )
        let placement = try #require(
            accepted.map.groups
                .first(where: { $0.group == fixture.groups[1] })?
                .placements.first(where: { $0.occurrence.source == fixture.id("target") })
        )
        await #expect(
            throws: AlignmentAcceptanceError.analysisStale([.dependenciesChanged])
        ) {
            _ = try await fixture.pipeline.splitAcceptedOccurrence(
                model: splitModel,
                episode: fixture.episodeID,
                group: fixture.groups[1],
                source: fixture.id("target"),
                epoch: target,
                frame: placement.occurrence.frameCount / 2,
                newEpoch: newEpoch
            )
        }
    }

    @Test func anchorRevisionAfterSplitFitsSourcePairsInGroupTime() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 30, signal: .scene(seed: 28))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 30, signal: .scene(seed: 28, rate: 1.00001, offset: 0.02))]),
        ])
        let report = try await fixture.analyse()
        let oldEpoch = fixture.epochs[1]
        let accepted = try await fixture.acceptAndActivate(
            report, [oldEpoch: .numeric(ppm: 1, offsetMilliseconds: 2)]
        )
        let placement = try #require(
            accepted.map.groups
                .first(where: { $0.group == fixture.groups[1] })?
                .placements.first(where: { $0.occurrence.source == fixture.id("target") })
        )
        let splitFrame = placement.occurrence.frameCount / 2
        let splitSeconds = Double(splitFrame)
            / Double(placement.occurrence.nominalRate.framesPerSecond)
        let newEpoch = RecordingEpochID()
        var splitModel = accepted.model
        let episodeIndex = try #require(
            splitModel.episodes.firstIndex(where: { $0.id == fixture.episodeID })
        )
        let groupIndex = try #require(
            splitModel.episodes[episodeIndex].recorderGroups.firstIndex(where: {
                $0.id == fixture.groups[1]
            })
        )
        splitModel.episodes[episodeIndex].recorderGroups[groupIndex].epochs.append(
            RecordingEpoch(id: newEpoch, label: "Take 2")
        )
        let split = try await fixture.pipeline.splitAcceptedOccurrence(
            model: splitModel,
            episode: fixture.episodeID,
            group: fixture.groups[1],
            source: fixture.id("target"),
            epoch: oldEpoch,
            frame: splitFrame,
            newEpoch: newEpoch
        )
        try await fixture.pipeline.activate(split)

        let anchors = [
            AlignmentAnchor(
                sourceSeconds: splitSeconds + 1,
                alignedSeconds: 101
            ),
            AlignmentAnchor(
                sourceSeconds: splitSeconds + 10,
                alignedSeconds: 110
            ),
        ]
        let revised = try await fixture.pipeline.reviseAcceptedMap(
            model: split.model,
            episode: fixture.episodeID,
            decisions: [newEpoch: .anchors(anchors)]
        )
        let mapping = try #require(
            revised.map.groups.flatMap(\.epochs).first(where: { $0.epoch == newEpoch })
        ).mapping
        guard case let .mapped(segments, .manual(correction)) = mapping else {
            Issue.record("expected a manual anchor map")
            return
        }
        #expect(abs(segments[0].rateRatio.approximateDouble - 1) < 0.000_000_001)
        #expect(abs(segments[0].alignedOffset.approximateDouble - 100) < 0.000_000_001)
        #expect(AlignmentAnchorNote.decode(correction.note) == anchors)
    }
}
