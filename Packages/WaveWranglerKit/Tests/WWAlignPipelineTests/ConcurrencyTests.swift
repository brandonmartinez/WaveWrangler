import Foundation
import Testing
import WWCore
@testable import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

/// Late results, cancellation, shutdown and concurrency bounds. Every ordering is forced with the
/// coordinator's DEBUG commit hook or the gateway's read callback (never timing), and each late-result test
/// has a negative control that skips the coordinator's currency check and shows the stale result WOULD
/// otherwise publish.
@Suite("Late results never publish; cancellation and shutdown are coherent; work is bounded")
struct ConcurrencyTests {
    /// A short two-recorder episode (renders in a few seconds).
    static func short() -> [GroupSpec] { TwoRecorder.groups(referenceSeconds: 6, targetSeconds: 4) }

    /// One reference group and `count` target groups.
    static func fanOut(_ count: Int) -> [GroupSpec] {
        [GroupSpec(name: "Reference recorder", sources: [SourceSpec(name: "ref", seconds: 6, signal: .scene(seed: TwoRecorder.seed))])]
            + (0 ..< count).map { index in
                GroupSpec(name: "Field \(index)", sources: [
                    SourceSpec(name: "t\(index)", seconds: 4, signal: .scene(seed: TwoRecorder.seed, rate: TwoRecorder.rate, offset: TwoRecorder.offset)),
                ])
            }
    }

    static let truth = EpochMapDecision.numeric(ppm: 100, offsetMilliseconds: 1250)

    static func isAligned(_ slot: DerivedSlot) -> Bool { slot.name.hasPrefix(AlignmentAssetKinds.alignedAudio.kind + "/") }

    static func published(_ results: [PipelineJobResult]) -> [PipelineJobResult] {
        results.filter { if case .published = $0.outcome { true } else { false } }
    }

    /// Suspends (never blocks) until `condition` holds.
    static func until(_ condition: @Sendable () async -> Bool) async throws {
        while await !condition() { try await Task.sleep(for: .milliseconds(2)) }
    }

    /// Releases nothing it does not own: no reader open, no admission held.
    static func expectQuiescent(_ fixture: PipelineFixture, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(fixture.content.openReaders == 0, "every reader is closed", sourceLocation: sourceLocation)
        #expect(fixture.content.total.opens == fixture.content.total.closes, sourceLocation: sourceLocation)
        let gate = await fixture.pipeline.gate.snapshot
        #expect(gate.active == 0 && gate.activeBytes == 0 && gate.waiting == 0, "gate idle: \(gate)", sourceLocation: sourceLocation)
    }

    // MARK: Late results

    @Test("A source change that lands while the analysis commits discards it; skipping the currency check would publish it", arguments: [false, true])
    func lateAnalysisResult(skipCurrencyCheck: Bool) async throws {
        let fixture = try await PipelineFixture(Self.short(), skipCurrencyCheck: skipCurrencyCheck, label: "late-analysis")
        let targetEpoch = fixture.epochs[1]
        let tgt = fixture.id("tgt")
        let slot = PipelineSlots.analysis(targetEpoch)
        let coordinator = fixture.coordinator
        let fired = Box(false)
        fixture.script.set { committing, _ in
            guard committing == slot, fired.update({ let first = !$0; $0 = true; return first }) else { return }
            await coordinator.updateSource(SourceRevision(source: tgt, token: "metadata:changed-while-committing"))
        }
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(fired.value)
        let analysis = try #require(report.analyses[targetEpoch])
        if skipCurrencyCheck {
            // Negative control: the very same late result publishes when the check is skipped.
            #expect(analysis.outcome == .published(analysis.key))
            #expect(fixture.store.payload(for: analysis.key) != nil)
            #expect(await coordinator.staleReasons(for: analysis.key) == [.sourceChanged(tgt)])
        } else {
            #expect(analysis.outcome == .discardedStale([.sourceChanged(tgt)]))
            #expect(report.epochFailures[targetEpoch] == .staleInputs([.sourceChanged(tgt)]))
            #expect(report.records[targetEpoch] == nil)
            #expect(fixture.store.payload(for: analysis.key) == nil, "nothing reached the store")
        }
        // Either way the state never shows a proposal measured on a superseded revision.
        #expect(await fixture.states(report)[targetEpoch]?.status.proposal == nil)
        await Self.expectQuiescent(fixture)
    }

    @Test("A map change that lands while aligned segments commit discards them all; skipping the currency check would publish them", arguments: [false, true])
    func lateRenderResult(skipCurrencyCheck: Bool) async throws {
        let fixture = try await PipelineFixture(Self.short(), skipCurrencyCheck: skipCurrencyCheck, label: "late-render")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: Self.truth])
        let coordinator = fixture.coordinator
        let next = MapRevisionReference(episode: fixture.episodeID, revision: 2)
        let fired = Box(false)
        let changed = Latch()
        // The first aligned commit changes the accepted map; every other commit waits until it has, so no
        // segment can slip through before the change (deterministic in both modes).
        fixture.script.set { slot, _ in
            guard Self.isAligned(slot) else { return }
            if fired.update({ let first = !$0; $0 = true; return first }) {
                await coordinator.acceptMap(next)
                await changed.open()
            } else {
                await changed.wait()
            }
        }
        let rendered = try await fixture.render()
        #expect(fired.value)
        #expect(!rendered.isComplete)
        let results = rendered.groups.flatMap(\.results)
        let published = Self.published(results)
        if skipCurrencyCheck {
            #expect(!published.isEmpty, "negative control: late segments publish without the check")
            for result in published {
                #expect(fixture.store.payload(for: result.key) != nil)
                #expect(await coordinator.staleReasons(for: result.key).contains(.mapChanged(fixture.episodeID)))
            }
        } else {
            #expect(published.isEmpty)
            #expect(results.contains { if case let .discardedStale(reasons) = $0.outcome { reasons.contains(.mapChanged(fixture.episodeID)) } else { false } })
            for result in results { #expect(fixture.store.payload(for: result.key) == nil) }
            for group in rendered.groups {
                switch group.failure {
                case let .staleInputs(reasons)?: #expect(reasons.contains(.mapChanged(fixture.episodeID)))
                case .acceptedMapChanged?: break
                default: Issue.record("group \(group.group) ended \(String(describing: group.failure))")
                }
            }
        }
        await Self.expectQuiescent(fixture)
        // The document's revision is no longer the coordinator's: rendering again is refused up front.
        await #expect(throws: AlignedAssetRefusal.acceptedMapNotActive(document: 1, coordinator: 2)) { try await fixture.render() }
    }

    @Test(
        "A change to the reference source while a target segment commits discards every target segment; an identity without source revisions (negative control) would publish them",
        arguments: [true, false]
    )
    func lateRenderAfterOtherSourceChange(identityKeysSources: Bool) async throws {
        var hooks = AlignmentPipelineTestHooks()
        hooks.mapIdentityKeysSources = identityKeysSources
        let fixture = try await PipelineFixture(Self.short(), hooks: hooks, label: "late-render-other-source")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: Self.truth])
        let coordinator = fixture.coordinator
        let ref = fixture.id("ref")
        let tgt = fixture.id("tgt")
        let targetGroup = fixture.groups[1]
        let identitySlot = PipelineSlots.acceptedMapIdentity(fixture.episodeID)
        let changedToken = "metadata:reference-changed-while-target-commits"
        let fired = Box(false)
        let changed = Latch()
        // The target group's first aligned commit (rendered, verified, about to publish) changes the
        // reference source's revision; its later commits wait until it has. Only the target group is scripted:
        // its segments key the target source alone, so only the map identity can carry the reference change.
        fixture.script.set { slot, _ in
            guard Self.isAligned(slot), slot.name.contains("/\(targetGroup)/") else { return }
            if fired.update({ let first = !$0; $0 = true; return first }) {
                await coordinator.updateSource(SourceRevision(source: ref, token: changedToken))
                await changed.open()
            } else {
                await changed.wait()
            }
        }
        let rendered = try await fixture.render()
        #expect(fired.value)
        let targetReport = try #require(rendered.groups.first { $0.group == targetGroup })
        let targetResults = targetReport.results
        #expect(!targetResults.isEmpty)
        for result in targetResults { #expect(result.key.sources.map(\.source) == [tgt], "target segments key only the target source") }
        let published = Self.published(targetResults)
        if identityKeysSources {
            #expect(published.isEmpty, "no target segment publishes after the reference changed")
            for result in targetResults { #expect(fixture.store.payload(for: result.key) == nil) }
            #expect(targetResults.contains { if case let .discardedStale(reasons) = $0.outcome { reasons.contains(.upstreamChanged) } else { false } })
            switch targetReport.failure {
            case let .staleInputs(reasons)?: #expect(reasons.contains(.upstreamChanged))
            case .acceptedMapChanged?: break
            default: Issue.record("target group ended \(String(describing: targetReport.failure))")
            }
            guard case let .stale(_, reasons) = await coordinator.state(of: identitySlot) else {
                Issue.record("the map identity is still current after its reference changed")
                return
            }
            #expect(reasons.contains(.sourceChanged(ref)))
        } else {
            // Negative control: without the source revisions in the identity, the stale target segments publish
            // and the coordinator still considers them current.
            #expect(!published.isEmpty, "negative control: late target segments publish")
            for result in published {
                #expect(fixture.store.payload(for: result.key) != nil)
                #expect(await coordinator.staleReasons(for: result.key).isEmpty)
            }
            guard case .ready = await coordinator.state(of: identitySlot) else {
                Issue.record("negative control: the identity should not see the reference change")
                return
            }
        }
        await Self.expectQuiescent(fixture)
        // Either way the map no longer matches its sources: rendering again is refused up front.
        do {
            _ = try await fixture.render()
            Issue.record("a map whose reference changed rendered again")
        } catch {
            guard let refusal = error as? AlignedAssetRefusal, case .mapStale = refusal else {
                Issue.record("expected mapStale, got \(error)")
                return
            }
        }
    }

    // MARK: Cancellation

    @Test("Cancelling mid-decode stops reading, closes every reader, releases the gate, publishes nothing; a rerun succeeds")
    func cancelMidDecode() async throws {
        let fixture = try await PipelineFixture(Self.short(), label: "cancel-decode")
        let targetEpoch = fixture.epochs[1]
        let targetPath = ProceduralContentIO.path(fixture.url("tgt"))
        let fired = Box(false)
        let coordinator = fixture.coordinator
        let slot = PipelineSlots.analysis(targetEpoch)
        fixture.content.setOnRead { path, index in
            guard path == targetPath, index == 1, fired.update({ let first = !$0; $0 = true; return first }) else { return }
            cancelSlotDuringRead(coordinator, slot)
        }
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(fired.value)
        #expect(report.epochFailures[targetEpoch] == .cancelled)
        #expect(report.records[targetEpoch] == nil)
        let analysis = try #require(report.analyses[targetEpoch])
        #expect(!analysis.isAvailable)
        #expect(fixture.store.payload(for: analysis.key) == nil)
        let target = fixture.content.record(fixture.url("tgt"))
        #expect(target.reads == 2, "no read after the cancelled one")
        #expect(target.furthestFrame < fixture.specs["tgt"]!.frames)
        await Self.expectQuiescent(fixture)

        fixture.content.setOnRead(nil)
        let rerun = try await fixture.analyse(preferredReference: "ref")
        #expect(rerun.epochFailures.isEmpty)
        #expect(rerun.records[targetEpoch] != nil)
        #expect(rerun.analyses[targetEpoch]?.outcome == .published(analysis.key), "same key, now published")
        await Self.expectQuiescent(fixture)
    }

    @Test("Cancelling the caller while its analysis commits cancels the job; nothing publishes; a rerun succeeds")
    func cancelCallerAtCommit() async throws {
        let fixture = try await PipelineFixture(Self.short(), label: "cancel-caller")
        let targetEpoch = fixture.epochs[1]
        let slot = PipelineSlots.analysis(targetEpoch)
        let reached = Latch()
        let release = Latch()
        fixture.script.set { committing, _ in
            guard committing == slot else { return }
            await reached.open()
            await release.wait()
        }
        let pipeline = fixture.pipeline
        let (model, episode, sources, authorizations, ref) = (fixture.model, fixture.episodeID, fixture.sources, fixture.authorizations, fixture.id("ref"))
        let caller = Task {
            await pipeline.analyse(model: model, episode: episode, sources: sources, authorizations: authorizations, preferredReference: ref)
        }
        await reached.wait()
        caller.cancel()
        let coordinator = fixture.coordinator
        try await Self.until { if case .cancelled = await coordinator.state(of: slot) { true } else { false } }
        await release.open()
        let report = try #require(await caller.value)
        let analysis = try #require(report.analyses[targetEpoch])
        #expect(analysis.outcome == .cancelled)
        #expect(report.epochFailures[targetEpoch] == .cancelled)
        #expect(fixture.store.payload(for: analysis.key) == nil)
        await Self.expectQuiescent(fixture)

        fixture.script.set(nil)
        let rerun = try await fixture.analyse(preferredReference: "ref")
        #expect(rerun.analyses[targetEpoch]?.outcome == .published(analysis.key))
    }

    @Test("Shutdown while aligned segments commit: nothing publishes, every reader closes, later work is refused")
    func shutdownDuringRender() async throws {
        let fixture = try await PipelineFixture(Self.short(), label: "shutdown-render")
        let report = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(report, [fixture.epochs[1]: Self.truth])
        let reached = Latch()
        let release = Latch()
        fixture.script.set { slot, _ in
            guard Self.isAligned(slot) else { return }
            await reached.open()
            await release.wait()
        }
        let render = Task { try await fixture.render() }
        await reached.wait()
        let coordinator = fixture.coordinator
        let shutdown = Task { await coordinator.shutdown() }
        try await Self.until { await coordinator.isShutdown }
        await release.open()
        await shutdown.value
        let rendered = try await render.value
        #expect(Self.published(rendered.groups.flatMap(\.results)).isEmpty)
        for group in rendered.groups { #expect(group.failure == .cancelled, "group \(group.group): \(String(describing: group.failure))") }
        for result in rendered.groups.flatMap(\.results) { #expect(fixture.store.payload(for: result.key) == nil) }
        await Self.expectQuiescent(fixture)
        let opens = fixture.content.total.opens
        await #expect(throws: AlignedAssetRefusal.coordinatorShutDown) { try await fixture.render() }
        #expect(await fixture.pipeline.analyse(model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations)?.records.isEmpty == true)
        #expect(fixture.content.total.opens == opens, "nothing opened after shutdown")
    }

    // MARK: Bounds

    @Test("Analysis and rendering never exceed the configured concurrency: admissions and open readers are bounded")
    func boundedWork() async throws {
        let fixture = try await PipelineFixture(Self.fanOut(5), label: "bounds")
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.analyses.count == 5)
        #expect(report.sourceFailures.isEmpty && report.epochFailures.isEmpty)
        var gate = await fixture.pipeline.gate.snapshot
        // Upper bounds only: overlap itself depends on how many cooperative threads exist (one under
        // LIBDISPATCH_COOPERATIVE_POOL_STRICT); ResourceGateTests prove deterministically that the cap is reached.
        #expect((1...2).contains(gate.peakActive), "probes and analyses ran at most two at a time: \(gate)")
        #expect(gate.admitted == 6 + 5)
        #expect((1...2).contains(fixture.content.peakOpenReaders), "at most one reader per admitted unit (excerpts decode sequentially)")

        var decisions: [RecordingEpochID: EpochMapDecision] = [:]
        for epoch in fixture.epochs.dropFirst() { decisions[epoch] = Self.truth }
        try await fixture.acceptAndActivate(report, decisions)
        let rendered = try await fixture.render()
        #expect(rendered.isComplete)
        #expect(rendered.groups.count == 6)
        gate = await fixture.pipeline.gate.snapshot
        #expect((1...2).contains(gate.peakActive))
        #expect((1...2).contains(fixture.content.peakOpenReaders), "at most one single-source group render per admission")
        #expect(fixture.content.total.readsOnMainThread == 0)
        await Self.expectQuiescent(fixture)
    }

    @Test("The gate is shared: a unit already admitted elsewhere leaves analysis one slot")
    func gateIsShared() async throws {
        let fixture = try await PipelineFixture(Self.fanOut(3), label: "shared-gate")
        try await fixture.pipeline.gate.acquire(bytes: 0)
        let report = try await fixture.analyse(preferredReference: "ref")
        await fixture.pipeline.gate.release(bytes: 0)
        #expect(report.epochFailures.isEmpty)
        #expect(fixture.content.peakOpenReaders == 1)
        #expect(await fixture.pipeline.gate.snapshot.peakActive == 2)
        await Self.expectQuiescent(fixture)
    }

    @Test("A unit whose working set exceeds the whole memory budget is refused before anything is decoded")
    func overBudgetUnitIsRefused() async throws {
        // 16 MiB is the floor; a 600 s excerpt at a 120 s search cannot fit.
        let configuration = AlignmentPipelineConfiguration(concurrency: 2, analysisMemoryBudgetBytes: 1, targetExcerptSeconds: 600, searchDeviationSeconds: 120, renderSegmentSeconds: 2)
        #expect(configuration.analysisMemoryBudgetBytes == 16 << 20)
        let fixture = try await PipelineFixture(TwoRecorder.groups(referenceSeconds: 900, targetSeconds: 700), configuration: configuration, label: "budget")
        let report = try await fixture.analyse(preferredReference: "ref")
        guard case let .memoryBudget(requested, budget)? = report.epochFailures[fixture.epochs[1]] else {
            Issue.record("expected a memory-budget refusal, got \(String(describing: report.epochFailures[fixture.epochs[1]]))")
            return
        }
        #expect(budget == 16 << 20 && requested > budget)
        #expect(fixture.content.total.reads == 0, "refused before decoding")
        await Self.expectQuiescent(fixture)
    }
}
