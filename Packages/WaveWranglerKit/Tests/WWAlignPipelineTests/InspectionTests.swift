import Testing
import WWAlignPipeline
import WWCore
import WWDerived
import WWTimeMap

@Suite("Metadata-only Alignment inspection")
struct InspectionTests {
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
