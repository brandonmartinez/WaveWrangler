import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWAlignPipeline

enum RenderEnvelopeProfileGate {
    static let enabled = ProcessInfo.processInfo.environment["WW_RENDER_ENVELOPE_PROFILE"] == "1"
    static let reason: Comment = "run each profile in a separate process (WW_RENDER_ENVELOPE_PROFILE=1)"
}

private actor GroupOverlap {
    private var groups = Set<RecorderGroupID>()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive(_ group: RecorderGroupID) async {
        groups.insert(group)
        if groups.count == 2 {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Aligned render whole-process memory profiles", .serialized,
       .enabled(if: RenderEnvelopeProfileGate.enabled, RenderEnvelopeProfileGate.reason))
struct RenderEnvelopeProfileTests {
    private static func cycleCohort(
        label: String
    ) async throws -> (fixture: PipelineFixture, units: [AnalysisUnit], excerptBytes: Int) {
        let configuration = AlignmentPipelineConfiguration(
            targetExcerptSeconds: 20, searchDeviationSeconds: 1,
            minimumAnalysisRate: 48_000, renderSegmentSeconds: 10
        )
        let fixture = try await PipelineFixture([
            GroupSpec(name: "reference", sources: [
                SourceSpec(name: "ref", channels: 1, seconds: 20, signal: .scene(seed: TwoRecorder.seed)),
            ]),
        ] + (0 ..< 12).map { index in
            GroupSpec(name: "target-\(index)", sources: [
                SourceSpec(name: "target-\(index)", channels: 1, seconds: 20, signal: .scene(seed: TwoRecorder.seed)),
            ])
        }, configuration: configuration, label: label)
        let reference = try #require(fixture.sources.first)
        let referenceFacts = try await SourceProbe.run(
            reference, token: PipelineFixture.registration(reference.id, reference.url).token,
            environment: fixture.pipeline.environment
        )
        let choice = AlignmentReferenceChoice(
            group: fixture.groups[0], epoch: fixture.epochs[0], source: reference.id
        )
        var units: [AnalysisUnit] = []
        for index in 0 ..< 12 {
            let target = try #require(fixture.sources.dropFirst().first {
                $0.id == fixture.id("target-\(index)")
            })
            let facts = try await SourceProbe.run(
                target, token: PipelineFixture.registration(target.id, target.url).token,
                environment: fixture.pipeline.environment
            )
            units.append(AnalysisUnit(
                referenceChoice: choice, reference: reference, referenceFacts: referenceFacts,
                targetGroup: fixture.groups[index + 1], targetEpoch: fixture.epochs[index + 1],
                target: target, targetFacts: facts, configuration: configuration,
                chunkFrames: fixture.decoder.configuration.chunkFrames
            ))
        }
        let excerptBytes = units.reduce(0) { $0 + $1.cycleTargetRange.count * MemoryLayout<Float>.size }
        #expect(excerptBytes == 12 * 3_840_000)
        return (fixture, units, excerptBytes)
    }

    @Test("Twenty-seven independent retained excerpt caches stay inside process admission")
    func retainedExcerptsAcrossInstances() async throws {
        let (fixture, cohort, excerptBytes) = try await Self.cycleCohort(label: "retained-excerpts-27")
        let configuration = fixture.pipeline.configuration
        let sampler = MemorySampler()
        let release = Latch()
        let holders = Box(0)
        let pipelines = (0 ..< 27).map { _ in
            AlignmentPipeline(coordinator: fixture.coordinator, decoder: fixture.decoder, configuration: configuration)
        }
        let tasks = pipelines.map { pipeline in
            Task {
                try await CycleExcerptCache.withAdmission(
                    units: cohort, excerptBytes: excerptBytes, environment: pipeline.environment
                ) { cache in
                    for unit in cohort.dropLast() {
                        let samples = [Float](repeating: 0.25, count: 20 * 48_000)
                        await cache.rememberTarget(unit, samples: samples)
                    }
                    for unit in cohort.dropLast() {
                        let samples = try await cache.samples(for: unit, decoder: fixture.decoder)
                        #expect(samples.count == 20 * 48_000)
                    }
                    holders.update { $0 += 1 }
                    await release.wait()
                }
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline {
            let snapshot = await ResourceGate.process.snapshot
            if holders.value == 1 && snapshot.waiting == 26 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let held = await ResourceGate.process.snapshot
        #expect(holders.value == 1 && held.active == 1 && held.waiting == 26)
        #expect(held.activeBytes <= AlignmentPipelineConfiguration.maximumMemoryBudgetBytes)
        #expect(fixture.content.total.opens == 13, "no cold source reads before cohort admission")
        for task in tasks { task.cancel() }
        await release.open()
        for task in tasks {
            do {
                try await task.value
            } catch is CancellationError {
                // Waiting cohorts are cancelled without ever retaining excerpts.
            }
        }
        struct SyntheticFailure: Error {}
        await #expect(throws: SyntheticFailure.self) {
            try await CycleExcerptCache.withAdmission(
                units: cohort, excerptBytes: excerptBytes, environment: pipelines[0].environment
            ) { cache in
                await cache.rememberTarget(cohort[0], samples: [Float](repeating: 0.25, count: 20 * 48_000))
                throw SyntheticFailure()
            }
        }
        let inBody = Latch()
        let cancelled = Task {
            try await CycleExcerptCache.withAdmission(
                units: cohort, excerptBytes: excerptBytes, environment: pipelines[1].environment
            ) { cache in
                await cache.rememberTarget(cohort[0], samples: [Float](repeating: 0.25, count: 20 * 48_000))
                await inBody.open()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await inBody.wait()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let peaks = sampler.stop()
        let rss = MemorySampler.maxResident()
        #expect(await ResourceGate.process.snapshot.activeBytes == 0)
        for pipeline in pipelines { #expect(await pipeline.gate.snapshot.activeBytes == 0) }
        print("[render-envelope] 27 independent 20s/48k/12-target cohorts: ru_maxrss \(rss), sampled RSS \(peaks.resident), footprint \(peaks.footprint), admitted \(held.activeBytes), waiters \(held.waiting)")
        #expect(rss <= 1_073_741_824 && peaks.resident <= 1_073_741_824 && peaks.footprint <= 1_073_741_824)
    }

    @Test("A cached analysis cohort overlaps a six-channel render and a cached rerender")
    func analysisAndRender() async throws {
        let (analysis, cohort, excerptBytes) = try await Self.cycleCohort(label: "analysis-render-cohort")
        let atRenderPublish = Latch()
        let release = Latch()
        let rendering = try await PipelineFixture([
            GroupSpec(name: "reference", sources: [
                SourceSpec(name: "ref", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed)),
            ]),
            GroupSpec(name: "target", sources: (0 ..< 3).map {
                SourceSpec(name: "target-\($0)", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed))
            }),
        ], configuration: AlignmentPipelineConfiguration(
            targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 10
        ), hooks: AlignmentPipelineTestHooks(beforeSegmentPublish: { _, _ in
            await atRenderPublish.open()
            await release.wait()
        }), label: "analysis-render-six")
        let report = try await rendering.analyse(preferredReference: "ref")
        try await rendering.acceptAndActivate(report, [rendering.epochs[1]:
            .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth")])
        let ready = Latch()
        let sampler = MemorySampler()
        let analysisWork = Task {
            try await CycleExcerptCache.withAdmission(
                units: cohort, excerptBytes: excerptBytes, environment: analysis.pipeline.environment
            ) { cache in
                for unit in cohort.dropFirst() {
                    await cache.rememberTarget(unit, samples: [Float](repeating: 0.25, count: 20 * 48_000))
                }
                await ready.open()
                _ = try await cohort[0].run(
                    environment: analysis.pipeline.environment, peers: Array(cohort.dropFirst()), cache: cache
                )
                await release.wait()
            }
        }
        await ready.wait()
        let renderWork = Task { try await rendering.render() }
        await atRenderPublish.wait()
        let active = await ResourceGate.process.snapshot
        #expect(active.active == 2 && active.activeBytes <= AlignmentPipelineConfiguration.maximumMemoryBudgetBytes)
        await release.open()
        try await analysisWork.value
        let first = try await renderWork.value
        let repeated = try await rendering.render()
        let peaks = sampler.stop()
        let rss = MemorySampler.maxResident()
        #expect(first.isComplete && repeated.isComplete)
        #expect(repeated.groups.allSatisfy { $0.segmentsReused == $0.segments })
        #expect(await ResourceGate.process.snapshot.activeBytes == 0)
        print("[render-envelope] simultaneous 11 retained 20s/48k excerpts + 12-track analysis + six-channel 10s render; cached rerender: ru_maxrss \(rss), sampled RSS \(peaks.resident), footprint \(peaks.footprint), reserved \(active.activeBytes)")
        #expect(rss <= 1_073_741_824 && peaks.resident <= 1_073_741_824 && peaks.footprint <= 1_073_741_824)
    }

    @Test("Six channels at the 180-second segment boundary")
    func boundary() async throws {
        let config = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 180
        )
        let fixture = try await RenderEnvelopeTests.fixture(
            configuration: config, targets: [2, 2, 2], seconds: 180, label: "boundary-180"
        )
        try await profile(fixture, shape: "3 inputs × 2 channels, 48k output, concurrency 2, 16k decoder, 180s segment")
    }

    @Test("Two independent six-channel pipeline instances at the 180-second boundary")
    func independentInstances() async throws {
        let config = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 180
        )
        let firstEntered = Latch()
        let releaseFirst = Latch()
        let hooks = AlignmentPipelineTestHooks(beforeSegmentPublish: { _, _ in
            await firstEntered.open()
            await releaseFirst.wait()
        })
        let first = try await PipelineFixture([
            GroupSpec(name: "reference", sources: [SourceSpec(name: "ref", channels: 2, seconds: 180, signal: .scene(seed: TwoRecorder.seed))]),
            GroupSpec(name: "target", sources: (0 ..< 3).map {
                SourceSpec(name: "target-\($0)", channels: 2, seconds: 180, signal: .scene(seed: TwoRecorder.seed))
            }),
        ], configuration: config, hooks: hooks, label: "instance-first")
        let analysis = try await first.analyse(preferredReference: "ref")
        try await first.acceptAndActivate(analysis, [first.epochs[1]:
            .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth")])
        let second = try await RenderEnvelopeTests.fixture(
            configuration: config, targets: [2, 2, 2], seconds: 180, label: "instance-second"
        )
        let sampler = MemorySampler()
        let firstSources = first.sources.filter { $0.id != first.id("ref") }
        let firstIDs = Set(firstSources.map(\.id))
        let firstRender = Task {
            try await first.pipeline.renderAlignedAssets(
                model: first.model, episode: first.episodeID, sources: firstSources,
                authorizations: first.authorizations.filter { firstIDs.contains($0.source) }
            )
        }
        await firstEntered.wait()
        let secondOpens = second.content.total.opens
        let secondSources = second.sources.filter { $0.id != second.id("ref") }
        let secondIDs = Set(secondSources.map(\.id))
        let secondRender = Task {
            try await second.pipeline.renderAlignedAssets(
                model: second.model, episode: second.episodeID, sources: secondSources,
                authorizations: second.authorizations.filter { secondIDs.contains($0.source) }
            )
        }
        try await ConcurrencyTests.until { await ResourceGate.process.snapshot.waiting > 0 }
        let held = await ResourceGate.process.snapshot
        #expect(held.active == 1 && held.activeBytes > 450 << 20)
        #expect(second.content.total.opens == secondOpens, "second instance cannot open render cursors while first owns admission")
        await releaseFirst.open()
        let reports = try await (firstRender.value, secondRender.value)
        let peaks = sampler.stop()
        let rss = MemorySampler.maxResident()
        #expect(reports.0.isComplete && reports.0.groups.last?.segmentsRendered == 1)
        if reports.1.isComplete {
            #expect(reports.1.groups.last?.segmentsRendered == 1)
        } else {
            #expect(reports.1.groups.allSatisfy {
                guard case let .renderEnvelope(reason)? = $0.failure else { return false }
                return reason.contains("process memory") && $0.segmentsRendered == 0
            })
            #expect(second.content.total.opens == secondOpens, "warm-baseline refusal opens no cursors")
        }
        #expect(await ResourceGate.process.snapshot.activeBytes == 0)
        print("[render-envelope] independent 180s six-channel instances: second complete \(reports.1.isComplete), failures \(reports.1.groups.map { String(describing: $0.failure) }), ru_maxrss \(rss), sampled RSS \(peaks.resident), footprint \(peaks.footprint), process admission \(held.activeBytes)")
        #expect(rss <= 1_073_741_824 && peaks.resident <= 1_073_741_824 && peaks.footprint <= 1_073_741_824)
    }

    @Test("Two simultaneous eight-channel groups, cached rerender")
    func simultaneous() async throws {
        let groups = [
            GroupSpec(name: "reference", sources: [
                SourceSpec(name: "ref", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed)),
            ]),
            GroupSpec(name: "A", sources: (0 ..< 4).map {
                SourceSpec(name: "a-\($0)", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed))
            }),
            GroupSpec(name: "B", sources: (0 ..< 4).map {
                SourceSpec(name: "b-\($0)", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed))
            }),
        ]
        let config = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 10
        )
        let overlap = GroupOverlap()
        let fixture = try await PipelineFixture(
            groups, configuration: config,
            hooks: AlignmentPipelineTestHooks(beforeSegmentPublish: { group, _ in await overlap.arrive(group) }),
            label: "simultaneous"
        )
        let analysis = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(analysis, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth"),
            fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth"),
        ])
        try await profile(fixture, shape: "2 groups × 4 inputs × 2 channels, 48k output, concurrency 2, 16k decoder, 10s segment")
    }

    @Test("Seven mixed-rate channels, resampling and cached rerender")
    func resampling() async throws {
        let fixture = try await RenderEnvelopeTests.fixture(
            targets: [4, 3], targetRates: [44_100, 48_000], seconds: 10, label: "seven-mixed-rate"
        )
        try await profile(fixture, shape: "2 inputs × 4+3 channels, 44.1/48k inputs → 48k output, concurrency 2, 16k decoder, 2s segment")
    }

    private func profile(_ fixture: PipelineFixture, shape: String) async throws {
        let baseline = MemorySampler.now()
        let before = MemorySampler.maxResident()
        let sampler = MemorySampler()
        let sources = fixture.sources.filter { $0.id != fixture.id("ref") }
        let ids = Set(sources.map(\.id))
        let authorizations = fixture.authorizations.filter { ids.contains($0.source) }
        let first = try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID, sources: sources, authorizations: authorizations
        )
        let repeatRender = try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID, sources: sources, authorizations: authorizations
        )
        let sampled = sampler.stop()
        let maxRSS = MemorySampler.maxResident()
        #expect(first.isComplete && repeatRender.isComplete)
        #expect(first.groups.allSatisfy { $0.segmentsRendered > 0 })
        #expect(repeatRender.groups.allSatisfy { $0.segmentsReused == $0.segments })
        #expect(fixture.content.openReaders == 0)
        let gate = await fixture.pipeline.gate.snapshot
        print("""
        [render-envelope] shape: \(shape)
        [render-envelope] host: \(ProcessInfo.processInfo.hostName), bytes: baseline RSS \(baseline.resident), footprint \(baseline.footprint), ru_maxrss \(before)
        [render-envelope] sampled RSS \(sampled.resident), physical footprint \(sampled.footprint), ru_maxrss \(maxRSS), gate peak estimates \(gate.peakBytes), gate peak units \(gate.peakActive)
        [render-envelope] first segments \(first.groups.map(\.segmentsRendered)), repeated segments \(repeatRender.groups.map(\.segmentsReused))
        """)
        #expect(maxRSS <= 1_073_741_824)
        #expect(sampled.resident <= 1_073_741_824)
        #expect(sampled.footprint <= 1_073_741_824)
    }
}
