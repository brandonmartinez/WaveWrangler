import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

/// Accepted maps are applied only while they still describe the inputs they were accepted against, under a
/// verified content identity, over the interval the evidence supports; shutdown waits for every reader.
@Suite("Map currency: content identity, dependencies, supported coverage, coherent shutdown")
struct MapCurrencyTests {
    static let other = EpochMapDecision.numeric(ppm: -50, offsetMilliseconds: 900)

    // MARK: Content identity (one snapshot, two maps)

    @Test("Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards")
    func twoAcceptsFromOneSnapshot() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "two-accepts")
        let target = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        let base = fixture.model
        let pipeline = fixture.pipeline
        let episode = fixture.episodeID
        let first = try await pipeline.accept(model: base, episode: episode, report: report, decisions: [target: ConcurrencyTests.truth])
        let second = try await pipeline.accept(model: base, episode: episode, report: report, decisions: [target: Self.other])
        #expect(first.revision == second.revision, "both maps carry the same next revision number")
        #expect(first.mapContentDigest != second.mapContentDigest)

        await #expect(throws: AlignmentAcceptanceError.supersededAcceptance) { try await pipeline.activate(first) }
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
        fixture.model = second.model
        try await pipeline.activate(second)
        try await pipeline.activate(second)  // a retry is idempotent

        await #expect(throws: AlignmentAcceptanceError.staleSnapshot) { try await pipeline.activate(first) }
        await #expect(throws: AlignmentAcceptanceError.staleSnapshot) {
            _ = try await pipeline.accept(model: base, episode: episode, report: report, decisions: [target: ConcurrencyTests.truth])
        }
        await #expect(throws: AlignmentAcceptanceError.staleSnapshot) {
            _ = try await pipeline.accept(model: first.model, episode: episode, report: report, decisions: [:])
        }

        let rendered = try await fixture.render()
        #expect(rendered.isComplete)
        let keys = ConcurrencyTests.published(rendered.groups.flatMap(\.results)).map(\.key)
        #expect(!keys.isEmpty)
        for key in keys {
            #expect(key.upstream.contains(second.identity.key.digest))
            #expect(!key.upstream.contains(first.identity.key.digest))
        }
        // The superseded document names the same revision number, but its content is not the active map.
        fixture.model = first.model
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) { try await fixture.render() }
        #expect(fixture.content.total.opens == opens, "nothing opened")
    }

    @Test("A different map under the same revision number never adopts the first map's aligned assets")
    func sameRevisionDifferentMapNeverReusesAssets() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "same-revision")
        let target = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        let base = fixture.model
        let first = try await fixture.acceptAndActivate(report, [target: ConcurrencyTests.truth])
        let firstRender = try await fixture.render()
        #expect(firstRender.isComplete)
        let firstKeys = Set(ConcurrencyTests.published(firstRender.groups.flatMap(\.results)).map(\.key))
        #expect(!firstKeys.isEmpty)

        // The document is reverted to the snapshot before that acceptance and reopened in another pipeline
        // instance, which accepts a different map: the same revision number, different content.
        fixture.reopenPipeline()
        fixture.model = base
        let second = try await fixture.acceptAndActivate(report, [target: Self.other])
        #expect(second.revision == first.revision)
        #expect(second.mapContentDigest != first.mapContentDigest)
        for key in firstKeys { #expect(await !fixture.coordinator.staleReasons(for: key).isEmpty, "the first map's segments are stale") }

        let secondRender = try await fixture.render()
        #expect(secondRender.isComplete)
        let results = secondRender.groups.flatMap(\.results)
        let secondKeys = Set(ConcurrencyTests.published(results).map(\.key))
        #expect(ConcurrencyTests.published(results).count == results.count, "every segment rendered afresh, none adopted")
        #expect(secondKeys.count == firstKeys.count)
        #expect(secondKeys.isDisjoint(with: firstKeys))
        for key in secondKeys {
            #expect(key.upstream == [second.identity.key.digest])
            let segment = try AlignedAudioSegment.decode(try #require(fixture.store.payload(for: key)))
            #expect(segment.header.mapDigest == second.mapContentDigest, "each segment records the map content it was rendered under")
        }
    }

    @Test("Persisted undo and redo restore each revision's identity and cached dependents")
    func persistedUndoRedoRestoresIdentityAndDependents() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "undo-redo")
        let target = fixture.epochs[1]
        let report = try await fixture.analyse(preferredReference: "ref")
        let first = try await fixture.acceptAndActivate(
            report,
            [target: ConcurrencyTests.truth]
        )
        let firstRender = try await fixture.render()
        let firstKeys = Set(
            ConcurrencyTests.published(firstRender.groups.flatMap(\.results)).map(\.key)
        )
        #expect(!firstKeys.isEmpty)

        let second = try await fixture.pipeline.reviseAcceptedMap(
            model: first.model,
            episode: fixture.episodeID,
            decisions: [target: Self.other]
        )
        fixture.model = second.model
        try await fixture.pipeline.activate(second)
        let secondRender = try await fixture.render()
        let secondKeys = Set(
            ConcurrencyTests.published(secondRender.groups.flatMap(\.results)).map(\.key)
        )
        #expect(!secondKeys.isEmpty)
        #expect(secondKeys.isDisjoint(with: firstKeys))

        fixture.model = first.model
        try await fixture.pipeline.activate(model: first.model, episode: fixture.episodeID)
        let restoredFirst = try await fixture.render()
        #expect(restoredFirst.isComplete)
        for key in firstKeys {
            #expect(await fixture.coordinator.staleReasons(for: key).isEmpty)
        }
        for key in secondKeys {
            #expect(await fixture.coordinator.staleReasons(for: key).contains(.mapChanged(fixture.episodeID)))
        }

        fixture.model = second.model
        try await fixture.pipeline.activate(model: second.model, episode: fixture.episodeID)
        let restoredSecond = try await fixture.render()
        #expect(restoredSecond.isComplete)
        for key in secondKeys {
            #expect(await fixture.coordinator.staleReasons(for: key).isEmpty)
        }
        for key in firstKeys {
            #expect(await fixture.coordinator.staleReasons(for: key).contains(.mapChanged(fixture.episodeID)))
        }
    }

    @Test("activate refuses an acceptance whose identity or result does not match the document's map version")
    func activateRefusesForgedContent() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(referenceSeconds: 6, targetSeconds: 4), label: "forged-content")
        let episodeID = fixture.episodeID
        let report = try await fixture.analyse(preferredReference: "ref")
        let accepted = try await fixture.pipeline.accept(model: fixture.model, episode: episodeID, report: report, decisions: [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0)])
        let version = try #require(accepted.model.episode(episodeID)?.alignment?.map(revision: accepted.revision.revision))
        // The identity of another version (same map, another recipe) under the same revision number.
        let (other, otherRevision) = try accepted.model.recordingMap(
            accepted.map, in: episodeID, inputs: version.inputs.sources, recipe: RecipeReference(name: "other", revision: 1), derivedFrom: accepted.revision.revision
        )
        let otherVersion = try #require(other.episode(episodeID)?.alignment?.map(revision: otherRevision.revision))
        let forgedIdentity = try AcceptedMapIdentity(
            revision: accepted.revision, version: otherVersion, map: accepted.map, registered: await fixture.coordinator.inputs.sources
        )
        #expect(forgedIdentity != accepted.identity)
        let forged = AcceptedAlignment(
            model: accepted.model, revision: accepted.revision, map: accepted.map, sourcesOutsideCoverage: accepted.sourcesOutsideCoverage,
            identity: forgedIdentity, token: accepted.token, base: accepted.base, result: accepted.result
        )
        await #expect(throws: AlignmentAcceptanceError.mapContentMismatch) { try await fixture.pipeline.activate(forged) }
        let wrongResult = AcceptedAlignment(
            model: accepted.model, revision: accepted.revision, map: accepted.map, sourcesOutsideCoverage: accepted.sourcesOutsideCoverage,
            identity: accepted.identity, token: accepted.token, base: accepted.base, result: accepted.base
        )
        await #expect(throws: AlignmentAcceptanceError.mapContentMismatch) { try await fixture.pipeline.activate(wrongResult) }
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty, "nothing activated")
        // Positive control: the genuine acceptance activates.
        try await fixture.pipeline.activate(accepted)
        #expect(await fixture.coordinator.inputs.acceptedMaps[episodeID] == accepted.revision.revision)
    }

    // MARK: Dependencies (placements and revisions)

    @Test("Moving a source to another epoch of its group after analysis makes accept refuse the stale plan")
    func movedWithinGroupAfterAnalysis() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "moved-analysis")
        let tgt = fixture.id("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        let moved = try fixture.moveToNewEpoch("tgt")
        for decisions in [[fixture.epochs[1]: ConcurrencyTests.truth], [:]] {
            let changes = await Self.acceptChanges(fixture, report, decisions)
            #expect(changes.contains(.sourceMoved(tgt)), "\(changes)")
            #expect(changes.contains(.epochSourcesChanged(moved)), "\(changes)")
            #expect(changes.contains(.epochSourcesChanged(fixture.epochs[1])), "\(changes)")
        }
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
    }

    @Test("Moving a source to another epoch of its group after acceptance makes render refuse before opening anything")
    func movedWithinGroupAfterAcceptance() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "moved-render")
        let tgt = fixture.id("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        let accepted = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let persisted = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: accepted.revision.revision))
        #expect(MapDependencies.persistedDigest(persisted) != nil, "the dependencies are persisted with the map")

        try fixture.moveToNewEpoch("tgt")
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.mapStale([.sourceMoved(tgt)])) { try await fixture.render() }
        #expect(fixture.content.total.opens == opens, "nothing opened")
    }

    @Test("A source revision change after acceptance refuses activation and rendering of the map")
    func sourceRevisionChangeAfterAcceptance() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "revision-change")
        let tgt = fixture.id("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        let accepted = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [fixture.epochs[1]: ConcurrencyTests.truth])
        fixture.model = accepted.model
        try fixture.rewrite("tgt")
        await fixture.coordinator.updateSource(try PipelineFixture.registration(tgt, fixture.url("tgt")))
        await #expect(throws: AlignmentAcceptanceError.analysisStale([.dependenciesChanged])) { try await fixture.pipeline.activate(accepted) }
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty, "a stale map is never applied")
    }

    @Test("A source revision change after activation refuses rendering before opening anything")
    func sourceRevisionChangeAfterActivation() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "revision-render")
        let tgt = fixture.id("tgt")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        try fixture.rewrite("tgt")
        await fixture.coordinator.updateSource(try PipelineFixture.registration(tgt, fixture.url("tgt")))
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.mapStale([.dependenciesChanged])) { try await fixture.render() }
        #expect(fixture.content.total.opens == opens, "nothing opened")
    }

    @Test("A map revision without this module's dependency record is never rendered")
    func mapWithoutDependenciesIsNotRendered() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "no-deps")
        let report = try await fixture.analyse(preferredReference: "ref")
        let accepted = try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let inputs = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.acceptedMap?.inputs)
        let (recorded, revision) = try fixture.model.recordingMap(accepted.map, in: fixture.episodeID, inputs: inputs.sources, recipe: nil, derivedFrom: accepted.revision.revision)
        fixture.model = try recorded.acceptingMap(revision: revision.revision, in: fixture.episodeID)
        await fixture.coordinator.acceptMap(revision)
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.mapStale([.dependenciesMissing])) { try await fixture.render() }
        #expect(fixture.content.total.opens == opens)
    }

    static func acceptChanges(_ fixture: PipelineFixture, _ report: AlignmentAnalysisReport, _ decisions: [RecordingEpochID: EpochMapDecision]) async -> [AlignmentDependencyChange] {
        do {
            _ = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: decisions)
            Issue.record("a stale plan was accepted")
            return []
        } catch {
            guard case let .analysisStale(changes) = error else {
                Issue.record("unexpected \(error)")
                return []
            }
            return changes
        }
    }

    // MARK: Coverage (no extrapolation)

    /// The two-recorder report with both sources re-described as `seconds` long and the target's proposal
    /// replaced by `segment` (rate 1, offset +0.25 s unless given).
    static func longReport(_ fixture: PipelineFixture, seconds: Int64, segment: AffineClockSegment) async throws -> (AlignmentAnalysisReport, [SourceID: SourceFacts], [RecordingEpochID: EpochAnalysisRecord]) {
        let report = try await fixture.analyse(preferredReference: "ref")
        var facts = report.facts
        for name in ["ref", "tgt"] {
            let id = fixture.id(name)
            let rate = Int64(try #require(facts[id]).sampleRate)
            facts[id]?.interpretation.frames.validFrames = seconds * rate
        }
        var records = report.records
        var record = try #require(records[fixture.epochs[1]])
        var proposal = try #require(record.proposal)
        proposal.segment = segment
        record.proposal = proposal
        records[fixture.epochs[1]] = record
        return (report, facts, records)
    }

    static let quarter: ExactRational = (try? ExactRational(1, 4)) ?? .zero

    @Test("A centred 10-minute proposal on a 75-minute source maps only its interval; the rest stays outsideCoverage both ways")
    func proposalCoverageIsNotExtended() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "coverage")
        let target = fixture.epochs[1]
        let tgt = fixture.id("tgt")
        let segment = try AffineClockSegment(groupClockStart: ExactRational(Int64(1950)), groupClockEnd: ExactRational(Int64(2550)), rateRatio: .one, alignedOffset: Self.quarter)
        let (report, facts, records) = try await Self.longReport(fixture, seconds: 75 * 60, segment: segment)
        let rate: Int64 = 48_000
        let total: Int64 = 75 * 60 * rate
        let first: Int64 = 1950 * rate
        let end: Int64 = 2550 * rate
        let occurrence = alignmentOccurrenceID(for: tgt)

        let accepted: [RecordingEpochID: EpochMapDecision] = [target: .acceptProposal()]
        let undecided: [RecordingEpochID: EpochMapDecision] = [:]
        for decisions in [accepted, undecided] {
            let built = try MapAcceptance.build(plan: report.plan, facts: facts, analyses: records, decisions: decisions, prior: nil)
            #expect(built.outsideCoverage.isEmpty)
            let group = try #require(built.map.group(containing: occurrence))
            let spans = try #require(group.placements.first { $0.occurrence.id == occurrence }?.spans)
            #expect(spans.map(\.startFrame) == [first])
            #expect(spans.map(\.endFrame) == [end])
            #expect(AcceptanceTests.segment(built.map, target) == segment, "the proposal's own interval, unextended")
            let kind = AcceptanceTests.provenances(built.map)[target]
            #expect(kind == (decisions.isEmpty ? .acousticConsistentProposal : .manual))

            for frame in [0, first - 1, end, total - 1] {
                #expect(try group.alignedTime(ofFrame: frame, in: occurrence) == .outsideCoverage, "frame \(frame)")
            }
            for frame in [first, end - 1] {
                guard case let .aligned(position) = try group.alignedTime(ofFrame: frame, in: occurrence) else {
                    Issue.record("frame \(frame) is inside the proposal")
                    continue
                }
                let expected = try ExactRational(frame, rate).adding(Self.quarter)
                #expect(position.instant == expected)
            }
            // Where the extrapolated line would have put the source's first and last frames: not inverted.
            let extrapolatedStart = Self.quarter
            let extrapolatedEnd = try ExactRational(total - 1, rate).adding(Self.quarter)
            #expect(try group.sourceFrame(at: extrapolatedStart, in: occurrence) == .outsideCoverage)
            #expect(try group.sourceFrame(at: extrapolatedEnd, in: occurrence) == .outsideCoverage)
            guard case let .source(position) = try group.sourceFrame(at: ExactRational(Int64(2000)), in: occurrence) else {
                Issue.record("an instant inside the proposal inverts")
                continue
            }
            let insideFrame: Int64 = 2000 * rate - 12_000
            #expect(position.frame == insideFrame)

            // The render hull covers only the mapped interval.
            let hull = try GroupRenderJob.hull(map: group, occurrences: [occurrence], outputRate: Int(rate))
            let hullStart: Int64 = first + 12_000
            let hullEnd: Int64 = end + 12_000
            #expect(hull == hullStart ..< hullEnd)
        }
    }

    @Test("Extending a proposal over the whole epoch is an explicit manual decision that says so")
    func extendingIsExplicitAndManual() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "extend")
        let target = fixture.epochs[1]
        let tgt = fixture.id("tgt")
        let segment = try AffineClockSegment(groupClockStart: ExactRational(Int64(1950)), groupClockEnd: ExactRational(Int64(2550)), rateRatio: .one, alignedOffset: Self.quarter)
        let (report, facts, records) = try await Self.longReport(fixture, seconds: 75 * 60, segment: segment)
        let total: Int64 = 75 * 60 * 48_000
        let occurrence = alignmentOccurrenceID(for: tgt)
        let built = try MapAcceptance.build(plan: report.plan, facts: facts, analyses: records, decisions: [target: .extendProposalToEpoch(note: "whole take")], prior: nil)
        let group = try #require(built.map.group(containing: occurrence))
        let spans = try #require(group.placements.first { $0.occurrence.id == occurrence }?.spans)
        #expect(spans.map(\.startFrame) == [0])
        #expect(spans.map(\.endFrame) == [total])
        let mapping = group.epochs.first { $0.epoch == target }?.mapping
        let note = "proposal extended to the whole epoch: whole take"
        let expected = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(Int64(75 * 60)), rateRatio: .one, alignedOffset: Self.quarter)
        #expect(mapping == .mapped(segments: [expected], provenance: .manual(ManualCorrection(basis: .acceptedAcousticProposal, note: note))))
        guard case let .aligned(position) = try group.alignedTime(ofFrame: 0, in: occurrence) else {
            Issue.record("the extended map covers the first frame")
            return
        }
        #expect(position.instant == Self.quarter)
    }

    @Test("A proposal reaching past either end of the source is clipped to the source's frames")
    func proposalIsClippedToTheSource() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "clip")
        let target = fixture.epochs[1]
        let tgt = fixture.id("tgt")
        let rate: Int64 = 48_000
        let total: Int64 = 600 * rate
        let occurrence = alignmentOccurrenceID(for: tgt)
        let late = try AffineClockSegment(groupClockStart: ExactRational(Int64(500)), groupClockEnd: ExactRational(Int64(700)), rateRatio: .one, alignedOffset: Self.quarter)
        let early = try AffineClockSegment(groupClockStart: ExactRational(Int64(-10)), groupClockEnd: ExactRational(Int64(30)), rateRatio: .one, alignedOffset: Self.quarter)
        let expectations: [(AffineClockSegment, Int64, Int64)] = [(late, 500 * rate, total), (early, 0, 30 * rate)]
        for (segment, start, end) in expectations {
            let (report, facts, records) = try await Self.longReport(fixture, seconds: 600, segment: segment)
            let built = try MapAcceptance.build(plan: report.plan, facts: facts, analyses: records, decisions: [target: .acceptProposal()], prior: nil)
            let spans = try #require(built.map.group(containing: occurrence)?.placements.first { $0.occurrence.id == occurrence }?.spans)
            #expect(spans.map(\.startFrame) == [start])
            #expect(spans.map(\.endFrame) == [end])
        }
    }

    @Test("A source with no frame inside its epoch's proposal is left unplaced and reported, never stretched")
    func sourceOutsideProposalIsReported() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "outside")
        let target = fixture.epochs[1]
        let tgt = fixture.id("tgt")
        let segment = try AffineClockSegment(groupClockStart: ExactRational(Int64(1950)), groupClockEnd: ExactRational(Int64(2550)), rateRatio: .one, alignedOffset: Self.quarter)
        let (report, facts, records) = try await Self.longReport(fixture, seconds: 30 * 60, segment: segment)
        let undecided = try MapAcceptance.build(plan: report.plan, facts: facts, analyses: records, decisions: [:], prior: nil)
        #expect(undecided.outsideCoverage == [tgt])
        #expect(undecided.map.group(containing: alignmentOccurrenceID(for: tgt)) == nil)
        #expect(throws: AlignmentAcceptanceError.noPlaceableSource(target)) {
            try MapAcceptance.build(plan: report.plan, facts: facts, analyses: records, decisions: [target: .acceptProposal()], prior: nil)
        }
    }

    // MARK: Shutdown waits for render readers

    @Test("shutdown() cancels a render still waiting for admission: it returns without the gate ever being released")
    func shutdownCancelsQueuedRender() async throws {
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), label: "shutdown-queued")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let gate = fixture.pipeline.gate
        let budget = await gate.budgetBytes
        try await gate.acquire(bytes: budget)
        let opens = fixture.content.total.opens
        let render = Task { try await fixture.render() }
        try await ResourceGateTests.until(gate) { $0.waiting > 0 }
        let pipeline = fixture.pipeline
        let returned = Box(false)
        let shutdown = Task {
            await pipeline.shutdown()
            returned.value = true
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !returned.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(returned.value, "shutdown cancelled the queued render instead of waiting for admission")
        await gate.release(bytes: budget)
        await shutdown.value
        let rendered = try await render.value
        #expect(ConcurrencyTests.published(rendered.groups.flatMap(\.results)).isEmpty)
        #expect(fixture.content.total.opens == opens, "nothing opened")
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("shutdown() returns only once every render reader is closed; untracked renders (negative control) let it return with a reader open", arguments: [true, false])
    func shutdownAwaitsRenderReaders(tracked: Bool) async throws {
        let reached = Latch()
        let release = Latch()
        var hooks = AlignmentPipelineTestHooks()
        hooks.trackRenders = tracked
        hooks.beforeSegmentPublish = { _, _ in
            await reached.open()
            await release.wait()
        }
        let fixture = try await PipelineFixture(ConcurrencyTests.short(), hooks: hooks, label: "shutdown-readers")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: ConcurrencyTests.truth])
        let render = Task { try await fixture.render() }
        await reached.wait()
        let content = fixture.content
        #expect(content.openReaders > 0, "the first render holds a gateway cursor, before any commit")
        let pipeline = fixture.pipeline
        let returned = Box(false)
        let readersAtReturn = Box(-1)
        let shutdown = Task {
            await pipeline.shutdown()
            readersAtReturn.value = content.openReaders
            returned.value = true
        }
        if tracked {
            try await ConcurrencyTests.until { await fixture.coordinator.isShutdown }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!returned.value, "shutdown is still waiting for the held render")
            await release.open()
            await shutdown.value
            #expect(readersAtReturn.value == 0, "every cursor closed before shutdown returned")
        } else {
            try await ConcurrencyTests.until { returned.value }
            #expect(readersAtReturn.value > 0, "negative control: an untracked render outlives shutdown")
            await release.open()
            await shutdown.value
        }
        let rendered = try await render.value
        let results = rendered.groups.flatMap(\.results)
        #expect(ConcurrencyTests.published(results).isEmpty)
        for result in results { #expect(fixture.store.payload(for: result.key) == nil) }
        await ConcurrencyTests.expectQuiescent(fixture)
        await #expect(throws: AlignedAssetRefusal.coordinatorShutDown) { try await fixture.render() }
    }
}
