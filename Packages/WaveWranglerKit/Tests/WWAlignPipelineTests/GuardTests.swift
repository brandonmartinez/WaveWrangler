import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
@testable import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

/// Direct tests of the pipeline's defence-in-depth guards. Each one sits behind another check (the plan
/// calls `check` before `admitted`; the decoder of this build only produces the current format revision;
/// the decoder, renderer, gate and coordinator also refuse cancelled, shut-down or stale work), so
/// end-to-end tests cannot tell whether the guard itself holds. These pin each guard on its own.
@Suite("Defence-in-depth guards hold on their own")
struct GuardTests {
    // MARK: Eligibility

    @Test("`admitted` never lends a location or revision for an ineligible source, even one that is registered")
    func admittedRefusesEveryIneligibleSource() throws {
        let url = URL(fileURLWithPath: "/nonexistent/originals/a.wav")
        let on = SourceID(), off = SourceID(), unauthorized = SourceID(), unregistered = SourceID(), unlocated = SourceID()
        let eligibility = ContentEligibility(
            sources: [
                AlignmentSource(id: on, url: url, availability: .on),
                AlignmentSource(id: off, url: url, availability: .off),
                AlignmentSource(id: unauthorized, url: url, availability: .on),
                AlignmentSource(id: unregistered, url: url, availability: .on),
            ],
            authorizations: [on, off, unregistered, unlocated].map(ContentWorkAuthorization.explicitUserRequest(for:)),
            registered: [on: "metadata:on", off: "metadata:off", unauthorized: "metadata:unauthorized", unlocated: "metadata:unlocated"]
        )
        let admitted = try #require(eligibility.admitted(on))
        #expect(admitted.source.id == on && admitted.token == "metadata:on")
        let expected: [(SourceID, SourceIneligibility)] = [
            (off, .availabilityOff), (unauthorized, .notAuthorized), (unregistered, .notRegistered), (unlocated, .locationUnknown),
        ]
        for (id, reason) in expected {
            #expect(eligibility.check(id) == reason)
            #expect(eligibility.admitted(id) == nil, "\(reason) must not be admitted")
        }
    }

    // MARK: Probe verification

    @Test("A decoder interpretation from another format or envelope revision is refused, whatever the revision token")
    func probeRefusesAnotherFormatRevision() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(referenceSeconds: 2, targetSeconds: 2), label: "guard-format")
        let id = fixture.id("ref")
        let token = try PipelineFixture.registration(id, fixture.url("ref")).token
        let decoder = SourceDecoder(access: SourceAccessContext(io: fixture.metadataIO), content: fixture.content)
        let current = try await decoder.withDecodingCursor(fixture.url("ref"), source: id) { $0.interpretation }
        #expect(throws: Never.self) { try SourceProbe.verify(current, source: id, token: token) }

        var newerFormat = current
        newerFormat.formatInterpretationVersion += 1
        #expect(throws: AlignmentWorkFailure.formatRevisionMismatch(interpretation: current.formatInterpretationVersion + 1, envelope: current.envelopeVersion)) {
            try SourceProbe.verify(newerFormat, source: id, token: token)
        }
        var newerEnvelope = current
        newerEnvelope.envelopeVersion += 1
        #expect(throws: AlignmentWorkFailure.formatRevisionMismatch(interpretation: current.formatInterpretationVersion, envelope: current.envelopeVersion + 1)) {
            try SourceProbe.verify(newerEnvelope, source: id, token: token)
        }
        // Content-digest tokens skip the fingerprint comparison, never the format check.
        #expect(throws: AlignmentWorkFailure.self) { try SourceProbe.verify(newerFormat, source: id, token: "content:digest") }
    }

    // MARK: Acceptance currency

    @Test("`build` refuses or withholds a proposal measured on another revision of either source, even if handed it directly", arguments: ["tgt", "ref"])
    func buildRefusesProposalFromAnotherRevision(changed: String) async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "guard-current")
        let report = try await fixture.analyse(preferredReference: "ref")
        let targetEpoch = fixture.epochs[1]
        let record = try #require(report.records[targetEpoch])
        try #require(record.proposal != nil)
        let current = try MapAcceptance.build(plan: report.plan, facts: report.facts, analyses: report.records, decisions: [targetEpoch: .acceptProposal()], prior: nil)
        #expect(AcceptanceTests.provenances(current.map)[targetEpoch] == .manual)

        // The record is handed over as if current (bypassing the coordinator's staleness filter), but the
        // probed facts now carry a newer revision of one source.
        var facts = report.facts
        let id = fixture.id(changed)
        facts[id]?.revisionToken = "metadata:newer-revision"
        #expect(throws: AlignmentAcceptanceError.proposalNotCurrent(targetEpoch)) {
            try MapAcceptance.build(plan: report.plan, facts: facts, analyses: report.records, decisions: [targetEpoch: .acceptProposal()], prior: nil)
        }
        // Undecided: the stale proposal is not carried into the map as U3 either.
        let undecided = try MapAcceptance.build(plan: report.plan, facts: facts, analyses: report.records, decisions: [:], prior: nil)
        let mapping = undecided.map.groups.flatMap(\.epochs).first { $0.epoch == targetEpoch }?.mapping
        guard case .unsupported? = mapping else {
            Issue.record("a stale proposal was carried forward: \(String(describing: mapping))")
            return
        }
    }

    // MARK: Bounded decode

    @Test("An analysis decode stops within one chunk of the frames it needs, never reading the rest of the file")
    func analysisDecodeStopsAtNeededRange() async throws {
        let chunk = 4096
        let fixture = try await PipelineFixture(TwoRecorder.groups(referenceSeconds: 6, targetSeconds: 4), chunkFrames: chunk, label: "guard-stop")
        let id = fixture.id("ref")
        let spec = try #require(fixture.specs["ref"])
        let decoder = SourceDecoder(access: SourceAccessContext(io: fixture.metadataIO), content: fixture.content, configuration: .init(chunkFrames: chunk))
        let interpretation = try await decoder.withDecodingCursor(fixture.url("ref"), source: id) { $0.interpretation }
        let facts = SourceFacts(interpretation: interpretation, revisionToken: try PipelineFixture.registration(id, fixture.url("ref")).token)
        #expect(facts.sampleRate == spec.sampleRate && facts.frameCount == spec.frames && facts.channelCount == spec.channels)
        let source = try #require(fixture.sources.first { $0.id == id })
        let range: Range<Int64> = 48_000 ..< 96_000
        let needed = try AnalysisDecimator(sourceRate: spec.sampleRate, minimumRate: 8000, range: range).neededInput
        let samples = try await AnalysisUnit.decodeAnalysisBuffer(source, facts: facts, range: range, minimumRate: 8000, decoder: decoder)
        #expect(!samples.isEmpty)
        let furthest = fixture.content.record(fixture.url("ref")).furthestFrame
        #expect(furthest >= needed.upperBound, "the needed range was read")
        #expect(furthest < needed.upperBound + Int64(chunk), "read \(furthest) frames for \(needed); at most one chunk past the end")
        #expect(needed.upperBound + Int64(chunk) < spec.frames, "the fixture leaves frames that must not be read")
        #expect(fixture.content.openReaders == 0)
    }

    // MARK: Render applicability

    @Test("Rendering refuses an accepted map that no longer applies to the episode, before opening anything")
    func renderRefusesInapplicableMap() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "guard-applicable")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        // The person moves the field recorder's file into the reference group after accepting the map.
        let tgt = fixture.id("tgt")
        let episode = try #require(fixture.model.episodes.firstIndex { $0.id == fixture.episodeID })
        let record = try #require(fixture.model.episodes[episode].sources.firstIndex { $0.id == tgt })
        fixture.model.episodes[episode].sources[record].placement = SourcePlacement(recorderGroupID: fixture.groups[0], epochID: fixture.epochs[0])
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.mapNotApplicable([.sourceRegrouped(tgt, mapGroup: fixture.groups[1], currentGroup: fixture.groups[0])])) {
            try await fixture.render()
        }
        #expect(fixture.content.total.opens == opens, "nothing opened")
    }

    // MARK: Render currency

    /// A render job for the accepted map's first group (only its episode and revision matter to the guard).
    static func renderJob(_ fixture: PipelineFixture) async throws -> GroupRenderJob {
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let revision = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.acceptedRevision)
        let map = try fixture.model.timeMap(revision: revision, in: fixture.episodeID)
        let group = try #require(map.groups.first)
        let rate = try #require(group.placements.first?.occurrence.nominalRate)
        let reference = MapRevisionReference(episode: fixture.episodeID, revision: revision)
        let version = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: revision))
        return GroupRenderJob(
            episode: fixture.episodeID, revision: reference, identity: try AcceptedMapIdentity(revision: reference, version: version), map: group,
            nominalOutputRate: rate, participants: [], outputFrames: 0 ..< 1, segmentFrames: 1, recipeBaseName: "guard"
        )
    }

    @Test("Between segments a render stops when the accepted map is no longer its revision")
    func renderStopsOnMapChange() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "guard-map")
        let job = try await Self.renderJob(fixture)
        let coordinator = fixture.coordinator
        await #expect(throws: Never.self) { try await AlignedAssetRun.checkCurrent(job, coordinator: coordinator) }
        await coordinator.acceptMap(MapRevisionReference(episode: fixture.episodeID, revision: job.revision.revision + 1))
        await #expect(throws: AlignmentWorkFailure.acceptedMapChanged) { try await AlignedAssetRun.checkCurrent(job, coordinator: coordinator) }
    }

    @Test("Between segments a render stops when the active map content is not its identity, even under the same revision number")
    func renderStopsOnMapContentChange() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "guard-identity")
        let job = try await Self.renderJob(fixture)
        let coordinator = fixture.coordinator
        await #expect(throws: Never.self) { try await AlignedAssetRun.checkCurrent(job, coordinator: coordinator) }
        // Another version of the same map, recorded under another recipe: different content, same number.
        let map = try fixture.model.timeMap(revision: job.revision.revision, in: fixture.episodeID)
        let inputs = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: job.revision.revision)?.inputs)
        let (other, revision) = try fixture.model.recordingMap(map, in: fixture.episodeID, inputs: inputs.sources, recipe: RecipeReference(name: "other", revision: 1), derivedFrom: job.revision.revision)
        let version = try #require(other.episode(fixture.episodeID)?.alignment?.map(revision: revision.revision))
        let impostor = GroupRenderJob(
            episode: fixture.episodeID, revision: job.revision, identity: try AcceptedMapIdentity(revision: job.revision, version: version), map: job.map,
            nominalOutputRate: job.nominalOutputRate, participants: [], outputFrames: 0 ..< 1, segmentFrames: 1, recipeBaseName: "guard"
        )
        #expect(impostor.identity != job.identity)
        await #expect(throws: AlignmentWorkFailure.acceptedMapChanged) { try await AlignedAssetRun.checkCurrent(impostor, coordinator: coordinator) }
        #expect(await coordinator.inputs.acceptedMaps[fixture.episodeID] == job.revision.revision, "only the content differs")
    }

    @Test("Between segments a render stops once the coordinator has shut down")
    func renderStopsOnShutdown() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "guard-shutdown")
        let job = try await Self.renderJob(fixture)
        let coordinator = fixture.coordinator
        await coordinator.shutdown()
        // The accepted map is unchanged: only the shutdown can refuse here.
        #expect(await coordinator.inputs.acceptedMaps[fixture.episodeID] == job.revision.revision)
        await #expect(throws: AlignmentWorkFailure.cancelled) { try await AlignedAssetRun.checkCurrent(job, coordinator: coordinator) }
    }

    @Test("Between segments a render stops when its task is cancelled")
    func renderStopsOnCancellation() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "guard-cancel")
        let job = try await Self.renderJob(fixture)
        let coordinator = fixture.coordinator
        let gate = Latch()
        // The latch ignores cancellation, so the check runs strictly after `cancel()`.
        let check = Task { () async -> AlignmentWorkFailure? in
            await gate.wait()
            do throws(AlignmentWorkFailure) {
                try await AlignedAssetRun.checkCurrent(job, coordinator: coordinator)
                return nil
            } catch {
                return error
            }
        }
        check.cancel()
        await gate.open()
        #expect(await check.value == .cancelled)
        // Neither the map nor the coordinator changed: only the cancellation can refuse here.
        #expect(await coordinator.inputs.acceptedMaps[fixture.episodeID] == job.revision.revision)
        #expect(await coordinator.isShutdown == false)
    }
}
