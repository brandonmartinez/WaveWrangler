import Testing
import WWCore
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Organizer cut-lane inventory (synthetic, non-authorizing)")
struct OrganizerCutLaneInventoryTests {
    @Test func includesEverySourceChannelInEpisodeOrderButNeverSuppliesMappingProof() async throws {
        let fixture = try await InventoryFixture()
        let inventory = try await fixture.inspect()
        #expect(inventory.acceptedAlignmentRevision == 1)
        #expect(inventory.lanes.map(\.kind) == [
            .selectedPrimary, .unassigned, .backup, .backup,
        ])
        #expect(inventory.lanes.map(\.key.channel) == [0, 1, 0, 1])
        #expect(inventory.lanes.map(\.key.source) == [
            fixture.id("primary"), fixture.id("primary"),
            fixture.id("backup"), fixture.id("backup"),
        ])
        #expect(Set(inventory.lanes.map(\.key)).count == inventory.lanes.count)
        #expect(inventory.lanes.map(\.key.occurrence) == [
            alignmentOccurrenceID(for: fixture.id("primary")),
            alignmentOccurrenceID(for: fixture.id("primary")),
            alignmentOccurrenceID(for: fixture.id("backup")),
            alignmentOccurrenceID(for: fixture.id("backup")),
        ])
        #expect(inventory.lanes.map(\.epoch) == [
            fixture.fixture.epochs[0], fixture.fixture.epochs[0],
            fixture.fixture.epochs[1], fixture.fixture.epochs[1],
        ])
        let registered = await fixture.fixture.coordinator.inputs.sources
        #expect(inventory.lanes.allSatisfy {
            $0.registeredSourceRevision == registered[$0.key.source]
        })
        #expect(fixture.fixture.content.total.opens == 0)
        #expect(throws: OrganizerCutLaneRefusal.backupWithoutIndependentProof) {
            try inventory.mappingInputs()
        }
    }

    @Test func missingAndDuplicateOrganizerLanesRefuseWithoutMapping() async throws {
        let fixture = try await InventoryFixture()
        var missing = fixture.model
        missing.episodes[0].sources.removeLast()
        await #expect(throws: OrganizerCutLaneRefusal.invalidOrganizerState) {
            try await fixture.inspect(model: missing)
        }
        var unknownCount = fixture.model
        unknownCount.episodes[0].sources[0].observations.channelCount = .unknown
        await #expect(throws: OrganizerCutLaneRefusal.unverifiedChannels) {
            try await fixture.inspect(model: unknownCount)
        }
        var duplicate = fixture.model
        duplicate.episodes[0].sources.append(duplicate.episodes[0].sources[0])
        await #expect(throws: OrganizerCutLaneRefusal.invalidOrganizerState) {
            try await fixture.inspect(model: duplicate)
        }
        var duplicateAssignment = fixture.model
        duplicateAssignment.episodes[0].speakerAssignments.append(
            duplicateAssignment.episodes[0].speakerAssignments[0]
        )
        await #expect(throws: OrganizerCutLaneRefusal.invalidOrganizerState) {
            try await fixture.inspect(model: duplicateAssignment)
        }
        var noPrimary = fixture.model
        noPrimary.episodes[0].sources[0].role = .backup
        await #expect(throws: OrganizerCutLaneRefusal.ambiguousSelectedPrimary) {
            try await fixture.inspect(model: noPrimary)
        }
        var unknownBackup = fixture.model
        unknownBackup.episodes[0].speakerAssignments[0].backups[0].channel = .unknown
        await #expect(throws: OrganizerCutLaneRefusal.unverifiedChannels) {
            try await fixture.inspect(model: unknownBackup)
        }
    }

    @Test func changedSourceAndAcceptedMapRefuseStaleInventory() async throws {
        let fixture = try await InventoryFixture()
        await fixture.fixture.coordinator.updateSource(.init(
            source: fixture.id("backup"), token: "metadata:changed"
        ))
        await #expect(throws: OrganizerCutLaneRefusal.staleMap) {
            try await fixture.inspect()
        }
        let fresh = try await InventoryFixture()
        await fresh.fixture.coordinator.clearAcceptedMap(episode: fresh.fixture.episodeID)
        await #expect(throws: OrganizerCutLaneRefusal.staleMap) {
            try await fresh.inspect()
        }
    }

    @Test func registeredRevisionAloneCannotProveAnUnchangedSource() async throws {
        let fixture = try await InventoryFixture()
        try fixture.fixture.rewrite("backup")
        let inventory = try await fixture.inspect()
        #expect(fixture.fixture.content.total.opens == 0)
        #expect(throws: OrganizerCutLaneRefusal.backupWithoutIndependentProof) {
            try inventory.mappingInputs()
        }
    }

    @Test func unmappedOrUnknownBackingAndPrimaryOnlyProofRefuse() async throws {
        let fixture = try await InventoryFixture()
        var extra = fixture.model
        extra.episodes[0].sources.append(SourceRecord(displayNameHint: "unmapped"))
        await #expect(throws: OrganizerCutLaneRefusal.incompleteEpisode) {
            try await fixture.inspect(model: extra)
        }
        var misplaced = fixture.model
        misplaced.episodes[0].sources[1].placement.epochID = RecordingEpochID()
        await #expect(throws: OrganizerCutLaneRefusal.invalidOrganizerState) {
            try await fixture.inspect(model: misplaced)
        }
        var noBackup = fixture.model
        noBackup.episodes[0].sources.removeLast()
        noBackup.episodes[0].speakerAssignments[0].backups = []
        // A changed organizer snapshot is not the active map, even if its selected Primary remains.
        await #expect(throws: OrganizerCutLaneRefusal.staleMap) {
            try await fixture.inspect(model: noBackup)
        }
        let unsupported = try await InventoryFixture(unsupportedBackup: true)
        await #expect(throws: OrganizerCutLaneRefusal.unmappedLane) {
            try await unsupported.inspect()
        }
        var unassigned = fixture.model
        unassigned.episodes[0].speakerAssignments[0].backups = []
        unassigned.episodes[0].sources[1].role = .unassigned
        let inventory = try await fixture.inspect(model: unassigned)
        #expect(throws: OrganizerCutLaneRefusal.independentProtectionUnavailable) {
            try inventory.mappingInputs()
        }
    }
}

private struct InventoryFixture {
    let fixture: PipelineFixture
    let model: ShowDocumentModel
    let speaker: SpeakerID

    init(unsupportedBackup: Bool = false) async throws {
        fixture = try await PipelineFixture([
            .init(name: "Primary recorder", sources: [
                .init(name: "primary", seconds: 0.01, signal: .scene(seed: 8)),
            ]),
            .init(name: "Backup recorder", sources: [
                .init(name: "backup", seconds: 0.01, signal: .scene(seed: 9)),
            ]),
        ])
        speaker = SpeakerID()
        let first = fixture.id("primary"), second = fixture.id("backup")
        let sourceGroups = fixture.groups, sourceEpochs = fixture.epochs
        let group = sourceGroups[0], epoch = sourceEpochs[0]
        let rate = try NominalRate(48_000)
        let reference = TimelineReference(
            group: group, epoch: epoch, occurrence: alignmentOccurrenceID(for: first)
        )
        let segment = try AffineClockSegment(
            groupClockStart: .zero, groupClockEnd: try ExactRational(480, 48_000),
            rateRatio: .one, alignedOffset: .zero
        )
        let groups = try [first, second].enumerated().map { index, id in
            let groupID = sourceGroups[index], epochID = sourceEpochs[index]
            let mapping: EpochClockMap.Mapping = index == 1 && unsupportedBackup ?
                .unsupported(.estimatorAbstained) :
                .mapped(
                    segments: [segment],
                    provenance: index == 0 ? .timelineReference :
                        .manual(ManualCorrection(basis: .numericEntry))
                )
            return try GroupTimeMap(
                group: groupID, reference: reference,
                epochs: [.init(epoch: epochID, mapping: mapping)],
                placements: [.init(
                    occurrence: try SourceOccurrence(
                        id: alignmentOccurrenceID(for: id), source: id,
                        nominalRate: rate, frameCount: 480
                    ),
                    spans: [.init(
                        startFrame: 0, endFrame: 480, epoch: epochID,
                        groupClockOffset: .zero
                    )]
                )]
            )
        }
        let map = try AlignedTimelineMap(reference: reference, groups: groups)
        var base = fixture.model
        base.speakers = [Speaker(id: speaker, name: "Selected")]
        for index in base.episodes[0].sources.indices {
            base.episodes[0].sources[index].observations.channelCount = .known(2)
        }
        base.episodes[0].sources[0].role = .primary
        base.episodes[0].sources[0].roleConfirmation = .userConfirmed
        base.episodes[0].sources[1].role = .backup
        base.episodes[0].sources[1].roleConfirmation = .userConfirmed
        base.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker,
                primary: ChannelReference(sourceID: first, statedChannel: 0),
                primaryConfirmation: .userConfirmed,
                backups: [
                    ChannelReference(sourceID: second, statedChannel: 0),
                    ChannelReference(sourceID: second, statedChannel: 1),
                ]
            )
        ]
        let registered = await fixture.coordinator.inputs.sources
        let digest = try #require(MapDependencies.digest(
            map: map, tokens: registered, format: .current
        ))
        let recorded = try base.recordingMap(
            map, in: fixture.episodeID,
            inputs: [first, second].map {
                TimeMapSourceInput(sourceID: $0, formatInterpretationVersion: FormatRevision.current.interpretationVersion)
            },
            recipe: MapDependencies.recipe(digest: digest)
        )
        model = try recorded.model.acceptingMap(
            revision: recorded.revision.revision, in: fixture.episodeID
        )
        try await fixture.pipeline.activate(model: model, episode: fixture.episodeID)
    }

    func id(_ name: String) -> SourceID { fixture.id(name) }

    func inspect(model: ShowDocumentModel? = nil) async throws -> ProvisionalOrganizerCutLanes {
        try await fixture.pipeline.inspectCutLanes(
            model: model ?? self.model, episode: fixture.episodeID, selectedSpeaker: speaker
        )
    }
}
