import Foundation
import Testing
import WWCore
import WWDerived
import WWPersistence
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Global tracks alignment review", .serialized)
struct TracksWorkflowTests {
    @Test func changingCallDelayAutomaticallyOffersReviewedPlayableFileTiming() async throws {
        let (fixture, speaker) = try await AdaptiveAnalysisTests.fixture(nativeAudio: true, referenceChannels: 1)
        fixture.model.speakers = [Speaker(id: speaker, name: "Shared")]
        fixture.model.episodes[0].speakerAssignments[0].primary?.channel = .unknown
        let before = fixture.model
        let report = try await fixture.pipeline.analyzeTracks(
            model: before, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let epoch = fixture.epochs[1]
        #expect(report.records[epoch]?.needsAdaptiveTiming == true)
        #expect(report.records[epoch]?.proposal == nil, "Adaptive timing must not weaken the single-rate gate")
        let adaptive = try #require(report.adaptiveRecords[epoch])
        #expect(adaptive.timing.regions.count >= 2)
        #expect(adaptive.target.source == fixture.id("backup"))
        #expect(fixture.model == before)
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
        let opens = fixture.content.total.opens
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(
                model: before, episode: fixture.episodeID, report: report, decisions: [:],
                replacingAlignment: true, adaptiveSelections: [epoch: false],
                sources: fixture.sources, authorizations: []
            )
        }
        #expect(fixture.content.total.opens == opens, "Acceptance cannot read originals without current authorization")
        let unselected = try await fixture.pipeline.accept(
            model: before, episode: fixture.episodeID, report: report, decisions: [:],
            replacingAlignment: true
        )
        #expect(unselected.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == nil)
        let accepted = try await fixture.pipeline.accept(
            model: before, episode: fixture.episodeID, report: report, decisions: [:],
            replacingAlignment: true, adaptiveSelections: [epoch: false],
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        let correction = try #require(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(correction.source == fixture.id("backup") && correction.channelCount == 2)
        #expect(correction.segments.allSatisfy { $0.kind != .estimated })
        #expect(accepted.model.episodes[0].sources == before.episodes[0].sources)
        #expect(accepted.model.episodes[0].recorderGroups == before.episodes[0].recorderGroups)
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty, "Only verified publication may activate the result")
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let restored = try coder.decode(coder.encode(accepted.model, revision: 1)).payload
        #expect(restored == accepted.model)
        try await fixture.pipeline.activate(accepted)
        let fingerprint = try await fixture.decoder.withDecodingCursor(fixture.url("backup"), source: correction.source) {
            $0.interpretation.sourceFingerprint
        }
        let witness = try await fixture.decoder.captureRawIdentity(fixture.url("backup"), matching: fingerprint)
        let segment = try #require(correction.segments.first { $0.sourceEnd - $0.sourceStart > 2 })
        let audio = try await fixture.pipeline.adaptiveAudioWindow(
            model: restored, episode: fixture.episodeID, source: correction.source,
            sourceURL: fixture.url("backup"), matching: witness,
            startSeconds: segment.alignedStart + 0.5, durationSeconds: 1
        )
        #expect(audio.count == 2 && audio[0].contains { abs($0) > 0.001 })
        #expect(zip(audio[0], audio[1]).allSatisfy { abs($0 * channelGain(1) - $1) < 0.0001 })
        #expect(fixture.content.record(fixture.url("other file")).decodedFrames == 0)
        let rerun = try await fixture.pipeline.analyzeTracks(
            model: restored, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let preserved = try await fixture.pipeline.accept(
            model: restored, episode: fixture.episodeID, report: rerun, decisions: [:],
            replacingAlignment: true
        )
        #expect(preserved.map == accepted.map)
        #expect(preserved.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == [correction])
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(
                model: restored, episode: fixture.episodeID, report: rerun,
                decisions: [epoch: .numeric(ppm: 0, offsetMilliseconds: 100)],
                replacingAlignment: true
            )
        }
        var reassigned = restored
        reassigned.episodes[0].speakerAssignments = []
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(
                model: reassigned, episode: fixture.episodeID, report: rerun, decisions: [:],
                replacingAlignment: true, adaptiveSelections: [epoch: false],
                sources: fixture.sources, authorizations: fixture.authorizations
            )
        }
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func adaptiveReplacementUsesANewReferencesOriginalClockNotItsOldOffset() async throws {
        let (fixture, _) = try await AdaptiveAnalysisTests.fixture()
        let initial = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let prior = try await fixture.acceptAndActivate(initial, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 7_000)
        ])
        let selected = try prior.model.preferringAlignmentReference(
            true, group: fixture.groups[1], in: fixture.episodeID
        )
        let report = try await fixture.pipeline.analyzeTracks(
            model: selected, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let record = try #require(report.adaptiveRecords[fixture.epochs[0]])
        #expect(record.reference.source == fixture.id("backup"))
        #expect(record.referenceToAlignedOffset == 0 && record.referenceToAlignedRate == 1)
        let accepted = try await fixture.pipeline.accept(
            model: selected, episode: fixture.episodeID, report: report, decisions: [:],
            replacingAlignment: true, adaptiveSelections: [fixture.epochs[0]: true],
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        #expect(accepted.map.reference.group == fixture.groups[1])
        #expect(accepted.map.reference.occurrence == report.plan.reference?.occurrence)
        let curve = try #require(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(curve.source == fixture.id("ref") && curve.reference == fixture.id("backup"))
        #expect(curve.retainsAllAudio)
        #expect(curve.segments == (try record.audioPreservation.get()))
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == prior.revision.revision)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func failedSingleRateFitDoesNotEraseAnUnselectedManualPlacement() async throws {
        let (fixture, _) = try await AdaptiveAnalysisTests.fixture()
        let initial = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let prior = try await fixture.acceptAndActivate(initial, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 830)
        ])
        let report = try await fixture.pipeline.analyzeTracks(
            model: prior.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        #expect(report.adaptiveRecords[fixture.epochs[1]] != nil)
        let accepted = try await fixture.pipeline.accept(
            model: prior.model, episode: fixture.episodeID, report: report, decisions: [:],
            replacingAlignment: true
        )
        #expect(accepted.map == prior.map)
        #expect(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == nil)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == prior.revision.revision)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func automaticAdaptiveGapsStillRequireSeparateEstimatedTimingConsent() async throws {
        let (fixture, _) = try await AdaptiveAnalysisTests.quietFixture()
        let report = try await fixture.pipeline.analyzeTracks(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        let epoch = fixture.epochs[1]
        let record = try #require(report.adaptiveRecords[epoch])
        try #require(!record.timing.estimatedIntervals.isEmpty)
        let strict = try await fixture.pipeline.accept(
            model: fixture.model, episode: fixture.episodeID, report: report, decisions: [:],
            replacingAlignment: true, adaptiveSelections: [epoch: false],
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        let estimated = try await fixture.pipeline.accept(
            model: fixture.model, episode: fixture.episodeID, report: report, decisions: [:],
            replacingAlignment: true, adaptiveSelections: [epoch: true],
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        let strictCurve = try #require(strict.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        let estimatedCurve = try #require(estimated.model.episodes[0].alignment?.acceptedMap?.sourceCorrections?.first)
        #expect(strictCurve.segments.allSatisfy { $0.kind != .estimated })
        #expect(estimatedCurve.segments.contains { $0.kind == .estimated })
        #expect(estimatedCurve.segments.filter { $0.kind != .estimated } == strictCurve.segments)
        #expect(strict.map == estimated.map)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func selectedReferenceChangesOnlyAfterReplacementAcceptance() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Original", sources: [.init(name: "original", seconds: 24, signal: .scene(seed: 19))]),
            GroupSpec(name: "Selected", sources: [.init(name: "selected", seconds: 24, signal: .scene(seed: 19, offset: 0.2))]),
            GroupSpec(name: "Third", sources: [.init(name: "third", seconds: 24, signal: .scene(seed: 19, offset: 0.4))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("original"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("selected"), statedChannel: 0),
                          .init(sourceID: fixture.id("third"), statedChannel: 0)]),
        ]
        let initial = try await fixture.pipeline.prepareManual(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        let prior = try await fixture.acceptAndActivate(initial, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 7_000),
            fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: 9_000),
        ])
        let selected = try prior.model.preferringAlignmentReference(true, group: fixture.groups[1], in: fixture.episodeID)
        let report = try await fixture.pipeline.analyzeTracks(model: selected, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(report.plan.reference?.source == fixture.id("selected"))
        #expect(report.referenceRevision == prior.revision.revision)
        #expect(selected.episodes[0].alignment == prior.model.episodes[0].alignment)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == prior.revision.revision)
        let proposal = try #require(report.records[fixture.epochs[0]]?.proposal)
        #expect(abs(proposal.offsetAtCenterSeconds + 0.2) < 0.04,
                "Selected audio hears scene(u + 0.2), so original audio maps to u - 0.2, not the former seven-second offset; measured \(proposal.offsetAtCenterSeconds)")
        #expect(report.references.values.allSatisfy { $0.group == fixture.groups[1] })
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(model: selected, episode: fixture.episodeID,
                report: report, decisions: [fixture.epochs[0]: .acceptProposal()])
        }
        let changedChoice = try selected.preferringAlignmentReference(true, group: fixture.groups[0], in: fixture.episodeID)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(model: changedChoice, episode: fixture.episodeID,
                report: report, decisions: [fixture.epochs[0]: .acceptProposal()], replacingAlignment: true)
        }
        let accepted = try await fixture.pipeline.accept(model: selected, episode: fixture.episodeID,
            report: report, decisions: [fixture.epochs[0]: .acceptProposal(), fixture.epochs[2]: .acceptProposal()],
            replacingAlignment: true)
        #expect(accepted.map.reference.group == fixture.groups[1])
        #expect(accepted.map.reference.epoch == fixture.epochs[1])
        #expect(accepted.model.episodes[0].alignment?.maps.first == prior.model.episodes[0].alignment?.maps.first)
        #expect(accepted.model.episodes[0].alignment?.maps.count == 2)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == prior.revision.revision,
                "Accepting a proposal value must not publish it before a verified save")
        try await fixture.pipeline.activate(accepted)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == accepted.revision.revision)
        let inspection = try #require(await fixture.pipeline.inspect(
            model: accepted.model, episode: fixture.episodeID, sources: fixture.sources))
        #expect(inspection.acceptedMap?.reference.group == fixture.groups[1])
    }

    @Test func anUnavailableSelectedReferenceNeverFallsBackToAnotherRecorder() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Available", sources: [.init(name: "available", seconds: 22, signal: .scene(seed: 2))]),
            GroupSpec(name: "Selected", sources: [.init(name: "selected", seconds: 22, signal: .scene(seed: 2), authorized: false)]),
        ])
        let selected = try fixture.model.preferringAlignmentReference(true, group: fixture.groups[1], in: fixture.episodeID)
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.analyzeTracks(model: selected, episode: fixture.episodeID,
                sources: fixture.sources, authorizations: fixture.authorizations)
        }
        #expect(fixture.content.total.opens == 0 && fixture.content.total.reads == 0)
    }

    @Test func selectingTheCurrentRecorderKeepsItsAcceptedReferenceOccurrence() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                .init(name: "first", seconds: 22, signal: .scene(seed: 2)),
                .init(name: "accepted", seconds: 22, signal: .scene(seed: 2)),
            ]),
        ])
        let initial = try await fixture.pipeline.prepareManual(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        let prior = try await fixture.acceptAndActivate(initial, [:])
        var reordered = prior.model
        reordered.episodes[0].sources.reverse()
        let selected = try reordered.preferringAlignmentReference(true, group: fixture.groups[0], in: fixture.episodeID)
        let report = try await fixture.pipeline.analyzeTracks(model: selected, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(report.plan.reference?.occurrence == prior.map.reference.occurrence,
                "Selecting the current recorder cannot silently change its reference file when source order changes")
    }

    @Test func allSpeakerPairsShareOneReviewAndAcceptanceRemainsExplicit() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [.init(name: "reference", seconds: 24, signal: .scene(seed: 19))]),
            GroupSpec(name: "Second", sources: [.init(name: "second", seconds: 24, signal: .scene(seed: 19, offset: 0.2))]),
            GroupSpec(name: "Third", sources: [.init(name: "third", seconds: 24, signal: .scene(seed: 19, offset: 0.4))]),
            GroupSpec(name: "Unassigned", sources: [.init(name: "unassigned", seconds: 24, signal: .scene(seed: 91))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("reference"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("second"), statedChannel: 0),
                          .init(sourceID: fixture.id("third"), statedChannel: 0)]),
        ]
        let original = fixture.model
        let report = try await fixture.pipeline.analyzeTracks(
            model: original, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        #expect(fixture.model == original && original.episodes[0].alignment == nil)
        #expect(report.records.count == 2 && report.references.count == 2)
        #expect(report.records.values.allSatisfy { $0.proposal != nil })
        #expect(report.adaptiveRecords.isEmpty, "Stable offset/rate recordings must keep the ordinary affine path")
        #expect(report.epochFailures[fixture.epochs[3]] != nil, "Missing assignments are unresolved, never mixed-channel matches")
        var changedAssignments = original
        changedAssignments.episodes[0].speakerAssignments = []
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await fixture.pipeline.accept(model: changedAssignments, episode: fixture.episodeID,
                report: report, decisions: [fixture.epochs[1]: .acceptProposal()], replacingAlignment: true)
        }
        let accepted = try await fixture.pipeline.accept(model: original, episode: fixture.episodeID,
            report: report, decisions: [fixture.epochs[1]: .acceptProposal(), fixture.epochs[2]: .acceptProposal()],
            replacingAlignment: true)
        #expect(await fixture.pipeline.coordinator.inputs.acceptedMaps[fixture.episodeID] == nil,
                "Acceptance alone must not activate timing before verified save")
        #expect(accepted.map.groups.first { $0.group == fixture.groups[3] }?.epochs.first?.mapping == .unsupported(.notAttempted))
        for index in [1, 2] {
            let proposal = try #require(report.records[fixture.epochs[index]]?.proposal)
            let group = try #require(accepted.map.groups.first { $0.group == fixture.groups[index] })
            guard case let .mapped(segments, _) = group.epochs.first?.mapping else {
                Issue.record("Accepted measured proposal missing")
                continue
            }
            #expect(segments == [proposal.segment], "Never extend into unmeasured audio")
        }
        try await fixture.pipeline.activate(accepted)
        fixture.model = accepted.model
        let replacement = try await fixture.pipeline.analyzeTracks(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(fixture.model == accepted.model, "New analysis keeps prior accepted work live")
        let replaced = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID,
            report: replacement, decisions: [fixture.epochs[2]: .acceptProposal()], replacingAlignment: true)
        #expect(replaced.map.reference == accepted.map.reference)
        #expect(replaced.model.episodes[0].alignment?.maps.count == 2)
        #expect(replaced.map.groups.first { $0.group == fixture.groups[1] }
            == accepted.map.groups.first { $0.group == fixture.groups[1] },
                "Unselected proposals must not retire saved timing while the reference is unchanged")
    }

    @Test func unknownMultichannelAssignmentsDoNotUseTheLegacyWholeTrackAnalyzer() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "one", channels: 2, seconds: 22, signal: .scene(seed: 2))]),
            GroupSpec(name: "Two", sources: [.init(name: "two", seconds: 22, signal: .scene(seed: 2))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("one"), statedChannel: nil),
                backups: [.init(sourceID: fixture.id("two"), statedChannel: 0)]),
        ]
        let report = try await fixture.pipeline.analyzeTracks(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(report.records.isEmpty && report.adaptiveRecords.isEmpty && report.epochFailures[fixture.epochs[1]] != nil)
        #expect(fixture.content.total.reads == 0, "Metadata probes are not authorization to decode unassigned channels")
    }

    @Test func verifiedMonoAlignsWithoutInventingAStereoChannelOrChangingSavedAssignments() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "ref", channels: 1, seconds: 24, signal: .scene(seed: 19))]),
            .init(name: "Mono backup", sources: [.init(name: "mono", channels: 1, seconds: 24, signal: .scene(seed: 19, offset: 0.2))]),
            .init(name: "Stereo backup", sources: [.init(name: "stereo", channels: 2, seconds: 24, signal: .scene(seed: 19))]),
        ])
        fixture.model.episodes[0].sources[0].observations.channelCount = .known(2)
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("ref"), statedChannel: nil),
                backups: [.init(sourceID: fixture.id("mono"), statedChannel: nil),
                          .init(sourceID: fixture.id("stereo"), statedChannel: nil)]),
        ]
        let before = fixture.model
        let snapshot = try #require(await fixture.pipeline.inspect(
            model: before, episode: fixture.episodeID, sources: fixture.sources
        ))
        #expect(snapshot.speakerMatches[fixture.epochs[1]]?.isEmpty == true)
        let opens = fixture.content.total.opens
        let measured = snapshot.speakerMatches(in: before.episodes[0], channelCounts: [
            fixture.id("ref"): 1, fixture.id("mono"): 1, fixture.id("stereo"): 2,
        ])
        #expect(measured[fixture.epochs[1]]?.first?.referenceChannel == 0)
        #expect(measured[fixture.epochs[1]]?.first?.targetChannel == 0)
        #expect(measured[fixture.epochs[2]]?.isEmpty == true)
        #expect(fixture.content.total.opens == opens, "Inspecting already measured channels must not open originals")
        let report = try await fixture.pipeline.analyzeTracks(
            model: before, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations
        )
        #expect(report.records[fixture.epochs[1]]?.proposal != nil)
        #expect(report.records[fixture.epochs[2]] == nil)
        guard case let .setupRequired(detail)? = report.epochFailures[fixture.epochs[2]] else {
            Issue.record("A multichannel choice must produce an actionable setup requirement")
            return
        }
        #expect(detail.contains("stereo.wav (2 channels)") && detail.contains("Recordings & Speakers"))
        #expect(fixture.content.record(fixture.url("stereo")).decodedFrames == 0)
        #expect(fixture.model == before)
        let accepted = try await fixture.pipeline.accept(
            model: before, episode: fixture.episodeID, report: report,
            decisions: [fixture.epochs[1]: .acceptProposal()], replacingAlignment: true
        )
        #expect(accepted.model.episodes[0].speakerAssignments == before.episodes[0].speakerAssignments)
        #expect(accepted.model.episodes[0].sources == before.episodes[0].sources)
        let states = await fixture.pipeline.states(
            model: before, episode: fixture.episodeID, report: report, reviewingAnalysis: true
        )
        #expect(states.first { $0.epoch == fixture.epochs[2] }?.remedies.contains(.goToSetup) == true)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func missingAuthorizationLeavesAnExplicitSetupBlockWithoutOpeningContent() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "One", sources: [.init(name: "one", seconds: 22, signal: .scene(seed: 2))]),
            GroupSpec(name: "Two", sources: [.init(name: "two", seconds: 22, signal: .scene(seed: 2))]),
        ])
        let report = try await fixture.pipeline.analyzeTracks(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: [])
        #expect(report.plan.reference == nil && report.records.isEmpty)
        #expect(report.plan.ineligible.values.allSatisfy { $0 == .notAuthorized })
        #expect(report.plan.ineligible.count == 2)
        #expect(fixture.content.total.opens == 0 && fixture.content.total.reads == 0)
        let states = await fixture.pipeline.states(model: fixture.model, episode: fixture.episodeID,
            report: report, reviewingAnalysis: true)
        #expect(states.count == 2 && states.allSatisfy { $0.remedies.contains(.goToSetup) })
    }

    @Test func alignedRelayReferencesUseCapturedAcceptedTimingWithoutRebasing() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [.init(name: "reference", seconds: 24, signal: .scene(seed: 19))]),
            GroupSpec(name: "Relay", sources: [.init(name: "relay", seconds: 24, signal: .scene(seed: 19, offset: 0.2))]),
            GroupSpec(name: "Third", sources: [.init(name: "third", seconds: 24, signal: .scene(seed: 19, offset: 0.4))]),
        ])
        fixture.model.episodes[0].speakerAssignments = [
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("reference"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("relay"), statedChannel: 0)]),
            .init(speakerID: SpeakerID(), primary: .init(sourceID: fixture.id("relay"), statedChannel: 0),
                backups: [.init(sourceID: fixture.id("third"), statedChannel: 0)]),
        ]
        let initial = try await fixture.pipeline.prepareManual(model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        let prior = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID,
            report: initial, decisions: [
                fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 200),
                fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: 400),
            ])
        try await fixture.pipeline.activate(prior)
        let report = try await fixture.pipeline.analyzeTracks(model: prior.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations)
        #expect(report.references[fixture.epochs[2]]?.source == fixture.id("relay"))
        #expect(report.referenceRevision == prior.revision.revision)
        let proposal = try #require(report.records[fixture.epochs[2]]?.proposal)
        let accepted = try await fixture.pipeline.accept(model: prior.model, episode: fixture.episodeID,
            report: report, decisions: [fixture.epochs[2]: .acceptProposal()], replacingAlignment: true)
        let third = try #require(accepted.map.groups.first { $0.group == fixture.groups[2] })
        guard case let .mapped(segments, _) = third.epochs.first?.mapping else {
            Issue.record("Relay proposal was not accepted")
            return
        }
        #expect(segments == [proposal.segment], "Measured absolute timing stays anchored to the captured reference, not another proposal")
        #expect(accepted.map.reference == prior.map.reference)
        #expect(accepted.map.groups.first { $0.group == fixture.groups[1] }
            == prior.map.groups.first { $0.group == fixture.groups[1] })
    }
}
